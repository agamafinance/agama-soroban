#![no_std]
//! Etherfuse Stablebond adapter.
//!
//! Exposes the same three calls as every other pool type, so the Allocation
//! Engine can route to a tokenized government bond and to an off-chain credit
//! facility through identical code:
//!
//! ```text
//! allocate(amount)      deploy capital into the pool
//! deallocate(amount)    return capital to the Vault
//! get_exposure()        capital currently deployed
//! ```
//!
//! What differs from the private credit adapter is not the interface, it is the
//! settlement and the valuation. Stablebond positions are on-chain and redeem
//! in a block, so `deallocate` returns the USDC to the Vault immediately rather
//! than waiting on an originator. Pricing is deterministic and comes from the
//! Etherfuse feed, registered in the Oracle Adapter with a 48 hour staleness
//! window and no deviation bound: a bond revaluation is not an anomaly to be
//! bounded, it is the instrument doing what it is supposed to do.
//!
//! That difference is why this adapter is the low-risk leg of the book, and why
//! the Engine can size it against a short withdrawal queue while sizing private
//! credit against a long one.
//!
//! Only the Engine can move capital: an admin path here would bypass the
//! concentration caps and the reserve floor the Engine exists to enforce.
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
//! while the adapter holds USDC redirects money that belongs to the old Vault.
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
pub const POOL_KIND: Symbol = symbol_short!("ETHERFUS");
/// Oracle Adapter feed this pool is valued from.
pub const ORACLE_FEED: Symbol = symbol_short!("EF_BOND");
/// Stablebond redemptions are on-chain, so capital comes back in the same call.
pub const SETTLEMENT_DAYS: u32 = 0;

#[contracterror]
#[derive(Copy, Clone, Debug, Eq, PartialEq)]
#[repr(u32)]
pub enum AdapterError {
    AlreadyInitialized = 700,
    NotInitialized = 701,
    InvalidAmount = 702,
    /// Deallocating more than is currently deployed.
    ExposureUnderflow = 703,
    NotAdmin = 704,
    /// The Engine and Vault pointers cannot move while the adapter holds
    /// booked exposure or USDC.
    NotEmpty = 705,
    /// The proposed Engine does not answer that it governs the proposed Vault.
    CounterpartyMismatch = 706,
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
pub struct EtherfuseAdapter;

#[contractimpl]
impl EtherfuseAdapter {
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

    /// Book capital released by the Vault into Stablebond exposure. Called by
    /// the Engine, which has already checked it against the concentration caps
    /// and the reserve floor.
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

    /// Redeem and return capital to the Vault, reducing the exposure by the
    /// same amount in the same call so the two cannot disagree.
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
        e.storage()
            .instance()
            .set(&Cfg::Exposure, &(exposure - amount));
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

    /// Days from `deallocate` to cash in the Vault. Zero: on-chain redemption.
    pub fn settlement_days(_e: Env) -> u32 {
        SETTLEMENT_DAYS
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
