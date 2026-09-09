#![cfg(test)]
use super::*;
use soroban_sdk::testutils::{Address as _, Events as _, Ledger as _, MockAuth, MockAuthInvoke};
use soroban_sdk::IntoVal;
use soroban_sdk::{Address, Env, TryFromVal};

// Ledger time the fixtures start from, far enough into the epoch that the
// staleness windows can be subtracted without underflowing.
const T0: u64 = 1_800_000_000;
const ONE: i128 = 10_000_000; // 1.0 at 7 decimals

struct Fix {
    e: Env,
    oracle: OracleAdapterClient<'static>,
    admin: Address,
    reporter: Address,
}

/// Registers the three feeds the protocol actually runs with, using the
/// parameter constants from the contract rather than repeating literals here.
fn setup() -> Fix {
    let e = Env::default();
    e.mock_all_auths();
    e.ledger().set_timestamp(T0);

    let admin = Address::generate(&e);
    let reporter = Address::generate(&e);

    let id = e.register(OracleAdapter, (admin.clone(),));
    let oracle = OracleAdapterClient::new(&e, &id);
    oracle.add_reporter(&admin, &reporter);

    oracle.register_feed(
        &admin,
        &FEED_USDC_USD,
        &REFLECTOR_STALENESS,
        &REFLECTOR_DEVIATION_BPS,
        &REFLECTOR_MIN_NAV,
        &REFLECTOR_MAX_NAV,
        &REFLECTOR_MIN_INTERVAL,
    );
    oracle.register_feed(
        &admin,
        &FEED_PC_NAV,
        &PRIVATE_CREDIT_STALENESS,
        &PRIVATE_CREDIT_DEVIATION_BPS,
        &NAV_BAND_MIN,
        &NAV_BAND_MAX,
        &NAV_MIN_INTERVAL,
    );
    oracle.register_feed(
        &admin,
        &FEED_EF_BOND,
        &ETHERFUSE_STALENESS,
        &ETHERFUSE_DEVIATION_BPS,
        &NAV_BAND_MIN,
        &NAV_BAND_MAX,
        &NAV_MIN_INTERVAL,
    );

    Fix {
        e,
        oracle,
        admin,
        reporter,
    }
}

/// True if any event carries `name` as one of its topics. `events().all()`
/// only reflects the most recent invocation, so this has to be called
/// immediately after the call under test.
fn emitted(e: &Env, name: &str) -> bool {
    let wanted = Symbol::new(e, name);
    e.events().all().iter().any(|(_, topics, _)| {
        topics
            .iter()
            .any(|t| Symbol::try_from_val(e, &t).map(|s: Symbol| s == wanted) == Ok(true))
    })
}

#[test]
fn registered_feeds_carry_their_own_guards() {
    let f = setup();
    let usdc = f.oracle.get_feed(&FEED_USDC_USD);
    assert_eq!(usdc.staleness_secs, 3_600);
    assert_eq!(usdc.deviation_bps, 200);

    let pc = f.oracle.get_feed(&FEED_PC_NAV);
    assert_eq!(pc.staleness_secs, 7 * 86_400);
    assert_eq!(pc.deviation_bps, 500);

    let ef = f.oracle.get_feed(&FEED_EF_BOND);
    assert_eq!(ef.staleness_secs, 48 * 3_600);
    assert_eq!(ef.deviation_bps, 0); // deterministic, no bound
}

#[test]
fn valid_push_updates_nav() {
    let f = setup();
    f.oracle.push_nav(&f.reporter, &FEED_USDC_USD, &ONE, &T0);
    assert_eq!(f.oracle.get_nav(&FEED_USDC_USD), ONE);

    // A second report inside the bound (1% move against a 2% bound), far
    // enough after the first to clear the feed's minimum interval, lands.
    f.e.ledger().set_timestamp(T0 + REFLECTOR_MIN_INTERVAL);
    let moved = ONE * 101 / 100;
    f.oracle.push_nav(
        &f.reporter,
        &FEED_USDC_USD,
        &moved,
        &(T0 + REFLECTOR_MIN_INTERVAL),
    );
    assert_eq!(f.oracle.get_nav(&FEED_USDC_USD), moved);
    assert_eq!(
        f.oracle.last_update(&FEED_USDC_USD).timestamp,
        T0 + REFLECTOR_MIN_INTERVAL
    );
}

