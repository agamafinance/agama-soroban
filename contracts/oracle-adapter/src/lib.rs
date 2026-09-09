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
//! | feed                    | staleness | deviation | interval | band          |
//! |-------------------------|-----------|-----------|----------|---------------|
//! | Reflector USDC/USD peg  | 1 hour    | 200 bps   | 5 min    | 0.90 to 1.10  |
//! | Private credit NAV      | 7 days    | 500 bps   | 1 hour   | 0.50 to 2.00  |
//! | Etherfuse bond price    | 48 hours  | none      | 1 hour   | 0.50 to 2.00  |
//!
//! Five properties matter more than the rest, and each of them is a test:
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
//! 4. Every value has to sit inside the feed's absolute band, including the
//!    first one. A deviation bound is a bound on a move, and a move needs
//!    something to move from, so the first report for a feed was previously
//!    unconstrained: `push_nav(i128::MAX)` was accepted and became the
//!    reference every later bound was measured against.
//! 5. A feed cannot be walked anywhere by repetition. The deviation bound is
//!    per push, so without a rate limit forty pushes of +5% moved a NAV by a
//!    factor of seven in forty seconds, every one of them inside the bound.
//!    Each feed carries a minimum interval, measured in ledger time between
//!    accepted values rather than in the timestamps the reporter supplies,
//!    because a reporter chooses those and can space them however it likes.
//!
//! The reference point lives in persistent storage, not temporary. It used to
//! be temporary, on the reasoning that the latest NAV is replaced on every
//! update and history belongs in the event stream. That is true and it was the
//! wrong storage anyway: when a temporary entry expires there is no reference
//! left, and a report with nothing to compare against skips the monotonicity
//! check, the deviation bound and the rate limit in one go. Waiting out a TTL
//! is not an attack anybody has to work at.
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
// The NAV point is the reference every guard is measured against, so its TTL
// outlasts the longest staleness window (7 days for private credit) by a wide
// margin: a reference that has expired does not make the checks weaker, it
// removes them.
const NAV_BUMP: u32 = 90 * DAY_LEDGERS;
const NAV_LIFETIME: u32 = NAV_BUMP - DAY_LEDGERS;

/// Feed identifiers and guard parameters the protocol runs with. They live here
/// rather than only in a deploy script so the on-chain configuration and the
/// documented configuration cannot drift apart.
pub const FEED_USDC_USD: Symbol = symbol_short!("USDC_USD");
pub const FEED_PC_NAV: Symbol = symbol_short!("PC_NAV");
pub const FEED_EF_BOND: Symbol = symbol_short!("EF_BOND");

/// NAV is reported at 7 decimals, the same scale as the tokens it prices.
pub const ONE: i128 = 10_000_000;

/// Reflector USDC/USD peg check: 1 hour staleness, 200 bps deviation.
pub const REFLECTOR_STALENESS: u64 = 3_600;
pub const REFLECTOR_DEVIATION_BPS: u32 = 200;
/// A dollar peg that has left this band is not a price to trade on, it is an
/// incident. Wider than the 200 bps per push bound on purpose: the band is the
/// outer wall, the deviation bound is the working limit.
pub const REFLECTOR_MIN_NAV: i128 = ONE * 9 / 10;
pub const REFLECTOR_MAX_NAV: i128 = ONE * 11 / 10;
/// Five minutes between accepted peg values. The feed updates far more often
/// than the protocol needs it to, so the limit costs nothing and caps how far
/// a compromised reporter can walk the peg in an hour.
pub const REFLECTOR_MIN_INTERVAL: u64 = 300;

/// Private credit NAV reporter: 7 days staleness, 500 bps deviation.
pub const PRIVATE_CREDIT_STALENESS: u64 = 7 * 86_400;
pub const PRIVATE_CREDIT_DEVIATION_BPS: u32 = 500;
/// A book that has halved or doubled has not been revalued, it has defaulted or
/// been misreported, and either way it is not a number to price redemptions on
/// without somebody looking at it.
pub const NAV_BAND_MIN: i128 = ONE / 2;
pub const NAV_BAND_MAX: i128 = ONE * 2;
/// An hour between accepted values. The book settles in D+15 to D+90, so
/// nothing legitimate needs to say two different things about it in one hour.
pub const NAV_MIN_INTERVAL: u64 = 3_600;

/// Etherfuse bond price: 48 hours staleness, deterministic so no bound.
pub const ETHERFUSE_STALENESS: u64 = 48 * 3_600;
pub const ETHERFUSE_DEVIATION_BPS: u32 = 0;

