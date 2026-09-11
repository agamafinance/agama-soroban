#![cfg(test)]
//! Property-based fuzzing of the quorum, over randomised sequences of reports
//! from randomised reporters at randomised timestamps, with the threshold moved
//! underneath them.
//!
//! # Why this contract and why this property
//!
//! A quorum threshold above 1 buys exactly one thing: independence between
//! reporters. Everything else about a feed, the band, the staleness window, the
//! deviation bound and the minimum interval, binds on a single value and is
//! covered by the hand-written tests. What those cannot cover is the property
//! that only emerges across an interleaving: that a value commits only once
//! that many **distinct** reporters have agreed on it for the same round.
//!
//! That property was false when the quorum was first written. A round that
//! resolved and was refused cleared the record of who had voted in it and left
//! the losing tallies standing, so one reporter could seed a value, wait for the
//! round to be refused on another, vote for its own a second time and carry a
//! quorum of two alone.
//!
//! # What this suite does not cover, measured rather than assumed
//!
//! It does not find that one, and it is worth saying so rather than letting the
//! file's existence imply otherwise. The harness can see it: put the defect back
//! and hand it the sequence and it fires, which
//! `a_reporter_cannot_carry_a_round_alone_by_voting_into_it_twice` is the record
//! of. What it cannot do is generate the sequence. Reaching it needs four
//! specific steps inside one round, a seed, two reporters agreeing on something
//! the deviation bound will throw out, and the seeder returning, and uniform
//! generation did not produce it in 3000 cases over six slots, nor in 3000 with
//! the slots concentrated into three.
//!
//! So that property is pinned by construction in the test named above, and this
//! suite covers the ones a random interleaving does reach. A fuzz suite that is
//! assumed to cover something it does not is worse than no suite, because it
//! stops anybody looking.
//!
//! # What this suite mocks
//!
//! Every case calls `Env::mock_all_auths()`, exactly as `test.rs` does, which
//! disables Soroban's authorization checking wholesale. The reporter set is
//! still enforced, because `process` checks membership itself rather than
//! relying on the signature, and the suite includes addresses that are not
//! reporters to exercise that. It proves nothing about signatures.
//!
//! # Invariants
//!
//!  - a feed's stored value is always one that a full quorum of **distinct**
//!    authorized reporters submitted for a single round, tracked independently
//!    of the contract by the harness
//!  - the stored timestamp is strictly increasing
//!  - a stored value is always inside the feed's band
//!  - no address outside the reporter set ever contributes to a commit

extern crate std;

use super::*;
use proptest::prelude::*;
use proptest::test_runner::TestCaseError;
use soroban_sdk::testutils::{Address as _, Ledger as _};
use std::collections::{BTreeMap, BTreeSet};

const NUM_REPORTERS: usize = 4;
/// One more address than there are reporters, so a stranger is always in range.
const NUM_ADDRESSES: usize = NUM_REPORTERS + 1;

type PResult = Result<(), TestCaseError>;

#[derive(Clone, Debug)]
enum Op {
    /// A report from `who`, which is a reporter for indices below
    /// `NUM_REPORTERS` and a stranger at the last one.
    Submit { who: usize, nav: i128, at: u64 },
    SetThreshold { threshold: u32 },
    AdvanceTime { seconds: u64 },
}

/// A deliberately small set of values, because the property needs two things
/// the obvious generator does not produce.
///
/// A quorum needs two reporters to pick the *same* number, which never happens
/// if the space is wide. And the interesting round is one that reaches quorum
/// and is then **refused**, because that is the round that stays open, so the
/// set has to straddle the deviation bound: some values a round can commit and
/// some a round agrees on and the guard throws out.
///
/// The bound is 500 bps from the last committed value. `NEAR` is inside it and
/// `FAR` is not, so a round agreeing on a `FAR` value reaches quorum and is
/// refused, which is the state the whole invariant turns on.
fn nav_strategy() -> impl Strategy<Value = i128> {
    const NEAR: [i128; 3] = [ONE, ONE * 102 / 100, ONE * 98 / 100];
    const FAR: [i128; 3] = [ONE * 150 / 100, ONE * 60 / 100, ONE * 190 / 100];
    prop_oneof![
        1 => Just(0i128),
        1 => Just(NAV_BAND_MAX + 1),
        8 => (0usize..3).prop_map(|i| NEAR[i]),
        8 => (0usize..3).prop_map(|i| FAR[i]),
    ]
}

/// Slots, heavily concentrated.
///
/// A round is one feed and one reported timestamp, so the properties worth
/// checking here only exist when several reporters land in the *same* round.
/// Spread submissions over even half a dozen slots and they almost never do: at
/// 3000 cases over six slots, the sequence that carries a quorum on one
/// reporter voting twice never came up once. A generator that cannot reach the
/// interesting shape is a generator bug rather than a limit on the property, so
/// the slots are deliberately few and skewed.
fn slot_strategy() -> impl Strategy<Value = u64> {
    prop_oneof![
        6 => Just(0u64),
        6 => Just(1u64),
        2 => Just(2u64),
    ]
}

