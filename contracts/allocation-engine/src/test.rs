#![cfg(test)]
use super::*;
use etherfuse::{EtherfuseAdapter, EtherfuseAdapterClient};
use mock_usdc::{MockUsdc, MockUsdcClient};
use private_credit::{PrivateCreditAdapter, PrivateCreditAdapterClient};
use soroban_sdk::testutils::{Address as _, MockAuth, MockAuthInvoke};
use soroban_sdk::{
    contract, contractimpl, symbol_short, token::TokenClient, IntoVal, InvokeError, String,
};

const USDC: i128 = 10_000_000; // 1 USDC at 7 decimals
const FUNDING: i128 = 1_000 * USDC;

// Caps chosen so each one binds on its own in some scenario, which is the only
// way to prove all three are actually evaluated. Three pools share a
// jurisdiction here and two share an originator, which is what makes the
// aggregate caps reachable in a fixture this small.
const POOL_CAP: u32 = 3_000; // 30%
const ORIGINATOR_CAP: u32 = 4_000; // 40%
const JURISDICTION_CAP: u32 = 5_000; // 50%
const RESERVE_FLOOR: u32 = 2_000; // 20%

// The limits the testnet deployment actually runs with, on two pools with one
// originator and one jurisdiction each. They live here so the arithmetic that
// makes the reserve floor reachable is checked by the test suite rather than
// asserted in a deploy script.
const DEPLOYED_POOL_CAP: u32 = 4_000; // 40% in any single pool
const DEPLOYED_ORIGINATOR_CAP: u32 = 4_500; // 45% behind any single originator
const DEPLOYED_JURISDICTION_CAP: u32 = 5_000; // 50% under any single legal regime
const DEPLOYED_RESERVE_FLOOR: u32 = 2_500; // 25% stays as idle USDC

/// Minimal stand-in for the Vault: it custodies the USDC and implements the
/// calls the Engine makes. The real Vault has its own test suite, and its own
/// copy of the reserve floor; this one enforces nothing, so a limit that holds
/// here is a limit the Engine is enforcing by itself.
///
/// `queued` stands in for the Vault's withdrawal liabilities so the Engine's
/// use of free rather than gross reserves can be exercised without dragging the
/// whole queue in.
#[contract]
pub struct MockVault;

#[contractimpl]
impl MockVault {
    pub fn initialize(e: Env, admin: Address, usdc: Address) {
        e.storage().instance().set(&symbol_short!("admin"), &admin);
        e.storage().instance().set(&symbol_short!("usdc"), &usdc);
    }

    /// The Engine's constructor and `set_vault` both require the Vault to name
    /// the same admin the Engine is being given, and `write_down` reads it
    /// again before it asks the Vault to record the loss.
    pub fn admin(e: Env) -> Address {
        e.storage().instance().get(&symbol_short!("admin")).unwrap()
    }

    pub fn idle_reserves(e: Env) -> i128 {
        TokenClient::new(&e, &Self::usdc(e.clone())).balance(&e.current_contract_address())
    }

    /// What the withdrawal queue is owed, which is not deployable.
    pub fn set_queued(e: Env, amount: i128) {
        e.storage().instance().set(&symbol_short!("queued"), &amount);
    }

    pub fn free_reserves(e: Env) -> i128 {
        let queued: i128 = e
            .storage()
            .instance()
            .get(&symbol_short!("queued"))
            .unwrap_or(0);
        let free = Self::idle_reserves(e) - queued;
        if free < 0 {
            0
        } else {
            free
        }
    }

    pub fn settle_allocation(e: Env, pool: Address, amount: i128) {
        TokenClient::new(&e, &Self::usdc(e.clone())).transfer(
            &e.current_contract_address(),
            &pool,
            &amount,
        );
    }

    /// The real Vault verifies the cash arrived. This one records the call so
    /// the tests can assert the Engine makes it.
    pub fn record_repayment(e: Env, amount: i128) {
        let seen: i128 = e
            .storage()
            .instance()
            .get(&symbol_short!("repaid"))
            .unwrap_or(0);
        e.storage()
            .instance()
            .set(&symbol_short!("repaid"), &(seen + amount));
    }

    pub fn repaid(e: Env) -> i128 {
        e.storage()
            .instance()
            .get(&symbol_short!("repaid"))
            .unwrap_or(0)
    }

    pub fn record_writedown(e: Env, admin: Address, amount: i128) {
        // The real Vault compares this against its own stored admin and refuses
        // a stranger, so the mock does too. Without that, a test of the
        // Engine's admin alignment check would pass whether the check existed
        // or not, which is the opposite of what it is for.
        if admin != Self::admin(e.clone()) {
            panic!("not the vault admin");
        }
        admin.require_auth();
        let seen: i128 = e
            .storage()
            .instance()
            .get(&symbol_short!("written"))
            .unwrap_or(0);
        e.storage()
            .instance()
            .set(&symbol_short!("written"), &(seen + amount));
    }

    pub fn written_down(e: Env) -> i128 {
        e.storage()
            .instance()
            .get(&symbol_short!("written"))
            .unwrap_or(0)
    }

    /// The Vault leg of `recover`. The real one verifies the cash reached its
    /// own balance before it believes a stroop of it; that check has its own
    /// test in the Vault crate, and what is under test here is that the Engine
    /// makes the call with the right admin and the right amount.
    pub fn record_recovery(e: Env, admin: Address, amount: i128) {
        if admin != Self::admin(e.clone()) {
            panic!("not the vault admin");
        }
        admin.require_auth();
        let seen: i128 = e
            .storage()
            .instance()
            .get(&symbol_short!("recov"))
            .unwrap_or(0);
        e.storage()
            .instance()
            .set(&symbol_short!("recov"), &(seen + amount));
    }

