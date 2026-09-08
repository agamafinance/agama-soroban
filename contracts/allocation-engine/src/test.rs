#![cfg(test)]
use super::*;
use etherfuse::{EtherfuseAdapter, EtherfuseAdapterClient};
use mock_usdc::{MockUsdc, MockUsdcClient};
use private_credit::{PrivateCreditAdapter, PrivateCreditAdapterClient};
use soroban_sdk::testutils::Address as _;
use soroban_sdk::{contract, contractimpl, symbol_short, token::TokenClient, String};

const USDC: i128 = 10_000_000; // 1 USDC at 7 decimals
const FUNDING: i128 = 1_000 * USDC;

// Caps chosen so each one binds on its own in some scenario, which is the only
// way to prove all three are actually evaluated.
const POOL_CAP: u32 = 3_000; // 30%
const ORIGINATOR_CAP: u32 = 4_000; // 40%
const JURISDICTION_CAP: u32 = 5_000; // 50%
const RESERVE_FLOOR: u32 = 2_000; // 20%

/// Minimal stand-in for the Vault: it custodies the USDC and implements the two
/// calls the Engine makes. The real Vault has its own test suite; wiring it in
/// here would couple the two crates' fixtures together for no extra coverage of
/// the Engine's own logic.
#[contract]
pub struct MockVault;

#[contractimpl]
impl MockVault {
    pub fn initialize(e: Env, usdc: Address) {
        e.storage().instance().set(&symbol_short!("usdc"), &usdc);
    }

    pub fn idle_reserves(e: Env) -> i128 {
        TokenClient::new(&e, &Self::usdc(e.clone())).balance(&e.current_contract_address())
    }

    pub fn settle_allocation(e: Env, pool: Address, amount: i128) {
        TokenClient::new(&e, &Self::usdc(e.clone())).transfer(
            &e.current_contract_address(),
            &pool,
            &amount,
        );
    }

    fn usdc(e: Env) -> Address {
        e.storage().instance().get(&symbol_short!("usdc")).unwrap()
    }
}

struct Fix {
    e: Env,
    engine: AllocationEngineClient<'static>,
    usdc: MockUsdcClient<'static>,
    vault_id: Address,
    admin: Address,
    /// Private credit, originator QIRO, jurisdiction US.
    pool_a: Address,
    /// Private credit, same originator and jurisdiction as pool A.
    pool_b: Address,
    /// Etherfuse, different originator, same jurisdiction as pool A.
    pool_c: Address,
    adapter_a: PrivateCreditAdapterClient<'static>,
    adapter_c: EtherfuseAdapterClient<'static>,
}

fn setup() -> Fix {
    let e = Env::default();
    e.mock_all_auths();
    let admin = Address::generate(&e);

    let usdc_id = e.register(MockUsdc, ());
    let usdc = MockUsdcClient::new(&e, &usdc_id);
    usdc.initialize(
        &admin,
        &7u32,
        &String::from_str(&e, "USD Coin"),
        &String::from_str(&e, "USDC"),
    );

    let vault_id = e.register(MockVault, ());
    MockVaultClient::new(&e, &vault_id).initialize(&usdc_id);
    usdc.faucet(&vault_id, &FUNDING);

    let engine_id = e.register(AllocationEngine, ());
    let engine = AllocationEngineClient::new(&e, &engine_id);
    engine.initialize(&admin, &vault_id);

    // Two private credit pools fronted by the same originator, plus an
    // Etherfuse pool under the same jurisdiction as the first two. The Engine
    // routes to both adapter types through the identical interface.
    let pool_a = e.register(PrivateCreditAdapter, ());
    let adapter_a = PrivateCreditAdapterClient::new(&e, &pool_a);
    adapter_a.initialize(&admin, &engine_id, &vault_id, &usdc_id);

    let pool_b = e.register(PrivateCreditAdapter, ());
    PrivateCreditAdapterClient::new(&e, &pool_b).initialize(&admin, &engine_id, &vault_id, &usdc_id);

    let pool_c = e.register(EtherfuseAdapter, ());
    let adapter_c = EtherfuseAdapterClient::new(&e, &pool_c);
    adapter_c.initialize(&admin, &engine_id, &vault_id, &usdc_id);

    engine.register_pool(
        &admin,
        &pool_a,
        &symbol_short!("QIRO"),
        &symbol_short!("US"),
        &POOL_CAP,
    );
    engine.register_pool(
        &admin,
        &pool_b,
        &symbol_short!("QIRO"),
        &symbol_short!("US"),
        &POOL_CAP,
    );
    engine.register_pool(
        &admin,
        &pool_c,
        &symbol_short!("ETHERFUS"),
        &symbol_short!("US"),
        &POOL_CAP,
    );

    engine.set_caps(&admin, &POOL_CAP, &ORIGINATOR_CAP, &JURISDICTION_CAP);
    engine.set_reserve_floor(&admin, &RESERVE_FLOOR);

    Fix {
        e,
        engine,
        usdc,
        vault_id,
        admin,
        pool_a,
        pool_b,
        pool_c,
        adapter_a,
        adapter_c,
    }
}