fn op_strategy() -> impl Strategy<Value = Op> {
    prop_oneof![
        14 => (0usize..NUM_ADDRESSES, nav_strategy(), slot_strategy())
            .prop_map(|(who, nav, slot)| Op::Submit { who, nav, at: slot }),
        3 => (1u32..=3).prop_map(|threshold| Op::SetThreshold { threshold }),
        4 => (0u64..=3 * NAV_MIN_INTERVAL).prop_map(|seconds| Op::AdvanceTime { seconds }),
    ]
}

struct FuzzState {
    e: Env,
    oracle: OracleAdapterClient<'static>,
    admin: Address,
    addresses: [Address; NUM_ADDRESSES],
    base_time: u64,
    /// What the harness believes about each round, kept independently of the
    /// contract: for one reported timestamp, which distinct reporters have
    /// voted and what each of them voted for.
    votes: BTreeMap<u64, BTreeMap<usize, i128>>,
    threshold: u32,
    last_committed: Option<(i128, u64)>,
}

impl FuzzState {
    fn addr(&self, idx: usize) -> Address {
        self.addresses[idx % NUM_ADDRESSES].clone()
    }

    fn is_reporter(&self, idx: usize) -> bool {
        idx % NUM_ADDRESSES < NUM_REPORTERS
    }

    /// The timestamp a slot maps to. Slots rather than raw timestamps so that
    /// two reporters can land in the same round often enough for a quorum to be
    /// reachable at all.
    fn slot_time(&self, slot: u64) -> u64 {
        self.base_time + slot * NAV_MIN_INTERVAL
    }

    /// Does the harness's own record show a full quorum of distinct authorized
    /// reporters on `nav` for this round?
    fn harness_sees_quorum(&self, at: u64, nav: i128) -> bool {
        let agreeing: BTreeSet<usize> = self
            .votes
            .get(&at)
            .map(|round| {
                round
                    .iter()
                    .filter(|(who, v)| self.is_reporter(**who) && **v == nav)
                    .map(|(who, _)| *who)
                    .collect()
            })
            .unwrap_or_default();
        agreeing.len() as u32 >= self.threshold
    }
}

fn setup() -> FuzzState {
    let e = Env::default();
    e.mock_all_auths();
    let base_time = 1_800_000_000u64;
    e.ledger().set_timestamp(base_time + 100 * NAV_MIN_INTERVAL);

    let admin = Address::generate(&e);
    let addresses: [Address; NUM_ADDRESSES] = core::array::from_fn(|_| Address::generate(&e));

    let id = e.register(OracleAdapter, (admin.clone(),));
    let oracle = OracleAdapterClient::new(&e, &id);
    for (i, a) in addresses.iter().enumerate() {
        if i < NUM_REPORTERS {
            oracle.add_reporter(&admin, a);
        }
    }
    oracle.register_feed(
        &admin,
        &FEED_PC_NAV,
        &PRIVATE_CREDIT_STALENESS,
        &PRIVATE_CREDIT_DEVIATION_BPS,
        &NAV_BAND_MIN,
        &NAV_BAND_MAX,
        &NAV_MIN_INTERVAL,
    );

    FuzzState {
        e,
        oracle,
        admin,
        addresses,
        base_time,
        votes: BTreeMap::new(),
        threshold: 1,
        last_committed: None,
    }
}

fn apply(state: &mut FuzzState, op: &Op) {
    match op {
        Op::Submit { who, nav, at } => {
            let when = state.slot_time(*at);
            let reporter = state.addr(*who);
            let before = state.oracle.try_get_nav(&FEED_PC_NAV).ok().and_then(|r| r.ok());
            let outcome = state
                .oracle
                .try_submit_nav(&reporter, &FEED_PC_NAV, nav, &when);
            let after = state.oracle.try_get_nav(&FEED_PC_NAV).ok().and_then(|r| r.ok());

            // The harness records the vote only when the contract accepted it
            // as a vote, which is the same set of preconditions the contract
            // checks before `record_vote`: an authorized reporter, a positive
            // value inside the band, and a timestamp not in the future.
            // Recorded keyed by reporter, so a second vote from the same
            // reporter replaces the first rather than adding to a count. That
            // is the whole property: a quorum is distinct reporters, not
            // distinct votes, and a harness that tallied votes would agree with
            // a contract that tallied votes and catch nothing.
            let counted = matches!(outcome, Ok(_));
            if counted {
                state
                    .votes
                    .entry(when)
                    .or_default()
                    .insert(*who % NUM_ADDRESSES, *nav);
            }
            if before != after {
                if let Some(v) = after {
                    state.last_committed = Some((v, when));
                }
            }
        }
        Op::SetThreshold { threshold } => {
            if state
                .oracle
                .try_set_quorum_threshold(&state.admin, &FEED_PC_NAV, threshold)
                .is_ok()
            {
                state.threshold = *threshold;
            }
        }
        Op::AdvanceTime { seconds } => {
            let now = state.e.ledger().timestamp();
            state.e.ledger().set_timestamp(now + seconds);
        }
    }
}

