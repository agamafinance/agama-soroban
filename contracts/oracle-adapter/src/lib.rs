#![no_std]
//! Oracle Adapter, the single source of truth for NAV.
//!
//! Every price or NAV the protocol consumes enters through this contract, so
//! the Vault never has to know whether a number came from a Reflector price
//! feed, from the off-chain private credit reporter, or from Etherfuse bond
//! pricing. What differs between those sources is not the interface, it is how
//! much staleness and how much movement is plausible, so each feed carries its
//! own guards and is validated against them on every push:
//!
//! | feed                    | staleness | deviation bound      |
//! |-------------------------|-----------|----------------------|
//! | Reflector USDC/USD peg  | 1 hour    | 200 bps              |
//! | Private credit NAV      | 7 days    | 500 bps              |
//! | Etherfuse bond price    | 48 hours  | none (deterministic) |
//!
//! Three properties matter more than the rest, and each of them is a test:
//!
//! 1. Only an address in the reporter set can push. The set is admin managed
//!    and every rotation emits an event.
//! 2. Timestamps are strictly monotonic per feed, and never in the future.
//!    A future timestamp would keep a dead feed looking fresh forever.
//! 3. A push that breaks the feed's deviation bound never lands, and never
//!    lands quietly. Soroban discards the events of an invocation that errors,
//!    so a single entry point cannot both fail the caller and leave a
//!    `nav_rejected` event in the ledger. The two are therefore split:
//!    `push_nav` fails the transaction, `submit_nav` records the rejection as
//!    an event and returns `RejectedDeviation`. Neither one stores the value.
//!
//! Reads go through `get_nav`, which returns `OracleStale` rather than a stale
//! number when the stored timestamp is older than the feed's threshold. A
//! consumer that ignores errors therefore cannot accidentally price on old data.

use soroban_sdk::{
    contract, contracterror, contractevent, contractimpl, contracttype, symbol_short, Address, Env,
    Map, Symbol, Vec,
};

const BPS: i128 = 10_000;

// TTL bumps. Instance state (admin, reporter set, feed config) is read on every
// push, so keeping it alive is a prerequisite for the contract working at all.
const DAY_LEDGERS: u32 = 17_280; // ~ledgers per day at 5s
const INSTANCE_BUMP: u32 = 30 * DAY_LEDGERS;
const INSTANCE_LIFETIME: u32 = INSTANCE_BUMP - DAY_LEDGERS;
// The NAV point is temporary, but its TTL still has to outlast the longest
// staleness window (7 days for private credit) or the feed would read as
// "never reported" instead of "stale" between two legitimate reports.
const NAV_BUMP: u32 = 30 * DAY_LEDGERS;
const NAV_LIFETIME: u32 = NAV_BUMP - DAY_LEDGERS;

/// Feed identifiers and guard parameters the protocol runs with. They live here
/// rather than only in a deploy script so the on-chain configuration and the
/// documented configuration cannot drift apart.
pub const FEED_USDC_USD: Symbol = symbol_short!("USDC_USD");
pub const FEED_PC_NAV: Symbol = symbol_short!("PC_NAV");
pub const FEED_EF_BOND: Symbol = symbol_short!("EF_BOND");

/// Reflector USDC/USD peg check: 1 hour staleness, 200 bps deviation.
pub const REFLECTOR_STALENESS: u64 = 3_600;
pub const REFLECTOR_DEVIATION_BPS: u32 = 200;
/// Private credit NAV reporter: 7 days staleness, 500 bps deviation.
pub const PRIVATE_CREDIT_STALENESS: u64 = 7 * 86_400;
pub const PRIVATE_CREDIT_DEVIATION_BPS: u32 = 500;
/// Etherfuse bond price: 48 hours staleness, deterministic so no bound.
pub const ETHERFUSE_STALENESS: u64 = 48 * 3_600;
pub const ETHERFUSE_DEVIATION_BPS: u32 = 0;

#[contracterror]
#[derive(Copy, Clone, Debug, Eq, PartialEq)]
#[repr(u32)]
pub enum OracleError {
    AlreadyInitialized = 500,
    NotInitialized = 501,
    NotAdmin = 502,
    /// Caller is not in the reporter set.
    UnauthorizedReporter = 503,
    FeedNotRegistered = 504,
    FeedAlreadyRegistered = 505,
    InvalidFeedConfig = 506,
    InvalidNav = 507,
    /// Pushed timestamp is not strictly after the last one for this feed.
    NonMonotonicTimestamp = 508,
    /// Pushed timestamp is ahead of ledger time.
    TimestampInFuture = 509,
    /// Move from the previous NAV exceeds the feed's deviation bound.
    DeviationOutOfBounds = 510,
    /// The stored NAV is older than the feed's staleness threshold.
    OracleStale = 511,
    NoNavReported = 512,
}

