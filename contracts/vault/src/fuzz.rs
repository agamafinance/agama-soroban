#![cfg(test)]
//! Property-based fuzzing of the accounting invariants across the Vault, the
//! Allocation Engine and two pool adapters, over randomised sequences of the
//! operations a depositor, an operator and the withdrawal queue itself can
//! perform.
//!
//! # What this suite mocks
//!
//! Every case calls `Env::mock_all_auths()`, exactly as `test.rs` does, which
//! disables Soroban's authorization checking wholesale: any call is
//! authorized for any caller. That is a real limitation and it is stated here
//! rather than left implicit. This suite fuzzes the arithmetic that has to
//! survive an arbitrary interleaving of operations; it proves nothing about
//! who is allowed to trigger them. Authorization has its own hand-written
//! tests in `test.rs`, several of which use targeted `mock_auths` for exactly
//! that reason.
//!
//! # Scope
//!
//! Randomised sequences of deposit, request_withdrawal, claim_withdrawal,
//! settle_withdrawal, allocate, deallocate, write_down, recover, book_recovery,
//! a direct USDC donation (to give `book_recovery` something to book against,
//! since that call is the one path that recognises cash the Vault was never
//! told about) and pause/unpause, over two registered pools of different
//! adapter kinds, checking after every step:
//!
//!  - agUSD supply tracks USDC deposited minus USDC requested for withdrawal
//!    (the burn happens at request time, not at claim time, so this is the
//!    sum the contract's own mint and burn calls actually make)
//!  - `get_total_assets` equals idle reserves plus the sum of every adapter's
//!    own `get_exposure`
//!  - `free_reserves` equals idle reserves minus `outstanding_liabilities`,
//!    clamped at zero, and is never negative
//!  - `outstanding_liabilities` equals the sum of every unclaimed queued claim
//!  - the sum of adapter exposures never exceeds `deployed_capital`
//!  - a successful `allocate` never leaves free reserves below the floor
//!  - every adapter's own USDC balance is never less than what it has booked
//!    as exposure
//!  - whichever entry point pays a claim, claims are paid in strict FIFO
//!    order: if claim `k` is paid, every claim before it is paid too
//!  - `floor_base` is left exactly unchanged by allocate, deallocate, a
//!    payout and a write-down, and is never lowered by a recovery
//!
//! `floor_base` genuinely falls on `request_withdrawal`, because that is the
//! moment a queued claim's agUSD is burned and its cash stops being free, and
//! it genuinely rises on `deposit` and on the direct donation modelled here.
//! Both are ordinary economic activity rather than the property under test, so
//! this suite does not assert monotonicity across them. What is under test is
//! the specific guarantee described in the module docs on
//! `Vault::recognised_losses`: that a write-down cannot manufacture releasable
//! headroom, and a recovery cannot give back less than it took.
//!
//! `book_recovery` is deliberately left out of that last bullet. This suite
//! found, and `book_recovery_can_lower_floor_base` below demonstrates by hand,
//! that it does not hold: `book_recovery` can lower `floor_base`, contrary to
//! its own module docs. See that test for the mechanism and the PR
//! description for the write-up. The combined sequence below still exercises
//! `book_recovery` for the other invariants, which do hold for it; only the
//! `floor_base` claim is excluded here, in favour of the dedicated failing
//! test that documents the break on its own.
//!
//! Deferred claims, the path where the token itself refuses a payout, are
//! outside what this suite can reach: the mock USDC used here never refuses a
//! transfer once the balance is sufficient, and the Vault checks liquidity
//! before attempting one, so `settle_withdrawal` cannot exercise that branch
//! from this harness. It has its own hand-written test in `test.rs`.
//!
//! Every contract call here goes through the `try_` client method, and a
//! failing attempt is simply skipped: a failed call leaves no trace in
//! storage, so there is nothing to reconcile, and the invariants below are
//! checked identically whether the step before them did anything or not. A
//! failing case is shrunk and persisted by `proptest` to a regression file
//! next to this one, which is what makes it replayable: rerunning the suite
//! picks the persisted case up automatically.

extern crate std;

use std::vec;

use super::*;
use allocation_engine::{AllocationEngine, AllocationEngineClient};
use etherfuse::{EtherfuseAdapter, EtherfuseAdapterClient};
use mock_usdc::{MockUsdc, MockUsdcClient};
use private_credit::{PrivateCreditAdapter, PrivateCreditAdapterClient};
use proptest::prelude::*;
use proptest::test_runner::TestCaseError;
use soroban_sdk::testutils::Address as _;
use soroban_sdk::{symbol_short, String};