fn check_invariants(state: &FuzzState, op: &Op) -> PResult {
    let stored = state.oracle.try_get_nav(&FEED_PC_NAV).ok().and_then(|r| r.ok());
    if let Some(nav) = stored {
        prop_assert!(
            nav >= NAV_BAND_MIN && nav <= NAV_BAND_MAX,
            "a stored value is outside the feed's band: {} after {:?}",
            nav,
            op
        );
        let (last, at) = state
            .last_committed
            .expect("a value is stored but the harness never saw a commit");
        prop_assert_eq!(
            nav,
            last,
            "the stored value is not the one the harness last saw commit"
        );
        let _ = at;
    }
    Ok(())
}

proptest! {
    #![proptest_config(ProptestConfig::with_cases(64))]

    /// A value commits only when a full quorum of distinct authorized reporters
    /// has agreed on it for one round, tracked by the harness independently of
    /// the contract.
    #[test]
    fn a_value_commits_only_on_a_quorum_of_distinct_reporters(
        ops in proptest::collection::vec(op_strategy(), 1..40)
    ) {
        let mut state = setup();
        let mut prev_time = 0u64;
        for op in &ops {
            let before = state.oracle.try_get_nav(&FEED_PC_NAV).ok().and_then(|r| r.ok());
            apply(&mut state, op);
            let after = state.oracle.try_get_nav(&FEED_PC_NAV).ok().and_then(|r| r.ok());

            if before != after {
                let (nav, at) = state.last_committed.unwrap();
                prop_assert!(
                    state.harness_sees_quorum(at, nav),
                    "a value committed without the harness seeing a quorum of \
                     distinct reporters agree on it: nav={} at={} threshold={} op={:?}",
                    nav,
                    at,
                    state.threshold,
                    op
                );
                prop_assert!(
                    at > prev_time,
                    "the stored timestamp did not strictly increase: {} then {}",
                    prev_time,
                    at
                );
                prev_time = at;
            }
            check_invariants(&state, op)?;
        }
    }
}

/// The one property random generation could not reach, pinned by construction.
///
/// A quorum above 1 buys independence between reporters, and the way to lose it
/// is a round that resolves, is refused, and leaves its tallies standing with
/// no record of who voted. One reporter then seeds a value, waits for the round
/// to be refused on another, votes again and carries a quorum of two alone.
///
/// The harness above can see that: put the defect back and hand it this exact
/// sequence and it fires. What it cannot do is find the sequence. It needs four
/// specific steps in one round, a seed, two agreeing on something the deviation
/// bound will throw out, and the seeder returning, and uniform generation did
/// not produce it in 3000 cases over six slots, nor in 3000 with the slots
/// concentrated into three.
///
/// That is worth writing down rather than shipping a suite that looks like it
/// covers this. It does not. This test does, by construction, and the fuzz
/// suite covers the properties that a random interleaving does reach.
#[test]
fn a_reporter_cannot_carry_a_round_alone_by_voting_into_it_twice() {
    let mut state = setup();
    // A reference value, so the deviation bound has something to measure from.
    apply(&mut state, &Op::Submit { who: 0, nav: ONE, at: 0 });
    state
        .oracle
        .set_quorum_threshold(&state.admin, &FEED_PC_NAV, &2u32);
    state.threshold = 2;
    apply(&mut state, &Op::AdvanceTime { seconds: 2 * NAV_MIN_INTERVAL });

    // Reporter 1 seeds the value it wants, inside the bound so it could commit.
    let theirs = ONE * 102 / 100;
    apply(&mut state, &Op::Submit { who: 1, nav: theirs, at: 1 });
    // Two others agree on something the deviation bound throws out, which
    // resolves the round and refuses it.
    apply(&mut state, &Op::Submit { who: 2, nav: ONE * 150 / 100, at: 1 });
    apply(&mut state, &Op::Submit { who: 3, nav: ONE * 150 / 100, at: 1 });
    assert_eq!(
        state.oracle.get_nav(&FEED_PC_NAV),
        ONE,
        "the refused round moved the feed"
    );

    // The second vote from the seeder is refused, so the round cannot be
    // carried by one key.
    let when = state.slot_time(1);
    assert_eq!(
        state
            .oracle
            .try_submit_nav(&state.addr(1), &FEED_PC_NAV, &theirs, &when),
        Err(Ok(OracleError::AlreadyVoted))
    );
    assert_eq!(state.oracle.get_nav(&FEED_PC_NAV), ONE);

    // And a genuine second reporter still carries it, so this is a check on
    // distinctness rather than a wall across the round. Reporter 0 is the one
    // that has not spoken in this round: 2 and 3 already have, and they get the
    // same refusal for the same reason, which is the guard rather than a quirk
    // of who went first.
    assert_eq!(
        state
            .oracle
            .try_submit_nav(&state.addr(2), &FEED_PC_NAV, &theirs, &when),
        Err(Ok(OracleError::AlreadyVoted))
    );
    state
        .oracle
        .submit_nav(&state.addr(0), &FEED_PC_NAV, &theirs, &when);
    assert_eq!(state.oracle.get_nav(&FEED_PC_NAV), theirs);
}
