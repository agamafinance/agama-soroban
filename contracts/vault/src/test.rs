#![cfg(test)]
use super::*;
use allocation_engine::{AllocationEngine, AllocationEngineClient};
use mock_usdc::{MockUsdc, MockUsdcClient};
use oracle_adapter::{OracleAdapter, OracleAdapterClient};
use private_credit::{PrivateCreditAdapter, PrivateCreditAdapterClient};
use soroban_sdk::testutils::{Address as _, Ledger as _};
use soroban_sdk::{symbol_short, String};

const USDC: i128 = 10_000_000; // 1 USDC at 7 decimals
const T0: u64 = 1_800_000_000;

struct Fix {
    e: Env,
    vault: VaultClient<'static>,
    usdc: MockUsdcClient<'static>,
    agusd: MockUsdcClient<'static>,
    engine: AllocationEngineClient<'static>,
    oracle: OracleAdapterClient<'static>,
    pool: Address,
    admin: Address,
    reporter: Address,
}

/// The whole stack: Vault, Allocation Engine, Oracle Adapter and one private
/// credit pool, wired together the way they are deployed. agUSD is stood in for
/// by a second SEP-41 token whose admin is the Vault, which is the mint and
/// burn authority the real agUSD grants the Vault contract.
fn setup() -> Fix {
    let e = Env::default();
    e.mock_all_auths();
    e.ledger().set_timestamp(T0);

    let admin = Address::generate(&e);
    let reporter = Address::generate(&e);

    let usdc_id = e.register(MockUsdc, ());
    let usdc = MockUsdcClient::new(&e, &usdc_id);
    usdc.initialize(
        &admin,
        &7u32,
        &String::from_str(&e, "USD Coin"),
        &String::from_str(&e, "USDC"),
    );

    let vault_id = e.register(Vault, ());
    let vault = VaultClient::new(&e, &vault_id);

    let agusd_id = e.register(MockUsdc, ());
    let agusd = MockUsdcClient::new(&e, &agusd_id);
    agusd.initialize(
        &vault_id,
        &7u32,
        &String::from_str(&e, "Agama USD"),
        &String::from_str(&e, "agUSD"),
    );

    let engine_id = e.register(AllocationEngine, ());
    let engine = AllocationEngineClient::new(&e, &engine_id);
    engine.initialize(&admin, &vault_id);

    vault.initialize(&admin, &usdc_id, &agusd_id, &engine_id);

    let oracle_id = e.register(OracleAdapter, ());
    let oracle = OracleAdapterClient::new(&e, &oracle_id);
    oracle.initialize(&admin);
    oracle.add_reporter(&admin, &reporter);
    oracle.register_feed(
        &admin,
        &oracle_adapter::FEED_PC_NAV,
        &oracle_adapter::PRIVATE_CREDIT_STALENESS,
        &oracle_adapter::PRIVATE_CREDIT_DEVIATION_BPS,
    );
    vault.set_oracle(&admin, &oracle_id, &oracle_adapter::FEED_PC_NAV);

    let pool = e.register(PrivateCreditAdapter, ());
    PrivateCreditAdapterClient::new(&e, &pool).initialize(&admin, &engine_id, &vault_id, &usdc_id);
    engine.register_pool(
        &admin,
        &pool,
        &symbol_short!("QIRO"),
        &symbol_short!("US"),
        &10_000u32,
    );
    // The caps and the reserve floor have their own suite in the Engine crate.
    // Here they are opened up so the Vault's queue can be tested against real
    // allocations rather than against a mock.
    engine.set_caps(&admin, &10_000, &10_000, &10_000);
    engine.set_reserve_floor(&admin, &0u32);

    Fix {
        e,
        vault,
        usdc,
        agusd,
        engine,
        oracle,
        pool,
        admin,
        reporter,
    }
}

/// Funds `who` with USDC and deposits it, returning the depositor.
fn depositor(f: &Fix, amount: i128) -> Address {
    let who = Address::generate(&f.e);
    f.usdc.faucet(&who, &amount);
    f.vault.deposit(&who, &amount);
    who
}

#[test]
fn deposit_mints_agusd_one_for_one() {
    let f = setup();
    let alice = Address::generate(&f.e);
    f.usdc.faucet(&alice, &(1_000 * USDC));

    assert_eq!(f.vault.deposit(&alice, &(400 * USDC)), 400 * USDC);
    assert_eq!(f.agusd.balance(&alice), 400 * USDC);
    assert_eq!(f.usdc.balance(&alice), 600 * USDC);
    assert_eq!(f.vault.idle_reserves(), 400 * USDC);
    assert_eq!(f.vault.get_total_assets(), 400 * USDC);
}

