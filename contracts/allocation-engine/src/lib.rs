#![no_std]
//! Allocation Engine, the constraint layer between the Vault and the pools.
//!
//! # Operational model
//!
//! V1 is admin directed. The Engine does not decide where capital goes: a human
//! operator does, by calling `allocate` with a pool and an amount. What the
//! Engine does is refuse. Every allocation is checked, on-chain and in the same
//! transaction, against four limits, and any one of them failing reverts the
//! call:
//!
//!  - the per-pool cap, so no single pool can take the book
//!  - the per-originator cap, so several pools fronted by the same originator
//!    cannot add up to concentrated counterparty risk
//!  - the per-jurisdiction cap, so the book is not one legal regime deep
//!  - the reserve floor, a minimum share of total assets that has to stay as
//!    idle USDC in the Vault
//!
//! The V2 off-chain optimizer changes who proposes an allocation. It does not
//! change who enforces these limits, which is why they live here and not in a
//! backend.
//!
//! # The reserve floor
//!
//! Fast-exit liquidity used to come from a Blend v2 position that could be
//! withdrawn instantly. Blend V2 is being wound down after the Comet BLND-USDC
//! exploit and has been removed from the SCF Integration List, and it is not
//! replaced by another protocol. The role it played is now a property of the
//! Engine instead of a dependency on somebody else's pool: `allocate` reverts
//! if the call would push idle reserves below `floor_bps` of total assets.
//!
//! This is a strictly stronger position than the one it replaces. A liquidity
//! buffer parked in a lending protocol is only as instant as that protocol's
//! utilization on the day you need it; USDC that never left the Vault has no
//! such dependency.
//!
//! # Fail closed
//!
//! `initialize` leaves every cap at zero and the reserve floor at 100%, so an
//! Engine that has been deployed but not yet configured cannot deploy capital
//! at all. Opening it up is an explicit admin action with an event attached.
//!
//! # Accounting
//!
//! Exposure records are persistent, not instance state: they have to survive
//! settlement cycles that run for weeks (D+15 to D+90 for private credit) and
//! outlive any single configuration change. Total assets are read as idle
//! reserves plus booked exposure, so allocating moves value between the two
//! without changing the denominator the caps are measured against.

use soroban_sdk::{
    contract, contractclient, contracterror, contractevent, contractimpl, contracttype, Address,
    Env, Map, Symbol, Vec,
};

const BPS: i128 = 10_000;

const DAY_LEDGERS: u32 = 17_280;
const INSTANCE_BUMP: u32 = 30 * DAY_LEDGERS;
const INSTANCE_LIFETIME: u32 = INSTANCE_BUMP - DAY_LEDGERS;
// Exposure records outlive settlement cycles, so they get the longest TTL the
// protocol uses anywhere: a private credit position can be open for 90 days.
const EXPOSURE_BUMP: u32 = 90 * DAY_LEDGERS;
const EXPOSURE_LIFETIME: u32 = EXPOSURE_BUMP - DAY_LEDGERS;

/// The part of the Vault the Engine talks to. Declared here rather than taken
/// as a crate dependency so the two contracts stay independently deployable.
#[contractclient(name = "VaultClient")]
pub trait VaultInterface {
    /// USDC sitting in the Vault, the quantity the reserve floor protects.
    fn idle_reserves(e: Env) -> i128;
    /// Move `amount` of that USDC to `pool`. The Vault is the only custodian;
    /// the Engine can instruct a release but never holds the funds itself.
    fn settle_allocation(e: Env, pool: Address, amount: i128);
}

/// The uniform pool interface. Every adapter implements exactly this, which is
/// what lets the Engine route to an off-chain credit facility and to a
/// tokenized bond with the same code path.
#[contractclient(name = "PoolAdapterClient")]
pub trait PoolAdapter {
    fn allocate(e: Env, amount: i128);
    fn deallocate(e: Env, amount: i128);
    fn get_exposure(e: Env) -> i128;
}