const USDC: i128 = 10_000_000; // 1 USDC at 7 decimals
const BPS: i128 = 10_000;
const NUM_USERS: usize = 4;

type PResult = Result<(), TestCaseError>;

#[derive(Clone, Debug)]
enum Op {
    Deposit { user: usize, amount: i128 },
    RequestWithdrawal { user: usize, amount: i128 },
    ClaimWithdrawal { claim_id: u64 },
    SettleWithdrawal,
    Allocate { pool: usize, amount: i128 },
    Deallocate { pool: usize, amount: i128 },
    WriteDown { pool: usize, amount: i128 },
    Recover { pool: usize },
    Donate { amount: i128 },
    BookRecovery { pool: usize, amount: i128 },
    SetPaused(bool),
}

/// Amounts drawn from the boundaries that matter (zero, negative, either side
/// of the anti-dust floor) plus an ordinary range, weighted so most cases are
/// ordinary but the boundaries show up often enough to matter.
fn amount_strategy() -> impl Strategy<Value = i128> {
    prop_oneof![
        2 => Just(0i128),
        2 => Just(-1i128),
        2 => Just(MIN_WITHDRAWAL - 1),
        2 => Just(MIN_WITHDRAWAL),
        2 => Just(MIN_WITHDRAWAL + 1),
        10 => 1i128..=5_000 * USDC,
    ]
}

fn op_strategy() -> impl Strategy<Value = Op> {
    prop_oneof![
        4 => (0usize..NUM_USERS, amount_strategy())
            .prop_map(|(user, amount)| Op::Deposit { user, amount }),
        4 => (0usize..NUM_USERS, amount_strategy())
            .prop_map(|(user, amount)| Op::RequestWithdrawal { user, amount }),
        4 => (1u64..=40).prop_map(|claim_id| Op::ClaimWithdrawal { claim_id }),
        4 => Just(Op::SettleWithdrawal),
        4 => (0usize..2, amount_strategy())
            .prop_map(|(pool, amount)| Op::Allocate { pool, amount }),
        3 => (0usize..2, amount_strategy())
            .prop_map(|(pool, amount)| Op::Deallocate { pool, amount }),
        2 => (0usize..2, amount_strategy())
            .prop_map(|(pool, amount)| Op::WriteDown { pool, amount }),
        2 => (0usize..2usize).prop_map(|pool| Op::Recover { pool }),
        2 => amount_strategy().prop_map(|amount| Op::Donate { amount }),
        2 => (0usize..2, amount_strategy())
            .prop_map(|(pool, amount)| Op::BookRecovery { pool, amount }),
        1 => any::<bool>().prop_map(Op::SetPaused),
    ]
}

struct FuzzState {
    e: Env,
    vault: VaultClient<'static>,
    vault_id: Address,
    usdc: MockUsdcClient<'static>,
    usdc_id: Address,
    agusd: MockUsdcClient<'static>,
    engine: AllocationEngineClient<'static>,
    pc_pool: PrivateCreditAdapterClient<'static>,
    pc_pool_id: Address,
    ef_pool: EtherfuseAdapterClient<'static>,
    ef_pool_id: Address,
    users: [Address; NUM_USERS],
    admin: Address,
    total_deposited: i128,
    total_requested: i128,
    total_claims_created: u64,
}

impl FuzzState {
    fn pool_id(&self, idx: usize) -> Address {
        if idx % 2 == 0 {
            self.pc_pool_id.clone()
        } else {
            self.ef_pool_id.clone()
        }
    }

    fn sum_exposure(&self) -> i128 {
        self.pc_pool.get_exposure() + self.ef_pool.get_exposure()
    }

    fn user(&self, idx: usize) -> Address {
        self.users[idx % NUM_USERS].clone()
    }
}