#[test]
fn unauthorized_caller_is_rejected() {
    let f = setup();
    let stranger = Address::generate(&f.e);
    assert!(!f.oracle.is_reporter(&stranger));

    let r = f.oracle.try_push_nav(&stranger, &FEED_USDC_USD, &ONE, &T0);
    assert_eq!(r, Err(Ok(OracleError::UnauthorizedReporter)));

    // And nothing was written.
    assert_eq!(
        f.oracle.try_get_nav(&FEED_USDC_USD),
        Err(Ok(OracleError::NoNavReported))
    );
}

#[test]
fn removed_reporter_can_no_longer_push() {
    let f = setup();
    f.oracle.push_nav(&f.reporter, &FEED_USDC_USD, &ONE, &T0);
    f.oracle.remove_reporter(&f.admin, &f.reporter);
    assert!(!f.oracle.is_reporter(&f.reporter));

    f.e.ledger().set_timestamp(T0 + 60);
    let r = f
        .oracle
        .try_push_nav(&f.reporter, &FEED_USDC_USD, &ONE, &(T0 + 60));
    assert_eq!(r, Err(Ok(OracleError::UnauthorizedReporter)));
}

#[test]
fn stale_read_errors_with_oracle_stale() {
    let f = setup();
    f.oracle.push_nav(&f.reporter, &FEED_USDC_USD, &ONE, &T0);

    // Exactly at the threshold the feed is still good.
    f.e.ledger().set_timestamp(T0 + REFLECTOR_STALENESS);
    assert_eq!(f.oracle.get_nav(&FEED_USDC_USD), ONE);

    // One second past it, the read fails rather than returning an old number.
    f.e.ledger().set_timestamp(T0 + REFLECTOR_STALENESS + 1);
    assert_eq!(
        f.oracle.try_get_nav(&FEED_USDC_USD),
        Err(Ok(OracleError::OracleStale))
    );

    // The point itself is still readable for monitoring.
    assert_eq!(f.oracle.last_update(&FEED_USDC_USD).nav, ONE);
}

#[test]
fn private_credit_tolerates_a_week_of_silence() {
    let f = setup();
    let nav = ONE;
    f.oracle.push_nav(&f.reporter, &FEED_PC_NAV, &nav, &T0);

    // Six days without a report is normal for a credit book.
    f.e.ledger().set_timestamp(T0 + 6 * 86_400);
    assert_eq!(f.oracle.get_nav(&FEED_PC_NAV), nav);

    // Eight days is not.
    f.e.ledger().set_timestamp(T0 + 8 * 86_400);
    assert_eq!(
        f.oracle.try_get_nav(&FEED_PC_NAV),
        Err(Ok(OracleError::OracleStale))
    );
}

#[test]
fn out_of_bounds_deviation_fails_push_nav() {
    let f = setup();
    let nav = ONE;
    f.oracle.push_nav(&f.reporter, &FEED_PC_NAV, &nav, &T0);

    // 4% move against a 5% bound: accepted.
    f.e.ledger().set_timestamp(T0 + 86_400);
    let within = nav * 104 / 100;
    f.oracle
        .push_nav(&f.reporter, &FEED_PC_NAV, &within, &(T0 + 86_400));
    assert_eq!(f.oracle.get_nav(&FEED_PC_NAV), within);

    // 6% move against a 5% bound: the transaction fails and the previous NAV
    // survives untouched, timestamp included.
    f.e.ledger().set_timestamp(T0 + 2 * 86_400);
    let beyond = within * 106 / 100;
    let r = f
        .oracle
        .try_push_nav(&f.reporter, &FEED_PC_NAV, &beyond, &(T0 + 2 * 86_400));
    assert_eq!(r, Err(Ok(OracleError::DeviationOutOfBounds)));
    assert_eq!(f.oracle.get_nav(&FEED_PC_NAV), within);
    assert_eq!(f.oracle.last_update(&FEED_PC_NAV).timestamp, T0 + 86_400);
}

#[test]
fn out_of_bounds_deviation_emits_nav_rejected_on_submit_nav() {
    let f = setup();
    let nav = ONE;
    assert_eq!(
        f.oracle.submit_nav(&f.reporter, &FEED_PC_NAV, &nav, &T0),
        PushOutcome::Accepted
    );

    f.e.ledger().set_timestamp(T0 + 86_400);
    let beyond = nav * 120 / 100; // 2000 bps against a 500 bps bound
    assert_eq!(
        f.oracle
            .submit_nav(&f.reporter, &FEED_PC_NAV, &beyond, &(T0 + 86_400)),
        PushOutcome::RejectedDeviation
    );
    // The refusal is in the event stream, where an operator can see it without
    // scanning failed transactions.
    assert!(
        emitted(&f.e, "nav_rejected"),
        "a refused submission must be visible in the event stream"
    );
    // And nothing was stored: the previous NAV and its timestamp both stand.
    assert_eq!(f.oracle.get_nav(&FEED_PC_NAV), nav);
    assert_eq!(f.oracle.last_update(&FEED_PC_NAV).timestamp, T0);
}