#[contracterror]
#[derive(Copy, Clone, Debug, Eq, PartialEq)]
#[repr(u32)]
pub enum EngineError {
    AlreadyInitialized = 400,
    NotInitialized = 401,
    NotAdmin = 402,
    PoolAlreadyRegistered = 403,
    PoolNotRegistered = 404,
    /// A cap or floor outside 0 to 10000 bps.
    InvalidCap = 405,
    InvalidAmount = 406,
    /// This pool would hold more than its cap allows.
    PoolCapExceeded = 407,
    /// The pools fronted by this originator would exceed the originator cap.
    OriginatorCapExceeded = 408,
    /// The pools in this jurisdiction would exceed the jurisdiction cap.
    JurisdictionCapExceeded = 409,
    /// The call would push idle Vault reserves below the floor.
    ReserveFloorBreached = 410,
    /// The Vault does not hold enough idle USDC to fund the allocation at all.
    InsufficientReserves = 411,
    /// Deallocating more than the pool has booked as deployed.
    ExposureUnderflow = 412,
}

/// Whitelist entry for a pool. `originator` and `jurisdiction` are the keys the
/// concentration caps aggregate over, so two pools sharing an originator are
/// counted together even though they are separate contracts.
#[derive(Clone, Debug, Eq, PartialEq)]
#[contracttype]
pub struct Pool {
    pub originator: Symbol,
    pub jurisdiction: Symbol,
    /// This pool's own limit, in bps of total assets. The effective limit is
    /// the tighter of this and the global per-pool cap.
    pub cap_bps: u32,
}

/// Global concentration limits, in bps of total assets.
#[derive(Clone, Debug, Eq, PartialEq)]
#[contracttype]
pub struct Caps {
    pub pool_bps: u32,
    pub originator_bps: u32,
    pub jurisdiction_bps: u32,
}

/// Instance storage: admin, Vault address, caps, reserve floor and the pool
/// registry. Configuration, read on every allocation.
#[derive(Clone)]
#[contracttype]
enum Cfg {
    Admin,
    Vault,
    Caps,
    ReserveFloorBps,
    Pools,
}

/// Persistent storage: the exposure book. These records have to survive
/// settlement cycles measured in months, so they never live in temporary or
/// instance storage.
#[derive(Clone)]
#[contracttype]
enum Store {
    Exposure(Address),
    TotalAllocated,
}

#[contractevent]
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct PoolRegistered {
    #[topic]
    pub pool: Address,
    pub originator: Symbol,
    pub jurisdiction: Symbol,
    pub cap_bps: u32,
}

#[contractevent]
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct CapsUpdated {
    pub pool_bps: u32,
    pub originator_bps: u32,
    pub jurisdiction_bps: u32,
}

#[contractevent]
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ReserveFloorUpdated {
    pub floor_bps: u32,
}

#[contractevent]
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct Allocated {
    #[topic]
    pub pool: Address,
    pub amount: i128,
    pub pool_exposure: i128,
    /// Idle USDC left in the Vault after the release, so the reserve position
    /// after every allocation is in the event stream and not only derivable.
    pub idle_after: i128,
}

#[contractevent]
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct Deallocated {
    #[topic]
    pub pool: Address,
    pub amount: i128,
    pub pool_exposure: i128,
}

#[contract]
pub struct AllocationEngine;

#[contractimpl]
impl AllocationEngine {
    /// Wire the Engine to the Vault whose capital it governs.
    ///
    /// Deliberately fail closed: caps start at zero and the reserve floor at
    /// 100%, so a deployed but unconfigured Engine refuses every allocation.
    /// The alternative, defaulting to unlimited, would make a forgotten
    /// configuration step indistinguishable from an intentional one.
    pub fn initialize(e: Env, admin: Address, vault: Address) -> Result<(), EngineError> {
        if e.storage().instance().has(&Cfg::Admin) {
            return Err(EngineError::AlreadyInitialized);
        }
        admin.require_auth();
        e.storage().instance().set(&Cfg::Admin, &admin);
        e.storage().instance().set(&Cfg::Vault, &vault);
        e.storage().instance().set(
            &Cfg::Caps,
            &Caps {
                pool_bps: 0,
                originator_bps: 0,
                jurisdiction_bps: 0,
            },
        );
        e.storage()
            .instance()
            .set(&Cfg::ReserveFloorBps, &(BPS as u32));
        e.storage()
            .instance()
            .set(&Cfg::Pools, &Map::<Address, Pool>::new(&e));
        Self::bump_instance(&e);
        Ok(())
    }

