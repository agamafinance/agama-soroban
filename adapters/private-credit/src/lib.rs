#![no_std]
//! Private credit adapter.
//!
//! Wraps an off-chain credit originator behind the same three calls every pool
//! type exposes to the Allocation Engine, so the Engine never has to know that
//! this one settles in weeks while an Etherfuse position settles in a block:
//!
//! ```text
//! allocate(amount)      deploy capital into the pool
//! deallocate(amount)    return capital to the Vault
//! get_exposure()        capital currently deployed
//! ```
//!
//! The adapter is the on-chain escrow for the position. `allocate` is called by
//! the Engine after the Vault has released the USDC to this contract, and books
//! the exposure; the originator draws it down off-chain against the facility.
//! Repayments come back to this address, and `deallocate` books them against
//! the exposure and moves the USDC to the Vault in the same call, so the
//! exposure the Engine reads and the cash the Vault holds cannot drift apart.
//!
//! Settlement is D+15 to D+90 depending on the instrument, which is why NAV for
//! this pool comes from the Oracle Adapter's private credit reporter (7 day
//! staleness) rather than from a price feed: between two reports there is
//! genuinely nothing new to say about the book.
//!
//! Only the Engine can move capital. There is no admin path that allocates or
//! deallocates behind the Engine's back, because that path would bypass every
//! concentration cap and the reserve floor.
//!
//! # Which Engine, and which Vault
//!
//! Both addresses used to be written by `initialize` and never again, and the
//! deployed generation of this adapter is stuck to an Engine and a Vault that
//! have since been superseded. An adapter is the cheapest contract in the
//! stack and it still had to be redeployed, purely because two addresses could
//! not be rewritten.
//!
//! `set_counterparties` moves both at once, admin gated, refused unless the
//! adapter is holding nothing (no booked exposure and no USDC on the balance),
//! and refused unless the Engine offered says it governs the Vault offered.
//! Every one of those conditions is load bearing. Exposure recorded here was
//! authorized by the current Engine against the caps it enforces, so moving
//! the Engine mid-position orphans a book only the old Engine can unwind. And
//! `deallocate` sends capital to the stored Vault address, so moving it
//! while the adapter holds USDC, whether booked or arrived unannounced from an
//! originator's repayment, redirects money that belongs to the old Vault.
//! Being empty today says nothing about tomorrow, which is why the symmetry
//! check is there as well: it is what stops an adapter being pointed at a Vault
//! its Engine does not serve, and repaying capital to an address of the admin's
//! choosing one allocation later.

use soroban_sdk::{
    contract, contractclient, contracterror, contractevent, contractimpl, contracttype,
    symbol_short, token::TokenClient, Address, Env, Symbol,
};

/// The Allocation Engine, as seen from the adapter. Only `set_counterparties`
/// calls it, to check that an Engine it is about to answer to governs the Vault
/// it is about to repay.
#[contractclient(name = "EngineClient")]
pub trait AllocationEngineInterface {
    fn vault(e: Env) -> Address;
}

const DAY_LEDGERS: u32 = 17_280;
const INSTANCE_BUMP: u32 = 30 * DAY_LEDGERS;
const INSTANCE_LIFETIME: u32 = INSTANCE_BUMP - DAY_LEDGERS;

/// Identifies the pool type to anything reading the adapter generically.
pub const POOL_KIND: Symbol = symbol_short!("PRIVCRED");
/// Oracle Adapter feed this pool is valued from.
pub const ORACLE_FEED: Symbol = symbol_short!("PC_NAV");
/// Settlement window, in days, advertised to the Engine and the UI.
pub const MIN_SETTLEMENT_DAYS: u32 = 15;
pub const MAX_SETTLEMENT_DAYS: u32 = 90;