#[test]
fn full_deposit_request_claim_flow() {
    let f = setup();
    let alice = depositor(&f, 1_000 * USDC);

    let claim_id = f.vault.request_withdrawal(&alice, &(400 * USDC));
    assert_eq!(claim_id, 1); // ids start at 1 so that 0 is never valid
    // The agUSD is gone at request time, not at claim time.
    assert_eq!(f.agusd.balance(&alice), 600 * USDC);
    assert_eq!(f.vault.queue_length(), 1);
    assert_eq!(f.vault.claim_status(&claim_id), ClaimStatus::Ready);

    f.vault.claim_withdrawal(&alice, &claim_id);
    assert_eq!(f.usdc.balance(&alice), 400 * USDC);
    assert_eq!(f.vault.idle_reserves(), 600 * USDC);
    assert_eq!(f.vault.claim_status(&claim_id), ClaimStatus::Claimed);
    assert_eq!(f.vault.queue_head(), 2);
    assert_eq!(f.vault.queue_length(), 0);
}

#[test]
fn claims_are_paid_strictly_in_order() {
    let f = setup();
    let alice = depositor(&f, 1_000 * USDC);
    let bob = depositor(&f, 1_000 * USDC);
    let carol = depositor(&f, 1_000 * USDC);

    let a = f.vault.request_withdrawal(&alice, &(100 * USDC));
    let b = f.vault.request_withdrawal(&bob, &(200 * USDC));
    let c = f.vault.request_withdrawal(&carol, &(300 * USDC));
    assert_eq!((a, b, c), (1, 2, 3));

    // There is plenty of liquidity for all three, so the only thing stopping
    // Bob and Carol is their position in the queue.
    assert!(f.vault.idle_reserves() > 600 * USDC);
    assert_eq!(f.vault.claim_status(&b), ClaimStatus::Pending);
    assert_eq!(f.vault.claim_status(&c), ClaimStatus::Pending);
    assert_eq!(
        f.vault.try_claim_withdrawal(&carol, &c),
        Err(Ok(VaultError::NotAtQueueHead))
    );
    assert_eq!(
        f.vault.try_claim_withdrawal(&bob, &b),
        Err(Ok(VaultError::NotAtQueueHead))
    );

    f.vault.claim_withdrawal(&alice, &a);
    // Paying the head promotes exactly one claim, and only the next one.
    assert_eq!(f.vault.claim_status(&b), ClaimStatus::Ready);
    assert_eq!(f.vault.claim_status(&c), ClaimStatus::Pending);
    assert_eq!(
        f.vault.try_claim_withdrawal(&carol, &c),
        Err(Ok(VaultError::NotAtQueueHead))
    );

    f.vault.claim_withdrawal(&bob, &b);
    f.vault.claim_withdrawal(&carol, &c);
    assert_eq!(f.usdc.balance(&alice), 100 * USDC);
    assert_eq!(f.usdc.balance(&bob), 200 * USDC);
    assert_eq!(f.usdc.balance(&carol), 300 * USDC);
    assert_eq!(f.vault.queue_head(), 4);
}

#[test]
fn the_admin_cannot_jump_the_queue() {
    let f = setup();
    let alice = depositor(&f, 1_000 * USDC);
    f.usdc.faucet(&f.admin, &(1_000 * USDC));
    f.vault.deposit(&f.admin, &(1_000 * USDC));

    let alice_claim = f.vault.request_withdrawal(&alice, &(100 * USDC));
    let admin_claim = f.vault.request_withdrawal(&f.admin, &(100 * USDC));

    // Being the admin buys nothing: there is no privileged path through
    // claim_withdrawal, and no pause-and-reorder trick either.
    assert_eq!(
        f.vault.try_claim_withdrawal(&f.admin, &admin_claim),
        Err(Ok(VaultError::NotAtQueueHead))
    );
    f.vault.set_paused(&f.admin, &true);
    assert_eq!(
        f.vault.try_claim_withdrawal(&f.admin, &admin_claim),
        Err(Ok(VaultError::Paused))
    );
    f.vault.set_paused(&f.admin, &false);

    f.vault.claim_withdrawal(&alice, &alice_claim);
    f.vault.claim_withdrawal(&f.admin, &admin_claim);
}