    /// Whitelist a pool adapter along with the metadata the caps aggregate
    /// over. A pool that is not registered cannot receive capital at all, so
    /// this is the first of the four gates.
    pub fn register_pool(
        e: Env,
        admin: Address,
        pool_id: Address,
        originator: Symbol,
        jurisdiction: Symbol,
        cap_bps: u32,
    ) -> Result<(), EngineError> {
        Self::require_admin(&e, &admin)?;
        if cap_bps as i128 > BPS {
            return Err(EngineError::InvalidCap);
        }
        let mut pools = Self::pool_map(&e);
        if pools.contains_key(pool_id.clone()) {
            return Err(EngineError::PoolAlreadyRegistered);
        }
        pools.set(
            pool_id.clone(),
            Pool {
                originator: originator.clone(),
                jurisdiction: jurisdiction.clone(),
                cap_bps,
            },
        );
        e.storage().instance().set(&Cfg::Pools, &pools);
        Self::bump_instance(&e);
        PoolRegistered {
            pool: pool_id,
            originator,
            jurisdiction,
            cap_bps,
        }
        .publish(&e);
        Ok(())
    }

    /// Set the global concentration limits, in bps of total assets.
    ///
    /// The per-pool figure here is an upper bound on every pool: a pool's
    /// effective limit is the tighter of its own `cap_bps` and this one, so
    /// tightening globally cannot be undone by a generous per-pool entry.
    pub fn set_caps(
        e: Env,
        admin: Address,
        pool_cap_bps: u32,
        originator_cap_bps: u32,
        jurisdiction_cap_bps: u32,
    ) -> Result<(), EngineError> {
        Self::require_admin(&e, &admin)?;
        if pool_cap_bps as i128 > BPS
            || originator_cap_bps as i128 > BPS
            || jurisdiction_cap_bps as i128 > BPS
        {
            return Err(EngineError::InvalidCap);
        }
        e.storage().instance().set(
            &Cfg::Caps,
            &Caps {
                pool_bps: pool_cap_bps,
                originator_bps: originator_cap_bps,
                jurisdiction_bps: jurisdiction_cap_bps,
            },
        );
        Self::bump_instance(&e);
        CapsUpdated {
            pool_bps: pool_cap_bps,
            originator_bps: originator_cap_bps,
            jurisdiction_bps: jurisdiction_cap_bps,
        }
        .publish(&e);
        Ok(())
    }

    /// Set the minimum share of total assets that must stay as idle USDC in the
    /// Vault. This is the protocol's fast-exit liquidity, held as cash rather
    /// than as a position in someone else's lending market.
    pub fn set_reserve_floor(e: Env, admin: Address, floor_bps: u32) -> Result<(), EngineError> {
        Self::require_admin(&e, &admin)?;
        if floor_bps as i128 > BPS {
            return Err(EngineError::InvalidCap);
        }
        e.storage().instance().set(&Cfg::ReserveFloorBps, &floor_bps);
        Self::bump_instance(&e);
        ReserveFloorUpdated { floor_bps }.publish(&e);
        Ok(())
    }

