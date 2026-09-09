#![cfg(test)]
use super::*;
use allocation_engine::{AllocationEngine, AllocationEngineClient, EngineError};
use mock_usdc::{MockUsdc, MockUsdcClient};
use oracle_adapter::{OracleAdapter, OracleAdapterClient};
use private_credit::PrivateCreditAdapter;
use soroban_sdk::testutils::storage::Persistent as _;
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

    // The Vault comes first, because everything else is wired to it. It takes
    // only its admin and its USDC: agUSD and the Engine arrive afterwards,
    // through the setters that check them.
    let vault_id = e.register(Vault, (admin.clone(), usdc_id.clone()));
    let vault = VaultClient::new(&e, &vault_id);

    let agusd_id = e.register(MockUsdc, ());
    let agusd = MockUsdcClient::new(&e, &agusd_id);
    agusd.initialize(
        &vault_id,
        &7u32,
        &String::from_str(&e, "Agama USD"),
        &String::from_str(&e, "agUSD"),
    );

    let engine_id = e.register(AllocationEngine, (admin.clone(), vault_id.clone()));
    let engine = AllocationEngineClient::new(&e, &engine_id);

    vault.set_agusd(&admin, &agusd_id);
    vault.set_engine(&admin, &engine_id);

    let oracle_id = e.register(OracleAdapter, (admin.clone(),));
    let oracle = OracleAdapterClient::new(&e, &oracle_id);
    oracle.add_reporter(&admin, &reporter);
    oracle.register_feed(
        &admin,
        &oracle_adapter::FEED_PC_NAV,
        &oracle_adapter::PRIVATE_CREDIT_STALENESS,
        &oracle_adapter::PRIVATE_CREDIT_DEVIATION_BPS,
        &oracle_adapter::NAV_BAND_MIN,
        &oracle_adapter::NAV_BAND_MAX,
        &oracle_adapter::NAV_MIN_INTERVAL,
    );
    vault.set_oracle(&admin, &oracle_id, &oracle_adapter::FEED_PC_NAV);

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
    let nav = USDC;
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

    // Only the USDC pointer arrives at construction, and it has to answer the
    // token interface, so a real token stands where a generated address used to.
    let usdc_id = e.register(MockUsdc, ());
    MockUsdcClient::new(&e, &usdc_id).initialize(
        &admin,
        &7u32,
        &String::from_str(&e, "USD Coin"),
        &String::from_str(&e, "USDC"),
    );
    let vault_id = e.register(Vault, (admin.clone(), usdc_id.clone()));
    let vault = VaultClient::new(&e, &vault_id);

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
    let engine_id = f.e.register(AllocationEngine, (f.admin.clone(), vault.clone()));
    let engine = AllocationEngineClient::new(&f.e, &engine_id);
    let pool = f.e.register(
        PrivateCreditAdapter,
        (
            f.admin.clone(),
            engine_id.clone(),
            vault.clone(),
            f.usdc.address.clone(),
        ),
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
    let stray = f.e.register(
        AllocationEngine,
        (f.admin.clone(), f.vault.address.clone()),
    );
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
    let other_vault = f.e.register(Vault, (f.admin.clone(), f.usdc.address.clone()));
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
    // The live failure this setter was written for. A Vault ends up pointing at
    // an Engine whose exposure book is real and non-empty and none of whose
    // money is its own, and reading that book instead of its own would freeze
    // the pointer in precisely the case it has to move.
    //
    // The Vault used to arrive in that state at initialization, which took the
    // Engine on trust. It cannot any more: the constructor takes no Engine at
    // all and `set_engine` refuses one that does not name this Vault back. The
    // state is still reachable, because the Engine has a matching setter of its
    // own: a Vault that is pointed at an Engine correctly, and is then left
    // behind when the Engine follows the protocol to a newer Vault, is the same
    // mis-wiring arrived at from the other end. That is what is built here.
    let f = setup();

    let stranded_id = f.e.register(Vault, (f.admin.clone(), f.usdc.address.clone()));
    let stranded = VaultClient::new(&f.e, &stranded_id);
    let stranded_agusd = f.e.register(MockUsdc, ());
    MockUsdcClient::new(&f.e, &stranded_agusd).initialize(
        &stranded_id,
        &7u32,
        &String::from_str(&f.e, "Agama USD"),
        &String::from_str(&f.e, "agUSD"),
    );
    stranded.set_agusd(&f.admin, &stranded_agusd);

    // Wired correctly, both ways, at the point the pointer is set.
    let (foreign, _) = spare_engine(&f, &stranded_id);
    let foreign_id = foreign.address.clone();
    stranded.set_engine(&f.admin, &foreign_id);
    assert_eq!(stranded.allocation_engine(), foreign_id);

    // The Engine then moves on to a newer Vault and nothing drags the old one
    // along with it.
    let other_vault_id = f.e.register(Vault, (f.admin.clone(), f.usdc.address.clone()));
    let other_vault = VaultClient::new(&f.e, &other_vault_id);
    let other_agusd_id = f.e.register(MockUsdc, ());
    MockUsdcClient::new(&f.e, &other_agusd_id).initialize(
        &other_vault_id,
        &7u32,
        &String::from_str(&f.e, "Agama USD"),
        &String::from_str(&f.e, "agUSD"),
    );
    other_vault.set_agusd(&f.admin, &other_agusd_id);
    foreign.set_vault(&f.admin, &other_vault_id);
    other_vault.set_engine(&f.admin, &foreign_id);
    other_vault.set_reserve_floor(&f.admin, &0u32);

    // And builds a real book out of the newer Vault's money.
    let foreign_pool = f.e.register(
        PrivateCreditAdapter,
        (
            f.admin.clone(),
            foreign_id.clone(),
            other_vault_id.clone(),
            f.usdc.address.clone(),
        ),
    );
    foreign.register_pool(
        &f.admin,
        &foreign_pool,
        &symbol_short!("QIRO"),
        &symbol_short!("US"),
        &10_000u32,
    );
    let bob = Address::generate(&f.e);
    f.usdc.faucet(&bob, &(500 * USDC));
    other_vault.deposit(&bob, &(500 * USDC));
    foreign.allocate(&f.admin, &foreign_pool, &(300 * USDC));
    assert_eq!(foreign.total_allocated(), 300 * USDC);

    // The stranded Vault can never deploy a dollar: the Engine it names governs
    // somebody else. Walking out is exactly what the setter is for, and the
    // 300 USDC book on the Engine it is leaving must not stand in the way,
    // because none of it is this Vault's money.
    assert_eq!(stranded.deployed_capital(), 0);
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

/// The admin key was a single point of failure with no way back from either of
/// the two ways it fails: lost, and every admin gated call in the contract goes
/// with it; compromised, and it cannot be replaced.
///
/// Checked with targeted authorizations, because the whole property under test
/// is who signed what, and `mock_all_auths` would answer that question for
/// everybody at once.
#[test]
fn the_admin_role_can_be_handed_over_in_two_steps_and_only_to_a_live_key() {
    let f = setup();
    let successor = Address::generate(&f.e);
    let mallory = Address::generate(&f.e);
    assert_eq!(f.vault.pending_admin(), None);

    // A stranger cannot propose.
    f.e.mock_auths(&[MockAuth {
        address: &mallory,
        invoke: &MockAuthInvoke {
            contract: &f.vault.address,
            fn_name: "propose_admin",
            args: (mallory.clone(), mallory.clone()).into_val(&f.e),
            sub_invokes: &[],
        },
    }]);
    assert_eq!(
        f.vault.try_propose_admin(&mallory, &mallory),
        Err(Ok(VaultError::NotAdmin))
    );

    // The admin proposes. Nothing has moved yet: that is the point of the
    // second step, and it is what stops a one call transfer to a typo.
    f.e.mock_auths(&[MockAuth {
        address: &f.admin,
        invoke: &MockAuthInvoke {
            contract: &f.vault.address,
            fn_name: "propose_admin",
            args: (f.admin.clone(), successor.clone()).into_val(&f.e),
            sub_invokes: &[],
        },
    }]);
    f.vault.propose_admin(&f.admin, &successor);
    assert_eq!(f.vault.pending_admin(), Some(successor.clone()));
    assert_eq!(f.vault.admin(), f.admin);

    // Nobody but the proposed address can accept, and naming it is not enough:
    // the signature has to be theirs.
    f.e.mock_auths(&[MockAuth {
        address: &mallory,
        invoke: &MockAuthInvoke {
            contract: &f.vault.address,
            fn_name: "accept_admin",
            args: (mallory.clone(),).into_val(&f.e),
            sub_invokes: &[],
        },
    }]);
    assert_eq!(
        f.vault.try_accept_admin(&mallory),
        Err(Ok(VaultError::NotPendingAdmin))
    );
    f.e.mock_auths(&[MockAuth {
        address: &mallory,
        invoke: &MockAuthInvoke {
            contract: &f.vault.address,
            fn_name: "accept_admin",
            args: (successor.clone(),).into_val(&f.e),
            sub_invokes: &[],
        },
    }]);
    assert!(f.vault.try_accept_admin(&successor).is_err());
    assert_eq!(f.vault.admin(), f.admin);

    // The successor signs for itself, which is the proof the key is real and
    // reachable, and the role moves.
    f.e.mock_auths(&[MockAuth {
        address: &successor,
        invoke: &MockAuthInvoke {
            contract: &f.vault.address,
            fn_name: "accept_admin",
            args: (successor.clone(),).into_val(&f.e),
            sub_invokes: &[],
        },
    }]);
    f.vault.accept_admin(&successor);
    assert_eq!(f.vault.admin(), successor);
    assert_eq!(f.vault.pending_admin(), None);

    // The old key is now an ordinary address, and the new one has the powers.
    f.e.mock_all_auths();
    assert_eq!(
        f.vault.try_set_paused(&f.admin, &true),
        Err(Ok(VaultError::NotAdmin))
    );
    f.vault.set_paused(&successor, &true);
    assert!(f.vault.paused());

    // Accepting twice is not a second transfer.
    assert_eq!(
        f.vault.try_accept_admin(&successor),
        Err(Ok(VaultError::NoPendingAdmin))
    );
}

// ---------------------------------------------------------------------------
// Second adversarial review
// ---------------------------------------------------------------------------

/// A token that refuses to deliver to one address, which is what a Stellar
/// Asset Contract does when the destination has no trustline for the asset, has
/// had it frozen by the issuer, has a limit below the amount, or no longer
/// exists. The Vault's USDC is a SAC over a classic asset, so all four are
/// ordinary states rather than exotic ones.
#[contracttype]
#[derive(Clone)]
enum FrozenKey {
    Balance(Address),
    Blocked,
}

#[contract]
pub struct UndeliverableToken;

#[contractimpl]
impl UndeliverableToken {
    pub fn faucet(e: Env, to: Address, amount: i128) {
        let held: i128 = e
            .storage()
            .persistent()
            .get(&FrozenKey::Balance(to.clone()))
            .unwrap_or(0);
        e.storage()
            .persistent()
            .set(&FrozenKey::Balance(to), &(held + amount));
    }

    /// Stop the token delivering to `who`, and start again with `unblock`.
    pub fn block(e: Env, who: Address) {
        e.storage().instance().set(&FrozenKey::Blocked, &who);
    }

    pub fn unblock(e: Env) {
        e.storage().instance().remove(&FrozenKey::Blocked);
    }

    pub fn balance(e: Env, id: Address) -> i128 {
        e.storage()
            .persistent()
            .get(&FrozenKey::Balance(id))
            .unwrap_or(0)
    }

    pub fn transfer(e: Env, from: Address, to: Address, amount: i128) {
        from.require_auth();
        let blocked: Option<Address> = e.storage().instance().get(&FrozenKey::Blocked);
        if blocked == Some(to.clone()) {
            panic!("no trustline");
        }
        let held: i128 = e
            .storage()
            .persistent()
            .get(&FrozenKey::Balance(from.clone()))
            .unwrap_or(0);
        if held < amount {
            panic!("insufficient balance");
        }
        e.storage()
            .persistent()
            .set(&FrozenKey::Balance(from), &(held - amount));
        let credited: i128 = e
            .storage()
            .persistent()
            .get(&FrozenKey::Balance(to.clone()))
            .unwrap_or(0);
        e.storage()
            .persistent()
            .set(&FrozenKey::Balance(to), &(credited + amount));
    }
}

struct FrozenFix {
    e: Env,
    vault: VaultClient<'static>,
    usdc: UndeliverableTokenClient<'static>,
}

/// A Vault whose USDC can be made to refuse a delivery. No Engine allocations
/// here: what is under test is the payout path.
fn frozen_setup() -> FrozenFix {
    let e = Env::default();
    e.mock_all_auths();
    e.ledger().set_timestamp(T0);
    let admin = Address::generate(&e);

    let usdc_id = e.register(UndeliverableToken, ());
    let usdc = UndeliverableTokenClient::new(&e, &usdc_id);

    let vault_id = e.register(Vault, (admin.clone(), usdc_id.clone()));
    let vault = VaultClient::new(&e, &vault_id);

    let agusd_id = e.register(MockUsdc, ());
    MockUsdcClient::new(&e, &agusd_id).initialize(
        &vault_id,
        &7u32,
        &String::from_str(&e, "Agama USD"),
        &String::from_str(&e, "agUSD"),
    );

    let engine_id = e.register(AllocationEngine, (admin.clone(), vault_id.clone()));
    vault.set_agusd(&admin, &agusd_id);
    vault.set_engine(&admin, &engine_id);

    FrozenFix { e, vault, usdc }
}

/// One claim nobody can deliver used to stop every withdrawal in the protocol,
/// permanently.
///
/// `settle_withdrawal` fixed the head claimant who never comes back. It did
/// nothing for the head claimant who cannot be paid, which is worse, because
/// the owner cannot resolve it by showing up either: the transfer traps, the
/// whole invocation traps, `queue_head` stays where it is, and the queue is
/// FIFO with no admin path around it by design. One USDC and a lowered
/// trustline limit bought a permanent freeze of everybody else's money.
///
/// Delivery is now attempted rather than assumed. A claim the token refuses is
/// stepped over, unpaid, and the queue carries on.
#[test]
fn a_claim_that_cannot_be_delivered_does_not_freeze_the_queue() {
    let f = frozen_setup();
    let griefer = Address::generate(&f.e);
    let bob = Address::generate(&f.e);
    f.usdc.faucet(&griefer, &(1 * USDC));
    f.usdc.faucet(&bob, &(500 * USDC));
    f.vault.deposit(&griefer, &(1 * USDC));
    f.vault.deposit(&bob, &(500 * USDC));

    // The anti-dust minimum, queued first, in front of a real withdrawal.
    let dust = f.vault.request_withdrawal(&griefer, &(1 * USDC));
    let real = f.vault.request_withdrawal(&bob, &(500 * USDC));
    assert_eq!((dust, real), (1, 2));
    assert_eq!(f.vault.outstanding_liabilities(), 501 * USDC);

    // And now the griefer makes itself unpayable.
    f.usdc.block(&griefer);

    // The claim's own owner is told, by a named error rather than a trap,
    // because the owner is the one who can fix the cause.
    assert_eq!(
        f.vault.try_claim_withdrawal(&griefer, &dust),
        Err(Ok(VaultError::PaymentRejected))
    );

    // Anybody may step the queue over it. The claim is not paid, not lost, and
    // no longer in the way.
    assert_eq!(f.vault.settle_withdrawal(), dust);
    assert!(f.vault.is_deferred(&dust));
    assert!(!f.vault.get_claim(&dust).claimed);
    assert_eq!(f.vault.queue_head(), 2);
    // Still owed, so its cash is still reserved and still undeployable.
    assert_eq!(f.vault.outstanding_liabilities(), 501 * USDC);
    assert_eq!(f.vault.free_reserves(), 0);

    // Bob, who has done nothing wrong, is paid.
    f.vault.claim_withdrawal(&bob, &real);
    assert_eq!(f.usdc.balance(&bob), 500 * USDC);
    assert_eq!(f.vault.outstanding_liabilities(), 1 * USDC);
    assert_eq!(f.vault.queue_length(), 0);
}

/// A deferred claim is a delayed payment, not a forfeited one.
#[test]
fn a_deferred_claim_is_still_owed_and_collectable_out_of_order() {
    let f = frozen_setup();
    let griefer = Address::generate(&f.e);
    let bob = Address::generate(&f.e);
    f.usdc.faucet(&griefer, &(10 * USDC));
    f.usdc.faucet(&bob, &(500 * USDC));
    f.vault.deposit(&griefer, &(10 * USDC));
    f.vault.deposit(&bob, &(500 * USDC));

    let stuck = f.vault.request_withdrawal(&griefer, &(10 * USDC));
    let after = f.vault.request_withdrawal(&bob, &(500 * USDC));
    f.usdc.block(&griefer);
    f.vault.settle_withdrawal();
    f.vault.claim_withdrawal(&bob, &after);

    // Nobody else can take it, in either entry point. `settle_withdrawal` has
    // already passed it, and it is not anybody else's claim.
    assert_eq!(
        f.vault.try_claim_withdrawal(&bob, &stuck),
        Err(Ok(VaultError::NotClaimOwner))
    );
    assert_eq!(
        f.vault.try_settle_withdrawal(),
        Err(Ok(VaultError::QueueEmpty))
    );

    // The obstruction goes away, and the owner collects, out of head order,
    // without dragging the head pointer backwards.
    f.usdc.unblock();
    assert_eq!(f.vault.claim_status(&stuck), ClaimStatus::Ready);
    f.vault.claim_withdrawal(&griefer, &stuck);
    assert_eq!(f.usdc.balance(&griefer), 10 * USDC);
    assert_eq!(f.vault.queue_head(), 3);
    assert!(!f.vault.is_deferred(&stuck));
    assert_eq!(f.vault.claim_status(&stuck), ClaimStatus::Claimed);

    // Once, and only once. The liability was decremented exactly one time.
    assert_eq!(
        f.vault.try_claim_withdrawal(&griefer, &stuck),
        Err(Ok(VaultError::AlreadyClaimed))
    );
    assert_eq!(f.vault.outstanding_liabilities(), 0);
    assert_eq!(f.vault.idle_reserves(), 0);
}

/// Stepping over a claim does not hand it to whoever stepped over it, and it
/// does not make it collectable by anyone but its owner.
///
/// Checked with targeted authorizations rather than the fixture's blanket mock,
/// which turns authorization off wholesale and would prove nothing here.
#[test]
fn only_the_owner_can_collect_a_deferred_claim() {
    let f = frozen_setup();
    let owner = Address::generate(&f.e);
    let stranger = Address::generate(&f.e);
    f.usdc.faucet(&owner, &(10 * USDC));
    f.vault.deposit(&owner, &(10 * USDC));
    let claim = f.vault.request_withdrawal(&owner, &(10 * USDC));
    f.usdc.block(&owner);
    f.vault.settle_withdrawal();
    f.usdc.unblock();

    // A stranger signing for itself: refused on ownership.
    f.e.mock_auths(&[MockAuth {
        address: &stranger,
        invoke: &MockAuthInvoke {
            contract: &f.vault.address,
            fn_name: "claim_withdrawal",
            args: (stranger.clone(), claim).into_val(&f.e),
            sub_invokes: &[],
        },
    }]);
    assert_eq!(
        f.vault.try_claim_withdrawal(&stranger, &claim),
        Err(Ok(VaultError::NotClaimOwner))
    );

    // A stranger naming the owner: refused on authorization, because the call
    // is not signed by the address it claims to be acting for.
    f.e.mock_auths(&[MockAuth {
        address: &stranger,
        invoke: &MockAuthInvoke {
            contract: &f.vault.address,
            fn_name: "claim_withdrawal",
            args: (owner.clone(), claim).into_val(&f.e),
            sub_invokes: &[],
        },
    }]);
    assert!(f.vault.try_claim_withdrawal(&owner, &claim).is_err());
    assert_eq!(f.usdc.balance(&stranger), 0);
    assert_eq!(f.usdc.balance(&owner), 0);
    assert!(f.vault.is_deferred(&claim));

    // The owner, signing for itself, is paid.
    f.e.mock_auths(&[MockAuth {
        address: &owner,
        invoke: &MockAuthInvoke {
            contract: &f.vault.address,
            fn_name: "claim_withdrawal",
            args: (owner.clone(), claim).into_val(&f.e),
            sub_invokes: &[],
        },
    }]);
    f.vault.claim_withdrawal(&owner, &claim);
    assert_eq!(f.usdc.balance(&owner), 10 * USDC);
}

/// The reserve floor is a share of a base a write-down cannot move.
///
/// `record_writedown` lowers `deployed_capital` with no cash moving. While the
/// floor was a share of net assets, that lowered the floor's absolute size by
/// `floor_bps` of whatever was written off, so allocating to the floor and
/// writing the position down, over and over, walked the entire reserves out of
/// the Vault in slices that were each individually inside the limit. On this
/// exact fixture it left one stroop of a 1000 USDC book behind a 25% floor.
#[test]
fn a_write_down_buys_no_room_under_the_reserve_floor() {
    let f = setup();
    f.engine.set_reserve_floor(&f.admin, &2_500u32);
    f.vault.set_reserve_floor(&f.admin, &2_500u32);
    depositor(&f, 1_000 * USDC);

    // One honest allocation takes the book to the floor, and the floor holds.
    f.engine.allocate(&f.admin, &f.pool, &(750 * USDC));
    assert_eq!(f.vault.free_reserves(), 250 * USDC);
    assert!(f.engine.try_allocate(&f.admin, &f.pool, &1).is_err());

    // Recognise the whole position as lost. No cash moves: the adapter is still
    // holding every dollar of it.
    f.engine
        .write_down(&f.admin, &f.pool, &(750 * USDC), &symbol_short!("DEFAULT"));
    assert_eq!(f.usdc.balance(&f.pool), 750 * USDC);
    assert_eq!(f.vault.deployed_capital(), 0);
    assert_eq!(f.vault.recognised_losses(), 750 * USDC);

    // The base the floor is a share of has not moved, so neither has the floor.
    assert_eq!(f.vault.get_net_assets(), 250 * USDC);
    assert_eq!(f.vault.floor_base(), 1_000 * USDC);

    // Everything from here runs against a second pool, with its own originator
    // and its own jurisdiction. The Engine now charges a write-off against the
    // cap of the pool it happened at, so the defaulted pool is over its own
    // concentration limit and a refusal there would be that limit rather than
    // the floor. The floor is a limit on the whole book, so the honest place to
    // ask whether a write-down reopened it is a pool the write-down is not
    // already answering for.
    let clean = f.e.register(
        PrivateCreditAdapter,
        (
            f.admin.clone(),
            f.engine.address.clone(),
            f.vault.address.clone(),
            f.usdc.address.clone(),
        ),
    );
    f.engine.register_pool(
        &f.admin,
        &clean,
        &symbol_short!("SOLO"),
        &symbol_short!("MX"),
        &10_000u32,
    );
    assert_eq!(
        f.engine.try_allocate(&f.admin, &clean, &1),
        Err(Ok(EngineError::ReserveFloorBreached))
    );

    // And it stays put however many times the loop is run.
    for _ in 0..40 {
        let free = f.vault.free_reserves();
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
        f.vault.free_reserves(),
        250 * USDC,
        "the 25% floor has to hold across write-downs, not only across allocations"
    );

    // A fresh deposit raises the base and releases headroom in the ordinary
    // way, so the guard fails closed without stranding the contract.
    depositor(&f, 1_000 * USDC);
    assert_eq!(f.vault.floor_base(), 2_000 * USDC);
    f.engine.allocate(&f.admin, &clean, &(750 * USDC));
    assert_eq!(f.vault.free_reserves(), 500 * USDC);
    assert!(f.engine.try_allocate(&f.admin, &clean, &1).is_err());
}

/// A recovery is the receipt that contradicts a write-down, and the Vault
/// believes it exactly as far as it believes a repayment: not at all, until the
/// cash is in its own balance. `record_recovery` moves `recognised_losses`,
/// which is a term in the base the reserve floor is a percentage of, so an
/// amount that can be asserted rather than seen is an amount that buys
/// deployable headroom out of nothing.
///
/// The second half is the one the whole design turns on. The loss the recovery
/// takes out of the base is, stroop for stroop, the cash it puts into free
/// reserves, so `floor_base` does not move. What a write-down cannot buy, a
/// recovery cannot buy back.
#[test]
fn a_recovery_has_to_have_arrived_and_leaves_the_floors_base_where_it_was() {
    let f = setup();
    depositor(&f, 1_000 * USDC);
    f.engine.allocate(&f.admin, &f.pool, &(400 * USDC));
    // Three quarters of the position is recognised as lost. No cash moves: the
    // adapter is still holding every dollar the Vault released to it.
    f.engine
        .write_down(&f.admin, &f.pool, &(300 * USDC), &symbol_short!("DEFAULT"));

    assert_eq!(f.vault.recognised_losses(), 300 * USDC);
    assert_eq!(f.vault.deployed_capital(), 100 * USDC);
    assert_eq!(f.vault.idle_reserves(), 600 * USDC);
    assert_eq!(f.vault.booked_reserves(), 600 * USDC);
    assert_eq!(f.vault.floor_base(), 1_000 * USDC);
    assert_eq!(f.usdc.balance(&f.pool), 400 * USDC);

    // Nothing has arrived that the Vault cannot already account for, so one
    // stroop is one stroop too many.
    assert_eq!(
        f.vault.try_record_recovery(&f.admin, &1),
        Err(Ok(VaultError::RecoveryNotReceived))
    );
    assert_eq!(f.vault.recognised_losses(), 300 * USDC);
    assert_eq!(f.vault.floor_base(), 1_000 * USDC);

    // The adapter sweeps 150 USDC of the defaulted position home. From inside
    // the Vault a sweep is nothing more than a balance that grew without the
    // Vault being told, which is exactly what the check measures.
    f.usdc.transfer(&f.pool, &f.vault.address, &(150 * USDC));
    assert_eq!(f.vault.idle_reserves(), 750 * USDC);
    assert_eq!(f.vault.booked_reserves(), 600 * USDC);

    // Still bounded by what actually landed, to the stroop.
    assert_eq!(
        f.vault.try_record_recovery(&f.admin, &(150 * USDC + 1)),
        Err(Ok(VaultError::RecoveryNotReceived))
    );

    f.vault.record_recovery(&f.admin, &(150 * USDC));
    assert_eq!(f.vault.recognised_losses(), 150 * USDC);
    assert_eq!(f.vault.booked_reserves(), 750 * USDC);
    // A recovery is not a repayment and must not behave like one: the deployed
    // book was cleared of this capital by the write-down and nothing here puts
    // it back.
    assert_eq!(f.vault.deployed_capital(), 100 * USDC);
    assert_eq!(
        f.vault.floor_base(),
        1_000 * USDC,
        "the loss released from the base has to equal the cash added to reserves"
    );
}

/// Surplus above the losses on the book is interest, not an error. It is a
/// recovery that was never written off, so there is nothing for it to release,
/// and the arithmetic has to floor at zero rather than run `recognised_losses`
/// negative: a negative loss in the floor's base is a discount on the buffer
/// every future release is measured against.
///
/// It books as reserves like any other asset, so the base rises by exactly the
/// excess and the floor asks for its share of it.
#[test]
fn a_recovery_larger_than_the_losses_clears_them_and_lifts_the_base() {
    let f = setup();
    depositor(&f, 1_000 * USDC);
    f.engine.allocate(&f.admin, &f.pool, &(400 * USDC));
    f.engine
        .write_down(&f.admin, &f.pool, &(300 * USDC), &symbol_short!("DEFAULT"));
    assert_eq!(f.vault.floor_base(), 1_000 * USDC);

    // The originator repays the whole 400 USDC, which is 100 more than was ever
    // written off against it.
    f.usdc.transfer(&f.pool, &f.vault.address, &(400 * USDC));
    f.vault.record_recovery(&f.admin, &(400 * USDC));

    assert_eq!(
        f.vault.recognised_losses(),
        0,
        "the losses stop at zero rather than going negative"
    );
    assert_eq!(f.vault.booked_reserves(), 1_000 * USDC);
    assert_eq!(f.vault.deployed_capital(), 100 * USDC);
    // 400 in, 300 of it released against a loss, so the base is up by the 100
    // that was pure surplus and by nothing else.
    assert_eq!(f.vault.floor_base(), 1_100 * USDC);
}

/// `bump_claim` takes no authorization at all, and that is a decision rather
/// than an omission. The caller chooses no amount, no recipient and no claim
/// state; the only effect is to postpone an archival, and the caller pays the
/// rent for it. Extending a stranger's TTL is a donation, and the keeper that
/// has to send these transactions holds none of the protocol's keys.
///
/// The contrast is what proves it. In the same state, against the same claim,
/// with the same explicitly empty authorization list, the call that does need a
/// signature is refused and this one is not.
#[test]
fn bumping_a_claim_needs_no_authorization_while_collecting_one_does() {
    let f = setup();
    let alice = depositor(&f, 1_000 * USDC);
    let claim_id = f.vault.request_withdrawal(&alice, &(400 * USDC));
    assert_eq!(f.vault.claim_status(&claim_id), ClaimStatus::Ready);

    // Replace the fixture's blanket mock with an empty authorization list.
    // Nothing is signed for by anybody from here on.
    f.e.set_auths(&[]);

    // Alice cannot take her own claim, and it is at the head of the queue with
    // the cash sitting there, so the only thing missing is her signature.
    assert!(f.vault.try_claim_withdrawal(&alice, &claim_id).is_err());
    assert_eq!(f.vault.claim_status(&claim_id), ClaimStatus::Ready);

    // The same unauthorized caller can keep the entry readable.
    f.vault.bump_claim(&claim_id);
    assert_eq!(f.vault.claim_status(&claim_id), ClaimStatus::Ready);
    assert_eq!(f.vault.get_claim(&claim_id).owner, alice);
    assert_eq!(f.vault.get_claim(&claim_id).amount, 400 * USDC);

    // Refusing an id that was never issued is about the claim rather than the
    // caller, which is the only thing this entry point is allowed to refuse
    // for.
    assert_eq!(
        f.vault.try_bump_claim(&9_999),
        Err(Ok(VaultError::ClaimNotFound))
    );
}

/// The bump has to postpone the archival rather than merely return success.
/// Claims are persistent and bumped only when they are written, the book behind
/// them settles at D+15 to D+90 against a 90 day TTL, and an archived
/// persistent entry cannot be read: `read_claim` fails and takes
/// `claim_withdrawal` and `settle_withdrawal` with it, so the whole queue stops
/// at the head until somebody pays for a `RestoreFootprint`.
///
/// Read straight off the ledger entry, because the property is the remaining
/// TTL and nothing the contract returns reports it.
#[test]
fn bumping_a_claim_pushes_its_archival_back_out() {
    let f = setup();
    let alice = depositor(&f, 1_000 * USDC);
    let claim_id = f.vault.request_withdrawal(&alice, &(400 * USDC));
    let vault_id = f.vault.address.clone();

    let ttl_at_request = f.e.as_contract(&vault_id, || {
        f.e.storage().persistent().get_ttl(&Store::Claim(claim_id))
    });
    assert_eq!(ttl_at_request, CLAIM_BUMP);

    // The queue stalls for a while behind a book that has not settled. Nothing
    // writes to the claim, so nothing extends it, and it ages by exactly the
    // ledgers that pass.
    f.e.ledger().with_mut(|l| l.sequence_number += 200_000);
    let ttl_while_waiting = f.e.as_contract(&vault_id, || {
        f.e.storage().persistent().get_ttl(&Store::Claim(claim_id))
    });
    assert!(
        ttl_while_waiting < ttl_at_request,
        "an untouched claim has to be measurably closer to archival"
    );
    assert_eq!(ttl_while_waiting, CLAIM_BUMP - 200_000);

    f.vault.bump_claim(&claim_id);
    let ttl_after_bump = f.e.as_contract(&vault_id, || {
        f.e.storage().persistent().get_ttl(&Store::Claim(claim_id))
    });
    assert!(
        ttl_after_bump > ttl_while_waiting,
        "the bump has to buy the claim time it did not have"
    );
    assert_eq!(ttl_after_bump, CLAIM_BUMP);

    // And the claim is still the same claim: postponing an archival is the only
    // thing that happened to it.
    assert_eq!(f.vault.get_claim(&claim_id).owner, alice);
    assert_eq!(f.vault.get_claim(&claim_id).amount, 400 * USDC);
    assert_eq!(f.vault.claim_status(&claim_id), ClaimStatus::Ready);
}

/// USDC is the one counterparty the constructor takes, because it is the one
/// that is not circular, and it is also the one pointer in this contract with
/// no setter at all. Getting it right in the deploy is the only chance there
/// is, so the constructor checks it as far as an address can be checked: it has
/// to answer the token interface, which an ordinary account cannot. The deploy
/// fails rather than producing a Vault that can never take a deposit.
#[test]
#[should_panic(expected = "#325")]
fn a_vault_cannot_be_constructed_against_a_usdc_that_is_not_a_token() {
    let f = setup();
    let not_a_token = Address::generate(&f.e);
    f.e.register(Vault, (f.admin.clone(), not_a_token));
}

/// `set_agusd` is the only door the agUSD pointer has, so it runs the check the
/// constructor cannot: the token has to name this Vault as its minter. A token
/// that names somebody else is a Vault that holds the deposit and cannot issue
/// a unit against it, and that is not a hypothetical. It is how the first Vault
/// was lost, and it cost a redeployment of two contracts to find out.
#[test]
fn the_agusd_pointer_refuses_a_token_this_vault_cannot_mint() {
    let f = setup();
    let stranger = Address::generate(&f.e);

    // A well formed agUSD in every respect except the one that matters: its
    // mint authority is somebody else.
    let foreign_id = f.e.register(MockUsdc, ());
    MockUsdcClient::new(&f.e, &foreign_id).initialize(
        &stranger,
        &7u32,
        &String::from_str(&f.e, "Agama USD"),
        &String::from_str(&f.e, "agUSD"),
    );
    assert_eq!(MockUsdcClient::new(&f.e, &foreign_id).minter(), stranger);
    assert_eq!(
        f.vault.try_set_agusd(&f.admin, &foreign_id),
        Err(Ok(VaultError::AgUsdMismatch))
    );

    // An address that cannot answer `minter()` at all is refused the same way,
    // because the question is asked rather than assumed.
    assert_eq!(
        f.vault.try_set_agusd(&f.admin, &stranger),
        Err(Ok(VaultError::AgUsdMismatch))
    );

    // The pointer has not moved, and the Vault still mints through the token
    // that does name it back.
    assert_eq!(f.vault.agusd(), f.agusd.address);
    let alice = depositor(&f, 100 * USDC);
    assert_eq!(f.agusd.balance(&alice), 100 * USDC);
}

/// The constructor deliberately writes no Engine, so every Vault spends the
/// window between its deploy and its first `set_engine` unable to release a
/// stroop. That is the property that makes `set_engine`, which interrogates the
/// incoming Engine and refuses one that does not name this Vault back, the only
/// door the Engine pointer has: there is no other way for an address to end up
/// in it and no default that would do while it is empty.
#[test]
fn a_vault_that_has_not_been_given_an_engine_releases_nothing() {
    let f = setup();

    // Constructed and nothing else, and funded, so that the refusals below
    // cannot be read as an empty balance.
    let bare_id = f.e.register(Vault, (f.admin.clone(), f.usdc.address.clone()));
    let bare = VaultClient::new(&f.e, &bare_id);
    f.usdc.faucet(&bare_id, &(1_000 * USDC));
    assert_eq!(bare.idle_reserves(), 1_000 * USDC);

    assert_eq!(
        bare.try_allocation_engine(),
        Err(Ok(VaultError::NotInitialized))
    );
    let pool = Address::generate(&f.e);
    assert_eq!(
        bare.try_settle_allocation(&pool, &(100 * USDC)),
        Err(Ok(VaultError::NotInitialized))
    );
    assert_eq!(bare.idle_reserves(), 1_000 * USDC);
    assert_eq!(f.usdc.balance(&pool), 0);

    // The door, and only the door. An Engine that answers that it governs this
    // Vault and arrives with an empty book gets the pointer, and the release
    // that was NotInitialized a transaction ago goes through.
    let (engine, spare_pool) = spare_engine(&f, &bare_id);
    bare.set_engine(&f.admin, &engine.address);
    bare.set_reserve_floor(&f.admin, &0u32);
    assert_eq!(bare.allocation_engine(), engine.address);

    engine.allocate(&f.admin, &spare_pool, &(100 * USDC));
    assert_eq!(bare.idle_reserves(), 900 * USDC);
    assert_eq!(bare.deployed_capital(), 100 * USDC);
    assert_eq!(f.usdc.balance(&spare_pool), 100 * USDC);
}