#[test]
fn submit_nav_still_fails_on_malformed_reports() {
    let f = setup();
    // A disputed valuation is an outcome, a malformed report is an error.
    let stranger = Address::generate(&f.e);
    assert_eq!(
        f.oracle.try_submit_nav(&stranger, &FEED_PC_NAV, &ONE, &T0),
        Err(Ok(OracleError::UnauthorizedReporter))
    );
    assert_eq!(
        f.oracle
            .try_submit_nav(&f.reporter, &FEED_PC_NAV, &ONE, &(T0 + 1)),
        Err(Ok(OracleError::TimestampInFuture))
    );
}

#[test]
fn deterministic_feed_accepts_any_move() {
    let f = setup();
    // Etherfuse bond pricing is registered with a zero deviation bound, so a
    // large but legitimate revaluation must not be treated as an anomaly.
    f.oracle.push_nav(&f.reporter, &FEED_EF_BOND, &ONE, &T0);
    f.e.ledger().set_timestamp(T0 + 3_600);
    let doubled = ONE * 2;
    f.oracle
        .push_nav(&f.reporter, &FEED_EF_BOND, &doubled, &(T0 + 3_600));
    assert_eq!(f.oracle.get_nav(&FEED_EF_BOND), doubled);
}

#[test]
fn non_monotonic_timestamp_is_rejected() {
    let f = setup();
    f.e.ledger().set_timestamp(T0 + 100);
    f.oracle
        .push_nav(&f.reporter, &FEED_USDC_USD, &ONE, &(T0 + 100));

    // Same timestamp: refused, "strictly greater" is not "greater or equal".
    let r = f
        .oracle
        .try_push_nav(&f.reporter, &FEED_USDC_USD, &ONE, &(T0 + 100));
    assert_eq!(r, Err(Ok(OracleError::NonMonotonicTimestamp)));

    // Older timestamp: refused, so a replayed report cannot rewind the feed.
    let r = f
        .oracle
        .try_push_nav(&f.reporter, &FEED_USDC_USD, &ONE, &(T0 + 50));
    assert_eq!(r, Err(Ok(OracleError::NonMonotonicTimestamp)));
}

#[test]
fn future_timestamp_is_rejected() {
    let f = setup();
    // Accepting this would disable the staleness guard for good.
    let r = f
        .oracle
        .try_push_nav(&f.reporter, &FEED_USDC_USD, &ONE, &(T0 + 1));
    assert_eq!(r, Err(Ok(OracleError::TimestampInFuture)));
}

#[test]
fn non_positive_nav_is_rejected() {
    let f = setup();
    assert_eq!(
        f.oracle.try_push_nav(&f.reporter, &FEED_USDC_USD, &0, &T0),
        Err(Ok(OracleError::InvalidNav))
    );
    assert_eq!(
        f.oracle
            .try_push_nav(&f.reporter, &FEED_USDC_USD, &-ONE, &T0),
        Err(Ok(OracleError::InvalidNav))
    );
}

#[test]
fn unregistered_feed_is_rejected_on_both_sides() {
    let f = setup();
    let unknown = Symbol::new(&f.e, "NOPE");
    assert_eq!(
        f.oracle.try_push_nav(&f.reporter, &unknown, &ONE, &T0),
        Err(Ok(OracleError::FeedNotRegistered))
    );
    assert_eq!(
        f.oracle.try_get_nav(&unknown),
        Err(Ok(OracleError::FeedNotRegistered))
    );
}

#[test]
fn feed_guards_are_write_once() {
    let f = setup();
    // Re-registering USDC/USD with a 100% deviation bound must not silently
    // disarm the guard for every consumer already reading that feed id.
    let r = f
        .oracle
        .try_register_feed(
            &f.admin,
            &FEED_USDC_USD,
            &3_600u64,
            &10_000u32,
            &1i128,
            &(i128::MAX),
            &0u64,
        );
    assert_eq!(r, Err(Ok(OracleError::FeedAlreadyRegistered)));
    assert_eq!(f.oracle.get_feed(&FEED_USDC_USD).deviation_bps, 200);
}

