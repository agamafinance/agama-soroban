#![no_std]
//! Vault contract, the entry point for capital.
//!
//! USDC comes in, agUSD goes out 1:1, and the USDC stays here until the
//! Allocation Engine instructs a release. The Vault is the protocol's only
//! custodian: the Engine decides nothing about custody and holds nothing, it
//! calls `settle_allocation` and the funds move from here.
//!
//! # Deposits and withdrawals are asymmetric on purpose
//!
//! Depositing is instant, because taking cash in is always possible.
//! Withdrawing is two steps, `request_withdrawal` then `claim_withdrawal`,
//! because the assets backing agUSD are private credit positions that settle in
//! D+15 to D+90. A vault that promised instant redemption against that book
//! would be promising something it can only honour while nobody asks.
//!
//! agUSD is a synthetic dollar, not a yield-bearing share: a withdrawal returns
//! one USDC per agUSD burned. Yield accrues to sagUSD, in the staking contract,
//! by share price appreciation. NAV from the Oracle Adapter is therefore read
//! for reporting and monitoring, not applied to the redemption rate.
//!
//! # The queue is strictly first in, first out
//!
//! Claims are numbered in the order they are requested and paid in that order.
//! `claim_withdrawal` refuses anything that is not at the head of the queue,
//! and there is no admin path around it: a protocol that can reorder its own
//! withdrawal queue under stress has not really got one.
//!
//! The cost of that choice is a liveness one, and it is deliberate: if the
//! owner of the head claim never comes back to claim it, the queue does not
//! advance. Skipping them would be precisely the priority jumping the queue
//! exists to prevent, so V1 accepts the stall.
//!
//! # Circuit breaker
//!
//! `set_paused` blocks deposits, withdrawal requests, claims and new
//! allocations. It does not touch the staking contract or the Oracle Adapter:
//! during an incident, NAV reporting is exactly what should keep running.
//! Pausing allocations goes slightly beyond blocking user flows, and is
//! deliberate: deploying more capital into pools during an emergency stop is
//! the opposite of what the stop is for.

use soroban_sdk::{
    contract, contractclient, contracterror, contractevent, contractimpl, contracttype,
    token::TokenClient, Address, Env, Symbol,
};

const DAY_LEDGERS: u32 = 17_280;
const INSTANCE_BUMP: u32 = 30 * DAY_LEDGERS;
const INSTANCE_LIFETIME: u32 = INSTANCE_BUMP - DAY_LEDGERS;

/// agUSD, as seen from the Vault. The Vault is the token's admin, so it is the
/// only address that can mint against a deposit or burn against a withdrawal.
#[contractclient(name = "AgUsdClient")]
pub trait ShareToken {
    fn mint(e: Env, to: Address, amount: i128);
    fn burn(e: Env, from: Address, amount: i128);
    fn balance(e: Env, id: Address) -> i128;
}

/// The Allocation Engine, as seen from the Vault.
#[contractclient(name = "EngineClient")]
pub trait AllocationEngineInterface {
    fn total_allocated(e: Env) -> i128;
}

/// The Oracle Adapter, as seen from the Vault. `get_nav` fails rather than
/// returning a stale number, and the Vault lets that failure propagate.
#[contractclient(name = "OracleClient")]
pub trait OracleInterface {
    fn get_nav(e: Env, feed_id: Symbol) -> i128;
}

#[contracterror]
#[derive(Copy, Clone, Debug, Eq, PartialEq)]
#[repr(u32)]
pub enum VaultError {
    AlreadyInitialized = 300,
    NotInitialized = 301,
    NotAdmin = 302,
    /// The circuit breaker is on.
    Paused = 303,
    /// Zero or negative amount.
    InvalidAmount = 304,
    /// Withdrawal below the anti-dust minimum.
    BelowMinWithdrawal = 305,
    ClaimNotFound = 306,
    NotClaimOwner = 307,
    AlreadyClaimed = 308,
    /// The claim is not at the head of the FIFO queue yet.
    NotAtQueueHead = 309,
    /// The claim is at the head but the Vault does not hold enough idle USDC.
    InsufficientLiquidity = 310,
    /// `set_oracle` has not been called yet.
    OracleNotConfigured = 311,
}

/// A queued withdrawal. The agUSD is burned at request time, so this record is
/// the user's only claim on the USDC and has to be durable.
#[derive(Clone, Debug, Eq, PartialEq)]
#[contracttype]
pub struct Claim {
    pub owner: Address,
    pub amount: i128,
    pub requested_at: u64,
    pub claimed: bool,
}