/// Deploys and wires one more private credit adapter against the fixture, for
/// the cases that need a pool the fixture did not pre-register.
fn extra_private_credit_pool(f: &Fix) -> Address {
    let id = f.e.register(PrivateCreditAdapter, ());
    PrivateCreditAdapterClient::new(&f.e, &id).initialize(
        &f.admin,
        &f.engine.address,
        &f.vault_id,
        &f.usdc.address,
    );
    id
}

#[test]
fn allocation_succeeds_under_caps_and_settles_in_the_same_call() {
    let f = setup();
    // 200 of 1000: 20% of the book, under every cap, and it leaves 80% idle.
    f.engine.allocate(&f.admin, &f.pool_a, &(200 * USDC));

    assert_eq!(f.engine.get_exposure(&f.pool_a), 200 * USDC);
    assert_eq!(f.engine.total_allocated(), 200 * USDC);
    // The cash moved with the book: the Vault released it and the adapter
    // booked it, in the same transaction as the check.
    assert_eq!(f.usdc.balance(&f.vault_id), 800 * USDC);
    assert_eq!(f.usdc.balance(&f.pool_a), 200 * USDC);
    assert_eq!(f.adapter_a.get_exposure(), 200 * USDC);
    assert_eq!(f.engine.get_reserve_ratio(), 8_000);
}

#[test]
fn allocation_is_rejected_when_it_breaches_the_pool_cap() {
    let f = setup();
    // 35% into a single pool against a 30% cap.
    assert_eq!(
        f.engine.try_allocate(&f.admin, &f.pool_a, &(350 * USDC)),
        Err(Ok(EngineError::PoolCapExceeded))
    );
    // A rejected allocation books nothing and moves nothing.
    assert_eq!(f.engine.get_exposure(&f.pool_a), 0);
    assert_eq!(f.usdc.balance(&f.vault_id), FUNDING);
    assert_eq!(f.adapter_a.get_exposure(), 0);
}

#[test]
fn allocation_is_rejected_when_it_breaches_the_originator_cap() {
    let f = setup();
    // Both pools are fronted by QIRO. Each is inside its own 30% pool cap, and
    // together they would be 60% of the book against a 40% originator cap.
    f.engine.allocate(&f.admin, &f.pool_a, &(300 * USDC));
    assert_eq!(
        f.engine.try_allocate(&f.admin, &f.pool_b, &(300 * USDC)),
        Err(Ok(EngineError::OriginatorCapExceeded))
    );
    assert_eq!(f.engine.get_exposure(&f.pool_b), 0);
    assert_eq!(f.engine.total_allocated(), 300 * USDC);
}

#[test]
fn allocation_is_rejected_when_it_breaches_the_jurisdiction_cap() {
    let f = setup();
    // Different originators (QIRO and ETHERFUS, 30% each, both under the 40%
    // originator cap) and different pool types, but the same jurisdiction, so
    // 60% of the book would sit under one legal regime against a 50% cap.
    f.engine.allocate(&f.admin, &f.pool_a, &(300 * USDC));
    assert_eq!(
        f.engine.try_allocate(&f.admin, &f.pool_c, &(300 * USDC)),
        Err(Ok(EngineError::JurisdictionCapExceeded))
    );
    assert_eq!(f.engine.get_exposure(&f.pool_c), 0);
    assert_eq!(f.adapter_c.get_exposure(), 0);
}