    /// Route `amount` of Vault capital into `pool_id`.
    ///
    /// Admin directed and admin authorized: the operator chooses the pool and
    /// the size, the Engine decides whether that is allowed. Four limits are
    /// checked against total assets (idle reserves plus everything already
    /// deployed), and any one of them failing reverts the whole call, so a
    /// rejected allocation moves no funds and books no exposure.
    ///
    /// Total assets are the denominator on purpose. Allocating moves value
    /// from idle to deployed without changing the total, so the caps measure a
    /// share of the book rather than a share of whatever happens to be liquid,
    /// and cannot be gamed by allocating in small pieces.
    ///
    /// The reserve floor is checked last and is the guard that replaces the
    /// removed Blend liquidity buffer: whatever the caps allow, the Vault has
    /// to be left holding at least `floor_bps` of total assets in idle USDC.
    ///
    /// On success the Vault releases the USDC to the pool and the adapter
    /// books it, in the same transaction as the check. There is no window in
    /// which the Engine has approved an allocation that has not settled.
    pub fn allocate(
        e: Env,
        admin: Address,
        pool_id: Address,
        amount: i128,
    ) -> Result<(), EngineError> {
        Self::require_admin(&e, &admin)?;
        if amount <= 0 {
            return Err(EngineError::InvalidAmount);
        }
        let pools = Self::pool_map(&e);
        let pool = pools
            .get(pool_id.clone())
            .ok_or(EngineError::PoolNotRegistered)?;

        let vault_address = Self::vault(e.clone())?;
        let vault = VaultClient::new(&e, &vault_address);
        let idle = vault.idle_reserves();
        let deployed = Self::total_allocated(e.clone());
        let total_assets = idle + deployed;
        if amount > idle {
            return Err(EngineError::InsufficientReserves);
        }

        let caps = Self::caps(e.clone());

        // Per pool: the tighter of the pool's own cap and the global one.
        let pool_cap_bps = pool.cap_bps.min(caps.pool_bps) as i128;
        let pool_exposure = Self::get_exposure(e.clone(), pool_id.clone()) + amount;
        if pool_exposure * BPS > pool_cap_bps * total_assets {
            return Err(EngineError::PoolCapExceeded);
        }

        // Per originator: summed across every pool that counterparty fronts.
        let originator_exposure =
            Self::exposure_where_originator(&e, &pools, &pool.originator) + amount;
        if originator_exposure * BPS > caps.originator_bps as i128 * total_assets {
            return Err(EngineError::OriginatorCapExceeded);
        }

        // Per jurisdiction: summed across every pool under that legal regime.
        let jurisdiction_exposure =
            Self::exposure_where_jurisdiction(&e, &pools, &pool.jurisdiction) + amount;
        if jurisdiction_exposure * BPS > caps.jurisdiction_bps as i128 * total_assets {
            return Err(EngineError::JurisdictionCapExceeded);
        }

        // Reserve floor: what the Vault is left holding as instantly available
        // cash once this release settles.
        let idle_after = idle - amount;
        if idle_after * BPS < Self::reserve_floor_bps(e.clone()) as i128 * total_assets {
            return Err(EngineError::ReserveFloorBreached);
        }

        Self::write_exposure(&e, &pool_id, pool_exposure);
        Self::write_total_allocated(&e, deployed + amount);
        Self::bump_instance(&e);

        vault.settle_allocation(&pool_id, &amount);
        PoolAdapterClient::new(&e, &pool_id).allocate(&amount);

        Allocated {
            pool: pool_id,
            amount,
            pool_exposure,
            idle_after,
        }
        .publish(&e);
        Ok(())
    }

    /// Record capital returning from a pool to the Vault.
    ///
    /// Authorized by the stored admin rather than by an address argument: the
    /// signature carries no admin parameter, and letting anyone trigger a
    /// repayment would let a third party force an early unwind. The adapter
    /// moves the USDC back to the Vault in the same call that reduces the
    /// exposure, so the book and the cash cannot diverge.
    ///
    /// No cap is checked here. Deallocating always moves the book towards the
    /// reserve floor and away from every concentration limit, so it can never
    /// be the operation that breaches one.
    pub fn deallocate(e: Env, pool_id: Address, amount: i128) -> Result<(), EngineError> {
        Self::admin(e.clone())?.require_auth();
        if amount <= 0 {
            return Err(EngineError::InvalidAmount);
        }
        if !Self::pool_map(&e).contains_key(pool_id.clone()) {
            return Err(EngineError::PoolNotRegistered);
        }
        let exposure = Self::get_exposure(e.clone(), pool_id.clone());
        if amount > exposure {
            return Err(EngineError::ExposureUnderflow);
        }

        PoolAdapterClient::new(&e, &pool_id).deallocate(&amount);

        let pool_exposure = exposure - amount;
        Self::write_exposure(&e, &pool_id, pool_exposure);
        Self::write_total_allocated(&e, Self::total_allocated(e.clone()) - amount);
        Self::bump_instance(&e);

        Deallocated {
            pool: pool_id,
            amount,
            pool_exposure,
        }
        .publish(&e);
        Ok(())
    }

    // ---- views ----

    /// Idle Vault reserves as a share of total assets, in bps. This is the
    /// number `set_reserve_floor` sets a lower bound on.
    pub fn get_reserve_ratio(e: Env) -> Result<u32, EngineError> {
        let vault_address = Self::vault(e.clone())?;
        let idle = VaultClient::new(&e, &vault_address).idle_reserves();
        let total_assets = idle + Self::total_allocated(e.clone());
        if total_assets <= 0 {
            // No assets means nothing is at risk, so the reserve is complete.
            return Ok(BPS as u32);
        }
        Ok((idle * BPS / total_assets) as u32)
    }

