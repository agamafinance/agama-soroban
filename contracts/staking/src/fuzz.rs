#![cfg(test)]
//! Property-based fuzzing of the sagUSD accounting invariants, over
//! randomised sequences of stake, request_unstake, claim and distribute_yield,
//! interleaved with random jumps of the ledger clock so the unstake cooldown
//! is sometimes still running and sometimes long past.
//!
//! # What this suite mocks
//!
//! Every case calls `Env::mock_all_auths()`, exactly as `test.rs` does, which
//! disables Soroban's authorization checking wholesale. This suite is about
//! the arithmetic that has to survive an arbitrary interleaving of
//! operations, not about who is allowed to trigger them; it proves nothing
//! about authorization one way or the other. agUSD is stood in for by a plain
//! SEP-41 token with an open faucet, the same substitution `vault`'s own test
//! suite makes, since nothing under test here depends on which token it is.
//!
//! # Invariants
//!
//!  - the contract's own agUSD balance always equals `nav()` plus the sum of
//!    every pending unstake, which is the whole of what backs an unmatured
//!    claim once its shares are already burned
//!  - the sagUSD share price (`exchange_rate`, aliased as `share_price`)
//!    never decreases, other than the well defined reset to 1.0 when the
//!    share supply itself returns to zero, at which point there is nobody
//!    left for a lower price to harm and nothing left for a higher one to
//!    describe
//!
//! Both are checked after every step, successful or not: a failed `try_` call
//! leaves no trace in storage, so the invariants hold identically either way.

extern crate std;

use super::*;
use mock_usdc::{MockUsdc, MockUsdcClient};
use proptest::prelude::*;
use proptest::test_runner::TestCaseError;
use soroban_sdk::testutils::{Address as _, Ledger as _};

const USDC: i128 = 10_000_000; // 1.0 at 7 decimals, whatever the token
const COOLDOWN: u64 = 300; // 5 minutes, matching test.rs
const NUM_USERS: usize = 4;

type PResult = Result<(), TestCaseError>;

#[derive(Clone, Debug)]
enum Op {
    Stake { user: usize, amount: i128 },
    RequestUnstake { user: usize, shares: i128 },
    Claim { user: usize },
    DistributeYield { amount: i128 },
    AdvanceTime { seconds: u64 },
}

/// Amounts drawn from the boundaries that matter (zero, negative, one stroop)
/// plus an ordinary range.
fn amount_strategy() -> impl Strategy<Value = i128> {
    prop_oneof![
        2 => Just(0i128),
        2 => Just(-1i128),
        2 => Just(1i128),
        10 => 1i128..=5_000 * USDC,
    ]
}

fn op_strategy() -> impl Strategy<Value = Op> {
    prop_oneof![
        5 => (0usize..NUM_USERS, amount_strategy())
            .prop_map(|(user, amount)| Op::Stake { user, amount }),
        5 => (0usize..NUM_USERS, amount_strategy())
            .prop_map(|(user, shares)| Op::RequestUnstake { user, shares }),
        4 => (0usize..NUM_USERS).prop_map(|user| Op::Claim { user }),
        3 => amount_strategy().prop_map(|amount| Op::DistributeYield { amount }),
        3 => (0u64..=3 * COOLDOWN).prop_map(|seconds| Op::AdvanceTime { seconds }),
    ]
}

struct FuzzState {
    e: Env,
    staking: StakingClient<'static>,
    staking_id: Address,
    agusd: MockUsdcClient<'static>,
    users: [Address; NUM_USERS],
    admin: Address,
    prev_price: Option<i128>,
}

impl FuzzState {
    fn user(&self, idx: usize) -> Address {
        self.users[idx % NUM_USERS].clone()
    }

    fn pending_sum(&self) -> i128 {
        self.users
            .iter()
            .map(|u| self.staking.pending(u).assets)
            .sum()
    }
}

fn setup() -> FuzzState {
    let e = Env::default();
    e.mock_all_auths();
    e.ledger().set_timestamp(1_000_000);

    let admin = Address::generate(&e);
    let users: [Address; NUM_USERS] = core::array::from_fn(|_| Address::generate(&e));

    let agusd_id = e.register(MockUsdc, ());
    let agusd = MockUsdcClient::new(&e, &agusd_id);
    agusd.initialize(
        &admin,
        &7u32,
        &String::from_str(&e, "Agama USD"),
        &String::from_str(&e, "agUSD"),
    );

    let staking_id = e.register(
        Staking,
        (
            admin.clone(),
            agusd_id.clone(),
            COOLDOWN,
            7u32,
            String::from_str(&e, "Staked agUSD"),
            String::from_str(&e, "sagUSD"),
        ),
    );
    let staking = StakingClient::new(&e, &staking_id);

    FuzzState {
        e,
        staking,
        staking_id,
        agusd,
        users,
        admin,
        prev_price: None,
    }
}

fn apply(state: &mut FuzzState, op: &Op) -> PResult {
    match op {
        Op::Stake { user, amount } => {
            let who = state.user(*user);
            if *amount > 0 {
                let _ = state.agusd.try_faucet(&who, amount);
            }
            let _ = state.staking.try_stake(&who, amount);
        }
        Op::RequestUnstake { user, shares } => {
            let who = state.user(*user);
            let _ = state.staking.try_request_unstake(&who, shares);
        }
        Op::Claim { user } => {
            let who = state.user(*user);
            let _ = state.staking.try_claim(&who);
        }
        Op::DistributeYield { amount } => {
            if *amount > 0 {
                let _ = state.agusd.try_faucet(&state.admin, amount);
            }
            let _ = state.staking.try_distribute_yield(amount);
        }
        Op::AdvanceTime { seconds } => {
            let now = state.e.ledger().timestamp();
            state.e.ledger().set_timestamp(now + seconds);
        }
    }
    Ok(())
}

fn check_invariants(state: &mut FuzzState) -> PResult {
    // The contract's own agUSD balance always equals nav() plus every
    // pending unstake: shares are burned and assets leave `nav` the moment a
    // pending unstake is recorded, so that pair is the whole of what the
    // balance still has to account for until claim() pays it out.
    let balance = state.agusd.balance(&state.staking_id);
    let nav = state.staking.nav();
    let pending_sum = state.pending_sum();
    prop_assert_eq!(
        balance,
        nav + pending_sum,
        "staking contract's agUSD balance diverged from nav() plus pending unstakes"
    );

    // The share price never decreases, except for the well defined reset to
    // 1.0 when the last share is redeemed: at that point request_unstake has
    // already returned every stroop of nav to its owner (shares == supply
    // divides exactly), so there is no held position for a reset to harm.
    let supply = state.staking.total_shares();
    let price = state.staking.exchange_rate();
    if supply == 0 {
        state.prev_price = None;
    } else {
        if let Some(prev) = state.prev_price {
            prop_assert!(
                price >= prev,
                "sagUSD share price fell from {} to {}",
                prev,
                price
            );
        }
        state.prev_price = Some(price);
    }

    Ok(())
}

proptest! {
    #![proptest_config(ProptestConfig::with_cases(64))]

    #[test]
    fn staking_accounting_invariants_hold(ops in proptest::collection::vec(op_strategy(), 1..40)) {
        let mut state = setup();
        check_invariants(&mut state)?;
        for op in &ops {
            apply(&mut state, op)?;
            check_invariants(&mut state)?;
        }
    }
}