#[test]
fn allocation_is_rejected_when_it_would_breach_the_reserve_floor() {
    let f = setup();
    // Raise the floor to 80%: this is the guard that replaces the removed
    // Blend liquidity buffer, so it has to bind even when every cap allows the
    // allocation.
    f.engine.set_reserve_floor(&f.admin, &8_000);

    // 300 is inside the 30% pool cap, the 40% originator cap and the 50%
    // jurisdiction cap, but it would leave the Vault at 70% idle.
    assert_eq!(
        f.engine.try_allocate(&f.admin, &f.pool_a, &(300 * USDC)),
        Err(Ok(EngineError::ReserveFloorBreached))
    );
    assert_eq!(f.usdc.balance(&f.vault_id), FUNDING);
    assert_eq!(f.engine.get_reserve_ratio(), 10_000);

    // 200 leaves exactly 80% idle, which is at the floor and therefore allowed.
    // Testing the boundary rather than only the failure catches an off-by-one
    // that would quietly eat into the reserve.
    f.engine.allocate(&f.admin, &f.pool_a, &(200 * USDC));
    assert_eq!(f.engine.get_reserve_ratio(), 8_000);

    // One more USDC now breaches it.
    assert_eq!(
        f.engine.try_allocate(&f.admin, &f.pool_a, &USDC),
        Err(Ok(EngineError::ReserveFloorBreached))
    );
}

#[test]
fn an_unconfigured_engine_cannot_deploy_capital() {
    let e = Env::default();
    e.mock_all_auths();
    let admin = Address::generate(&e);

    let usdc_id = e.register(MockUsdc, ());
    let usdc = MockUsdcClient::new(&e, &usdc_id);
    usdc.initialize(
        &admin,
        &7u32,
        &String::from_str(&e, "USD Coin"),
        &String::from_str(&e, "USDC"),
    );
    let vault_id = e.register(MockVault, ());
    MockVaultClient::new(&e, &vault_id).initialize(&usdc_id);
    usdc.faucet(&vault_id, &FUNDING);

    let engine_id = e.register(AllocationEngine, ());
    let engine = AllocationEngineClient::new(&e, &engine_id);
    engine.initialize(&admin, &vault_id);

    let pool = e.register(PrivateCreditAdapter, ());
    PrivateCreditAdapterClient::new(&e, &pool).initialize(&admin, &engine_id, &vault_id, &usdc_id);
    engine.register_pool(
        &admin,
        &pool,
        &symbol_short!("QIRO"),
        &symbol_short!("US"),
        &10_000u32,
    );

    // Caps default to zero and the floor to 100%, so even a single stroop
    // cannot leave the Vault until an admin has explicitly opened it up.
    assert_eq!(engine.caps().pool_bps, 0);
    assert_eq!(engine.reserve_floor_bps(), 10_000);
    assert_eq!(
        engine.try_allocate(&admin, &pool, &1),
        Err(Ok(EngineError::PoolCapExceeded))
    );
}

#[test]
fn the_global_pool_cap_tightens_a_generous_registry_entry() {
    let f = setup();
    // Register a pool with no limit of its own, then confirm the global cap
    // still binds: the effective limit is the tighter of the two.
    let pool_d = extra_private_credit_pool(&f);
    f.engine.register_pool(
        &f.admin,
        &pool_d,
        &symbol_short!("TENKA"),
        &symbol_short!("KY"),
        &10_000u32,
    );
    assert_eq!(f.engine.get_pool(&pool_d).cap_bps, 10_000);
    assert_eq!(
        f.engine.try_allocate(&f.admin, &pool_d, &(350 * USDC)),
        Err(Ok(EngineError::PoolCapExceeded))
    );
    f.engine.allocate(&f.admin, &pool_d, &(300 * USDC));
    assert_eq!(f.engine.get_exposure(&pool_d), 300 * USDC);
}