#[test]
fn a_claim_can_only_be_taken_by_its_owner_and_only_once() {
    let f = setup();
    let alice = depositor(&f, 1_000 * USDC);
    let mallory = Address::generate(&f.e);

    let claim_id = f.vault.request_withdrawal(&alice, &(100 * USDC));
    assert_eq!(
        f.vault.try_claim_withdrawal(&mallory, &claim_id),
        Err(Ok(VaultError::NotClaimOwner))
    );

    f.vault.claim_withdrawal(&alice, &claim_id);
    assert_eq!(
        f.vault.try_claim_withdrawal(&alice, &claim_id),
        Err(Ok(VaultError::AlreadyClaimed))
    );
    assert_eq!(f.usdc.balance(&alice), 100 * USDC);

    assert_eq!(
        f.vault.try_claim_withdrawal(&alice, &999u64),
        Err(Ok(VaultError::ClaimNotFound))
    );
}

#[test]
fn pausing_blocks_deposits_and_withdrawals() {
    let f = setup();
    let alice = depositor(&f, 1_000 * USDC);
    let claim_id = f.vault.request_withdrawal(&alice, &(100 * USDC));

    f.vault.set_paused(&f.admin, &true);
    assert!(f.vault.paused());

    f.usdc.faucet(&alice, &(100 * USDC));
    assert_eq!(
        f.vault.try_deposit(&alice, &(100 * USDC)),
        Err(Ok(VaultError::Paused))
    );
    assert_eq!(
        f.vault.try_request_withdrawal(&alice, &(100 * USDC)),
        Err(Ok(VaultError::Paused))
    );
    assert_eq!(
        f.vault.try_claim_withdrawal(&alice, &claim_id),
        Err(Ok(VaultError::Paused))
    );
    // New allocations stop too: an emergency stop that keeps deploying capital
    // into pools is not a stop. The Engine's checks pass, and the Vault
    // refuses the release, so the whole allocation reverts.
    assert!(f.engine.try_allocate(&f.admin, &f.pool, &(100 * USDC)).is_err());
    assert_eq!(f.engine.get_exposure(&f.pool), 0);

    // Reads keep working while paused, so operators can still see the book.
    assert_eq!(f.vault.claim_status(&claim_id), ClaimStatus::Ready);
    assert!(f.vault.get_total_assets() > 0);

    f.vault.set_paused(&f.admin, &false);
    let before = f.usdc.balance(&alice);
    f.vault.claim_withdrawal(&alice, &claim_id);
    assert_eq!(f.usdc.balance(&alice), before + 100 * USDC);
}

#[test]
fn zero_and_negative_amounts_are_rejected() {
    let f = setup();
    let alice = depositor(&f, 1_000 * USDC);

    assert_eq!(
        f.vault.try_deposit(&alice, &0),
        Err(Ok(VaultError::InvalidAmount))
    );
    assert_eq!(
        f.vault.try_deposit(&alice, &(-100 * USDC)),
        Err(Ok(VaultError::InvalidAmount))
    );
    assert_eq!(
        f.vault.try_request_withdrawal(&alice, &0),
        Err(Ok(VaultError::InvalidAmount))
    );
    assert_eq!(
        f.vault.try_request_withdrawal(&alice, &(-100 * USDC)),
        Err(Ok(VaultError::InvalidAmount))
    );
    // Nothing was queued by any of those.
    assert_eq!(f.vault.queue_tail(), 1);
}

#[test]
fn withdrawals_below_the_dust_floor_are_rejected() {
    let f = setup();
    let alice = depositor(&f, 1_000 * USDC);

    assert_eq!(
        f.vault.try_request_withdrawal(&alice, &(MIN_WITHDRAWAL - 1)),
        Err(Ok(VaultError::BelowMinWithdrawal))
    );
    // Exactly at the floor is fine: the guard is a minimum, not a step.
    let claim_id = f.vault.request_withdrawal(&alice, &MIN_WITHDRAWAL);
    assert_eq!(f.vault.get_claim(&claim_id).amount, MIN_WITHDRAWAL);
}