    /// Capital currently deployed into `pool_id`, in USDC.
    pub fn get_exposure(e: Env, pool_id: Address) -> i128 {
        e.storage()
            .persistent()
            .get(&Store::Exposure(pool_id))
            .unwrap_or(0)
    }

    /// The whole exposure book, keyed by pool. Registered pools with no
    /// exposure are included as zero, so the map doubles as the whitelist.
    pub fn get_exposures(e: Env) -> Map<Address, i128> {
        let mut out = Map::new(&e);
        for pool_id in Self::pool_map(&e).keys().iter() {
            out.set(pool_id.clone(), Self::get_exposure(e.clone(), pool_id));
        }
        out
    }

    /// Total capital booked as deployed across every pool. The Vault reads this
    /// to compute total assets.
    pub fn total_allocated(e: Env) -> i128 {
        e.storage()
            .persistent()
            .get(&Store::TotalAllocated)
            .unwrap_or(0)
    }

    pub fn caps(e: Env) -> Caps {
        e.storage().instance().get(&Cfg::Caps).unwrap_or(Caps {
            pool_bps: 0,
            originator_bps: 0,
            jurisdiction_bps: 0,
        })
    }

    pub fn reserve_floor_bps(e: Env) -> u32 {
        e.storage()
            .instance()
            .get(&Cfg::ReserveFloorBps)
            .unwrap_or(BPS as u32)
    }

    pub fn get_pool(e: Env, pool_id: Address) -> Result<Pool, EngineError> {
        Self::pool_map(&e)
            .get(pool_id)
            .ok_or(EngineError::PoolNotRegistered)
    }

    pub fn pools(e: Env) -> Vec<Address> {
        Self::pool_map(&e).keys()
    }

    pub fn vault(e: Env) -> Result<Address, EngineError> {
        e.storage()
            .instance()
            .get(&Cfg::Vault)
            .ok_or(EngineError::NotInitialized)
    }

    pub fn admin(e: Env) -> Result<Address, EngineError> {
        e.storage()
            .instance()
            .get(&Cfg::Admin)
            .ok_or(EngineError::NotInitialized)
    }

    // ---- internals ----

    fn require_admin(e: &Env, admin: &Address) -> Result<(), EngineError> {
        let stored: Address = e
            .storage()
            .instance()
            .get(&Cfg::Admin)
            .ok_or(EngineError::NotInitialized)?;
        if stored != *admin {
            return Err(EngineError::NotAdmin);
        }
        admin.require_auth();
        Ok(())
    }

    /// Exposure summed across every registered pool fronted by `originator`.
    /// The cap is on the counterparty, not on the contract, so three pools
    /// from the same originator count as one position.
    fn exposure_where_originator(
        e: &Env,
        pools: &Map<Address, Pool>,
        originator: &Symbol,
    ) -> i128 {
        let mut total: i128 = 0;
        for (pool_id, pool) in pools.iter() {
            if pool.originator == *originator {
                total += Self::get_exposure(e.clone(), pool_id);
            }
        }
        total
    }

    /// Exposure summed across every registered pool in `jurisdiction`.
    fn exposure_where_jurisdiction(
        e: &Env,
        pools: &Map<Address, Pool>,
        jurisdiction: &Symbol,
    ) -> i128 {
        let mut total: i128 = 0;
        for (pool_id, pool) in pools.iter() {
            if pool.jurisdiction == *jurisdiction {
                total += Self::get_exposure(e.clone(), pool_id);
            }
        }
        total
    }

    fn write_exposure(e: &Env, pool_id: &Address, value: i128) {
        let key = Store::Exposure(pool_id.clone());
        e.storage().persistent().set(&key, &value);
        e.storage()
            .persistent()
            .extend_ttl(&key, EXPOSURE_LIFETIME, EXPOSURE_BUMP);
    }

    fn write_total_allocated(e: &Env, value: i128) {
        e.storage().persistent().set(&Store::TotalAllocated, &value);
        e.storage().persistent().extend_ttl(
            &Store::TotalAllocated,
            EXPOSURE_LIFETIME,
            EXPOSURE_BUMP,
        );
    }

    fn pool_map(e: &Env) -> Map<Address, Pool> {
        e.storage()
            .instance()
            .get(&Cfg::Pools)
            .unwrap_or(Map::new(e))
    }

    fn bump_instance(e: &Env) {
        e.storage()
            .instance()
            .extend_ttl(INSTANCE_LIFETIME, INSTANCE_BUMP);
    }
}