#[contracterror]
#[derive(Copy, Clone, Debug, Eq, PartialEq)]
#[repr(u32)]
pub enum AdapterError {
    AlreadyInitialized = 600,
    NotInitialized = 601,
    InvalidAmount = 602,
    /// Deallocating more than is currently deployed.
    ExposureUnderflow = 603,
    NotAdmin = 604,
    /// The Engine and Vault pointers cannot move while the adapter holds
    /// booked exposure or USDC.
    NotEmpty = 605,
    /// The proposed Engine does not answer that it governs the proposed Vault.
    CounterpartyMismatch = 606,
}

#[derive(Clone)]
#[contracttype]
enum Cfg {
    Admin,
    Engine,
    Vault,
    Usdc,
    Exposure,
}

/// Emitted when the adapter is repointed. Which Engine may move this pool's
/// capital and which Vault it is repaid to are the only two things the adapter
/// decides, so a change to either belongs in the event stream.
#[contractevent]
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct CounterpartiesSet {
    #[topic]
    pub engine: Address,
    #[topic]
    pub vault: Address,
}

#[contract]
pub struct PrivateCreditAdapter;

#[contractimpl]
impl PrivateCreditAdapter {
    pub fn initialize(
        e: Env,
        admin: Address,
        engine: Address,
        vault: Address,
        usdc: Address,
    ) -> Result<(), AdapterError> {
        if e.storage().instance().has(&Cfg::Engine) {
            return Err(AdapterError::AlreadyInitialized);
        }
        admin.require_auth();
        e.storage().instance().set(&Cfg::Admin, &admin);
        e.storage().instance().set(&Cfg::Engine, &engine);
        e.storage().instance().set(&Cfg::Vault, &vault);
        e.storage().instance().set(&Cfg::Usdc, &usdc);
        e.storage().instance().set(&Cfg::Exposure, &0i128);
        Self::bump(&e);
        Ok(())
    }

    /// Point the adapter at a replacement Engine and Vault, together.
    ///
    /// One call, not two, because the two addresses are only meaningful as a
    /// pair: the Engine says what may be allocated here and the Vault says
    /// where `deallocate` sends it back to, and an adapter halfway between two
    /// generations is a contract that takes capital on one authority and
    /// returns it to another. So the Engine has to name the Vault, and both
    /// move in the same transaction or neither does.
    ///
    /// The symmetry check is the one that matters. Repointing the Vault while
    /// the adapter is empty looks harmless and is not: exposure booked
    /// afterwards would be repaid to whatever address was written here, with
    /// the Engine's book decrementing all the same, so the cash and the book
    /// would part company one repayment later and nothing would revert. An
    /// adapter that only accepts a Vault its own Engine governs cannot be aimed
    /// somewhere else.
    pub fn set_counterparties(
        e: Env,
        admin: Address,
        engine: Address,
        vault: Address,
    ) -> Result<(), AdapterError> {
        Self::require_admin(&e, &admin)?;
        Self::require_empty(&e)?;
        // An address that cannot answer is refused with one that answers
        // wrongly: neither is an Allocation Engine that governs this Vault.
        match EngineClient::new(&e, &engine).try_vault() {
            Ok(Ok(governed)) if governed == vault => {}
            _ => return Err(AdapterError::CounterpartyMismatch),
        }
        e.storage().instance().set(&Cfg::Engine, &engine);
        e.storage().instance().set(&Cfg::Vault, &vault);
        Self::bump(&e);
        CounterpartiesSet { engine, vault }.publish(&e);
        Ok(())
    }

    /// Book capital released by the Vault into this pool. Called by the Engine,
    /// which has already checked it against the concentration caps and the
    /// reserve floor.
    pub fn allocate(e: Env, amount: i128) -> Result<(), AdapterError> {
        Self::require_engine(&e)?;
        if amount <= 0 {
            return Err(AdapterError::InvalidAmount);
        }
        let exposure = Self::get_exposure(e.clone()) + amount;
        e.storage().instance().set(&Cfg::Exposure, &exposure);
        Self::bump(&e);
        Ok(())
    }

