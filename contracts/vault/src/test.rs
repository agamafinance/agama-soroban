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
fn a_third_party_can_settle_the_head_claim_for_its_owner() {
    let f = setup();
    let alice = depositor(&f, 1_000 * USDC);
    let stranger = Address::generate(&f.e);

    let claim_id = f.vault.request_withdrawal(&alice, &(400 * USDC));
    assert_eq!(f.vault.claim_status(&claim_id), ClaimStatus::Ready);

    // Alice never comes back. A stranger settles the claim instead, and the
    // money still lands with Alice, not with whoever called.
    let settled = f.vault.settle_withdrawal();
    assert_eq!(settled, claim_id);
    assert_eq!(f.usdc.balance(&alice), 400 * USDC);
    assert_eq!(f.usdc.balance(&stranger), 0);
    assert_eq!(f.vault.claim_status(&claim_id), ClaimStatus::Claimed);
    assert_eq!(f.vault.queue_head(), claim_id + 1);
}

#[test]
fn settling_advances_the_queue_for_the_next_claimant() {
    let f = setup();
    let alice = depositor(&f, 1_000 * USDC);
    let bob = depositor(&f, 1_000 * USDC);

    f.vault.request_withdrawal(&alice, &(100 * USDC));
    let b = f.vault.request_withdrawal(&bob, &(200 * USDC));

    assert_eq!(f.vault.claim_status(&b), ClaimStatus::Pending);
    f.vault.settle_withdrawal();
    assert_eq!(f.vault.claim_status(&b), ClaimStatus::Ready);

    // Bob can now claim for himself, the ordinary way.
    f.vault.claim_withdrawal(&bob, &b);
    assert_eq!(f.usdc.balance(&alice), 100 * USDC);
    assert_eq!(f.usdc.balance(&bob), 200 * USDC);
    assert_eq!(f.vault.queue_head(), 3);
}

#[test]
fn settling_cannot_redirect_payment_to_the_caller() {
    let f = setup();
    let alice = depositor(&f, 1_000 * USDC);
    let mallory = Address::generate(&f.e);

    f.vault.request_withdrawal(&alice, &(400 * USDC));
    // Nothing about the call names Mallory, so nothing about the payout can
    // either: `settle_withdrawal` takes no recipient argument at all.
    f.vault.settle_withdrawal();
    assert_eq!(f.usdc.balance(&alice), 400 * USDC);
    assert_eq!(f.usdc.balance(&mallory), 0);
}

#[test]
fn settling_with_insufficient_reserves_fails_cleanly() {
    let f = setup();
    let alice = depositor(&f, 1_000 * USDC);

    // Put 900 to work in the pool, leaving 100 idle against a 500 claim.
    f.engine.allocate(&f.admin, &f.pool, &(900 * USDC));
    let claim_id = f.vault.request_withdrawal(&alice, &(500 * USDC));
    assert_eq!(
        f.vault.try_settle_withdrawal(),
        Err(Ok(VaultError::InsufficientLiquidity))
    );
    assert_eq!(f.vault.queue_head(), claim_id);
    assert_eq!(f.usdc.balance(&alice), 0);

    // The pool repays, and the same call that used to fail now succeeds with
    // no other action.
    f.engine.deallocate(&f.pool, &(600 * USDC));
    f.vault.settle_withdrawal();
    assert_eq!(f.usdc.balance(&alice), 500 * USDC);
}

#[test]
fn settling_an_empty_queue_fails_cleanly() {
    let f = setup();
    depositor(&f, 1_000 * USDC);
    assert_eq!(f.vault.queue_length(), 0);
    assert_eq!(
        f.vault.try_settle_withdrawal(),
        Err(Ok(VaultError::QueueEmpty))
    );
}

