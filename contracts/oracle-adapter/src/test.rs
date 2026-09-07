#![cfg(test)]
use super::*;
use soroban_sdk::testutils::{Address as _, Events as _, Ledger as _};
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

    let id = e.register(OracleAdapter, ());
    let oracle = OracleAdapterClient::new(&e, &id);
    oracle.initialize(&admin);
    oracle.add_reporter(&admin, &reporter);

    oracle.register_feed(
        &admin,
        &FEED_USDC_USD,
        &REFLECTOR_STALENESS,
        &REFLECTOR_DEVIATION_BPS,
    );
    oracle.register_feed(
        &admin,
        &FEED_PC_NAV,
        &PRIVATE_CREDIT_STALENESS,
        &PRIVATE_CREDIT_DEVIATION_BPS,
    );
    oracle.register_feed(
        &admin,
        &FEED_EF_BOND,
        &ETHERFUSE_STALENESS,
        &ETHERFUSE_DEVIATION_BPS,
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

    // A second report inside the bound (1% move against a 2% bound) lands.
    f.e.ledger().set_timestamp(T0 + 60);
    let moved = ONE * 101 / 100;
    f.oracle
        .push_nav(&f.reporter, &FEED_USDC_USD, &moved, &(T0 + 60));
    assert_eq!(f.oracle.get_nav(&FEED_USDC_USD), moved);
    assert_eq!(f.oracle.last_update(&FEED_USDC_USD).timestamp, T0 + 60);
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
    let nav = 1_000 * ONE;
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
    let nav = 1_000 * ONE;
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
    let nav = 1_000 * ONE;
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
        .try_register_feed(&f.admin, &FEED_USDC_USD, &3_600u64, &10_000u32);
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
        f.oracle.try_register_feed(&f.admin, &new_feed, &0u64, &200u32),
        Err(Ok(OracleError::InvalidFeedConfig))
    );
    // A bound above 100% is not a bound.
    assert_eq!(
        f.oracle
            .try_register_feed(&f.admin, &new_feed, &3_600u64, &10_001u32),
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
            .try_register_feed(&stranger, &Symbol::new(&f.e, "X"), &3_600u64, &200u32),
        Err(Ok(OracleError::NotAdmin))
    );
}

#[test]
fn cannot_be_reinitialized() {
    let f = setup();
    let attacker = Address::generate(&f.e);
    assert_eq!(
        f.oracle.try_initialize(&attacker),
        Err(Ok(OracleError::AlreadyInitialized))
    );
    assert_eq!(f.oracle.admin(), f.admin);
}