/// Per feed validation guards, fixed at registration time.
#[derive(Clone, Debug, Eq, PartialEq)]
#[contracttype]
pub struct Feed {
    /// A read older than this many seconds fails with `OracleStale`.
    pub staleness_secs: u64,
    /// Maximum move from the previous NAV, in basis points. Zero means the
    /// feed is deterministic and no deviation bound applies.
    pub deviation_bps: u32,
}

/// What `submit_nav` did with a report.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
#[contracttype]
pub enum PushOutcome {
    /// Stored, and `nav_updated` was emitted.
    Accepted,
    /// Not stored, and `nav_rejected` was emitted. The previous NAV stands.
    RejectedDeviation,
}

/// The latest reported point for a feed.
#[derive(Clone, Debug, Eq, PartialEq)]
#[contracttype]
pub struct NavPoint {
    pub nav: i128,
    pub timestamp: u64,
}

/// Instance storage: admin, reporter set and feed configuration. All three are
/// small, read on every push, and must live as long as the contract does.
#[derive(Clone)]
#[contracttype]
enum Cfg {
    Admin,
    Reporters,
    Feeds,
}

/// Temporary storage: the latest NAV of a feed is replaced on every update, so
/// it never needs to outlive its own TTL window. History belongs in the event
/// stream, not in contract state.
#[derive(Clone)]
#[contracttype]
enum Store {
    Nav(Symbol),
}

/// Emitted when the reporter set changes, so rotations are auditable off-chain
/// without replaying the whole ledger.
#[contractevent]
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ReporterAdded {
    #[topic]
    pub reporter: Address,
}

#[contractevent]
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ReporterRemoved {
    #[topic]
    pub reporter: Address,
}

#[contractevent]
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct FeedRegistered {
    #[topic]
    pub feed_id: Symbol,
    pub staleness_secs: u64,
    pub deviation_bps: u32,
}

#[contractevent]
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct NavUpdated {
    #[topic]
    pub feed_id: Symbol,
    #[topic]
    pub reporter: Address,
    pub nav: i128,
    pub timestamp: u64,
}

/// Emitted when a push is refused for breaking the feed's deviation bound. The
/// point of the event is that a rejection is loud: an operator watching the
/// stream sees the value that was refused and against which reference.
#[contractevent]
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct NavRejected {
    #[topic]
    pub feed_id: Symbol,
    #[topic]
    pub reporter: Address,
    pub previous_nav: i128,
    pub rejected_nav: i128,
    pub deviation_bps: u32,
    pub bound_bps: u32,
}

#[contract]
pub struct OracleAdapter;

#[contractimpl]
impl OracleAdapter {
    /// One time setup. Re-initialization is rejected so an operator cannot
    /// quietly swap the admin, the reporter set or the feed guards.
    pub fn initialize(e: Env, admin: Address) -> Result<(), OracleError> {
        if e.storage().instance().has(&Cfg::Admin) {
            return Err(OracleError::AlreadyInitialized);
        }
        admin.require_auth();
        e.storage().instance().set(&Cfg::Admin, &admin);
        e.storage()
            .instance()
            .set(&Cfg::Reporters, &Map::<Address, bool>::new(&e));
        e.storage()
            .instance()
            .set(&Cfg::Feeds, &Map::<Symbol, Feed>::new(&e));
        Self::bump_instance(&e);
        Ok(())
    }

    /// Add an address to the reporter set. Emits `reporter_added` so rotations
    /// are auditable off-chain without replaying the whole ledger.
    pub fn add_reporter(e: Env, admin: Address, reporter: Address) -> Result<(), OracleError> {
        Self::require_admin(&e, &admin)?;
        let mut reporters = Self::reporter_map(&e);
        reporters.set(reporter.clone(), true);
        e.storage().instance().set(&Cfg::Reporters, &reporters);
        Self::bump_instance(&e);
        ReporterAdded { reporter }.publish(&e);
        Ok(())
    }

    /// Remove an address from the reporter set. Emits `reporter_removed`.
    pub fn remove_reporter(e: Env, admin: Address, reporter: Address) -> Result<(), OracleError> {
        Self::require_admin(&e, &admin)?;
        let mut reporters = Self::reporter_map(&e);
        reporters.remove(reporter.clone());
        e.storage().instance().set(&Cfg::Reporters, &reporters);
        Self::bump_instance(&e);
        ReporterRemoved { reporter }.publish(&e);
        Ok(())
    }

