#![cfg(test)]
use super::*;
use allocation_engine::{AllocationEngine, AllocationEngineClient};
use mock_usdc::{MockUsdc, MockUsdcClient};
use oracle_adapter::{OracleAdapter, OracleAdapterClient};
use private_credit::{PrivateCreditAdapter, PrivateCreditAdapterClient};
use soroban_sdk::testutils::{Address as _, Ledger as _};
use soroban_sdk::testutils::{MockAuth, MockAuthInvoke};
use soroban_sdk::{contract, contractimpl, symbol_short, IntoVal, String};

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
    // The caps and the Engine's copy of the reserve floor have their own suite
    // in the Engine crate. Here they are opened up so the Vault's queue can be
    // tested against real allocations rather than against a mock. The Vault's
    // own floor ships closed at 100%, so it is opened too; the tests that are
    // about the floor set it back themselves.
    engine.set_caps(&admin, &10_000, &10_000, &10_000);
    engine.set_reserve_floor(&admin, &0u32);
    vault.set_reserve_floor(&admin, &0u32);

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
    // claim_withdrawal, and no pause-and-reorder trick either. Pausing does not
    // even stop Alice, because payouts are outside the breaker, and it still
    // does not promote the admin's own claim.
    assert_eq!(
        f.vault.try_claim_withdrawal(&f.admin, &admin_claim),
        Err(Ok(VaultError::NotAtQueueHead))
    );
    f.vault.set_paused(&f.admin, &true);
    assert_eq!(
        f.vault.try_claim_withdrawal(&f.admin, &admin_claim),
        Err(Ok(VaultError::NotAtQueueHead))
    );
    f.vault.claim_withdrawal(&alice, &alice_claim);
    f.vault.set_paused(&f.admin, &false);

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