/// The whole stack, wired the way `test.rs` wires it: Vault, Allocation
/// Engine, and two pools of different adapter kinds sharing a jurisdiction so
/// the jurisdiction cap aggregates across both. agUSD is stood in for by a
/// second SEP-41 token whose admin is the Vault, matching `test.rs`. The
/// Oracle Adapter is left out entirely: nothing in the invariants under test
/// reads NAV, and `get_nav` has its own suite in `test.rs`.
fn setup() -> FuzzState {
    let e = Env::default();
    e.mock_all_auths();

    let admin = Address::generate(&e);
    let users: [Address; NUM_USERS] = core::array::from_fn(|_| Address::generate(&e));

    let usdc_id = e.register(MockUsdc, ());
    let usdc = MockUsdcClient::new(&e, &usdc_id);
    usdc.initialize(
        &admin,
        &7u32,
        &String::from_str(&e, "USD Coin"),
        &String::from_str(&e, "USDC"),
    );

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
    vault.set_reserve_floor(&admin, &1_000u32); // 10%, matching the Engine's below

    let pc_pool_id = e.register(
        PrivateCreditAdapter,
        (
            admin.clone(),
            engine_id.clone(),
            vault_id.clone(),
            usdc_id.clone(),
        ),
    );
    let pc_pool = PrivateCreditAdapterClient::new(&e, &pc_pool_id);
    engine.register_pool(
        &admin,
        &pc_pool_id,
        &symbol_short!("PCORIG"),
        &symbol_short!("US"),
        &5_000u32, // 50%
    );

    let ef_pool_id = e.register(
        EtherfuseAdapter,
        (
            admin.clone(),
            engine_id.clone(),
            vault_id.clone(),
            usdc_id.clone(),
        ),
    );
    let ef_pool = EtherfuseAdapterClient::new(&e, &ef_pool_id);
    engine.register_pool(
        &admin,
        &ef_pool_id,
        &symbol_short!("EFORIG"),
        // Shares the private credit pool's jurisdiction on purpose, so the
        // jurisdiction cap aggregates across both adapter kinds rather than
        // being reachable through only one of them.
        &symbol_short!("US"),
        &5_000u32, // 50%
    );

    engine.set_caps(&admin, &5_000, &6_000, &8_000);
    engine.set_reserve_floor(&admin, &1_000u32); // 10%

    FuzzState {
        e,
        vault,
        vault_id,
        usdc,
        usdc_id,
        agusd,
        engine,
        pc_pool,
        pc_pool_id,
        ef_pool,
        ef_pool_id,
        users,
        admin,
        total_deposited: 0,
        total_requested: 0,
        total_claims_created: 0,
    }
}

fn apply(state: &mut FuzzState, op: &Op) -> PResult {
    match op {
        Op::Deposit { user, amount } => {
            let who = state.user(*user);
            if *amount > 0 {
                let _ = state.usdc.try_faucet(&who, amount);
            }
            if let Ok(Ok(minted)) = state.vault.try_deposit(&who, amount) {
                state.total_deposited += minted;
            }
        }
        Op::RequestWithdrawal { user, amount } => {
            let who = state.user(*user);
            let result = state.vault.try_request_withdrawal(&who, amount);
            if matches!(result, Ok(Ok(_))) {
                state.total_requested += amount;
                state.total_claims_created += 1;
            }
        }
        Op::ClaimWithdrawal { claim_id } => {
            if let Ok(Ok(claim)) = state.vault.try_get_claim(claim_id) {
                if !claim.claimed {
                    let _ = state.vault.try_claim_withdrawal(&claim.owner, claim_id);
                }
            }
        }
        Op::SettleWithdrawal => {
            let _ = state.vault.try_settle_withdrawal();
        }
        Op::Allocate { pool, amount } => {
            let pool_id = state.pool_id(*pool);
            let result = state.engine.try_allocate(&state.admin, &pool_id, amount);
            if matches!(result, Ok(Ok(()))) {
                let free = state.vault.free_reserves();
                let floor_bps = state.vault.reserve_floor_bps() as i128;
                let base = state.vault.floor_base();
                prop_assert!(
                    free * BPS >= floor_bps * base,
                    "allocate left free reserves below the floor: free={} floor_bps={} base={}",
                    free,
                    floor_bps,
                    base
                );
            }
        }
        Op::Deallocate { pool, amount } => {
            let pool_id = state.pool_id(*pool);
            let _ = state.engine.try_deallocate(&pool_id, amount);
        }
        Op::WriteDown { pool, amount } => {
            let pool_id = state.pool_id(*pool);
            let _ =
                state
                    .engine
                    .try_write_down(&state.admin, &pool_id, amount, &symbol_short!("FUZZ"));
        }
        Op::Recover { pool } => {
            let pool_id = state.pool_id(*pool);
            let _ = state.engine.try_recover(&state.admin, &pool_id);
        }
        Op::Donate { amount } => {
            if *amount > 0 {
                let donor = Address::generate(&state.e);
                if let Ok(Ok(())) = state.usdc.try_faucet(&donor, amount) {
                    let token = soroban_sdk::token::TokenClient::new(&state.e, &state.usdc_id);
                    let _ = token.try_transfer(&donor, &state.vault_id, amount);
                }
            }
        }
        Op::BookRecovery { pool, amount } => {
            let pool_id = state.pool_id(*pool);
            let _ = state
                .engine
                .try_book_recovery(&state.admin, &pool_id, amount);
        }
        Op::SetPaused(paused) => {
            let _ = state.vault.try_set_paused(&state.admin, paused);
        }
    }
    Ok(())
}