#[test]
fn settling_respects_the_pause_circuit_breaker() {
    let f = setup();
    let alice = depositor(&f, 1_000 * USDC);
    f.vault.request_withdrawal(&alice, &(100 * USDC));

    f.vault.set_paused(&f.admin, &true);
    assert_eq!(
        f.vault.try_settle_withdrawal(),
        Err(Ok(VaultError::Paused))
    );
    f.vault.set_paused(&f.admin, &false);
    f.vault.settle_withdrawal();
    assert_eq!(f.usdc.balance(&alice), 100 * USDC);
}

#[test]
fn settling_stays_strictly_fifo_across_several_claims() {
    let f = setup();
    let alice = depositor(&f, 1_000 * USDC);
    let bob = depositor(&f, 1_000 * USDC);
    let carol = depositor(&f, 1_000 * USDC);
    let dave = depositor(&f, 1_000 * USDC);

    let a = f.vault.request_withdrawal(&alice, &(100 * USDC));
    let b = f.vault.request_withdrawal(&bob, &(200 * USDC));
    let c = f.vault.request_withdrawal(&carol, &(300 * USDC));
    let d = f.vault.request_withdrawal(&dave, &(400 * USDC));

    // A mix of self-claims and third party settlements, and the order paid
    // matches the order requested regardless of which path was used.
    assert_eq!(f.vault.settle_withdrawal(), a);
    f.vault.claim_withdrawal(&bob, &b);
    assert_eq!(f.vault.settle_withdrawal(), c);
    assert_eq!(f.vault.settle_withdrawal(), d);

    assert_eq!(f.usdc.balance(&alice), 100 * USDC);
    assert_eq!(f.usdc.balance(&bob), 200 * USDC);
    assert_eq!(f.usdc.balance(&carol), 300 * USDC);
    assert_eq!(f.usdc.balance(&dave), 400 * USDC);
    assert_eq!(f.vault.queue_head(), 5);
    assert_eq!(f.vault.queue_length(), 0);
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
    // Repointing agUSD is the authority to mint against the Vault's reserves,
    // so it is gated exactly as hard as the pause switch.
    assert_eq!(
        f.vault.try_set_agusd(&stranger, &stranger),
        Err(Ok(VaultError::NotAdmin))
    );
    // And repointing the Engine is the authority to release them.
    assert_eq!(
        f.vault.try_set_engine(&stranger, &stranger),
        Err(Ok(VaultError::NotAdmin))
    );
    assert_eq!(f.vault.agusd(), f.agusd.address);
    assert_eq!(f.vault.allocation_engine(), f.engine.address);
    assert!(!f.vault.paused());
}

/// A second Engine wired to `vault`, with its own pool adapter, opened up to
/// the same limits as the fixture's. Returns the Engine and its pool.
fn spare_engine(f: &Fix, vault: &Address) -> (AllocationEngineClient<'static>, Address) {
    let engine_id = f.e.register(AllocationEngine, ());
    let engine = AllocationEngineClient::new(&f.e, &engine_id);
    engine.initialize(&f.admin, vault);
    let pool = f.e.register(PrivateCreditAdapter, ());
    PrivateCreditAdapterClient::new(&f.e, &pool).initialize(
        &f.admin,
        &engine_id,
        vault,
        &f.usdc.address,
    );
    engine.register_pool(
        &f.admin,
        &pool,
        &symbol_short!("QIRO"),
        &symbol_short!("US"),
        &10_000u32,
    );
    engine.set_caps(&f.admin, &10_000, &10_000, &10_000);
    engine.set_reserve_floor(&f.admin, &0u32);
    (engine, pool)
}

#[test]
fn the_engine_pointer_moves_while_no_capital_of_this_vault_is_deployed() {
    let f = setup();
    depositor(&f, 1_000 * USDC);
    assert_eq!(f.vault.allocation_engine(), f.engine.address);

    // A replacement Engine, wired to this Vault and configured the same way.
    // This is the situation the setter exists for: the Engine written at
    // initialization has been superseded and the Vault has to follow it.
    let (replacement, spare_pool) = spare_engine(&f, &f.vault.address);
    f.vault.set_engine(&f.admin, &replacement.address);
    assert_eq!(f.vault.allocation_engine(), replacement.address);

    // The replacement can now do what it could not do a transaction ago.
    replacement.allocate(&f.admin, &spare_pool, &(100 * USDC));
    assert_eq!(f.vault.idle_reserves(), 900 * USDC);
    // Total assets are read through whichever Engine the Vault points at, so
    // the book follows the pointer.
    assert_eq!(f.vault.get_total_assets(), 1_000 * USDC);
}