#[test]
fn feed_config_is_validated() {
    let f = setup();
    let new_feed = Symbol::new(&f.e, "NEW");
    // A zero staleness window would make the feed unreadable one second after
    // every report.
    assert_eq!(
        f.oracle.try_register_feed(
            &f.admin,
            &new_feed,
            &0u64,
            &200u32,
            &NAV_BAND_MIN,
            &NAV_BAND_MAX,
            &NAV_MIN_INTERVAL
        ),
        Err(Ok(OracleError::InvalidFeedConfig))
    );
    // A bound above 100% is not a bound.
    assert_eq!(
        f.oracle
            .try_register_feed(
                &f.admin,
                &new_feed,
                &3_600u64,
                &10_001u32,
                &NAV_BAND_MIN,
                &NAV_BAND_MAX,
                &NAV_MIN_INTERVAL
            ),
        Err(Ok(OracleError::InvalidFeedConfig))
    );
    // A band that is not a band: no lower edge, or an upper edge below the
    // lower one. Both would leave the first report unconstrained again.
    assert_eq!(
        f.oracle.try_register_feed(
            &f.admin,
            &new_feed,
            &3_600u64,
            &200u32,
            &0i128,
            &NAV_BAND_MAX,
            &NAV_MIN_INTERVAL
        ),
        Err(Ok(OracleError::InvalidFeedConfig))
    );
    assert_eq!(
        f.oracle.try_register_feed(
            &f.admin,
            &new_feed,
            &3_600u64,
            &200u32,
            &NAV_BAND_MAX,
            &NAV_BAND_MIN,
            &NAV_MIN_INTERVAL
        ),
        Err(Ok(OracleError::InvalidFeedConfig))
    );
}

#[test]
fn non_admin_cannot_manage_reporters_or_feeds() {
    let f = setup();
    let stranger = Address::generate(&f.e);
    assert_eq!(
        f.oracle.try_add_reporter(&stranger, &stranger),
        Err(Ok(OracleError::NotAdmin))
    );
    assert_eq!(
        f.oracle
            .try_register_feed(
                &stranger,
                &Symbol::new(&f.e, "X"),
                &3_600u64,
                &200u32,
                &NAV_BAND_MIN,
                &NAV_BAND_MAX,
                &NAV_MIN_INTERVAL
            ),
        Err(Ok(OracleError::NotAdmin))
    );
}

/// The first value for a feed had nothing to be compared against, so it was
/// accepted unconditionally: `push_nav(i128::MAX)` landed, and every deviation
/// bound afterwards was measured as a percentage of it.
///
/// A deviation bound cannot cover this by construction, because a bound on a
/// move needs something to move from. The absolute band does, and it applies to
/// every report rather than only the first, which is what makes it the outer
/// wall rather than a special case.
#[test]
fn the_first_value_for_a_feed_is_bounded_too() {
    let f = setup();
    let fresh = Symbol::new(&f.e, "FRESH");
    f.oracle.register_feed(
        &f.admin,
        &fresh,
        &PRIVATE_CREDIT_STALENESS,
        &PRIVATE_CREDIT_DEVIATION_BPS,
        &NAV_BAND_MIN,
        &NAV_BAND_MAX,
        &NAV_MIN_INTERVAL,
    );

    assert_eq!(
        f.oracle.try_push_nav(&f.reporter, &fresh, &i128::MAX, &T0),
        Err(Ok(OracleError::NavOutOfBand))
    );
    assert_eq!(
        f.oracle
            .try_push_nav(&f.reporter, &fresh, &(NAV_BAND_MAX + 1), &T0),
        Err(Ok(OracleError::NavOutOfBand))
    );
    assert_eq!(
        f.oracle
            .try_push_nav(&f.reporter, &fresh, &(NAV_BAND_MIN - 1), &T0),
        Err(Ok(OracleError::NavOutOfBand))
    );
    assert_eq!(
        f.oracle.try_get_nav(&fresh),
        Err(Ok(OracleError::NoNavReported))
    );

    // Both edges are inclusive: the band is a wall, not a step.
    f.oracle.push_nav(&f.reporter, &fresh, &NAV_BAND_MAX, &T0);
    assert_eq!(f.oracle.get_nav(&fresh), NAV_BAND_MAX);
}

