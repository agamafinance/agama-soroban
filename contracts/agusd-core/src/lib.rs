#![no_std]
//! agUSD, the synthetic dollar the Vault mints against a deposit (SEP-41).
//!
//! # Why this contract exists next to `contracts/agusd`
//!
//! The first agUSD is not a plain token, it is a self contained vault. It
//! takes the USDC in, mints against it, keeps a liquidity buffer for instant
//! redemptions and pushes the excess into the credit vaults inside the same
//! deposit call. Custody, routing and issuance all live in one contract, which
//! is why it has no `mint`: nothing outside it was ever meant to create
//! supply.
//!
//! The second generation splits those three jobs apart. The Vault holds the
//! cash and owns the withdrawal queue, the Allocation Engine decides where
//! capital goes and enforces the concentration caps and the reserve floor, and
//! issuance is what is left over: a token that does nothing except keep
//! balances and let exactly one address create them. That address is the
//! Vault, so "one agUSD in circulation means one USDC was deposited into the
//! Vault" is enforced by this contract rather than promised by a document.
//!
//! The first agUSD is deployed, it has holders, and its behaviour is described
//! in public, so it is left exactly as it is rather than rewritten underneath
//! the people holding it. It also remains the token the deployed sagUSD
//! staking contract accepts, since that contract stores its address at
//! initialization. This is the token the Vault mints.
//!
//! # The minter freezes at the first mint
//!
//! `minter` is written by `initialize` and can be moved by `set_minter` until
//! the first agUSD is created. After that it is fixed for good: there is no
//! setter that still works, no admin mint and no pause that would let anyone
//! else create supply.
//!
//! The earlier version of this contract had no setter at all, on the argument
//! that an admin able to rotate the minter could point it at itself and print,
//! which is an admin mint with one extra step. The argument is right about a
//! token with a book. It is wrong about a token with no supply, where there is
//! nothing to print against and nobody to dilute, and paying for it turned out
//! to be expensive: the Vault named here was itself wired to an Allocation
//! Engine it could not use, and because issuance could not follow the Vault to
//! its replacement, a one line fix in one contract became two new contracts
//! and a token migration.
//!
//! So the guard is the mint counter rather than the calendar. Before the first
//! mint the minter is configuration. From the first mint onwards it is a
//! promise to the holders, and an auditor can check that the promise holds by
//! reading one number: any token with supply has a minter that has not moved
//! since the supply started existing.
//!
//! Be precise about what that does and does not rule out. It does not stop an
//! admin naming itself minter and printing: the two conditions are sequential,
//! so at a zero supply an admin can call `set_minter(admin)` and then `mint`,
//! and would then be frozen in as minter for the life of the contract. What it
//! rules out is doing that to a token that anybody is holding, and doing it
//! quietly. Every rotation emits `MinterSet`, so a pre-mint rotation is a
//! ledger event and not a silent state change, and which token is the
//! protocol's agUSD is decided by the Vault that names it and by the deployment
//! record, both of which are public. A token whose minter is not the Vault is
//! simply not this protocol's agUSD, and an admin who wanted one could always
//! have deployed it.
//!
//! The `admin` recorded by `initialize` is deliberately powerless over supply
//! once supply exists. It is stored so the deployment is attributable on-chain,
//! so future non-supply governance has an anchor, and so the minter can be
//! corrected before the token is used; every function that creates supply
//! checks the minter and never the admin.
//!
//! # Burning stays on the SEP-41 semantics
//!
//! `burn` and `burn_from` are the standard ones, authorized by the holder,
//! because that is what the Vault relies on: `request_withdrawal` calls
//! `burn(from, amount)` with the holder's authorization already carried by the
//! enclosing invocation. Restricting the burn path to the minter would buy
//! nothing (destroying your own balance harms nobody but you) and would break
//! any SEP-41 consumer that expects a holder to be able to retire tokens.
//! Supply can therefore only go up through the Vault, and down through the
//! holder.

use soroban_sdk::contracterror;
use soroban_sdk::{contract, contractevent, contractimpl, contracttype, Address, Env, String};
use token as tok;