/// `floor_base` moves only the way the design intends. See the module docs
/// above for why deposit, request_withdrawal and the donation are out of
/// scope here.
fn check_floor_base(state: &FuzzState, op: &Op, before: i128) -> PResult {
    let after = state.vault.floor_base();
    match op {
        Op::Allocate { .. }
        | Op::Deallocate { .. }
        | Op::ClaimWithdrawal { .. }
        | Op::SettleWithdrawal
        | Op::WriteDown { .. }
        | Op::SetPaused(_) => {
            prop_assert_eq!(
                after,
                before,
                "floor_base moved on an operation the design says leaves it unchanged: {:?}",
                op
            );
        }
        Op::Recover { .. } => {
            prop_assert!(
                after >= before,
                "floor_base fell after a recovery: before={} after={} op={:?}",
                before,
                after,
                op
            );
        }
        // Not checked: see `book_recovery_can_lower_floor_base` below.
        Op::BookRecovery { .. } => {}
        Op::Deposit { .. } | Op::RequestWithdrawal { .. } | Op::Donate { .. } => {}
    }
    Ok(())
}

fn check_invariants(state: &FuzzState) -> PResult {
    // 1. agUSD supply tracks USDC deposited minus USDC requested for
    // withdrawal (mint happens on deposit, burn happens on request, both
    // exactly the amount passed in).
    prop_assert_eq!(
        state.agusd.total_supply(),
        state.total_deposited - state.total_requested,
        "agUSD supply drifted from deposits minus withdrawal requests"
    );

    // 2. total assets equal idle reserves plus the sum of every adapter's own
    // booked exposure, which is the three way consistency between the
    // Vault's, the Engine's and each adapter's own copy of the same number.
    let sum_exposure = state.sum_exposure();
    prop_assert_eq!(
        state.vault.get_total_assets(),
        state.vault.idle_reserves() + sum_exposure,
        "get_total_assets diverged from idle reserves plus adapter exposure"
    );

    // 3. free reserves are idle reserves less outstanding liabilities, floored
    // at zero, and never negative.
    let idle = state.vault.idle_reserves();
    let outstanding = state.vault.outstanding_liabilities();
    let expected_free = core::cmp::max(idle - outstanding, 0);
    let free = state.vault.free_reserves();
    prop_assert_eq!(
        free,
        expected_free,
        "free_reserves diverged from idle reserves minus outstanding liabilities"
    );
    prop_assert!(free >= 0, "free_reserves went negative");

    // 4 and 11. outstanding liabilities equal the sum of every unclaimed
    // queued claim, and claims are paid in strict FIFO order whichever entry
    // point pays them: if claim k is paid, every claim before it is paid too.
    let mut unclaimed_sum: i128 = 0;
    let mut earlier_all_claimed = true;
    for id in 1..=state.total_claims_created {
        if let Ok(Ok(claim)) = state.vault.try_get_claim(&id) {
            if claim.claimed {
                prop_assert!(
                    earlier_all_claimed,
                    "claim {} was paid out of FIFO order",
                    id
                );
            } else {
                earlier_all_claimed = false;
                unclaimed_sum += claim.amount;
            }
        }
    }
    prop_assert_eq!(
        outstanding,
        unclaimed_sum,
        "outstanding_liabilities diverged from the sum of unclaimed queued claims"
    );

    // 5. the sum of adapter exposures never exceeds the Vault's own record of
    // deployed capital.
    prop_assert!(
        sum_exposure <= state.vault.deployed_capital(),
        "adapter exposure exceeded the Vault's own deployed_capital"
    );

    // 10. no adapter ever holds less USDC than it has booked as exposure.
    prop_assert!(
        state.usdc.balance(&state.pc_pool_id) >= state.pc_pool.get_exposure(),
        "private credit adapter holds less USDC than its booked exposure"
    );
    prop_assert!(
        state.usdc.balance(&state.ef_pool_id) >= state.ef_pool.get_exposure(),
        "etherfuse adapter holds less USDC than its booked exposure"
    );

    Ok(())
}