#[test]
#[should_panic]
fn an_engine_the_vault_does_not_point_at_cannot_release_its_capital() {
    // The whole reason `set_engine` exists. This Engine is wired to the Vault,
    // registers the pool, and is opened up to the same limits: correct in
    // every respect except that the Vault has not been told about it. The
    // release is refused, because the Vault authorizes `settle_allocation`
    // from the address it stores and from nothing else.
    let f = setup();
    depositor(&f, 1_000 * USDC);
    let (stranger_engine, spare_pool) = spare_engine(&f, &f.vault.address);
    stranger_engine.allocate(&f.admin, &spare_pool, &(100 * USDC));
}

#[test]
fn the_engine_pointer_is_frozen_while_this_vaults_capital_is_out() {
    let f = setup();
    depositor(&f, 1_000 * USDC);
    f.engine.allocate(&f.admin, &f.pool, &(700 * USDC));

    // 700 USDC are sitting in the pool adapter and only the Engine that put
    // them there can call them back. Repointing now would drop them out of
    // get_total_assets while leaving them entirely undrawable.
    let stray = f.e.register(AllocationEngine, ());
    AllocationEngineClient::new(&f.e, &stray).initialize(&f.admin, &f.vault.address);
    assert_eq!(
        f.vault.try_set_engine(&f.admin, &stray),
        Err(Ok(VaultError::CapitalDeployed))
    );
    assert_eq!(f.vault.allocation_engine(), f.engine.address);

    // Unwinding the book reopens the door: with nothing deployed there is
    // nothing left for the move to invalidate.
    f.engine.deallocate(&f.pool, &(700 * USDC));
    assert_eq!(f.engine.total_allocated(), 0);
    f.vault.set_engine(&f.admin, &stray);
    assert_eq!(f.vault.allocation_engine(), stray);
}

#[test]
fn the_engine_pointer_refuses_anything_that_does_not_name_this_vault() {
    // Without this the pointer would be a one call instruction to hand the
    // reserves to an ordinary account: `settle_allocation` authorizes whatever
    // this pointer names, and an account signs for itself.
    let f = setup();
    depositor(&f, 1_000 * USDC);
    let mallory = Address::generate(&f.e);
    assert_eq!(
        f.vault.try_set_engine(&f.admin, &mallory),
        Err(Ok(VaultError::EngineMismatch))
    );

    // A real Engine, correctly configured, that happens to govern a different
    // Vault is refused for the same reason.
    let other_vault = f.e.register(Vault, ());
    let (foreign, _) = spare_engine(&f, &other_vault);
    assert_eq!(
        f.vault.try_set_engine(&f.admin, &foreign.address),
        Err(Ok(VaultError::EngineMismatch))
    );
    assert_eq!(f.vault.allocation_engine(), f.engine.address);
    assert_eq!(f.vault.idle_reserves(), 1_000 * USDC);
}