#[test]
fn a_claim_beyond_idle_reserves_reports_a_liquidity_problem() {
    let f = setup();
    let alice = depositor(&f, 1_000 * USDC);

    // Put 900 to work in the pool, leaving 100 idle.
    f.engine.allocate(&f.admin, &f.pool, &(900 * USDC));
    assert_eq!(f.vault.idle_reserves(), 100 * USDC);
    assert_eq!(f.vault.get_total_assets(), 1_000 * USDC);

    let claim_id = f.vault.request_withdrawal(&alice, &(500 * USDC));
    // At the head of the queue and still unpayable: the error names the real
    // problem, which is capital, not sequencing.
    assert_eq!(f.vault.queue_head(), claim_id);
    assert_eq!(f.vault.claim_status(&claim_id), ClaimStatus::Pending);
    assert_eq!(
        f.vault.try_claim_withdrawal(&alice, &claim_id),
        Err(Ok(VaultError::InsufficientLiquidity))
    );

    // The pool repays, and the same claim becomes payable with no other action.
    f.engine.deallocate(&f.pool, &(600 * USDC));
    assert_eq!(f.vault.claim_status(&claim_id), ClaimStatus::Ready);
    f.vault.claim_withdrawal(&alice, &claim_id);
    assert_eq!(f.usdc.balance(&alice), 500 * USDC);
}

#[test]
fn total_assets_count_idle_reserves_plus_deployed_capital() {
    let f = setup();
    depositor(&f, 1_000 * USDC);
    assert_eq!(f.vault.get_total_assets(), 1_000 * USDC);

    f.engine.allocate(&f.admin, &f.pool, &(700 * USDC));
    // Allocating moves value between the two components without changing the
    // total, which is what makes total assets a safe denominator for the caps.
    assert_eq!(f.vault.idle_reserves(), 300 * USDC);
    assert_eq!(f.engine.total_allocated(), 700 * USDC);
    assert_eq!(f.vault.get_total_assets(), 1_000 * USDC);
}

#[test]
fn get_nav_reads_the_oracle_and_propagates_staleness() {
    let f = setup();
    let nav = 1_000 * USDC;
    f.oracle
        .push_nav(&f.reporter, &oracle_adapter::FEED_PC_NAV, &nav, &T0);
    assert_eq!(f.vault.get_nav(), nav);

    // Past the feed's 7 day window the Vault does not fall back to the last
    // number it saw: the adapter's staleness error propagates through.
    f.e.ledger()
        .set_timestamp(T0 + oracle_adapter::PRIVATE_CREDIT_STALENESS + 1);
    assert!(f.vault.try_get_nav().is_err());
}

#[test]
fn get_nav_before_the_oracle_is_wired_says_so() {
    let e = Env::default();
    e.mock_all_auths();
    let admin = Address::generate(&e);
    let other = Address::generate(&e);

    let vault_id = e.register(Vault, ());
    let vault = VaultClient::new(&e, &vault_id);
    vault.initialize(&admin, &other, &other, &other);

    // No made up default: an unwired oracle is reported as one.
    assert_eq!(
        vault.try_get_nav(),
        Err(Ok(VaultError::OracleNotConfigured))
    );
}

#[test]
fn only_the_allocation_engine_can_release_funds() {
    let f = setup();
    depositor(&f, 1_000 * USDC);
    let mallory = Address::generate(&f.e);

    // Drop the blanket auth mock: without the Engine's authorization the Vault
    // will not release capital to anyone.
    f.e.mock_auths(&[]);
    assert!(f
        .vault
        .try_settle_allocation(&mallory, &(100 * USDC))
        .is_err());
    assert_eq!(f.vault.idle_reserves(), 1_000 * USDC);
}

#[test]
fn cannot_be_reinitialized() {
    let f = setup();
    let attacker = Address::generate(&f.e);
    // The attack this blocks is repointing agusd_token at a contract the
    // caller controls and minting against the Vault's reserves.
    assert_eq!(
        f.vault
            .try_initialize(&attacker, &attacker, &attacker, &attacker),
        Err(Ok(VaultError::AlreadyInitialized))
    );
    assert_eq!(f.vault.admin(), f.admin);
    assert_eq!(f.vault.agusd(), f.agusd.address);
}

#[test]
fn only_the_admin_can_pause_or_rewire() {
    let f = setup();
    let stranger = Address::generate(&f.e);
    assert_eq!(
        f.vault.try_set_paused(&stranger, &true),
        Err(Ok(VaultError::NotAdmin))
    );
    assert_eq!(
        f.vault
            .try_set_oracle(&stranger, &stranger, &symbol_short!("FAKE")),
        Err(Ok(VaultError::NotAdmin))
    );
    assert!(!f.vault.paused());
}