#[test]
fn the_exposure_map_reads_back_the_whole_book() {
    let f = setup();
    f.engine.allocate(&f.admin, &f.pool_a, &(250 * USDC));
    f.engine.allocate(&f.admin, &f.pool_c, &(200 * USDC));

    let exposures = f.engine.get_exposures();
    // Registered pools with no exposure are present as zero, so the map
    // doubles as the whitelist rather than only as the book.
    assert_eq!(exposures.len(), 3);
    assert_eq!(exposures.get(f.pool_a.clone()).unwrap(), 250 * USDC);
    assert_eq!(exposures.get(f.pool_b.clone()).unwrap(), 0);
    assert_eq!(exposures.get(f.pool_c.clone()).unwrap(), 200 * USDC);
    assert_eq!(f.engine.total_allocated(), 450 * USDC);
    assert_eq!(f.engine.get_reserve_ratio(), 5_500);
}

#[test]
fn deallocate_reduces_exposure_and_returns_the_cash() {
    let f = setup();
    f.engine.allocate(&f.admin, &f.pool_a, &(300 * USDC));
    assert_eq!(f.usdc.balance(&f.vault_id), 700 * USDC);

    f.engine.deallocate(&f.pool_a, &(120 * USDC));

    // The Engine's book, the adapter's book and the Vault's cash all move by
    // the same amount in the same call.
    assert_eq!(f.engine.get_exposure(&f.pool_a), 180 * USDC);
    assert_eq!(f.adapter_a.get_exposure(), 180 * USDC);
    assert_eq!(f.engine.total_allocated(), 180 * USDC);
    assert_eq!(f.usdc.balance(&f.vault_id), 820 * USDC);
    assert_eq!(f.engine.get_reserve_ratio(), 8_200);

    // Room freed by the repayment can be reallocated.
    f.engine.allocate(&f.admin, &f.pool_a, &(120 * USDC));
    assert_eq!(f.engine.get_exposure(&f.pool_a), 300 * USDC);
}

#[test]
fn deallocate_beyond_exposure_is_rejected() {
    let f = setup();
    f.engine.allocate(&f.admin, &f.pool_a, &(100 * USDC));
    assert_eq!(
        f.engine.try_deallocate(&f.pool_a, &(200 * USDC)),
        Err(Ok(EngineError::ExposureUnderflow))
    );
    assert_eq!(f.engine.get_exposure(&f.pool_a), 100 * USDC);
}

#[test]
fn allocation_beyond_available_reserves_is_rejected() {
    let f = setup();
    // With the floor and the caps out of the way, the Vault still cannot
    // release more USDC than it holds.
    f.engine.set_reserve_floor(&f.admin, &0u32);
    f.engine.set_caps(&f.admin, &10_000, &10_000, &10_000);
    let pool_d = extra_private_credit_pool(&f);
    f.engine.register_pool(
        &f.admin,
        &pool_d,
        &symbol_short!("TENKA"),
        &symbol_short!("KY"),
        &10_000u32,
    );
    assert_eq!(
        f.engine.try_allocate(&f.admin, &pool_d, &(1_500 * USDC)),
        Err(Ok(EngineError::InsufficientReserves))
    );
    // And it can release everything it does hold.
    f.engine.allocate(&f.admin, &pool_d, &FUNDING);
    assert_eq!(f.engine.get_reserve_ratio(), 0);
}

#[test]
fn non_positive_and_unregistered_allocations_are_rejected() {
    let f = setup();
    assert_eq!(
        f.engine.try_allocate(&f.admin, &f.pool_a, &0),
        Err(Ok(EngineError::InvalidAmount))
    );
    assert_eq!(
        f.engine.try_allocate(&f.admin, &f.pool_a, &(-100 * USDC)),
        Err(Ok(EngineError::InvalidAmount))
    );
    let stranger_pool = Address::generate(&f.e);
    assert_eq!(
        f.engine.try_allocate(&f.admin, &stranger_pool, &(10 * USDC)),
        Err(Ok(EngineError::PoolNotRegistered))
    );
}

#[test]
fn only_the_admin_directs_capital() {
    let f = setup();
    let stranger = Address::generate(&f.e);
    assert_eq!(
        f.engine.try_allocate(&stranger, &f.pool_a, &(10 * USDC)),
        Err(Ok(EngineError::NotAdmin))
    );
    assert_eq!(
        f.engine
            .try_register_pool(
                &stranger,
                &f.pool_a,
                &symbol_short!("X"),
                &symbol_short!("Y"),
                &1_000u32
            ),
        Err(Ok(EngineError::NotAdmin))
    );
    assert_eq!(
        f.engine.try_set_reserve_floor(&stranger, &0u32),
        Err(Ok(EngineError::NotAdmin))
    );
    // Which Vault the Engine can instruct to release USDC is the single most
    // consequential setting it has, so it is gated with the rest of them.
    assert_eq!(
        f.engine.try_set_vault(&stranger, &stranger),
        Err(Ok(EngineError::NotAdmin))
    );
    assert_eq!(f.engine.vault(), f.vault_id);
}