#[contracterror]
#[derive(Copy, Clone, Debug, Eq, PartialEq)]
#[repr(u32)]
pub enum OracleError {
    /// Retired with `initialize`, which a `__constructor` replaced. The host
    /// runs a constructor exactly once, inside the deploy, so there is no
    /// second call for this to be the answer to. The number is kept rather than
    /// reused so that an old error code never means something new.
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
    /// The value is outside the feed's absolute band. Applies to every report
    /// including the first, which is the one a deviation bound cannot cover.
    NavOutOfBand = 513,
    /// The feed's minimum interval has not elapsed since the last accepted
    /// value, measured in ledger time.
    TooSoon = 514,
    /// `accept_admin` was called with no handover in flight.
    NoPendingAdmin = 515,
    /// `accept_admin` was called by an address that was not the one proposed.
    NotPendingAdmin = 516,
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
    /// Absolute band. Every value has to sit inside it, including the first,
    /// which is what a deviation bound structurally cannot cover: a bound on a
    /// move needs something to move from.
    pub min_nav: i128,
    pub max_nav: i128,
    /// Minimum ledger time between two accepted values. A deviation bound
    /// limits one step; this limits how many steps can be taken. Measured in
    /// ledger time rather than in reported timestamps, because the reporter
    /// chooses those and can space them as widely as it likes while pushing
    /// them all in the same minute.
    pub min_interval_secs: u64,
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
    /// The moment the reporter says the value is from.
    pub timestamp: u64,
    /// The ledger time the value was accepted at. The rate limit is measured
    /// against this, because it is the one of the two the reporter does not
    /// choose.
    pub recorded_at: u64,
}

/// Instance storage: admin, reporter set and feed configuration. All three are
/// small, read on every push, and must live as long as the contract does.
#[derive(Clone)]
#[contracttype]
enum Cfg {
    Admin,
    Reporters,
    Feeds,
    /// Half finished admin handover: proposed, not yet accepted.
    PendingAdmin,
}

/// Persistent storage: the latest NAV of a feed. It is replaced on every
/// update and history belongs in the event stream, which is why it used to be
/// temporary, and that was wrong for a reason that has nothing to do with
/// history. This entry is the reference the monotonicity check, the deviation
/// bound and the rate limit are all measured against, so an expired one does
/// not degrade those checks, it removes them.
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
    pub min_nav: i128,
    pub max_nav: i128,
    pub min_interval_secs: u64,
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

/// Emitted when an admin handover is proposed. The role has not moved yet: this
/// is the first half of a two step transfer, and it is in the event stream so
/// that a pending handover is visible to anyone watching rather than only to
/// whoever thinks to read the state.
#[contractevent]
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct AdminProposed {
    #[topic]
    pub new_admin: Address,
}

/// Emitted when a proposed admin accepts and the role actually moves.
#[contractevent]
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct AdminChanged {
    #[topic]
    pub admin: Address,
}

#[contract]
pub struct OracleAdapter;