    /// Return repaid capital to the Vault and reduce the exposure by the same
    /// amount, in one call, so the two can never disagree.
    pub fn deallocate(e: Env, amount: i128) -> Result<(), AdapterError> {
        Self::require_engine(&e)?;
        if amount <= 0 {
            return Err(AdapterError::InvalidAmount);
        }
        let exposure = Self::get_exposure(e.clone());
        if amount > exposure {
            return Err(AdapterError::ExposureUnderflow);
        }
        let usdc: Address = e
            .storage()
            .instance()
            .get(&Cfg::Usdc)
            .ok_or(AdapterError::NotInitialized)?;
        let vault: Address = e
            .storage()
            .instance()
            .get(&Cfg::Vault)
            .ok_or(AdapterError::NotInitialized)?;
        TokenClient::new(&e, &usdc).transfer(&e.current_contract_address(), &vault, &amount);
        e.storage().instance().set(&Cfg::Exposure, &(exposure - amount));
        Self::bump(&e);
        Ok(())
    }

    /// Capital currently deployed into this pool, in USDC.
    pub fn get_exposure(e: Env) -> i128 {
        e.storage().instance().get(&Cfg::Exposure).unwrap_or(0)
    }

    // ---- metadata, read by the Engine and the UI ----

    pub fn pool_kind(_e: Env) -> Symbol {
        POOL_KIND
    }

    pub fn oracle_feed(_e: Env) -> Symbol {
        ORACLE_FEED
    }

    /// Settlement window in days, as `(min, max)`. Nothing on-chain enforces
    /// it; it is published so the Engine's operators and the withdrawal queue
    /// can be sized against the real cash conversion time of the book.
    pub fn settlement_window(_e: Env) -> (u32, u32) {
        (MIN_SETTLEMENT_DAYS, MAX_SETTLEMENT_DAYS)
    }

    pub fn engine(e: Env) -> Result<Address, AdapterError> {
        e.storage()
            .instance()
            .get(&Cfg::Engine)
            .ok_or(AdapterError::NotInitialized)
    }

    pub fn vault(e: Env) -> Result<Address, AdapterError> {
        e.storage()
            .instance()
            .get(&Cfg::Vault)
            .ok_or(AdapterError::NotInitialized)
    }

    pub fn admin(e: Env) -> Result<Address, AdapterError> {
        e.storage()
            .instance()
            .get(&Cfg::Admin)
            .ok_or(AdapterError::NotInitialized)
    }

    // ---- internals ----

    fn require_admin(e: &Env, admin: &Address) -> Result<(), AdapterError> {
        let stored: Address = e
            .storage()
            .instance()
            .get(&Cfg::Admin)
            .ok_or(AdapterError::NotInitialized)?;
        if stored != *admin {
            return Err(AdapterError::NotAdmin);
        }
        admin.require_auth();
        Ok(())
    }

    /// Neither pointer moves while the adapter is holding anything. Exposure
    /// booked here was authorized by the current Engine, and USDC sitting here
    /// is owed to the current Vault, so an empty adapter is the only state in
    /// which repointing strands nothing. The balance is checked as well as the
    /// book because a repayment can arrive before it is recorded.
    fn require_empty(e: &Env) -> Result<(), AdapterError> {
        if Self::get_exposure(e.clone()) != 0 {
            return Err(AdapterError::NotEmpty);
        }
        let usdc: Address = e
            .storage()
            .instance()
            .get(&Cfg::Usdc)
            .ok_or(AdapterError::NotInitialized)?;
        if TokenClient::new(e, &usdc).balance(&e.current_contract_address()) != 0 {
            return Err(AdapterError::NotEmpty);
        }
        Ok(())
    }

    fn require_engine(e: &Env) -> Result<(), AdapterError> {
        let engine: Address = e
            .storage()
            .instance()
            .get(&Cfg::Engine)
            .ok_or(AdapterError::NotInitialized)?;
        engine.require_auth();
        Ok(())
    }

    fn bump(e: &Env) {
        e.storage()
            .instance()
            .extend_ttl(INSTANCE_LIFETIME, INSTANCE_BUMP);
    }
}

mod test;