#[test]
fn the_vault_pointer_moves_while_the_book_is_empty() {
    let f = setup();
    // A replacement Vault, funded and wired the same way. This is the live
    // failure: the Engine was initialized against a Vault that has since been
    // superseded, and until it follows, every cap it enforces is measured on a
    // balance sheet nobody is depositing into any more.
    let replacement = f.e.register(MockVault, ());
    MockVaultClient::new(&f.e, &replacement).initialize(&f.usdc.address);
    f.usdc.faucet(&replacement, &FUNDING);

    f.engine.set_vault(&f.admin, &replacement);
    assert_eq!(f.engine.vault(), replacement);

    // Allocations now draw on the new Vault and leave the old one alone.
    f.engine.allocate(&f.admin, &f.pool_a, &(200 * USDC));
    assert_eq!(f.usdc.balance(&replacement), 800 * USDC);
    assert_eq!(f.usdc.balance(&f.vault_id), FUNDING);
    assert_eq!(f.engine.get_reserve_ratio(), 8_000);
}

#[test]
fn the_vault_pointer_is_frozen_while_capital_is_deployed() {
    let f = setup();
    f.engine.allocate(&f.admin, &f.pool_a, &(200 * USDC));

    // 200 USDC of the current Vault's money is booked here. Repointing now
    // would leave the caps measured against one Vault's assets and the
    // exposure funded by another's, which is a ratio of two unrelated numbers.
    let replacement = f.e.register(MockVault, ());
    MockVaultClient::new(&f.e, &replacement).initialize(&f.usdc.address);
    assert_eq!(
        f.engine.try_set_vault(&f.admin, &replacement),
        Err(Ok(EngineError::CapitalDeployed))
    );
    assert_eq!(f.engine.vault(), f.vault_id);

    // Unwound to zero, the two halves of the ratio can belong to the same book
    // again and the pointer opens.
    f.engine.deallocate(&f.pool_a, &(200 * USDC));
    assert_eq!(f.engine.total_allocated(), 0);
    f.engine.set_vault(&f.admin, &replacement);
    assert_eq!(f.engine.vault(), replacement);
}

#[test]
fn caps_and_floors_outside_the_bps_range_are_rejected() {
    let f = setup();
    assert_eq!(
        f.engine.try_set_caps(&f.admin, &10_001, &1_000, &1_000),
        Err(Ok(EngineError::InvalidCap))
    );
    assert_eq!(
        f.engine.try_set_reserve_floor(&f.admin, &10_001),
        Err(Ok(EngineError::InvalidCap))
    );
    // The previous configuration is untouched.
    assert_eq!(f.engine.caps().pool_bps, POOL_CAP);
    assert_eq!(f.engine.reserve_floor_bps(), RESERVE_FLOOR);
}

#[test]
fn a_pool_cannot_be_registered_twice() {
    let f = setup();
    assert_eq!(
        f.engine.try_register_pool(
            &f.admin,
            &f.pool_a,
            &symbol_short!("OTHER"),
            &symbol_short!("KY"),
            &10_000u32
        ),
        Err(Ok(EngineError::PoolAlreadyRegistered))
    );
    // Re-registering must not be a way to relabel a pool's originator and slip
    // out from under an originator cap.
    assert_eq!(f.engine.get_pool(&f.pool_a).originator, symbol_short!("QIRO"));
}

#[test]
fn cannot_be_reinitialized() {
    let f = setup();
    let attacker = Address::generate(&f.e);
    assert_eq!(
        f.engine.try_initialize(&attacker, &attacker),
        Err(Ok(EngineError::AlreadyInitialized))
    );
    assert_eq!(f.engine.admin(), f.admin);
    assert_eq!(f.engine.vault(), f.vault_id);
}
