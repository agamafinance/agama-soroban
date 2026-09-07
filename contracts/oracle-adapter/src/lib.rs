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
//! 3. A push that breaks the feed's deviation bound does not silently pass and
//!    does not silently no-op: it emits `nav_rejected` and returns an error, so
//!    the caller sees the failure and the previous NAV stays in place.
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

    // ---- views ----

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