    /// Register a feed with the guards it will be validated against.
    ///
    /// Guards are write once: re-registering an existing feed is rejected. A
    /// feed whose staleness or deviation bound needs retuning gets a new feed
    /// id, which makes the change visible to every consumer instead of
    /// silently loosening a bound under an unchanged name.
    pub fn register_feed(
        e: Env,
        admin: Address,
        feed_id: Symbol,
        staleness_secs: u64,
        deviation_bps: u32,
    ) -> Result<(), OracleError> {
        Self::require_admin(&e, &admin)?;
        if staleness_secs == 0 || deviation_bps as i128 > BPS {
            return Err(OracleError::InvalidFeedConfig);
        }
        let mut feeds = Self::feed_map(&e);
        if feeds.contains_key(feed_id.clone()) {
            return Err(OracleError::FeedAlreadyRegistered);
        }
        feeds.set(
            feed_id.clone(),
            Feed {
                staleness_secs,
                deviation_bps,
            },
        );
        e.storage().instance().set(&Cfg::Feeds, &feeds);
        Self::bump_instance(&e);
        FeedRegistered {
            feed_id,
            staleness_secs,
            deviation_bps,
        }
        .publish(&e);
        Ok(())
    }

    /// Report a new NAV for a feed, failing the transaction if anything is
    /// wrong. This is the strict path: a caller cannot ignore a rejection
    /// because there is no successful outcome to ignore.
    ///
    /// Four things are checked, in order, and any one of them fails the call:
    ///
    ///  - the caller is in the reporter set (and has authorized this call)
    ///  - the NAV is strictly positive
    ///  - the timestamp is strictly after the last one for this feed, and is
    ///    not in the future. Without the future check a reporter could push a
    ///    timestamp years ahead and the feed would never read as stale again,
    ///    which turns the staleness guard off permanently.
    ///  - the move from the previous NAV is within the feed's deviation bound
    pub fn push_nav(
        e: Env,
        reporter: Address,
        feed_id: Symbol,
        nav: i128,
        timestamp: u64,
    ) -> Result<(), OracleError> {
        match Self::validate(&e, &reporter, &feed_id, nav, timestamp)? {
            Some(_) => Err(OracleError::DeviationOutOfBounds),
            None => {
                Self::store(&e, reporter, feed_id, nav, timestamp);
                Ok(())
            }
        }
    }

    /// Report a new NAV, surfacing a deviation breach as a `nav_rejected` event
    /// and a `RejectedDeviation` outcome instead of failing the transaction.
    ///
    /// This exists because of a Soroban property rather than a preference: the
    /// host rolls back the events of an invocation that errors, so an entry
    /// point that returns an error on a bound breach cannot also leave a record
    /// of that breach in the ledger event stream. The protocol wants both,
    /// hence two entry points over one shared validation:
    ///
    ///  - `push_nav` for callers that must be stopped, the transaction fails
    ///  - `submit_nav` for the off-chain reporter, whose operators need
    ///    rejections in the event stream and not only in failed transactions
    ///
    /// Everything that is not a deviation breach (unauthorized caller, unknown
    /// feed, non-positive NAV, non-monotonic or future timestamp) still fails
    /// the call here: those are malformed reports, not disputed valuations.
    /// A rejected submission writes nothing, so the previous NAV and its
    /// timestamp both stay in place.
    pub fn submit_nav(
        e: Env,
        reporter: Address,
        feed_id: Symbol,
        nav: i128,
        timestamp: u64,
    ) -> Result<PushOutcome, OracleError> {
        match Self::validate(&e, &reporter, &feed_id, nav, timestamp)? {
            Some(rejection) => {
                rejection.publish(&e);
                Ok(PushOutcome::RejectedDeviation)
            }
            None => {
                Self::store(&e, reporter, feed_id, nav, timestamp);
                Ok(PushOutcome::Accepted)
            }
        }
    }

    // ---- views ----

    /// The latest NAV for a feed, or `OracleStale` if the stored point is older
    /// than the feed's staleness threshold. Returning an error rather than a
    /// stale number is deliberate: a consumer that ignores the result cannot
    /// end up pricing on data the protocol considers expired.
    pub fn get_nav(e: Env, feed_id: Symbol) -> Result<i128, OracleError> {
        let feed = Self::feed_map(&e)
            .get(feed_id.clone())
            .ok_or(OracleError::FeedNotRegistered)?;
        let point: NavPoint = e
            .storage()
            .temporary()
            .get(&Store::Nav(feed_id))
            .ok_or(OracleError::NoNavReported)?;
        if e.ledger().timestamp().saturating_sub(point.timestamp) > feed.staleness_secs {
            return Err(OracleError::OracleStale);
        }
        Ok(point.nav)
    }