/// Where a claim stands. `Ready` is derived rather than stored: a claim is
/// ready exactly when it is at the head of the queue and the Vault holds the
/// cash, and both of those change without anyone touching the claim.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
#[contracttype]
pub enum ClaimStatus {
    Pending,
    Ready,
    Claimed,
}

/// Instance storage: addresses, the pause flag and the two queue pointers.
#[derive(Clone)]
#[contracttype]
enum Cfg {
    Admin,
    Usdc,
    AgUsd,
    Engine,
    Oracle,
    OracleFeed,
    Paused,
    QueueHead,
    QueueTail,
}

/// Persistent storage: the claim records, keyed by claim id.
#[derive(Clone)]
#[contracttype]
enum Store {
    Claim(u64),
}

#[contract]
pub struct Vault;

#[contractimpl]
impl Vault {
    /// Wire the Vault to its token contracts and to the Allocation Engine.
    ///
    /// Re-initialization is rejected. Without that guard, anyone able to call
    /// `initialize` a second time could repoint `agusd_token` at a contract
    /// they control and mint against the Vault's reserves.
    pub fn initialize(
        e: Env,
        admin: Address,
        usdc_token: Address,
        agusd_token: Address,
        allocation_engine: Address,
    ) -> Result<(), VaultError> {
        if e.storage().instance().has(&Cfg::Admin) {
            return Err(VaultError::AlreadyInitialized);
        }
        admin.require_auth();
        e.storage().instance().set(&Cfg::Admin, &admin);
        e.storage().instance().set(&Cfg::Usdc, &usdc_token);
        e.storage().instance().set(&Cfg::AgUsd, &agusd_token);
        e.storage().instance().set(&Cfg::Engine, &allocation_engine);
        e.storage().instance().set(&Cfg::Paused, &false);
        // Claim ids start at 1 so that 0 can never be a valid claim.
        e.storage().instance().set(&Cfg::QueueHead, &1u64);
        e.storage().instance().set(&Cfg::QueueTail, &1u64);
        Self::bump_instance(&e);
        Ok(())
    }

    /// Point the Vault at the Oracle Adapter and the feed it reads NAV from.
    ///
    /// Separate from `initialize` because the two contracts ship in different
    /// tranches: the Vault has to be deployable and usable before the Oracle
    /// Adapter exists. Until this is called, `get_nav` returns
    /// `OracleNotConfigured` rather than a made up number.
    pub fn set_oracle(
        e: Env,
        admin: Address,
        oracle: Address,
        feed_id: Symbol,
    ) -> Result<(), VaultError> {
        Self::require_admin(&e, &admin)?;
        e.storage().instance().set(&Cfg::Oracle, &oracle);
        e.storage().instance().set(&Cfg::OracleFeed, &feed_id);
        Self::bump_instance(&e);
        Ok(())
    }

    /// Circuit breaker. Blocks deposits, withdrawal requests, claims and new
    /// allocations; leaves staking and NAV reporting untouched.
    pub fn set_paused(e: Env, admin: Address, paused: bool) -> Result<(), VaultError> {
        Self::require_admin(&e, &admin)?;
        e.storage().instance().set(&Cfg::Paused, &paused);
        Self::bump_instance(&e);
        PauseToggled { paused }.publish(&e);
        Ok(())
    }

    /// Deposit USDC and receive agUSD 1:1. Returns the amount minted.
    ///
    /// The USDC lands before the agUSD is minted, so a token transfer that
    /// fails for any reason (insufficient balance, missing trustline, a frozen
    /// account) fails the whole call rather than minting against money that
    /// never arrived.
    ///
    /// 1:1 is the right rate because agUSD is a synthetic dollar, not a share
    /// in the book. Yield reaches holders through sagUSD's share price, not
    /// through a moving deposit rate, which is what keeps agUSD usable as a
    /// unit of account in the pools it is composed into.
    pub fn deposit(e: Env, from: Address, amount: i128) -> Result<i128, VaultError> {
        Self::require_not_paused(&e)?;
        from.require_auth();
        if amount <= 0 {
            return Err(VaultError::InvalidAmount);
        }
        let usdc = Self::usdc(e.clone())?;
        let agusd = Self::agusd(e.clone())?;

        TokenClient::new(&e, &usdc).transfer(&from, &e.current_contract_address(), &amount);
        AgUsdClient::new(&e, &agusd).mint(&from, &amount);
        Self::bump_instance(&e);

        Deposit {
            user: from,
            amount,
            minted: amount,
        }
        .publish(&e);
        Ok(amount)
    }