#[contractimpl]
impl OracleAdapter {
    /// One time setup. Re-initialization is rejected so an operator cannot
    /// quietly swap the admin, the reporter set or the feed guards.
    /// Record the admin, with an empty reporter set and no feeds registered, in the transaction that deploys it.
    ///
    /// This was `initialize`, a separate call, and being separate was the
    /// problem. A contract sitting deployed and uninitialized is a contract
    /// whose admin is whoever sends the next transaction, and the deployer's
    /// own call is public before it is mined, so it can be front-run by an
    /// identical one naming somebody else. On this contract that is the authority to name the reporters every NAV in the protocol is trusted from. A constructor runs inside
    /// the deploy, so there is no window to race, and the host runs it exactly
    /// once, which is what used to need a re-initialization guard.
    pub fn __constructor(e: Env, admin: Address) -> Result<(), OracleError> {
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
        min_nav: i128,
        max_nav: i128,
        min_interval_secs: u64,
    ) -> Result<(), OracleError> {
        Self::require_admin(&e, &admin)?;
        if staleness_secs == 0
            || deviation_bps as i128 > BPS
            || min_nav <= 0
            || max_nav < min_nav
        {
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
                min_nav,
                max_nav,
                min_interval_secs,
            },
        );
        e.storage().instance().set(&Cfg::Feeds, &feeds);
        Self::bump_instance(&e);
        FeedRegistered {
            feed_id,
            staleness_secs,
            deviation_bps,
            min_nav,
            max_nav,
            min_interval_secs,
        }
        .publish(&e);
        Ok(())
    }

    /// Report a new NAV for a feed, failing the transaction if anything is
    /// wrong. This is the strict path: a caller cannot ignore a rejection
    /// because there is no successful outcome to ignore.
    ///
    /// Six things are checked, in order, and any one of them fails the call:
    ///
    ///  - the caller is in the reporter set (and has authorized this call)
    ///  - the NAV is strictly positive
    ///  - the NAV is inside the feed's absolute band. This one applies to the
    ///    first report as well, which is the report a deviation bound cannot
    ///    reach: before it existed, the first value for a feed was accepted
    ///    unconditionally and became the reference every later bound was
    ///    measured against.
    ///  - the timestamp is strictly after the last one for this feed, and is
    ///    not in the future. Without the future check a reporter could push a
    ///    timestamp years ahead and the feed would never read as stale again,
    ///    which turns the staleness guard off permanently.
    ///  - the feed's minimum interval has elapsed in ledger time since the last
    ///    accepted value. A deviation bound limits one step and says nothing
    ///    about how many steps can be taken, so without this a feed can be
    ///    walked anywhere inside a minute.
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

    /// Hand the admin role to another address, in two steps.
    ///
    /// This contract had no rotation at all, which made the admin key a single
    /// point of failure with no way back from either of the two ways it fails.
    /// A key that is lost takes every admin gated call in this contract with
    /// it, permanently. A key that is compromised cannot be replaced, so the
    /// only remedy left is redeploying the contract and migrating whatever it
    /// holds, which for a custodian is not a remedy.
    ///
    /// Two steps rather than one, because a one step setter aimed at an
    /// address nobody controls produces exactly the unrecoverable state the
    /// rotation exists to fix, and it does it in a single transaction with no
    /// second chance. The proposed address has to authorize a transaction of
    /// its own before anything changes, and that signature is the proof the
    /// key is real and reachable.
    ///
    /// A proposal replaces any earlier one. An admin that changes its mind
    /// proposes a different address; an admin that wants to withdraw a
    /// proposal proposes itself, which is a no-op if it is ever accepted.
    pub fn propose_admin(e: Env, admin: Address, new_admin: Address) -> Result<(), OracleError> {
        Self::require_admin(&e, &admin)?;
        e.storage().instance().set(&Cfg::PendingAdmin, &new_admin);
        Self::bump_instance(&e);
        AdminProposed { new_admin }.publish(&e);
        Ok(())
    }

    /// Complete a handover. Only the proposed address can call it, and it has
    /// to authorize the call itself: that authorization is the entire point of
    /// the second step.
    pub fn accept_admin(e: Env, new_admin: Address) -> Result<(), OracleError> {
        let pending: Address = e
            .storage()
            .instance()
            .get(&Cfg::PendingAdmin)
            .ok_or(OracleError::NoPendingAdmin)?;
        if pending != new_admin {
            return Err(OracleError::NotPendingAdmin);
        }
        new_admin.require_auth();
        e.storage().instance().set(&Cfg::Admin, &new_admin);
        e.storage().instance().remove(&Cfg::PendingAdmin);
        Self::bump_instance(&e);
        AdminChanged {
            admin: new_admin,
        }
        .publish(&e);
        Ok(())
    }

    /// The address that has been proposed as admin and has not accepted yet.
    /// `None` means no handover is in flight.
    pub fn pending_admin(e: Env) -> Option<Address> {
        e.storage().instance().get(&Cfg::PendingAdmin)
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
            .persistent()
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
            .persistent()
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
        // The band is checked before anything that depends on a previous value,
        // because it is the only guard that covers the first report.
        if nav < feed.min_nav || nav > feed.max_nav {
            return Err(OracleError::NavOutOfBand);
        }
        if timestamp > e.ledger().timestamp() {
            return Err(OracleError::TimestampInFuture);
        }

        let last: Option<NavPoint> = e.storage().persistent().get(&Store::Nav(feed_id.clone()));
        let Some(last) = last else {
            return Ok(None); // first report for this feed, nothing to compare to
        };
        if timestamp <= last.timestamp {
            return Err(OracleError::NonMonotonicTimestamp);
        }
        if e.ledger().timestamp() < last.recorded_at.saturating_add(feed.min_interval_secs) {
            return Err(OracleError::TooSoon);
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
        e.storage().persistent().set(
            &key,
            &NavPoint {
                nav,
                timestamp,
                recorded_at: e.ledger().timestamp(),
            },
        );
        e.storage()
            .persistent()
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

mod test;