    pub fn recovered(e: Env) -> i128 {
        e.storage()
            .instance()
            .get(&symbol_short!("recov"))
            .unwrap_or(0)
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
    MockVaultClient::new(&e, &vault_id).initialize(&admin, &usdc_id);
    usdc.faucet(&vault_id, &FUNDING);

    let engine_id = e.register(AllocationEngine, (admin.clone(), vault_id.clone()));
    let engine = AllocationEngineClient::new(&e, &engine_id);

    // Two private credit pools fronted by the same originator, plus an
    // Etherfuse pool under the same jurisdiction as the first two. The Engine
    // routes to both adapter types through the identical interface.
    let pool_a = e.register(
        PrivateCreditAdapter,
        (
            admin.clone(),
            engine_id.clone(),
            vault_id.clone(),
            usdc_id.clone(),
        ),
    );
    let adapter_a = PrivateCreditAdapterClient::new(&e, &pool_a);

    let pool_b = e.register(
        PrivateCreditAdapter,
        (
            admin.clone(),
            engine_id.clone(),
            vault_id.clone(),
            usdc_id.clone(),
        ),
    );

    let pool_c = e.register(
        EtherfuseAdapter,
        (
            admin.clone(),
            engine_id.clone(),
            vault_id.clone(),
            usdc_id.clone(),
        ),
    );
    let adapter_c = EtherfuseAdapterClient::new(&e, &pool_c);

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
    f.e.register(
        PrivateCreditAdapter,
        (
            f.admin.clone(),
            f.engine.address.clone(),
            f.vault_id.clone(),
            f.usdc.address.clone(),
        ),
    )
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
    MockVaultClient::new(&e, &vault_id).initialize(&admin, &usdc_id);
    usdc.faucet(&vault_id, &FUNDING);

    let engine_id = e.register(AllocationEngine, (admin.clone(), vault_id.clone()));
    let engine = AllocationEngineClient::new(&e, &engine_id);

    let pool = e.register(
        PrivateCreditAdapter,
        (
            admin.clone(),
            engine_id.clone(),
            vault_id.clone(),
            usdc_id.clone(),
        ),
    );
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
    MockVaultClient::new(&f.e, &replacement).initialize(&f.admin, &f.usdc.address);
    f.usdc.faucet(&replacement, &FUNDING);

    f.engine.set_vault(&f.admin, &replacement);
    assert_eq!(f.engine.vault(), replacement);

    // The adapters have to follow, and until they do the Engine will not fund
    // them: they still repay the Vault it has just stopped governing. This
    // assertion used to be an allocation succeeding, which is the whole of the
    // third review's High finding.
    f.adapter_a
        .set_counterparties(&f.admin, &f.engine.address, &replacement);

    // Allocations now draw on the new Vault and leave the old one alone.
    f.engine.allocate(&f.admin, &f.pool_a, &(200 * USDC));
    assert_eq!(f.usdc.balance(&replacement), 800 * USDC);
    assert_eq!(f.usdc.balance(&f.vault_id), FUNDING);
    assert_eq!(f.engine.get_reserve_ratio(), 8_000);
}

/// The third review's High finding. `register_pool` proves an adapter names
/// this Engine and this Engine's Vault, and `set_vault` moves the second half
/// of that out from under every entry already in the registry.
///
/// Before the fix this test's first allocation succeeded: the replacement
/// Vault's USDC went to an adapter that repays the superseded one, and the
/// capital could never come home, because `deallocate` sends the cash to the
/// old Vault and asks the new one to confirm it arrived.
#[test]
fn an_adapter_left_behind_by_a_vault_repoint_cannot_be_funded_or_settled() {
    let f = setup();
    f.engine.allocate(&f.admin, &f.pool_a, &(200 * USDC));
    f.engine.deallocate(&f.pool_a, &(200 * USDC));

    let replacement = f.e.register(MockVault, ());
    MockVaultClient::new(&f.e, &replacement).initialize(&f.admin, &f.usdc.address);
    f.usdc.faucet(&replacement, &FUNDING);
    f.engine.set_vault(&f.admin, &replacement);

    // pool_a is still registered and still names the old Vault. Every other
    // gate lets it through: it is whitelisted, the amount is inside all three
    // caps and inside the reserve floor, and the adapter would accept the call
    // because its Engine pointer is the one thing that did not move.
    assert_eq!(f.adapter_a.vault(), f.vault_id);
    assert_eq!(f.adapter_a.engine(), f.engine.address);
    assert_eq!(
        f.engine.try_allocate(&f.admin, &f.pool_a, &(200 * USDC)),
        Err(Ok(EngineError::AdapterMismatch)),
        "the new Vault's money must not go to an adapter that repays the old one"
    );
    // Refused, and nothing moved: no exposure, no cash, on either Vault.
    assert_eq!(f.engine.get_exposure(&f.pool_a), 0);
    assert_eq!(f.engine.total_allocated(), 0);
    assert_eq!(f.usdc.balance(&replacement), FUNDING);
    assert_eq!(f.usdc.balance(&f.pool_a), 0);
    assert_eq!(f.adapter_a.get_exposure(), 0);

    // The other two directions are closed the same way, so a stale adapter
    // cannot settle a book against the wrong Vault's balance either.
    assert_eq!(
        f.engine.try_deallocate(&f.pool_a, &(1 * USDC)),
        Err(Ok(EngineError::AdapterMismatch))
    );
    f.usdc.faucet(&f.pool_a, &(5 * USDC));
    assert_eq!(
        f.engine.try_recover(&f.admin, &f.pool_a),
        Err(Ok(EngineError::AdapterMismatch)),
        "and a sweep must not send the surplus to a Vault this Engine does not govern"
    );
    assert_eq!(f.usdc.balance(&f.pool_a), 5 * USDC, "the sweep moved nothing");

    // Bringing the adapter across is what opens it again, which is the repair
    // path `set_counterparties` exists for and the one an operator should be
    // pushed towards by the refusal above.
    f.adapter_c
        .set_counterparties(&f.admin, &f.engine.address, &replacement);
    f.engine.allocate(&f.admin, &f.pool_c, &(200 * USDC));
    assert_eq!(f.engine.get_exposure(&f.pool_c), 200 * USDC);
    assert_eq!(f.usdc.balance(&replacement), 800 * USDC);
}

#[test]
fn the_vault_pointer_is_frozen_while_capital_is_deployed() {
    let f = setup();
    f.engine.allocate(&f.admin, &f.pool_a, &(200 * USDC));

    // 200 USDC of the current Vault's money is booked here. Repointing now
    // would leave the caps measured against one Vault's assets and the
    // exposure funded by another's, which is a ratio of two unrelated numbers.
    let replacement = f.e.register(MockVault, ());
    MockVaultClient::new(&f.e, &replacement).initialize(&f.admin, &f.usdc.address);
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
fn the_deployed_limits_leave_the_reserve_floor_able_to_bind() {
    // The configuration this Engine is deployed with, on the two pools it is
    // deployed with: private credit fronted by Qiro through a Luxembourg SPV,
    // and tokenized Mexican government debt through Etherfuse. One originator
    // and one jurisdiction each, so neither aggregate cap is reachable and the
    // per-pool cap is the tightest concentration limit in play.
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
    MockVaultClient::new(&e, &vault_id).initialize(&admin, &usdc_id);
    usdc.faucet(&vault_id, &FUNDING);

    let engine_id = e.register(AllocationEngine, (admin.clone(), vault_id.clone()));
    let engine = AllocationEngineClient::new(&e, &engine_id);

    let pc = e.register(
        PrivateCreditAdapter,
        (
            admin.clone(),
            engine_id.clone(),
            vault_id.clone(),
            usdc_id.clone(),
        ),
    );
    let ef = e.register(
        EtherfuseAdapter,
        (
            admin.clone(),
            engine_id.clone(),
            vault_id.clone(),
            usdc_id.clone(),
        ),
    );

    engine.register_pool(
        &admin,
        &pc,
        &symbol_short!("QIRO"),
        &symbol_short!("LU"),
        &DEPLOYED_POOL_CAP,
    );
    engine.register_pool(
        &admin,
        &ef,
        &symbol_short!("ETHERFUS"),
        &symbol_short!("MX"),
        &DEPLOYED_POOL_CAP,
    );
    engine.set_caps(
        &admin,
        &DEPLOYED_POOL_CAP,
        &DEPLOYED_ORIGINATOR_CAP,
        &DEPLOYED_JURISDICTION_CAP,
    );
    engine.set_reserve_floor(&admin, &DEPLOYED_RESERVE_FLOOR);

    // The property the previous configuration did not have. Two pools capped
    // at 30% each could deploy at most 60% of the book, so a 20% floor was
    // arithmetically unreachable: 40% stayed idle whatever the operator did
    // and the pool cap fired first every time. Here the pools can absorb 80%
    // and the floor will only release 75%, so the last 5% belongs to the floor
    // alone.
    assert!(2 * DEPLOYED_POOL_CAP > 10_000 - DEPLOYED_RESERVE_FLOOR);

    // Fill the book the way an operator would. 40% into private credit is
    // exactly its cap and leaves 60% idle.
    engine.allocate(&admin, &pc, &(400 * USDC));
    assert_eq!(engine.get_reserve_ratio(), 6_000);
    // 35% into Etherfuse brings idle reserves to the floor, to the stroop.
    engine.allocate(&admin, &ef, &(350 * USDC));
    assert_eq!(engine.get_reserve_ratio(), DEPLOYED_RESERVE_FLOOR);

    // Now the state this configuration exists to produce. 5% more into
    // Etherfuse would take it to 40%: inside its own cap, inside the global
    // pool cap, inside the originator cap and inside the jurisdiction cap.
    // Every concentration limit says yes and the allocation is still refused,
    // because the floor is what is left.
    assert_eq!(
        engine.try_allocate(&admin, &ef, &(50 * USDC)),
        Err(Ok(EngineError::ReserveFloorBreached))
    );
    assert_eq!(engine.get_exposure(&ef), 350 * USDC);
    assert_eq!(usdc.balance(&vault_id), 250 * USDC);

    // And it is the floor, not something else wearing its error code: drop the
    // floor and the identical call goes through.
    engine.set_reserve_floor(&admin, &2_000);
    engine.allocate(&admin, &ef, &(50 * USDC));
    assert_eq!(engine.get_exposure(&ef), 400 * USDC);
    assert_eq!(engine.get_reserve_ratio(), 2_000);

    // The pool cap has not stopped binding for the sake of it. One more stroop
    // into either pool is refused by the concentration limit, not by the floor.
    engine.set_reserve_floor(&admin, &0);
    assert_eq!(
        engine.try_allocate(&admin, &ef, &(1 * USDC)),
        Err(Ok(EngineError::PoolCapExceeded))
    );
    assert_eq!(
        engine.try_allocate(&admin, &pc, &(1 * USDC)),
        Err(Ok(EngineError::PoolCapExceeded))
    );
}

/// An adapter takes instructions from the Engine it stores and repays the Vault
/// it stores, and neither of those has to be the pair registering it.
///
/// Registered without the check, an adapter pointed at somebody else's Vault
/// takes capital from this one and sends the repayment to a third party, while
/// `deallocate` here decrements the book as though the money had come home.
/// Nothing reverts, and the exposure reads as settled while the cash is gone.
#[test]
fn a_pool_that_does_not_name_this_engine_and_this_vault_cannot_be_registered() {
    let f = setup();

    // Right Vault, wrong Engine: this adapter answers to somebody else, so
    // allocate and deallocate from here would simply be refused, and the
    // Engine's book would be a fiction from the first call.
    let other_engine = f.e.register(AllocationEngine, (f.admin.clone(), f.vault_id.clone()));
    let foreign_engine_pool = f.e.register(
        PrivateCreditAdapter,
        (
            f.admin.clone(),
            other_engine.clone(),
            f.vault_id.clone(),
            f.usdc.address.clone(),
        ),
    );
    assert_eq!(
        f.engine.try_register_pool(
            &f.admin,
            &foreign_engine_pool,
            &symbol_short!("QIRO"),
            &symbol_short!("US"),
            &POOL_CAP,
        ),
        Err(Ok(EngineError::AdapterMismatch))
    );

    // Right Engine, wrong Vault: the dangerous one. Allocation works, the book
    // is correct, and the repayment goes somewhere else.
    //
    // The adapter's own constructor and `set_counterparties` both refuse to
    // create that pairing, so the way it arises in practice is drift: an
    // adapter wired correctly and then left behind when the Engine follows the
    // Vault to a new generation. That is what is built here, with `set_vault`
    // standing in for the generation change, and the pointers are put back
    // afterwards so the rest of the fixture still describes itself.
    let other_vault = f.e.register(MockVault, ());
    MockVaultClient::new(&f.e, &other_vault).initialize(&f.admin, &f.usdc.address);
    let foreign_vault_pool = f.e.register(
        PrivateCreditAdapter,
        (
            f.admin.clone(),
            f.engine.address.clone(),
            f.vault_id.clone(),
            f.usdc.address.clone(),
        ),
    );
    f.engine.set_vault(&f.admin, &other_vault);
    assert_eq!(f.engine.vault(), other_vault);
    assert_eq!(
        f.engine.try_register_pool(
            &f.admin,
            &foreign_vault_pool,
            &symbol_short!("QIRO"),
            &symbol_short!("US"),
            &POOL_CAP,
        ),
        Err(Ok(EngineError::AdapterMismatch))
    );
    f.engine.set_vault(&f.admin, &f.vault_id);

    // An address that is not an adapter at all fails the same way rather than
    // being registered and failing later, in an allocation.
    assert_eq!(
        f.engine.try_register_pool(
            &f.admin,
            &Address::generate(&f.e),
            &symbol_short!("QIRO"),
            &symbol_short!("US"),
            &POOL_CAP,
        ),
        Err(Ok(EngineError::AdapterMismatch))
    );

    // Neither of them is on the whitelist, so neither can take a dollar.
    assert_eq!(f.engine.pools().len(), 3);
}

/// A credit loss could not be recognised at all.
///
/// `total_allocated` moved only through `allocate` and `deallocate`, and
/// `deallocate` transfers real USDC before it decrements the book. A defaulted
/// originator leaves the adapter holding nothing, so the transfer panics, the
/// exposure reports full face value forever, and every reserve ratio derived
/// from it is overstated by exactly the size of the loss.
#[test]
fn a_default_can_be_written_down_and_the_reserve_ratio_stops_lying() {
    let f = setup();
    f.engine.allocate(&f.admin, &f.pool_a, &(200 * USDC));
    assert_eq!(f.engine.get_reserve_ratio(), 8_000);

    // The originator defaults: the adapter holds no USDC, so the honest exit
    // is not available. Before the write-down existed, this was the end of it.
    f.usdc.burn(&f.pool_a, &(200 * USDC));
    assert!(f.engine.try_deallocate(&f.pool_a, &(200 * USDC)).is_err());
    assert_eq!(f.engine.get_exposure(&f.pool_a), 200 * USDC);
    assert_eq!(f.engine.get_reserve_ratio(), 8_000); // 800 idle over 1000 that no longer exists

    // Recognise half of it. Four books move together: this Engine's exposure,
    // the adapter's own, the Vault's deployed capital, and the cumulative
    // write-off that keeps the loss in the floor's denominator.
    f.engine.write_down(
        &f.admin,
        &f.pool_a,
        &(100 * USDC),
        &symbol_short!("DEFAULT"),
    );
    assert_eq!(f.engine.get_exposure(&f.pool_a), 100 * USDC);
    assert_eq!(f.engine.total_allocated(), 100 * USDC);
    assert_eq!(f.adapter_a.get_exposure(), 100 * USDC);
    assert_eq!(MockVaultClient::new(&f.e, &f.vault_id).written_down(), 100 * USDC);
    assert_eq!(f.engine.written_off(), 100 * USDC);
    // 800 idle over a base of 1000, which is still 8000 bps.
    //
    // The base does not move, and that is the point. This assertion used to
    // read 8888, on the reasoning that 800 over 900 was "now the truth", and it
    // was the wrong truth twice over. A liquidity ratio that goes *up* when the
    // book loses money is telling the operator the opposite of what happened,
    // and the same arithmetic underneath `allocate` meant every recognised loss
    // handed back releasable headroom worth a quarter of itself.
    assert_eq!(f.engine.floor_base(), 1_000 * USDC);
    assert_eq!(f.engine.get_reserve_ratio(), 8_000);

    // And the rest, which takes the exposure to zero without a stroop moving.
    f.engine.write_down(
        &f.admin,
        &f.pool_a,
        &(100 * USDC),
        &symbol_short!("DEFAULT"),
    );
    assert_eq!(f.engine.get_exposure(&f.pool_a), 0);
    assert_eq!(f.engine.total_allocated(), 0);
    assert_eq!(f.engine.written_off(), 200 * USDC);
    // The whole position is gone and the ratio has still not moved: no cash
    // left the Vault, so no liquidity was gained or lost.
    assert_eq!(f.engine.floor_base(), 1_000 * USDC);
    assert_eq!(f.engine.get_reserve_ratio(), 8_000);

    // It cannot write off more than is booked, and it is not a second
    // deallocation path: nothing was transferred anywhere.
    assert_eq!(
        f.engine
            .try_write_down(&f.admin, &f.pool_a, &(1 * USDC), &symbol_short!("DEFAULT")),
        Err(Ok(EngineError::WriteDownExceedsExposure))
    );
    assert_eq!(f.usdc.balance(&f.vault_id), 800 * USDC);
}

/// Only the admin can recognise a loss. A write-down is the one movement of the
/// book that is not backed by cash, so the identity of whoever authorizes it is
/// the entire control.
///
/// Checked with a targeted authorization rather than the fixture's blanket
/// mock, which turns authorization off wholesale.
#[test]
fn only_the_admin_can_write_down_an_exposure() {
    let f = setup();
    f.engine.allocate(&f.admin, &f.pool_a, &(200 * USDC));
    let stranger = Address::generate(&f.e);

    f.e.mock_auths(&[MockAuth {
        address: &stranger,
        invoke: &MockAuthInvoke {
            contract: &f.engine.address,
            fn_name: "write_down",
            args: (
                stranger.clone(),
                f.pool_a.clone(),
                200 * USDC,
                symbol_short!("DEFAULT"),
            )
                .into_val(&f.e),
            sub_invokes: &[],
        },
    }]);
    assert_eq!(
        f.engine
            .try_write_down(&stranger, &f.pool_a, &(200 * USDC), &symbol_short!("DEFAULT")),
        Err(Ok(EngineError::NotAdmin))
    );

    // Naming the admin without the admin's signature fails on authorization.
    f.e.mock_auths(&[MockAuth {
        address: &stranger,
        invoke: &MockAuthInvoke {
            contract: &f.engine.address,
            fn_name: "write_down",
            args: (
                f.admin.clone(),
                f.pool_a.clone(),
                200 * USDC,
                symbol_short!("DEFAULT"),
            )
                .into_val(&f.e),
            sub_invokes: &[],
        },
    }]);
    assert!(f
        .engine
        .try_write_down(&f.admin, &f.pool_a, &(200 * USDC), &symbol_short!("DEFAULT"))
        .is_err());
    assert_eq!(f.engine.get_exposure(&f.pool_a), 200 * USDC);
}

/// The floor and the caps are measured against free reserves and net assets,
/// so USDC the Vault already owes a queued withdrawal is not deployable and is
/// not in the denominator either.
#[test]
fn queued_withdrawals_are_subtracted_before_the_caps_and_the_floor() {
    let f = setup();
    let vault = MockVaultClient::new(&f.e, &f.vault_id);
    // 400 of the 1000 the Vault holds is owed to the withdrawal queue.
    vault.set_queued(&(400 * USDC));
    assert_eq!(vault.free_reserves(), 600 * USDC);

    // Every limit now reads 600, not 1000. The 20% floor releases 480 of it,
    // and the 30% pool cap allows 180: against the gross balance the same call
    // would have been allowed 300.
    assert_eq!(f.engine.get_reserve_ratio(), 10_000);
    assert_eq!(
        f.engine.try_allocate(&f.admin, &f.pool_a, &(200 * USDC)),
        Err(Ok(EngineError::PoolCapExceeded))
    );
    f.engine.allocate(&f.admin, &f.pool_a, &(180 * USDC));
    assert_eq!(f.engine.get_reserve_ratio(), 7_000); // 420 free over 600 net

    // And the queue keeps its money: 420 free plus 400 queued is the 820 the
    // Vault is holding.
    assert_eq!(f.usdc.balance(&f.vault_id), 820 * USDC);
}

/// Deallocation tells the Vault, and the real Vault checks the cash arrived
/// before it believes it. Without that call the Engine's book comes down and
/// the Vault's does not.
#[test]
fn deallocation_reports_the_repayment_to_the_vault() {
    let f = setup();
    let vault = MockVaultClient::new(&f.e, &f.vault_id);
    f.engine.allocate(&f.admin, &f.pool_a, &(200 * USDC));
    assert_eq!(vault.repaid(), 0);

    f.engine.deallocate(&f.pool_a, &(120 * USDC));
    assert_eq!(vault.repaid(), 120 * USDC);
    assert_eq!(f.engine.get_exposure(&f.pool_a), 80 * USDC);
}

/// Admin rotation, in the two steps that make it safe: a proposal that changes
/// nothing, and an acceptance signed by the address it hands the role to. An
/// unreachable key can therefore never be handed the role, which is the
/// unrecoverable state a one call setter would create in one transaction.
#[test]
fn the_admin_role_moves_only_to_an_address_that_signs_for_it() {
    let f = setup();
    let successor = Address::generate(&f.e);
    let mallory = Address::generate(&f.e);
    assert_eq!(f.engine.pending_admin(), None);

    // A stranger cannot propose.
    assert_eq!(
        f.engine.try_propose_admin(&mallory, &mallory),
        Err(Ok(EngineError::NotAdmin))
    );

    // The admin proposes and nothing moves yet.
    f.engine.propose_admin(&f.admin, &successor);
    assert_eq!(f.engine.pending_admin(), Some(successor.clone()));
    assert_eq!(f.engine.admin(), f.admin);

    // Only the proposed address can accept, and it has to sign for itself.
    assert_eq!(
        f.engine.try_accept_admin(&mallory),
        Err(Ok(EngineError::NotPendingAdmin))
    );
    f.e.mock_auths(&[MockAuth {
        address: &mallory,
        invoke: &MockAuthInvoke {
            contract: &f.engine.address,
            fn_name: "accept_admin",
            args: (successor.clone(),).into_val(&f.e),
            sub_invokes: &[],
        },
    }]);
    assert!(f.engine.try_accept_admin(&successor).is_err());
    assert_eq!(f.engine.admin(), f.admin);

    f.e.mock_all_auths();
    f.engine.accept_admin(&successor);
    assert_eq!(f.engine.admin(), successor);
    assert_eq!(f.engine.pending_admin(), None);
    assert_eq!(
        f.engine.try_accept_admin(&successor),
        Err(Ok(EngineError::NoPendingAdmin))
    );
}

/// The Engine's own copy of the reserve floor does not reopen when a position
/// is written off.
///
/// The floor used to be a share of total assets, and `write_down` lowers total
/// assets with no cash moving, so every write-off handed back releasable
/// headroom worth `floor_bps` of itself. Allocate to the floor, write the
/// position off, allocate to the new floor: the loop converges on emptying the
/// Vault, and every individual call passes the check.
///
/// `written_off` is the denominator term that closes it. It never falls, so the
/// base is invariant under a write-down exactly as it is under an allocation,
/// and that is what makes the floor hold across calls rather than within one.
///
/// This is the Engine half of the property. The Vault enforces it a second time
/// on its own numbers, and its crate has the same test against the real
/// contract; this one runs against the mock Vault, which enforces nothing, so a
/// limit that holds here is a limit this Engine is holding by itself.
#[test]
fn a_write_down_does_not_reopen_the_engines_reserve_floor() {
    let f = setup();
    // Open every concentration cap on a pool of its own, so the floor is the
    // only limit under test and a refusal cannot be a cap wearing its name.
    let pool = extra_private_credit_pool(&f);
    f.engine.register_pool(
        &f.admin,
        &pool,
        &symbol_short!("SOLO"),
        &symbol_short!("LU"),
        &10_000,
    );
    f.engine.set_caps(&f.admin, &10_000, &10_000, &10_000);
    f.engine.set_reserve_floor(&f.admin, &2_000);

    // Allocate everything the floor will release, and confirm it is binding.
    f.engine.allocate(&f.admin, &pool, &(800 * USDC));
    assert_eq!(f.engine.get_reserve_ratio(), 2_000);
    assert_eq!(
        f.engine.try_allocate(&f.admin, &pool, &1),
        Err(Ok(EngineError::ReserveFloorBreached))
    );

    // Write the whole position off. Nothing moves: the adapter still holds it.
    f.engine
        .write_down(&f.admin, &pool, &(800 * USDC), &symbol_short!("DEFAULT"));
    assert_eq!(f.engine.total_allocated(), 0);
    assert_eq!(f.engine.written_off(), 800 * USDC);
    assert_eq!(f.usdc.balance(&pool), 800 * USDC);

    // The base has not moved, so the floor has not moved either.
    assert_eq!(f.engine.floor_base(), 1_000 * USDC);
    assert_eq!(f.engine.get_reserve_ratio(), 2_000);

    // Everything from here runs against a second pool of its own, with its own
    // originator and its own jurisdiction, and the reason is the other half of
    // the same fix. A write-off is now charged against the pool it happened at
    // for as long as it stands, so the written-off pool is over its own cap and
    // a refusal there would be the concentration limit rather than the floor.
    // The floor is a limit on the whole book, so the honest way to ask whether
    // a write-down reopened it is to ask somewhere the write-down is not
    // already answering.
    let clean = extra_private_credit_pool(&f);
    f.engine.register_pool(
        &f.admin,
        &clean,
        &symbol_short!("SOLO2"),
        &symbol_short!("MX"),
        &10_000,
    );
    assert_eq!(f.engine.charged_exposure(&clean), 0);
    assert_eq!(
        f.engine.try_allocate(&f.admin, &clean, &1),
        Err(Ok(EngineError::ReserveFloorBreached))
    );

    // Run the loop it used to fall to, and watch the reserves stay put.
    for _ in 0..40 {
        let free = f.usdc.balance(&f.vault_id);
        if free <= 0 {
            break;
        }
        let mut take = free;
        while take > 0 && f.engine.try_allocate(&f.admin, &clean, &take).is_err() {
            take = take * 9 / 10;
        }
        if take == 0 {
            break;
        }
        f.engine
            .write_down(&f.admin, &clean, &take, &symbol_short!("DEFAULT"));
    }
    assert_eq!(
        f.usdc.balance(&f.vault_id),
        200 * USDC,
        "the 20% floor has to survive write-downs, not only allocations"
    );
}

// ---------------------------------------------------------------------------
// The second review's Medium findings.
// ---------------------------------------------------------------------------

/// M1. Filling a pool to its cap and writing the position off used to hand the
/// cap straight back, because a cap was measured on live exposure and a
/// write-down sets live exposure to zero while the adapter goes on holding
/// every dollar. Nothing about the concentration had changed; only the number
/// the limit was read from had.
#[test]
fn a_write_down_does_not_reopen_the_pool_cap() {
    let f = setup();
    // 30% of a 1000 USDC book.
    let cap = 300 * USDC;
    f.engine.allocate(&f.admin, &f.pool_a, &cap);
    assert_eq!(
        f.engine.try_allocate(&f.admin, &f.pool_a, &1),
        Err(Ok(EngineError::PoolCapExceeded)),
        "the pool is full before the write-down, which is the state under test"
    );

    f.engine
        .write_down(&f.admin, &f.pool_a, &cap, &symbol_short!("DEFAULT"));

    // Everything the old code looked at says the pool is empty.
    assert_eq!(f.engine.get_exposure(&f.pool_a), 0);
    assert_eq!(f.engine.total_allocated(), 0);
    // And the adapter is still holding every dollar of it, which is why the
    // concentration is exactly what it was a moment ago.
    assert_eq!(f.usdc.balance(&f.pool_a), cap);

    assert_eq!(
        f.engine.try_allocate(&f.admin, &f.pool_a, &1),
        Err(Ok(EngineError::PoolCapExceeded)),
        "a write-down must not buy back a cap any more than it buys back a floor"
    );
    assert_eq!(f.engine.charged_exposure(&f.pool_a), cap);
    assert_eq!(f.engine.written_off_pool(&f.pool_a), cap);
}

/// M1, the aggregate half. The originator and jurisdiction caps are built from
/// the same per-pool numbers, so a write-down at one pool used to release the
/// counterparty's whole limit and the legal regime's with it. That is the part
/// that matters most: the point of an originator cap is that several pools
/// fronted by one counterparty count as one position.
#[test]
fn a_write_down_keeps_charging_the_originator_and_the_jurisdiction() {
    let f = setup();
    // pool_a and pool_b are both fronted by QIRO; pool_c is a different
    // originator under the same jurisdiction as both.
    f.engine.allocate(&f.admin, &f.pool_a, &(300 * USDC));
    f.engine
        .write_down(&f.admin, &f.pool_a, &(300 * USDC), &symbol_short!("DEFAULT"));

    // QIRO is still 300 USDC deep through pool_a, so the 40% originator cap,
    // now 40% of the 700 USDC that is left, has 280 of room and 300 against it.
    assert_eq!(
        f.engine.try_allocate(&f.admin, &f.pool_b, &(100 * USDC)),
        Err(Ok(EngineError::OriginatorCapExceeded)),
        "a second pool fronted by the defaulted originator must not be refunded"
    );

    // The US book is 300 deep too, against a 50% jurisdiction cap on 700.
    assert_eq!(
        f.engine.try_allocate(&f.admin, &f.pool_c, &(100 * USDC)),
        Err(Ok(EngineError::JurisdictionCapExceeded)),
        "and neither must the jurisdiction the loss happened in"
    );
    // 50 USDC is inside what is left of the jurisdiction cap, so the refusal
    // above is the limit binding rather than the pool being closed outright.
    f.engine.allocate(&f.admin, &f.pool_c, &(50 * USDC));
}

/// M2. Capital written down to zero used to have no way out of the adapter:
/// `deallocate` is capped at booked exposure and there was none, and
/// `set_counterparties` refuses an adapter holding USDC, so a single stroop of
/// it closed the only repair path the contract had. Three generations of the
/// private credit adapter were retired over exactly this.
#[test]
fn recover_brings_written_down_capital_home_and_releases_the_charge() {
    let f = setup();
    let lost = 300 * USDC;
    f.engine.allocate(&f.admin, &f.pool_a, &lost);
    f.engine
        .write_down(&f.admin, &f.pool_a, &lost, &symbol_short!("DEFAULT"));

    // The state the finding describes, asserted rather than assumed.
    assert_eq!(f.engine.get_exposure(&f.pool_a), 0);
    assert_eq!(f.usdc.balance(&f.pool_a), lost);
    assert_eq!(
        f.engine.try_deallocate(&f.pool_a, &lost),
        Err(Ok(EngineError::ExposureUnderflow)),
        "deallocate cannot reach it, which is the whole of the finding"
    );
    assert_eq!(
        f.adapter_a
            .try_set_counterparties(&f.admin, &f.engine.address, &f.vault_id),
        Err(Ok(private_credit::AdapterError::NotEmpty)),
        "and the cash blocks the repair path as well as being stuck itself"
    );

    let vault_before = f.usdc.balance(&f.vault_id);
    let admin_before = f.usdc.balance(&f.admin);
    assert_eq!(f.engine.recover(&f.admin, &f.pool_a), lost);

    // It went to the Vault, and it went there because the destination is the
    // adapter's stored Vault rather than anything a caller supplies.
    assert_eq!(f.usdc.balance(&f.pool_a), 0);
    assert_eq!(f.usdc.balance(&f.vault_id), vault_before + lost);
    assert_eq!(
        f.usdc.balance(&f.admin),
        admin_before,
        "there is no path from here to the caller's own balance"
    );
    assert_eq!(MockVaultClient::new(&f.e, &f.vault_id).recovered(), lost);

    // The loss is released on both books, and with it the pool's cap charge.
    assert_eq!(f.engine.written_off(), 0);
    assert_eq!(f.engine.written_off_pool(&f.pool_a), 0);
    assert_eq!(f.engine.charged_exposure(&f.pool_a), 0);

    // A loss that did not happen stops consuming the limit, so the pool can be
    // funded again. That is the release valve on the finding above, and it is
    // the only one that does not require somebody to decide something.
    f.engine.allocate(&f.admin, &f.pool_a, &(300 * USDC));

    // And the repair path the stranded cash was blocking works again.
    assert_eq!(
        f.adapter_a
            .try_set_counterparties(&f.admin, &f.engine.address, &f.vault_id),
        Err(Ok(private_credit::AdapterError::NotEmpty)),
        "still refused, but now because the adapter has a live position rather than a dead one"
    );
}

/// M2, the surplus case. Interest paid above principal was stranded for the
/// same reason as a recovery, without any write-down being involved at all:
/// `deallocate` is capped at the exposure, so anything above it stayed.
#[test]
fn recover_moves_surplus_over_principal_even_with_no_loss_on_the_books() {
    let f = setup();
    f.engine.allocate(&f.admin, &f.pool_a, &(100 * USDC));
    // The originator pays 10 USDC of interest into the adapter.
    f.usdc.faucet(&f.pool_a, &(10 * USDC));

    let vault_before = f.usdc.balance(&f.vault_id);
    assert_eq!(f.engine.written_off(), 0);
    assert_eq!(f.engine.recover(&f.admin, &f.pool_a), 10 * USDC);
    assert_eq!(f.usdc.balance(&f.vault_id), vault_before + 10 * USDC);

    // The position is untouched and still fully funded, which is why the amount
    // is the surplus over the exposure rather than the balance.
    assert_eq!(f.engine.get_exposure(&f.pool_a), 100 * USDC);
    assert_eq!(f.usdc.balance(&f.pool_a), 100 * USDC);
    f.engine.deallocate(&f.pool_a, &(100 * USDC));
    assert_eq!(f.engine.get_exposure(&f.pool_a), 0);
}

/// M4. `write_down` needs one signature that satisfies this Engine's admin and
/// the Vault's, and the two roles rotate independently. Rotating one and not
/// the other leaves loss recognition impossible, which is the safe direction to
/// fail in and was not a discoverable one: the call trapped on the Vault's own
/// NotAdmin several frames down, and nothing reported the divergence in
/// advance.
#[test]
fn a_half_finished_admin_rotation_refuses_by_name() {
    let f = setup();
    f.engine.allocate(&f.admin, &f.pool_a, &(100 * USDC));
    assert!(f.engine.admin_aligned());
    assert_eq!(f.engine.vault_admin(), f.admin);

    // Rotate the Engine's admin and leave the Vault's where it is.
    let successor = Address::generate(&f.e);
    f.engine.propose_admin(&f.admin, &successor);
    f.engine.accept_admin(&successor);
    assert_eq!(f.engine.admin(), successor);

    assert!(
        !f.engine.admin_aligned(),
        "the divergence has to be readable before an incident, not during one"
    );
    assert_eq!(
        f.engine
            .try_write_down(&successor, &f.pool_a, &(1 * USDC), &symbol_short!("DEFAULT")),
        Err(Ok(EngineError::AdminMismatch)),
        "a named refusal from the contract that knows why, not a trap from the one that does not"
    );
    assert_eq!(
        f.engine.try_recover(&successor, &f.pool_a),
        Err(Ok(EngineError::AdminMismatch)),
        "recover needs the same pair of signatures and fails the same way"
    );
    // The old admin is not this Engine's admin any more either, so there is no
    // key that works while the rotation is half finished.
    assert_eq!(
        f.engine
            .try_write_down(&f.admin, &f.pool_a, &(1 * USDC), &symbol_short!("DEFAULT")),
        Err(Ok(EngineError::NotAdmin))
    );

    // Finish the rotation the other way and loss recognition comes back.
    f.engine.propose_admin(&successor, &f.admin);
    f.engine.accept_admin(&f.admin);
    assert!(f.engine.admin_aligned());
    f.engine
        .write_down(&f.admin, &f.pool_a, &(1 * USDC), &symbol_short!("DEFAULT"));
}

/// M5. `initialize` took the Vault on trust while `set_vault` interrogated it,
/// so the one call that created the wiring was the one call that checked none
/// of it. The constructor runs the check instead, and it runs it inside the
/// deploy transaction, which is also what closes the window an `initialize`
/// left open between deploying a contract and wiring it.
#[test]
#[should_panic(expected = "#419")]
fn the_constructor_refuses_a_vault_that_is_not_one() {
    let e = Env::default();
    e.mock_all_auths();
    let admin = Address::generate(&e);
    // An ordinary account cannot answer `admin()`, so it cannot be a Vault.
    let not_a_vault = Address::generate(&e);
    e.register(AllocationEngine, (admin, not_a_vault));
}

/// M5, the other half of the same asymmetry: an Engine whose Vault names a
/// different admin can never recognise a loss, because `write_down` needs one
/// signature that satisfies both. Refusing that wiring at deploy time is
/// cheaper than discovering it during a default.
#[test]
#[should_panic(expected = "#419")]
fn the_constructor_refuses_a_vault_with_a_different_admin() {
    let e = Env::default();
    e.mock_all_auths();
    let admin = Address::generate(&e);
    let stranger = Address::generate(&e);

    let usdc_id = e.register(MockUsdc, ());
    MockUsdcClient::new(&e, &usdc_id).initialize(
        &admin,
        &7u32,
        &String::from_str(&e, "USD Coin"),
        &String::from_str(&e, "USDC"),
    );
    let vault_id = e.register(MockVault, ());
    MockVaultClient::new(&e, &vault_id).initialize(&stranger, &usdc_id);

    e.register(AllocationEngine, (admin, vault_id));
}

/// M5. The repair path has to refuse what the constructor refuses, or the
/// constructor's check is one transaction away from being undone.
#[test]
fn set_vault_refuses_exactly_what_the_constructor_refuses() {
    let f = setup();
    assert_eq!(
        f.engine.try_set_vault(&f.admin, &Address::generate(&f.e)),
        Err(Ok(EngineError::VaultMismatch)),
        "an ordinary account cannot answer admin(), so it cannot be a Vault"
    );

    let stranger = Address::generate(&f.e);
    let other_vault = f.e.register(MockVault, ());
    MockVaultClient::new(&f.e, &other_vault).initialize(&stranger, &f.usdc.address);
    assert_eq!(
        f.engine.try_set_vault(&f.admin, &other_vault),
        Err(Ok(EngineError::VaultMismatch)),
        "and a real Vault under a different admin is the state M4 describes"
    );

    // A Vault that answers correctly is accepted, so the check is a check and
    // not a wall.
    let good_vault = f.e.register(MockVault, ());
    MockVaultClient::new(&f.e, &good_vault).initialize(&f.admin, &f.usdc.address);
    f.engine.set_vault(&f.admin, &good_vault);
    assert_eq!(f.engine.vault(), good_vault);
}

/// M1 of the third review, as the state it strands and the call that unstrands
/// it.
///
/// The adapter's `recover_surplus` may be taken by the adapter's own admin as
/// well as by the Engine. That fallback exists so that an adapter stuck to
/// superseded counterparties can be unstuck without a working Engine, and taken
/// that way it is described as the conservative direction: the cash reaches the
/// Vault and no book moves. What it does not say is that the books can then
/// never move at all. The surplus is gone, so `recover` reverts on the way in
/// and `record_recovery` has no other caller, and the write-down the sweep was
/// going to release is charged against the pool's cap and sitting in the
/// reserve floor's base for good.
#[test]
fn a_surplus_swept_by_the_adapter_admin_can_still_be_booked() {
    let f = setup();
    let vault = MockVaultClient::new(&f.e, &f.vault_id);
    f.engine.allocate(&f.admin, &f.pool_a, &(300 * USDC));
    f.engine.write_down(
        &f.admin,
        &f.pool_a,
        &(300 * USDC),
        &symbol_short!("DEFAULT"),
    );

    // The position is written off on all three books and the adapter is still
    // holding every dollar of it, which is what makes the whole balance a
    // surplus.
    assert_eq!(f.engine.written_off_pool(&f.pool_a), 300 * USDC);
    assert_eq!(f.engine.written_off(), 300 * USDC);
    assert_eq!(f.usdc.balance(&f.pool_a), 300 * USDC);

    // The adapter admin takes the fallback. The cash goes to the Vault, which
    // is the whole of what it promises.
    f.adapter_a.recover_surplus(&f.admin);
    assert_eq!(f.usdc.balance(&f.pool_a), 0);

    // And now the ordinary path is closed, permanently: there is no surplus
    // left for the Engine to sweep, so `recover` cannot reach the Vault leg at
    // all. Before `book_recovery` this was the end of it.
    // 611 is the adapter's own `NothingToRecover`, arriving as a sub-call
    // error rather than an Engine one because `recover` calls the adapter
    // without `try_`: there is no amount to pass on, so there is nothing for
    // the Engine to decide about.
    assert_eq!(
        f.engine.try_recover(&f.admin, &f.pool_a),
        Err(Err(InvokeError::Contract(611)))
    );
    assert_eq!(f.engine.written_off_pool(&f.pool_a), 300 * USDC);

    // The booking on its own, against cash the Vault already holds.
    f.engine.book_recovery(&f.admin, &f.pool_a, &(300 * USDC));

    assert_eq!(vault.recovered(), 300 * USDC);
    assert_eq!(f.engine.written_off_pool(&f.pool_a), 0);
    assert_eq!(f.engine.written_off(), 0);

    // The pool's cap is released with its charge, which is the point of
    // releasing it: a loss that did not happen stops consuming a limit.
    f.engine.allocate(&f.admin, &f.pool_a, &(300 * USDC));
    assert_eq!(f.engine.get_exposure(&f.pool_a), 300 * USDC);
}

/// A recovery booked directly and a recovery swept through the adapter leave
/// the Engine in states that cannot be told apart. That is the property that
/// makes the new entry point a second door onto the same room rather than a
/// second room.
#[test]
fn a_booked_recovery_and_a_swept_one_land_in_the_same_place() {
    let swept = {
        let f = setup();
        f.engine.allocate(&f.admin, &f.pool_a, &(300 * USDC));
        f.engine.write_down(
            &f.admin,
            &f.pool_a,
            &(300 * USDC),
            &symbol_short!("DEFAULT"),
        );
        f.engine.recover(&f.admin, &f.pool_a);
        (
            f.engine.written_off(),
            f.engine.written_off_pool(&f.pool_a),
            f.engine.total_allocated(),
            MockVaultClient::new(&f.e, &f.vault_id).recovered(),
        )
    };

    let booked = {
        let f = setup();
        f.engine.allocate(&f.admin, &f.pool_a, &(300 * USDC));
        f.engine.write_down(
            &f.admin,
            &f.pool_a,
            &(300 * USDC),
            &symbol_short!("DEFAULT"),
        );
        f.adapter_a.recover_surplus(&f.admin);
        f.engine.book_recovery(&f.admin, &f.pool_a, &(300 * USDC));
        (
            f.engine.written_off(),
            f.engine.written_off_pool(&f.pool_a),
            f.engine.total_allocated(),
            MockVaultClient::new(&f.e, &f.vault_id).recovered(),
        )
    };

    assert_eq!(swept, booked);
}

/// Surplus above the losses on the book is not an error and must not release
/// more cap than the pool was ever charged. Interest paid over principal was
/// never written off, so there is nothing of the pool's for it to give back.
#[test]
fn a_booked_recovery_releases_no_more_than_the_pool_was_charged() {
    let f = setup();
    // Both pools are fronted by the same originator, so the pair has to stay
    // inside the originator cap as well as their own.
    f.engine.allocate(&f.admin, &f.pool_a, &(250 * USDC));
    f.engine.allocate(&f.admin, &f.pool_b, &(100 * USDC));
    f.engine.write_down(
        &f.admin,
        &f.pool_a,
        &(100 * USDC),
        &symbol_short!("DEFAULT"),
    );
    f.engine.write_down(
        &f.admin,
        &f.pool_b,
        &(100 * USDC),
        &symbol_short!("DEFAULT"),
    );
    assert_eq!(f.engine.written_off(), 200 * USDC);

    // 150 against a pool charged 100. The pool gives back its 100 and not a
    // stroop of pool B's, while the global total takes the whole 150, which is
    // the Vault's own rule for `recognised_losses` and is why the two stay
    // equal.
    f.engine.book_recovery(&f.admin, &f.pool_a, &(150 * USDC));
    assert_eq!(f.engine.written_off_pool(&f.pool_a), 0);
    assert_eq!(f.engine.written_off_pool(&f.pool_b), 100 * USDC);
    assert_eq!(f.engine.written_off(), 50 * USDC);
}

/// The new entry point moves `recognised_losses`, which is a term in the
/// reserve floor's base, so it is gated exactly as `recover` is: this Engine's
/// admin, and the Vault's admin, which have to be the same address for the
/// Vault leg to be signable at all.
#[test]
fn only_the_admin_can_book_a_recovery() {
    let f = setup();
    let stranger = Address::generate(&f.e);
    f.engine.allocate(&f.admin, &f.pool_a, &(300 * USDC));
    f.engine.write_down(
        &f.admin,
        &f.pool_a,
        &(300 * USDC),
        &symbol_short!("DEFAULT"),
    );
    f.adapter_a.recover_surplus(&f.admin);

    assert_eq!(
        f.engine
            .try_book_recovery(&stranger, &f.pool_a, &(300 * USDC)),
        Err(Ok(EngineError::NotAdmin))
    );
    assert_eq!(
        f.engine.try_book_recovery(&f.admin, &f.pool_c, &0i128),
        Err(Ok(EngineError::InvalidAmount))
    );
    let unregistered = extra_private_credit_pool(&f);
    assert_eq!(
        f.engine
            .try_book_recovery(&f.admin, &unregistered, &USDC),
        Err(Ok(EngineError::PoolNotRegistered))
    );
    assert_eq!(f.engine.written_off_pool(&f.pool_a), 300 * USDC);
}

/// M3 of the third review, re-derived and refused.
///
/// The finding said an originator repaying the Vault directly leaves the
/// adapter with nothing to transfer, so `deallocate` panics and the position
/// reports face value forever. The premise does not hold for these adapters,
/// and this test is here to keep it not holding. USDC leaves an adapter by
/// exactly two doors, `deallocate`, which lowers the exposure by what it sends,
/// and `recover_surplus`, which sends only what is above the exposure and so
/// stops at equality. Nothing else can move it, in particular nothing can pay
/// it out to an originator. So `balance >= exposure` from a start of zero and
/// zero, and `deallocate` is always funded for what it owes.
///
/// The day this contract set grows a disbursement path, that stops being true
/// and this test is what says so, which is the reason to write it down as an
/// invariant rather than as a note. There is no `book_repayment` because there
/// is no state that needs one.
#[test]
fn an_adapter_can_never_hold_less_usdc_than_it_has_booked() {
    let f = setup();
    let check = |f: &Fix| {
        assert!(f.usdc.balance(&f.pool_a) >= f.adapter_a.get_exposure());
        assert!(f.usdc.balance(&f.pool_c) >= f.adapter_c.get_exposure());
    };

    check(&f);
    f.engine.allocate(&f.admin, &f.pool_a, &(250 * USDC));
    f.engine.allocate(&f.admin, &f.pool_c, &(150 * USDC));
    check(&f);
    f.engine.deallocate(&f.pool_a, &(120 * USDC));
    check(&f);
    f.engine
        .write_down(&f.admin, &f.pool_a, &(80 * USDC), &symbol_short!("DEFAULT"));
    check(&f);
    f.engine.recover(&f.admin, &f.pool_a);
    check(&f);
    // The adapter admin's fallback sweep, taken on a position with nothing
    // written off, moves the balance down to the exposure and stops there.
    f.usdc.faucet(&f.pool_c, &(10 * USDC));
    check(&f);
    f.adapter_c.recover_surplus(&f.admin);
    check(&f);

    // A donation only ever widens the gap, so it cannot break the invariant
    // either, and the surplus it creates is sweepable rather than stuck.
    f.usdc.faucet(&f.pool_a, &(50 * USDC));
    check(&f);
    f.engine.recover(&f.admin, &f.pool_a);
    check(&f);

    // The whole remaining position comes home, which is the property the
    // invariant exists to guarantee: `deallocate` is never short.
    f.engine
        .deallocate(&f.pool_a, &f.engine.get_exposure(&f.pool_a));
    assert_eq!(f.engine.get_exposure(&f.pool_a), 0);
    check(&f);
}