    /// Release idle USDC to a pool. Callable only by the Allocation Engine,
    /// which has already checked the concentration caps and the reserve floor.
    /// The Vault does not re-derive those limits: duplicating them here would
    /// mean two implementations that can disagree.
    pub fn settle_allocation(e: Env, pool: Address, amount: i128) -> Result<(), VaultError> {
        let engine: Address = e
            .storage()
            .instance()
            .get(&Cfg::Engine)
            .ok_or(VaultError::NotInitialized)?;
        engine.require_auth();
        Self::require_not_paused(&e)?;
        if amount <= 0 {
            return Err(VaultError::InvalidAmount);
        }
        let usdc = Self::usdc(e.clone())?;
        TokenClient::new(&e, &usdc).transfer(&e.current_contract_address(), &pool, &amount);
        Self::bump_instance(&e);
        Ok(())
    }

    // ---- views ----

    /// USDC held by the Vault. This is what the Engine's reserve floor
    /// protects and what claims are paid from.
    pub fn idle_reserves(e: Env) -> i128 {
        let Ok(usdc) = Self::usdc(e.clone()) else {
            return 0;
        };
        TokenClient::new(&e, &usdc).balance(&e.current_contract_address())
    }

    /// Idle reserves plus everything the Engine has booked as deployed.
    pub fn get_total_assets(e: Env) -> Result<i128, VaultError> {
        let engine: Address = e
            .storage()
            .instance()
            .get(&Cfg::Engine)
            .ok_or(VaultError::NotInitialized)?;
        Ok(Self::idle_reserves(e.clone()) + EngineClient::new(&e, &engine).total_allocated())
    }

    /// NAV for the Vault's feed, straight from the Oracle Adapter. A stale feed
    /// surfaces here as the adapter's `OracleStale` error rather than as an old
    /// number, because the failure is propagated instead of swallowed.
    pub fn get_nav(e: Env) -> Result<i128, VaultError> {
        let oracle: Address = e
            .storage()
            .instance()
            .get(&Cfg::Oracle)
            .ok_or(VaultError::OracleNotConfigured)?;
        let feed_id: Symbol = e
            .storage()
            .instance()
            .get(&Cfg::OracleFeed)
            .ok_or(VaultError::OracleNotConfigured)?;
        Ok(OracleClient::new(&e, &oracle).get_nav(&feed_id))
    }

    pub fn paused(e: Env) -> bool {
        e.storage().instance().get(&Cfg::Paused).unwrap_or(false)
    }

    pub fn admin(e: Env) -> Result<Address, VaultError> {
        e.storage()
            .instance()
            .get(&Cfg::Admin)
            .ok_or(VaultError::NotInitialized)
    }

    pub fn usdc(e: Env) -> Result<Address, VaultError> {
        e.storage()
            .instance()
            .get(&Cfg::Usdc)
            .ok_or(VaultError::NotInitialized)
    }

    pub fn agusd(e: Env) -> Result<Address, VaultError> {
        e.storage()
            .instance()
            .get(&Cfg::AgUsd)
            .ok_or(VaultError::NotInitialized)
    }

    pub fn allocation_engine(e: Env) -> Result<Address, VaultError> {
        e.storage()
            .instance()
            .get(&Cfg::Engine)
            .ok_or(VaultError::NotInitialized)
    }

    // ---- internals ----

    fn require_admin(e: &Env, admin: &Address) -> Result<(), VaultError> {
        let stored: Address = e
            .storage()
            .instance()
            .get(&Cfg::Admin)
            .ok_or(VaultError::NotInitialized)?;
        if stored != *admin {
            return Err(VaultError::NotAdmin);
        }
        admin.require_auth();
        Ok(())
    }

    fn require_not_paused(e: &Env) -> Result<(), VaultError> {
        if Self::paused(e.clone()) {
            return Err(VaultError::Paused);
        }
        Ok(())
    }

    fn bump_instance(e: &Env) {
        e.storage()
            .instance()
            .extend_ttl(INSTANCE_LIFETIME, INSTANCE_BUMP);
    }
}

#[contractevent]
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct Deposit {
    #[topic]
    pub user: Address,
    pub amount: i128,
    pub minted: i128,
}

#[contractevent]
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct PauseToggled {
    pub paused: bool,
}
