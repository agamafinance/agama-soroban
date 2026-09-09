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
//!
//! The constructor runs the same check. `initialize` was a separate call that
//! took both addresses on trust, so the one call that created the wiring
//! validated nothing while the call that repairs it validated everything, and
//! the gap between the deploy and the wiring was a public window in which
//! somebody else's `initialize` could land first. A constructor closes both:
//! there is no window, and an adapter cannot come into existence pointed at a
//! pair that does not match.
//!
//! # Getting stranded capital home
//!
//! `deallocate` is capped at booked exposure, which is right for a repayment
//! and useless for everything else that can leave USDC sitting here. A position
//! written down to zero leaves the cash with no exposure to return against.
//! Interest paid above principal is surplus the book never expected. In both
//! cases the money was stuck, and because `require_empty` refuses to repoint an
//! adapter holding USDC, one stroop of it also closed the only repair path this
//! contract has. That is not a hypothetical: three generations of this adapter
//! were retired for exactly it, and the deployment record says so each time.
//!
//! `recover_surplus` is the way out, and it is shaped so that it cannot be a
//! way to take anything. The destination is the Vault this adapter already
//! stores, never an address the caller supplies, so there is no parameter for an
//! admin to point somewhere else. The amount is not a parameter either: it is
//! whatever the balance holds above booked exposure, so a live position cannot
//! be swept out from under `deallocate`. Either the Engine or the admin may
//! call it. The Engine is the ordinary path, because the Engine passes the
//! recovery on to the Vault and the three books stay in step; the admin is the
//! path that still works when the Engine an adapter is stuck to has itself been
//! superseded, which is the state that caused the retirements.

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
    /// Retired with `initialize`, which a `__constructor` replaced. The host
    /// runs a constructor exactly once, inside the deploy, so there is no
    /// second call for this to be the answer to. The number is kept rather than
    /// reused so that an old error code never means something new.
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
    /// Writing down more than the adapter has booked as deployed.
    WriteDownExceedsExposure = 607,
    /// `accept_admin` was called with no handover in flight.
    NoPendingAdmin = 608,
    /// `accept_admin` was called by an address that was not the one proposed.
    NotPendingAdmin = 609,
    /// `recover_surplus` was called by an address that is neither this
    /// adapter's Engine nor its admin.
    NotAuthorized = 610,
    /// The adapter holds nothing above its booked exposure, so there is nothing
    /// to send home.
    NothingToRecover = 611,
}