/// The deviation bound is per push and says nothing about how many pushes there
/// can be. Forty of them at +5% moved a NAV by a factor of seven in forty
/// seconds, every one of them inside the bound and every one of them accepted.
///
/// The rate limit is measured in ledger time between accepted values, not in
/// the timestamps the reporter supplies, because the reporter chooses those:
/// forty timestamps a day apart can all be pushed in the same minute.
#[test]
fn a_feed_cannot_be_walked_by_repetition() {
    let f = setup();
    f.oracle
        .push_nav(&f.reporter, &FEED_PC_NAV, &ONE, &(T0 - 100));

    // The attack, as reported: each push inside the 500 bps bound, each
    // timestamp strictly later than the last and none of them in the future,
    // all of them submitted in the same second of ledger time. Fourteen steps
    // is where the compounding reaches the band, so the walk is over twice by
    // then; every one of them is refused on the interval first.
    let mut nav = ONE;
    for i in 1..=14u64 {
        nav = nav * 105 / 100;
        assert_eq!(
            f.oracle
                .try_push_nav(&f.reporter, &FEED_PC_NAV, &nav, &(T0 - 100 + i)),
            Err(Ok(OracleError::TooSoon))
        );
    }
    // And the fifteenth would have left the band anyway: the two guards
    // compose, one limiting how fast and one limiting how far.
    nav = nav * 105 / 100;
    assert!(nav > NAV_BAND_MAX);
    assert_eq!(f.oracle.get_nav(&FEED_PC_NAV), ONE);

    // One step per interval is all it gets, and the band stops the walk long
    // before it reaches a factor of seven.
    let mut clock = T0;
    let mut accepted = 0;
    loop {
        clock += NAV_MIN_INTERVAL;
        f.e.ledger().set_timestamp(clock);
        let next = nav_step(f.oracle.get_nav(&FEED_PC_NAV));
        if f.oracle
            .try_push_nav(&f.reporter, &FEED_PC_NAV, &next, &clock)
            .is_err()
        {
            break;
        }
        accepted += 1;
        assert!(accepted < 100);
    }
    assert!(f.oracle.get_nav(&FEED_PC_NAV) <= NAV_BAND_MAX);
}

fn nav_step(nav: i128) -> i128 {
    nav * 105 / 100
}

/// The reference point is the thing every guard is measured against, and it
/// used to live in temporary storage. When a temporary entry expires there is
/// no reference left, so a report with nothing to compare against skips the
/// monotonicity check, the deviation bound and the rate limit in one go, and
/// waiting out a TTL is not an attack anybody has to work at.
#[test]
fn the_reference_value_outlives_the_old_temporary_ttl() {
    let f = setup();
    f.oracle.push_nav(&f.reporter, &FEED_PC_NAV, &ONE, &T0);
    let start = f.e.ledger().sequence();

    // Well past the 30 day window the reference used to be kept for.
    f.e.ledger().set_sequence_number(start + 45 * 17_280);
    f.e.ledger().set_timestamp(T0 + 45 * 86_400);

    // The reference is still there, so a doubling is still refused for
    // breaking the deviation bound rather than waved through as a first
    // report, and a stale timestamp is still refused for going backwards.
    assert_eq!(f.oracle.last_update(&FEED_PC_NAV).nav, ONE);
    assert_eq!(
        f.oracle
            .try_push_nav(&f.reporter, &FEED_PC_NAV, &(ONE * 2), &(T0 + 45 * 86_400)),
        Err(Ok(OracleError::DeviationOutOfBounds))
    );
    assert_eq!(
        f.oracle
            .try_push_nav(&f.reporter, &FEED_PC_NAV, &ONE, &(T0 - 1)),
        Err(Ok(OracleError::NonMonotonicTimestamp))
    );
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
    assert_eq!(f.oracle.pending_admin(), None);

    // A stranger cannot propose.
    assert_eq!(
        f.oracle.try_propose_admin(&mallory, &mallory),
        Err(Ok(OracleError::NotAdmin))
    );

    // The admin proposes and nothing moves yet.
    f.oracle.propose_admin(&f.admin, &successor);
    assert_eq!(f.oracle.pending_admin(), Some(successor.clone()));
    assert_eq!(f.oracle.admin(), f.admin);

    // Only the proposed address can accept, and it has to sign for itself.
    assert_eq!(
        f.oracle.try_accept_admin(&mallory),
        Err(Ok(OracleError::NotPendingAdmin))
    );
    f.e.mock_auths(&[MockAuth {
        address: &mallory,
        invoke: &MockAuthInvoke {
            contract: &f.oracle.address,
            fn_name: "accept_admin",
            args: (successor.clone(),).into_val(&f.e),
            sub_invokes: &[],
        },
    }]);
    assert!(f.oracle.try_accept_admin(&successor).is_err());
    assert_eq!(f.oracle.admin(), f.admin);

    f.e.mock_all_auths();
    f.oracle.accept_admin(&successor);
    assert_eq!(f.oracle.admin(), successor);
    assert_eq!(f.oracle.pending_admin(), None);
    assert_eq!(
        f.oracle.try_accept_admin(&successor),
        Err(Ok(OracleError::NoPendingAdmin))
    );
}