    /// The raw stored point, staleness included. Monitoring needs to be able to
    /// see how stale a feed is, which `get_nav` deliberately refuses to say.
    pub fn last_update(e: Env, feed_id: Symbol) -> Result<NavPoint, OracleError> {
        e.storage()
            .temporary()
            .get(&Store::Nav(feed_id))
            .ok_or(OracleError::NoNavReported)
    }

    pub fn admin(e: Env) -> Result<Address, OracleError> {
        e.storage()
            .instance()
            .get(&Cfg::Admin)
            .ok_or(OracleError::NotInitialized)
    }

    pub fn is_reporter(e: Env, addr: Address) -> bool {
        Self::reporter_map(&e).get(addr).unwrap_or(false)
    }

    pub fn reporters(e: Env) -> Vec<Address> {
        Self::reporter_map(&e).keys()
    }

    pub fn get_feed(e: Env, feed_id: Symbol) -> Result<Feed, OracleError> {
        Self::feed_map(&e)
            .get(feed_id)
            .ok_or(OracleError::FeedNotRegistered)
    }

    // ---- internals ----

    /// Shared validation for both report paths.
    ///
    /// Returns `Err` for a malformed report, `Ok(Some(rejection))` for a
    /// well-formed report that breaks the feed's deviation bound, and
    /// `Ok(None)` for a report that should be stored. The caller decides what
    /// a bound breach means for it, which is the only difference between
    /// `push_nav` and `submit_nav`.
    fn validate(
        e: &Env,
        reporter: &Address,
        feed_id: &Symbol,
        nav: i128,
        timestamp: u64,
    ) -> Result<Option<NavRejected>, OracleError> {
        reporter.require_auth();
        if !Self::reporter_map(e).get(reporter.clone()).unwrap_or(false) {
            return Err(OracleError::UnauthorizedReporter);
        }
        let feed = Self::feed_map(e)
            .get(feed_id.clone())
            .ok_or(OracleError::FeedNotRegistered)?;
        if nav <= 0 {
            return Err(OracleError::InvalidNav);
        }
        if timestamp > e.ledger().timestamp() {
            return Err(OracleError::TimestampInFuture);
        }

        let last: Option<NavPoint> = e.storage().temporary().get(&Store::Nav(feed_id.clone()));
        let Some(last) = last else {
            return Ok(None); // first report for this feed, nothing to compare to
        };
        if timestamp <= last.timestamp {
            return Err(OracleError::NonMonotonicTimestamp);
        }
        // deviation_bps == 0 marks a deterministic feed (Etherfuse bond
        // pricing), where any move is by construction legitimate.
        if feed.deviation_bps == 0 || last.nav <= 0 {
            return Ok(None);
        }
        let deviation_bps = (nav - last.nav).abs() * BPS / last.nav;
        if deviation_bps <= feed.deviation_bps as i128 {
            return Ok(None);
        }
        Ok(Some(NavRejected {
            feed_id: feed_id.clone(),
            reporter: reporter.clone(),
            previous_nav: last.nav,
            rejected_nav: nav,
            deviation_bps: deviation_bps.min(u32::MAX as i128) as u32,
            bound_bps: feed.deviation_bps,
        }))
    }

    fn store(e: &Env, reporter: Address, feed_id: Symbol, nav: i128, timestamp: u64) {
        let key = Store::Nav(feed_id.clone());
        e.storage().temporary().set(&key, &NavPoint { nav, timestamp });
        e.storage()
            .temporary()
            .extend_ttl(&key, NAV_LIFETIME, NAV_BUMP);
        Self::bump_instance(e);
        NavUpdated {
            feed_id,
            reporter,
            nav,
            timestamp,
        }
        .publish(e);
    }

    fn bump_instance(e: &Env) {
        e.storage()
            .instance()
            .extend_ttl(INSTANCE_LIFETIME, INSTANCE_BUMP);
    }

    fn require_admin(e: &Env, admin: &Address) -> Result<(), OracleError> {
        let stored: Address = e
            .storage()
            .instance()
            .get(&Cfg::Admin)
            .ok_or(OracleError::NotInitialized)?;
        if stored != *admin {
            return Err(OracleError::NotAdmin);
        }
        admin.require_auth();
        Ok(())
    }

    fn reporter_map(e: &Env) -> Map<Address, bool> {
        e.storage()
            .instance()
            .get(&Cfg::Reporters)
            .unwrap_or(Map::new(e))
    }

    fn feed_map(e: &Env) -> Map<Symbol, Feed> {
        e.storage()
            .instance()
            .get(&Cfg::Feeds)
            .unwrap_or(Map::new(e))
    }
}