#[test]
fn an_engine_that_governs_another_vault_does_not_freeze_this_one() {
    // The live failure this setter was written for. The Vault was initialized
    // against an Engine that had already been wired to an earlier Vault, so
    // the Engine's exposure book is real and non-empty, and none of it is this
    // Vault's money. Reading the book alone would have frozen the pointer in
    // precisely the case it has to move.
    let f = setup();
    let other_vault_id = f.e.register(Vault, ());
    let other_vault = VaultClient::new(&f.e, &other_vault_id);

    let (foreign, foreign_pool) = spare_engine(&f, &other_vault_id);
    let foreign_id = foreign.address.clone();

    let other_agusd_id = f.e.register(MockUsdc, ());
    MockUsdcClient::new(&f.e, &other_agusd_id).initialize(
        &other_vault_id,
        &7u32,
        &String::from_str(&f.e, "Agama USD"),
        &String::from_str(&f.e, "agUSD"),
    );
    other_vault.initialize(
        &f.admin,
        &f.usdc.address,
        &other_agusd_id,
        &foreign_id,
    );
    let bob = Address::generate(&f.e);
    f.usdc.faucet(&bob, &(500 * USDC));
    other_vault.deposit(&bob, &(500 * USDC));
    foreign.allocate(&f.admin, &foreign_pool, &(300 * USDC));
    assert_eq!(foreign.total_allocated(), 300 * USDC);

    // Put our Vault on that Engine the only way it can get there, the way the
    // live deployment did: at initialization, before any setter exists to
    // refuse it.
    let stranded_id = f.e.register(Vault, ());
    let stranded = VaultClient::new(&f.e, &stranded_id);
    let stranded_agusd = f.e.register(MockUsdc, ());
    MockUsdcClient::new(&f.e, &stranded_agusd).initialize(
        &stranded_id,
        &7u32,
        &String::from_str(&f.e, "Agama USD"),
        &String::from_str(&f.e, "agUSD"),
    );
    stranded.initialize(&f.admin, &f.usdc.address, &stranded_agusd, &foreign_id);

    // That Vault can never deploy a dollar: the Engine it names governs
    // somebody else. Walking out is exactly what the setter is for, and the
    // 300 USDC book on the Engine it is leaving must not stand in the way,
    // because none of it is this Vault's money.
    let (own_engine, _) = spare_engine(&f, &stranded_id);
    stranded.set_engine(&f.admin, &own_engine.address);
    assert_eq!(stranded.allocation_engine(), own_engine.address);
    assert_eq!(foreign.total_allocated(), 300 * USDC);
}

#[test]
fn the_agusd_pointer_moves_before_the_first_deposit_and_never_after() {
    let f = setup();
    assert_eq!(f.vault.deposits(), 0);

    // A second token, also minted by the Vault, standing in for the case this
    // setter exists for: the address written at initialization turned out to
    // be the wrong contract.
    let replacement_id = f.e.register(MockUsdc, ());
    let replacement = MockUsdcClient::new(&f.e, &replacement_id);
    replacement.initialize(
        &f.vault.address,
        &7u32,
        &String::from_str(&f.e, "Agama USD"),
        &String::from_str(&f.e, "agUSD"),
    );
    f.vault.set_agusd(&f.admin, &replacement_id);
    assert_eq!(f.vault.agusd(), replacement_id);

    // The Vault mints through the new address from here on.
    let alice = Address::generate(&f.e);
    f.usdc.faucet(&alice, &(100 * USDC));
    f.vault.deposit(&alice, &(100 * USDC));
    assert_eq!(replacement.balance(&alice), 100 * USDC);
    assert_eq!(f.agusd.balance(&alice), 0);
    assert_eq!(f.vault.deposits(), 1);

    // And the door closes: 100 agUSD are outstanding, and repointing now would
    // leave them backed by a token this Vault no longer mints or burns.
    assert_eq!(
        f.vault.try_set_agusd(&f.admin, &f.agusd.address),
        Err(Ok(VaultError::DepositsExist))
    );
    assert_eq!(f.vault.agusd(), replacement_id);

    // Withdrawing everything does not reopen it: the counter records that the
    // Vault has issued, not what it is holding right now.
    let claim_id = f.vault.request_withdrawal(&alice, &(100 * USDC));
    f.vault.claim_withdrawal(&alice, &claim_id);
    assert_eq!(f.vault.idle_reserves(), 0);
    assert_eq!(
        f.vault.try_set_agusd(&f.admin, &f.agusd.address),
        Err(Ok(VaultError::DepositsExist))
    );
}