#[contracterror]
#[derive(Copy, Clone, Debug, Eq, PartialEq)]
#[repr(u32)]
pub enum AgUsdCoreError {
    /// Retired with `initialize`, which a `__constructor` replaced. The host
    /// runs a constructor exactly once, inside the deploy, so there is no
    /// second call for this to be the answer to. The number is kept rather than
    /// reused so that an old error code never means something new.
    AlreadyInitialized = 200,
    NotInitialized = 201,
    /// Someone other than the Vault tried to mint.
    NotMinter = 202,
    /// Zero or negative mint amount.
    InvalidAmount = 203,
    NotAdmin = 204,
    /// The token has already minted, so the minter is fixed for good.
    MinterFrozen = 205,
    /// `accept_admin` was called with no handover in flight.
    NoPendingAdmin = 206,
    /// `accept_admin` was called by an address that was not the one proposed.
    NotPendingAdmin = 207,
}

/// Instance storage. `Admin` is written once. `Minter` can be corrected until
/// `Mints` leaves zero, and never after.
#[derive(Clone)]
#[contracttype]
enum Cfg {
    Admin,
    Minter,
    Mints,
    /// Half finished admin handover: proposed, not yet accepted.
    PendingAdmin,
}

/// Emitted when the minting authority is corrected, which can only happen
/// before the token has minted anything. It is the single most consequential
/// thing that can be said about this contract, so it is never a silent state
/// change: a rotation is in the event stream whether anybody was watching the
/// storage or not.
#[contractevent]
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct MinterSet {
    #[topic]
    pub minter: Address,
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
pub struct AgUsdCore;

#[contractimpl]
impl AgUsdCore {
    /// Record the admin and the minting authority, and set the SEP-41 metadata, in the transaction that deploys it.
    ///
    /// This was `initialize`, a separate call, and being separate was the
    /// problem. A contract sitting deployed and uninitialized is a contract
    /// whose admin, and whose minter, is whoever sends the next transaction, and the deployer's
    /// own call is public before it is mined, so it can be front-run by an
    /// identical one naming somebody else. On this contract that is the authority to create supply, so the window was worth closing on its own terms and not only for consistency. A constructor runs inside
    /// the deploy, so there is no window to race, and the host runs it exactly
    /// once, which is what used to need a re-initialization guard.
    pub fn __constructor(
        e: Env,
        admin: Address,
        minter: Address,
        decimal: u32,
        name: String,
        symbol: String,
    ) -> Result<(), AgUsdCoreError> {
        admin.require_auth();
        e.storage().instance().set(&Cfg::Admin, &admin);
        e.storage().instance().set(&Cfg::Minter, &minter);
        tok::set_metadata(&e, decimal, name, symbol);
        tok::bump_instance(&e);
        Ok(())
    }

    /// Create `amount` agUSD for `to`. The Vault, and nothing else, may call
    /// this.
    ///
    /// The authorization is the stored minter's, not the caller's address as
    /// passed in an argument, so there is no version of this call that a
    /// caller can talk their way into. Zero is rejected along with negatives:
    /// a mint of nothing is either a bug upstream or an attempt to write a
    /// mint event that moved no money, and neither is worth recording.
    ///
    /// The supply event comes from the shared token module, the same `mint`
    /// event every other Agama token publishes, so an indexer needs no special
    /// case for this contract.
    pub fn mint(e: Env, to: Address, amount: i128) -> Result<(), AgUsdCoreError> {
        let minter = Self::minter(e.clone())?;
        minter.require_auth();
        if amount <= 0 {
            return Err(AgUsdCoreError::InvalidAmount);
        }
        tok::mint(&e, &to, amount);
        e.storage()
            .instance()
            .set(&Cfg::Mints, &(Self::mints(e.clone()) + 1));
        Ok(())
    }

    /// Correct the minting authority, before the token has minted anything.
    ///
    /// This is a deployment repair tool, not governance. The Vault a token is
    /// bound to is chosen before either contract has done anything, and if the
    /// Vault turns out to be unusable, as the one this token was first pointed
    /// at was, the alternative to this call is deploying a second token and
    /// migrating whatever the first one issued. That is a large price for a
    /// mistake that costs nothing to fix while the supply is zero.
    ///
    /// It stops working at the first mint, permanently, and that is what keeps
    /// the security property intact: agUSD in circulation was created by the
    /// minter recorded here, and that minter has not changed since the first
    /// unit existed.
    ///
    /// It does not stop an admin naming itself minter and printing, because
    /// the two conditions are sequential and both are satisfiable at a zero
    /// supply. What it stops is doing that to a token anybody holds, and doing
    /// it without a trace: the rotation emits `MinterSet`, and a token whose
    /// `minter()` is not the Vault named in the deployment record is not this
    /// protocol's agUSD in the first place.
    pub fn set_minter(e: Env, admin: Address, minter: Address) -> Result<(), AgUsdCoreError> {
        let stored: Address = e
            .storage()
            .instance()
            .get(&Cfg::Admin)
            .ok_or(AgUsdCoreError::NotInitialized)?;
        if stored != admin {
            return Err(AgUsdCoreError::NotAdmin);
        }
        admin.require_auth();
        if Self::mints(e.clone()) > 0 {
            return Err(AgUsdCoreError::MinterFrozen);
        }
        e.storage().instance().set(&Cfg::Minter, &minter);
        tok::bump_instance(&e);
        MinterSet { minter }.publish(&e);
        Ok(())
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
    pub fn propose_admin(e: Env, admin: Address, new_admin: Address) -> Result<(), AgUsdCoreError> {
        let stored: Address = e
            .storage()
            .instance()
            .get(&Cfg::Admin)
            .ok_or(AgUsdCoreError::NotInitialized)?;
        if stored != admin {
            return Err(AgUsdCoreError::NotAdmin);
        }
        admin.require_auth();
        e.storage().instance().set(&Cfg::PendingAdmin, &new_admin);
        tok::bump_instance(&e);
        AdminProposed { new_admin }.publish(&e);
        Ok(())
    }

    /// Complete a handover. Only the proposed address can call it, and it has
    /// to authorize the call itself: that authorization is the entire point of
    /// the second step.
    pub fn accept_admin(e: Env, new_admin: Address) -> Result<(), AgUsdCoreError> {
        let pending: Address = e
            .storage()
            .instance()
            .get(&Cfg::PendingAdmin)
            .ok_or(AgUsdCoreError::NoPendingAdmin)?;
        if pending != new_admin {
            return Err(AgUsdCoreError::NotPendingAdmin);
        }
        new_admin.require_auth();
        e.storage().instance().set(&Cfg::Admin, &new_admin);
        e.storage().instance().remove(&Cfg::PendingAdmin);
        tok::bump_instance(&e);
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

    /// The only address that can create supply. Frozen at the first mint.
    pub fn minter(e: Env) -> Result<Address, AgUsdCoreError> {
        e.storage()
            .instance()
            .get(&Cfg::Minter)
            .ok_or(AgUsdCoreError::NotInitialized)
    }

    /// Mints since deployment. Zero means the minter can still be corrected;
    /// anything else means it is fixed for the life of the contract. Counted
    /// rather than read off the supply, because burning back to zero is not
    /// the same thing as never having issued.
    pub fn mints(e: Env) -> u64 {
        e.storage().instance().get(&Cfg::Mints).unwrap_or(0)
    }

    /// Recorded at initialization and powerless over supply. Kept so the
    /// deployment is attributable and so later non-supply governance has an
    /// anchor.
    pub fn admin(e: Env) -> Result<Address, AgUsdCoreError> {
        e.storage()
            .instance()
            .get(&Cfg::Admin)
            .ok_or(AgUsdCoreError::NotInitialized)
    }

    // ---- SEP-41 ----
    pub fn balance(e: Env, id: Address) -> i128 {
        tok::balance(&e, &id)
    }
    pub fn transfer(e: Env, from: Address, to: Address, amount: i128) {
        tok::transfer(&e, from, to, amount)
    }
    pub fn transfer_from(e: Env, spender: Address, from: Address, to: Address, amount: i128) {
        tok::transfer_from(&e, spender, from, to, amount)
    }
    pub fn approve(e: Env, from: Address, spender: Address, amount: i128, expiration_ledger: u32) {
        tok::approve(&e, from, spender, amount, expiration_ledger)
    }
    pub fn allowance(e: Env, from: Address, spender: Address) -> i128 {
        tok::allowance(&e, &from, &spender)
    }
    pub fn burn(e: Env, from: Address, amount: i128) {
        tok::burn(&e, from, amount)
    }
    pub fn burn_from(e: Env, spender: Address, from: Address, amount: i128) {
        tok::burn_from(&e, spender, from, amount)
    }
    pub fn decimals(e: Env) -> u32 {
        tok::decimals(&e)
    }
    pub fn name(e: Env) -> String {
        tok::name(&e)
    }
    pub fn symbol(e: Env) -> String {
        tok::symbol(&e)
    }
    pub fn total_supply(e: Env) -> i128 {
        tok::total_supply(&e)
    }
}

mod test;