#[derive(Clone)]
#[contracttype]
enum Cfg {
    Admin,
    Engine,
    Vault,
    Usdc,
    Exposure,
    /// Half finished admin handover: proposed, not yet accepted.
    PendingAdmin,
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

/// Emitted when exposure is written off. It is the only way this adapter's book
/// falls with no capital moving, so an observer should never have to infer it
/// from the absence of a transfer.
#[contractevent]
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct WrittenDown {
    pub amount: i128,
    /// Exposure still booked after the write-down.
    pub exposure: i128,
}

/// Emitted when USDC held above the booked exposure is sent home. It is the
/// only way capital leaves this adapter without the exposure moving, so it
/// belongs in the stream, and it carries the destination so that an observer can
/// see it was the stored Vault rather than take it on trust.
#[contractevent]
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct SurplusRecovered {
    #[topic]
    pub vault: Address,
    pub amount: i128,
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
pub struct PrivateCreditAdapter;

#[contractimpl]
impl PrivateCreditAdapter {
    /// Wire the adapter to the Engine that may move its capital and the Vault
    /// it repays, in the transaction that deploys it.
    ///
    /// The pair is checked here exactly as `set_counterparties` checks it: the
    /// Engine has to answer that it governs the Vault. `initialize` took both
    /// on trust and could be front-run besides, which made the call that
    /// created the wiring the only one that validated none of it.
    pub fn __constructor(
        e: Env,
        admin: Address,
        engine: Address,
        vault: Address,
        usdc: Address,
    ) -> Result<(), AdapterError> {
        admin.require_auth();
        Self::require_symmetry(&e, &engine, &vault)?;
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
        Self::require_symmetry(&e, &engine, &vault)?;
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

    /// Write off booked exposure that is not coming back, without moving any
    /// capital.
    ///
    /// `deallocate` transfers the USDC before it decrements the book, which is
    /// the right order when there is USDC to transfer and no help at all when
    /// there is not: a defaulted originator leaves this adapter holding
    /// nothing, the transfer panics, and the exposure goes on reporting full
    /// face value forever. This is the entry point that lets the loss be
    /// recognised instead.
    ///
    /// Called by the Engine, in the same transaction as the Engine's own
    /// write-down and the Vault's, so the three books cannot disagree about how
    /// much of this position still exists. The Engine requires its admin for
    /// it, and so does the Vault; there is no path from here to reducing an
    /// exposure on the adapter alone.
    pub fn write_down(e: Env, amount: i128) -> Result<(), AdapterError> {
        Self::require_engine(&e)?;
        if amount <= 0 {
            return Err(AdapterError::InvalidAmount);
        }
        let exposure = Self::get_exposure(e.clone());
        if amount > exposure {
            return Err(AdapterError::WriteDownExceedsExposure);
        }
        e.storage()
            .instance()
            .set(&Cfg::Exposure, &(exposure - amount));
        Self::bump(&e);
        WrittenDown {
            amount,
            exposure: exposure - amount,
        }
        .publish(&e);
        Ok(())
    }

    /// Send everything the adapter holds above its booked exposure to the Vault
    /// it names, and return how much that was.
    ///
    /// This is the way home for capital `deallocate` cannot move: a recovery on
    /// a position that was written down to zero, and interest paid above
    /// principal. Both used to stay here forever, and because
    /// `set_counterparties` refuses an adapter with a non-zero balance, both
    /// also bricked the adapter's only repair path. It cost three redeployments
    /// of this contract before it was worth fixing.
    ///
    /// It cannot be used to take anything, and the reason is structural rather
    /// than a permission check. There is no destination parameter: the USDC goes
    /// to the Vault this adapter already stores, which `register_pool` and
    /// `set_counterparties` have both checked is the Vault its Engine governs.
    /// There is no amount parameter either: it is the balance less the booked
    /// exposure, so capital backing a live position is never swept and
    /// `deallocate` stays funded for exactly what it owes.
    ///
    /// Either the Engine or the admin may call it. The Engine is the ordinary
    /// path, and the only one that keeps the books in step, because the Engine
    /// passes the amount to the Vault, which verifies the arrival and releases
    /// the loss against it. The admin path exists because the failure this fixes
    /// is an adapter stuck to counterparties that have been superseded, and
    /// requiring a working Engine to unstick it would be requiring the thing
    /// that is broken. Taken that way the cash still reaches the Vault; what it
    /// does not do is update anybody's book, which is the conservative
    /// direction and is why it is the fallback rather than the path.
    pub fn recover_surplus(e: Env, caller: Address) -> Result<i128, AdapterError> {
        let engine: Address = e
            .storage()
            .instance()
            .get(&Cfg::Engine)
            .ok_or(AdapterError::NotInitialized)?;
        let admin: Address = e
            .storage()
            .instance()
            .get(&Cfg::Admin)
            .ok_or(AdapterError::NotInitialized)?;
        if caller != engine && caller != admin {
            return Err(AdapterError::NotAuthorized);
        }
        caller.require_auth();

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
        let token = TokenClient::new(&e, &usdc);
        let surplus =
            token.balance(&e.current_contract_address()) - Self::get_exposure(e.clone());
        if surplus <= 0 {
            return Err(AdapterError::NothingToRecover);
        }
        token.transfer(&e.current_contract_address(), &vault, &surplus);
        Self::bump(&e);
        SurplusRecovered {
            vault,
            amount: surplus,
        }
        .publish(&e);
        Ok(surplus)
    }

    /// Capital currently deployed into this pool, in USDC.
    pub fn get_exposure(e: Env) -> i128 {
        e.storage().instance().get(&Cfg::Exposure).unwrap_or(0)
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
    pub fn propose_admin(e: Env, admin: Address, new_admin: Address) -> Result<(), AdapterError> {
        Self::require_admin(&e, &admin)?;
        e.storage().instance().set(&Cfg::PendingAdmin, &new_admin);
        Self::bump(&e);
        AdminProposed { new_admin }.publish(&e);
        Ok(())
    }

    /// Complete a handover. Only the proposed address can call it, and it has
    /// to authorize the call itself: that authorization is the entire point of
    /// the second step.
    pub fn accept_admin(e: Env, new_admin: Address) -> Result<(), AdapterError> {
        let pending: Address = e
            .storage()
            .instance()
            .get(&Cfg::PendingAdmin)
            .ok_or(AdapterError::NoPendingAdmin)?;
        if pending != new_admin {
            return Err(AdapterError::NotPendingAdmin);
        }
        new_admin.require_auth();
        e.storage().instance().set(&Cfg::Admin, &new_admin);
        e.storage().instance().remove(&Cfg::PendingAdmin);
        Self::bump(&e);
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

    /// The Engine offered has to answer that it governs the Vault offered.
    ///
    /// What this rules out is an address that cannot answer the question, or
    /// answers it with a different Vault: a plain account, and a real Engine
    /// that governs somebody else. What it cannot rule out is a contract built
    /// to answer it, which returns whatever address it was written to return and
    /// passes without difficulty. The check is worth running because the
    /// realistic failure here is a mis-wiring rather than an attack, and both
    /// callers are admin gated either way; it is not worth reading as proof that
    /// the counterparty is what it says it is.
    fn require_symmetry(e: &Env, engine: &Address, vault: &Address) -> Result<(), AdapterError> {
        match EngineClient::new(e, engine).try_vault() {
            Ok(Ok(governed)) if governed == *vault => Ok(()),
            _ => Err(AdapterError::CounterpartyMismatch),
        }
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