proptest! {
    #![proptest_config(ProptestConfig::with_cases(24))]

    #[test]
    fn vault_engine_accounting_invariants_hold(ops in proptest::collection::vec(op_strategy(), 1..30)) {
        let mut state = setup();
        check_invariants(&state)?;
        for op in &ops {
            let floor_base_before = state.vault.floor_base();
            apply(&mut state, op)?;
            check_floor_base(&state, op, floor_base_before)?;
            check_invariants(&state)?;
        }
    }
}

/// `book_recovery` can lower `floor_base`, contradicting its own module docs:
/// "`floor_base` is unchanged where the recovery lands against a loss and
/// rises where it exceeds one, exactly as it is when `recover` supplies it.
/// What a write-down cannot buy, this cannot buy back."
///
/// The fuzzer above found the shape of this inside twenty lines of random
/// operations. What follows is the same finding written out with round
/// numbers so the mechanism is legible without reading a shrunk trace.
///
/// `recover` and `book_recovery` are documented as behaving identically with
/// respect to `floor_base`, and for `recover` that claim is true: the cash it
/// books was sitting in an adapter, which nothing in `floor_base` reads, so
/// the moment it lands in the Vault is the first moment it is counted, and
/// `free_reserves` rises there by exactly what `recognised_losses` falls by,
/// or more.
///
/// `book_recovery` books cash that is already inside the Vault's own idle
/// balance instead. `Vault::idle_reserves` reads the real token balance
/// directly and does not care whether `record_repayment` or `record_recovery`
/// has ever been told about it, so a stray transfer straight to the Vault (a
/// misdirected repayment, an over-payment, an operator's mistake) raises
/// `floor_base` once, the moment it arrives, whether or not anyone ever calls
/// `book_recovery` on it. Calling `book_recovery` afterwards, against any
/// registered pool, including one with no write-down against it at all, then
/// lowers `recognised_losses` by up to that same amount with no further cash
/// moving. The two effects do not cancel: the first already happened when the
/// cash landed, and the second spends the same dollar again, so `floor_base`
/// ends up lower than it stood right after the transfer arrived. That is a
/// real reduction in the reserve floor's base and, through it, in how much
/// idle USDC `allocate` is required to leave behind.
///
/// The module comment on `book_recovery` reasons that the call is safe
/// because "the global loss book and the Vault's both move by exactly the
/// cash that arrived", which is the `recover` reasoning, applied to a call
/// where the cash did not just arrive in this transaction. This test is the
/// counterexample to that sentence for `floor_base`. The comment's separate
/// point, that a recovery can be booked against the wrong pool and so free a
/// concentration charge that pool never earned back, is already disclosed
/// there and is not what this test is about.
#[test]
fn book_recovery_can_lower_floor_base() {
    let state = setup();

    // A stray transfer straight to the Vault. Nothing about the mechanism
    // requires this to be adversarial: an over-payment or a repayment sent to
    // the wrong address lands exactly the same way.
    let donor = Address::generate(&state.e);
    state.usdc.faucet(&donor, &(1_000 * USDC));
    let usdc_token = soroban_sdk::token::TokenClient::new(&state.e, &state.usdc_id);
    usdc_token.transfer(&donor, &state.vault_id, &(1_000 * USDC));

    let floor_base_after_donation = state.vault.floor_base();
    assert_eq!(floor_base_after_donation, 1_000 * USDC);

    // An unrelated pool default, recognised honestly through the Engine.
    // allocate and write_down are floor_base neutral, which this suite checks
    // on every case above; confirmed again here so the final assertion
    // isolates book_recovery as the only remaining suspect.
    state
        .engine
        .allocate(&state.admin, &state.ef_pool_id, &(500 * USDC));
    state.engine.write_down(
        &state.admin,
        &state.ef_pool_id,
        &(500 * USDC),
        &symbol_short!("FUZZ"),
    );
    assert_eq!(state.vault.floor_base(), floor_base_after_donation);

    // Book the stray transfer as a recovery against a different pool, one
    // that was never written down at all.
    state
        .engine
        .book_recovery(&state.admin, &state.pc_pool_id, &(500 * USDC));

    let floor_base_after_book_recovery = state.vault.floor_base();
    assert!(
        floor_base_after_book_recovery >= floor_base_after_donation,
        "floor_base fell from {} to {} after book_recovery, even though no \
         cash moved and the recovery was booked against a pool with no \
         write-down against it",
        floor_base_after_donation,
        floor_base_after_book_recovery
    );
}