/// The breaker stops what creates obligations and leaves what discharges them
/// alone.
///
/// It used to stop claims as well, and that was the wrong side of the line to
/// put them on: `request_withdrawal` burns the agUSD as it queues the claim, so
/// a user whose payout is paused holds neither the token nor the cash, for
/// exactly as long as the admin leaves the switch on. Pausing new requests
/// stops the queue growing during an incident, which is the point; refusing to
/// pay the claims already in it is a freeze on people who have already given up
/// their tokens.
#[test]
fn pausing_blocks_deposits_and_requests_but_never_a_payout() {
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
    // New allocations stop too: an emergency stop that keeps deploying capital
    // into pools is not a stop. The Engine's checks pass, and the Vault
    // refuses the release, so the whole allocation reverts.
    assert!(f.engine.try_allocate(&f.admin, &f.pool, &(100 * USDC)).is_err());
    assert_eq!(f.engine.get_exposure(&f.pool), 0);

    // Reads keep working while paused, so operators can still see the book.
    assert_eq!(f.vault.claim_status(&claim_id), ClaimStatus::Ready);
    assert!(f.vault.get_total_assets() > 0);

    // And the queued claim is paid while the breaker is still on. The agUSD
    // behind it is already burned; there is nothing left to protect by holding
    // the cash back.
    let before = f.usdc.balance(&alice);
    f.vault.claim_withdrawal(&alice, &claim_id);
    assert_eq!(f.usdc.balance(&alice), before + 100 * USDC);
    assert!(f.vault.paused());

    // The permissionless path is inside the breaker in exactly the same way:
    // it is the same payment.
    f.vault.set_paused(&f.admin, &false);
    let bob = depositor(&f, 1_000 * USDC);
    let bob_claim = f.vault.request_withdrawal(&bob, &(50 * USDC));
    f.vault.set_paused(&f.admin, &true);
    f.vault.settle_withdrawal();
    assert_eq!(f.vault.claim_status(&bob_claim), ClaimStatus::Claimed);
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
    other_vault.set_reserve_floor(&f.admin, &0u32);
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

/// The hostile Engine from the adversarial review, in full.
///
/// `set_engine` asks an incoming Engine whether it governs this Vault and
/// whether its book is empty. This contract answers both correctly, because
/// answering them correctly costs a stored address and a hardcoded zero. It is
/// the counterexample to the idea that interrogating a counterparty proves
/// anything about it, and the reason the Vault stopped delegating its own
/// solvency to whatever address it happens to point at.
#[contract]
pub struct HostileEngine;

#[contractimpl]
impl HostileEngine {
    pub fn initialize(e: Env, vault: Address) {
        e.storage().instance().set(&symbol_short!("vault"), &vault);
    }

    pub fn vault(e: Env) -> Address {
        e.storage().instance().get(&symbol_short!("vault")).unwrap()
    }

    /// Whatever number is convenient. Nothing forces it to be true, which is
    /// the whole point of the Vault keeping its own.
    pub fn total_allocated(_e: Env) -> i128 {
        0
    }

    /// Call `settle_allocation` for `amount` and report whether it worked. No
    /// cap, no floor, no event, no book: everything a real Engine does before
    /// it asks, this one skips.
    pub fn steal(e: Env, to: Address, amount: i128) -> bool {
        let vault = Self::vault(e.clone());
        matches!(
            VaultClient::new(&e, &vault).try_settle_allocation(&to, &amount),
            Ok(Ok(()))
        )
    }

    /// Reset the Vault's deployed book without returning anything, if it will
    /// let us. It will not: `record_writedown` needs the Vault admin's
    /// signature as well as this contract's call.
    pub fn erase_the_book(e: Env, admin: Address, amount: i128) -> bool {
        let vault = Self::vault(e.clone());
        matches!(
            VaultClient::new(&e, &vault).try_record_writedown(&admin, &amount),
            Ok(Ok(()))
        )
    }

    /// Claim a repayment that never arrived, if it will let us. It will not:
    /// the Vault checks its own balance first.
    pub fn fake_a_repayment(e: Env, amount: i128) -> bool {
        let vault = Self::vault(e.clone());
        matches!(
            VaultClient::new(&e, &vault).try_record_repayment(&amount),
            Ok(Ok(()))
        )
    }
}

/// The finding, and the fix, in one test: a hostile Engine gets exactly what an
/// honest one would have got, and then gets nothing.
///
/// Before, `settle_allocation` released USDC on the Engine's say-so and checked
/// nothing itself, on the reasoning that the Engine had already checked the
/// caps and the floor. That reasoning holds only for an Engine that runs those
/// checks, and `set_engine`'s guard cannot tell one of those from a contract
/// that answers `vault()` and returns zero from `total_allocated()`. Forty
/// lines emptied the Vault.
#[test]
fn a_hostile_engine_cannot_take_more_than_an_honest_one() {
    let f = setup();
    depositor(&f, 1_000 * USDC);
    // The floor the testnet deployment runs with, on both contracts.
    f.engine.set_reserve_floor(&f.admin, &2_500u32);
    f.vault.set_reserve_floor(&f.admin, &2_500u32);

    // What an honest Engine can do: 750, because 250 of the 1000 has to stay.
    assert!(f
        .engine
        .try_allocate(&f.admin, &f.pool, &(751 * USDC))
        .is_err());
    f.engine.allocate(&f.admin, &f.pool, &(750 * USDC));
    assert_eq!(f.vault.idle_reserves(), 250 * USDC);
    assert_eq!(f.vault.deployed_capital(), 750 * USDC);

    // Unwind, so the hostile Engine starts from the same balance sheet.
    f.engine.deallocate(&f.pool, &(750 * USDC));
    assert_eq!(f.vault.deployed_capital(), 0);
    assert_eq!(f.vault.idle_reserves(), 1_000 * USDC);

    let hostile_id = f.e.register(HostileEngine, ());
    let hostile = HostileEngineClient::new(&f.e, &hostile_id);
    hostile.initialize(&f.vault.address);
    // It passes the guard. That is the finding, not a bug in the test: the
    // guard asks two questions and this contract knows both answers.
    f.vault.set_engine(&f.admin, &hostile_id);
    assert_eq!(f.vault.allocation_engine(), hostile_id);

    let mallory = Address::generate(&f.e);
    // One stroop past what the floor allows is refused, from an Engine that
    // never checked a floor in its life.
    assert!(!hostile.steal(&mallory, &(750 * USDC + 1)));
    assert!(hostile.steal(&mallory, &(750 * USDC)));

    // And that is the end of it. The Vault's own deployed book went up by
    // exactly what left, the hostile Engine cannot write to it, and every
    // further release is measured against it.
    assert_eq!(f.vault.deployed_capital(), 750 * USDC);
    for _ in 0..10 {
        assert!(!hostile.steal(&mallory, &(10 * USDC)));
    }
    assert!(!hostile.steal(&mallory, &1));
    assert_eq!(f.usdc.balance(&mallory), 750 * USDC);
    assert_eq!(f.vault.idle_reserves(), 250 * USDC);

    // The two ways it could try to reset that book both fail. One needs cash it
    // does not have, the other needs a signature it cannot forge.
    assert!(!hostile.fake_a_repayment(&(750 * USDC)));
    f.e.mock_auths(&[]);
    assert!(!hostile.erase_the_book(&f.admin, &(750 * USDC)));
    assert_eq!(f.vault.deployed_capital(), 750 * USDC);
}

/// The floor is a floor across calls, not within one. Salami slicing a Vault
/// one small release at a time has to stop at the same place a single large
/// release does.
#[test]
fn the_floor_holds_across_repeated_releases() {
    let f = setup();
    depositor(&f, 1_000 * USDC);
    f.engine.set_reserve_floor(&f.admin, &2_500u32);
    f.vault.set_reserve_floor(&f.admin, &2_500u32);

    let mut deployed = 0;
    while f
        .engine
        .try_allocate(&f.admin, &f.pool, &(50 * USDC))
        .is_ok()
    {
        deployed += 50 * USDC;
        assert!(deployed <= 750 * USDC);
    }
    assert_eq!(deployed, 750 * USDC);
    assert_eq!(f.vault.free_reserves(), 250 * USDC);
    assert_eq!(f.engine.get_reserve_ratio(), 2_500);
}

/// A queued claim is money the Vault already owes, and it used to appear in no
/// on-chain quantity at all: not in agUSD supply, which was burned at request
/// time, not in idle reserves, not in total assets, not in the reserve ratio.
///
/// The confirmed consequence: deposit 1000, queue all 1000 for withdrawal, and
/// the Engine would still deploy 400 while `get_reserve_ratio` reported a
/// healthy 6000 bps. The claim then could not be paid.
#[test]
fn a_queued_withdrawal_is_not_free_liquidity() {
    let f = setup();
    let alice = depositor(&f, 1_000 * USDC);
    // Open both floors right up, so nothing but the liability itself is
    // stopping the allocation.
    f.engine.set_reserve_floor(&f.admin, &0u32);
    f.vault.set_reserve_floor(&f.admin, &0u32);

    let claim_id = f.vault.request_withdrawal(&alice, &(1_000 * USDC));
    // The gross balance has not moved: the USDC is still here, and that is
    // exactly what made this invisible.
    assert_eq!(f.vault.idle_reserves(), 1_000 * USDC);
    assert_eq!(f.vault.outstanding_liabilities(), 1_000 * USDC);
    assert_eq!(f.vault.free_reserves(), 0);
    assert_eq!(f.vault.get_total_assets(), 1_000 * USDC);
    assert_eq!(f.vault.get_net_assets(), 0);

    // The 400 the Engine used to deploy against money it already owed.
    assert_eq!(
        f.engine.try_allocate(&f.admin, &f.pool, &(400 * USDC)),
        Err(Ok(allocation_engine::EngineError::InsufficientReserves))
    );
    assert_eq!(f.engine.get_exposure(&f.pool), 0);

    // And the claim is payable, which is the whole point of refusing.
    assert_eq!(f.vault.claim_status(&claim_id), ClaimStatus::Ready);
    f.vault.claim_withdrawal(&alice, &claim_id);
    assert_eq!(f.usdc.balance(&alice), 1_000 * USDC);
    assert_eq!(f.vault.outstanding_liabilities(), 0);
}

/// Partway through: a queue that owes some of the book leaves the rest
/// deployable, and the floor is measured against what is left.
#[test]
fn the_floor_is_measured_on_free_reserves_not_the_gross_balance() {
    let f = setup();
    let alice = depositor(&f, 1_000 * USDC);
    f.engine.set_reserve_floor(&f.admin, &2_500u32);
    f.vault.set_reserve_floor(&f.admin, &2_500u32);

    f.vault.request_withdrawal(&alice, &(600 * USDC));
    assert_eq!(f.vault.free_reserves(), 400 * USDC);
    assert_eq!(f.vault.get_net_assets(), 400 * USDC);

    // 25% of 400 stays, so 300 may go. Against the gross balance it would have
    // been 25% of 1000, leaving room for 750 that is not there.
    assert!(f
        .engine
        .try_allocate(&f.admin, &f.pool, &(301 * USDC))
        .is_err());
    f.engine.allocate(&f.admin, &f.pool, &(300 * USDC));
    assert_eq!(f.vault.free_reserves(), 100 * USDC);
    assert_eq!(f.vault.idle_reserves(), 700 * USDC);
    // Still enough to pay the queue, which is what the subtraction protects.
    assert_eq!(f.vault.claim_status(&1u64), ClaimStatus::Ready);
}

/// One agUSD, never claimed, used to freeze every withdrawal behind it forever.
///
/// The head advanced only when the head claim's own owner called
/// `claim_withdrawal`, so the holder of the head had a veto over everyone
/// behind them and exercised it by doing nothing at all. The attack cost the
/// anti-dust minimum, and the attacker kept it.
#[test]
fn a_stalled_head_claim_no_longer_freezes_the_queue() {
    let f = setup();
    let mallory = depositor(&f, 1_000 * USDC);
    let bob = depositor(&f, 1_000 * USDC);
    let carol = depositor(&f, 1_000 * USDC);

    // The grief: one claim at the dust floor, at the head, never claimed.
    let griefer = f.vault.request_withdrawal(&mallory, &MIN_WITHDRAWAL);
    let bob_claim = f.vault.request_withdrawal(&bob, &(300 * USDC));
    let carol_claim = f.vault.request_withdrawal(&carol, &(200 * USDC));

    // Everyone behind is stuck, with plenty of liquidity to pay them.
    assert!(f.vault.idle_reserves() >= 3_000 * USDC);
    assert_eq!(
        f.vault.try_claim_withdrawal(&bob, &bob_claim),
        Err(Ok(VaultError::NotAtQueueHead))
    );

    // Bob unsticks himself without touching the ordering: the head claim is
    // paid, to Mallory, for exactly what Mallory asked for.
    let settled = f.vault.settle_withdrawal();
    assert_eq!(settled, griefer);
    assert_eq!(f.usdc.balance(&mallory), MIN_WITHDRAWAL);
    assert_eq!(f.vault.claim_status(&griefer), ClaimStatus::Claimed);
    assert_eq!(f.vault.queue_head(), bob_claim);

    // And the queue runs on, still strictly in order.
    assert_eq!(
        f.vault.try_claim_withdrawal(&carol, &carol_claim),
        Err(Ok(VaultError::NotAtQueueHead))
    );
    f.vault.claim_withdrawal(&bob, &bob_claim);
    f.vault.settle_withdrawal();
    assert_eq!(f.usdc.balance(&carol), 200 * USDC);
    assert_eq!(f.vault.queue_length(), 0);
    assert_eq!(f.vault.outstanding_liabilities(), 0);
}

/// `settle_withdrawal` takes no claim id and no recipient, so there is no lever
/// to pull. This is the test of that, rather than of the happy path.
#[test]
fn settle_withdrawal_offers_the_caller_no_choice_of_claim_or_recipient() {
    let f = setup();
    let alice = depositor(&f, 1_000 * USDC);
    let mallory = Address::generate(&f.e);

    // Nothing queued: there is no claim to name, so there is nothing to pay.
    assert_eq!(f.vault.try_settle_withdrawal(), Err(Ok(VaultError::QueueEmpty)));

    let alice_claim = f.vault.request_withdrawal(&alice, &(400 * USDC));
    let bob = depositor(&f, 1_000 * USDC);
    let bob_claim = f.vault.request_withdrawal(&bob, &(100 * USDC));

    // Mallory calls it and Alice is paid. Mallory cannot ask for Bob's claim
    // instead, and cannot ask to be paid: neither is an argument.
    f.vault.settle_withdrawal();
    assert_eq!(f.usdc.balance(&alice), 400 * USDC);
    assert_eq!(f.usdc.balance(&mallory), 0);
    assert_eq!(f.vault.get_claim(&alice_claim).owner, alice);
    assert_eq!(f.vault.queue_head(), bob_claim);

    // Reserves short of the head claim fail the same way a self-claim does,
    // rather than paying part of it. Reaching that state now takes a claim
    // queued after the capital went out, because the Engine can no longer
    // deploy against money the queue is already owed.
    let carol = depositor(&f, 1_000 * USDC);
    f.engine.allocate(&f.admin, &f.pool, &(f.vault.free_reserves()));
    assert_eq!(f.vault.free_reserves(), 0);
    let carol_claim = f.vault.request_withdrawal(&carol, &(500 * USDC));
    f.vault.claim_withdrawal(&bob, &bob_claim);
    assert_eq!(f.vault.queue_head(), carol_claim);
    assert_eq!(
        f.vault.try_settle_withdrawal(),
        Err(Ok(VaultError::InsufficientLiquidity))
    );
    assert_eq!(f.vault.claim_status(&carol_claim), ClaimStatus::Pending);
}

/// The Vault's floor is admin state, and it is the number every release is
/// measured against, so it is gated exactly as hard as the pause switch.
///
/// Checked with targeted authorizations rather than the fixture's blanket mock:
/// `mock_all_auths` turns authorization off wholesale, so a test that runs
/// under it proves nothing about who signed for what.
#[test]
fn only_the_admin_can_move_the_vaults_reserve_floor() {
    let f = setup();
    let stranger = Address::generate(&f.e);

    // A stranger naming themselves is refused on identity.
    f.e.mock_auths(&[MockAuth {
        address: &stranger,
        invoke: &MockAuthInvoke {
            contract: &f.vault.address,
            fn_name: "set_reserve_floor",
            args: (stranger.clone(), 0u32).into_val(&f.e),
            sub_invokes: &[],
        },
    }]);
    assert_eq!(
        f.vault.try_set_reserve_floor(&stranger, &0u32),
        Err(Ok(VaultError::NotAdmin))
    );

    // A stranger naming the admin is refused on authorization: the call is not
    // signed by the address it claims to be acting for.
    f.e.mock_auths(&[MockAuth {
        address: &stranger,
        invoke: &MockAuthInvoke {
            contract: &f.vault.address,
            fn_name: "set_reserve_floor",
            args: (f.admin.clone(), 0u32).into_val(&f.e),
            sub_invokes: &[],
        },
    }]);
    assert!(f.vault.try_set_reserve_floor(&f.admin, &0u32).is_err());
    assert_eq!(f.vault.reserve_floor_bps(), 0);

    // The admin, signing for themselves, moves it.
    f.e.mock_auths(&[MockAuth {
        address: &f.admin,
        invoke: &MockAuthInvoke {
            contract: &f.vault.address,
            fn_name: "set_reserve_floor",
            args: (f.admin.clone(), 3_000u32).into_val(&f.e),
            sub_invokes: &[],
        },
    }]);
    f.vault.set_reserve_floor(&f.admin, &3_000u32);
    assert_eq!(f.vault.reserve_floor_bps(), 3_000);
}

/// A repayment the Vault cannot see in its own balance is not a repayment.
/// This is what keeps `deployed_capital` from being a number the Engine writes.
#[test]
fn a_repayment_has_to_have_actually_arrived() {
    let f = setup();
    depositor(&f, 1_000 * USDC);
    f.engine.allocate(&f.admin, &f.pool, &(400 * USDC));
    assert_eq!(f.vault.deployed_capital(), 400 * USDC);
    assert_eq!(f.vault.booked_reserves(), 600 * USDC);

    let hostile_id = f.e.register(HostileEngine, ());
    let hostile = HostileEngineClient::new(&f.e, &hostile_id);
    hostile.initialize(&f.vault.address);
    // Repointing is refused outright while this Vault's capital is out, from
    // the Vault's own book rather than by asking the Engine it is leaving.
    assert_eq!(
        f.vault.try_set_engine(&f.admin, &hostile_id),
        Err(Ok(VaultError::CapitalDeployed))
    );

    // The honest path works because the cash comes with it.
    f.engine.deallocate(&f.pool, &(400 * USDC));
    assert_eq!(f.vault.deployed_capital(), 0);
    assert_eq!(f.vault.booked_reserves(), 1_000 * USDC);
    assert_eq!(f.vault.idle_reserves(), 1_000 * USDC);
}
