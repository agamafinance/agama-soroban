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
//! # The minter is fixed at initialization
//!
//! `minter` is written once, by `initialize`, and there is no setter, no
//! admin mint and no pause that would let anyone else create supply. An admin
//! able to rotate the minter could point it at itself and print, which is an
//! admin mint with one extra step, and it would make the claim above untrue.
//! Moving issuance to a different Vault therefore costs a new token
//! deployment. That is the price of being able to say, and have an auditor
//! check, that only the Vault can create agUSD.
//!
//! The `admin` recorded by `initialize` is deliberately powerless over supply.
//! It is stored so the deployment is attributable on-chain and so future
//! non-supply governance has an anchor; every function that can move supply
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
use soroban_sdk::{contract, contractimpl, contracttype, Address, Env, String};
use token as tok;

#[contracterror]
#[derive(Copy, Clone, Debug, Eq, PartialEq)]
#[repr(u32)]
pub enum AgUsdCoreError {
    AlreadyInitialized = 200,
    NotInitialized = 201,
    /// Someone other than the Vault tried to mint.
    NotMinter = 202,
    /// Zero or negative mint amount.
    InvalidAmount = 203,
}

/// Instance storage. Both entries are written once and never rewritten.
#[derive(Clone)]
#[contracttype]
enum Cfg {
    Admin,
    Minter,
}

#[contract]
pub struct AgUsdCore;

#[contractimpl]
impl AgUsdCore {
    /// Record the admin and the minting authority, and set the SEP-41
    /// metadata.
    ///
    /// Re-initialization is rejected. Without that guard anyone could call
    /// `initialize` a second time, name themselves minter, and print against a
    /// book they do not hold, which is the whole security property of this
    /// contract gone in one transaction.
    pub fn initialize(
        e: Env,
        admin: Address,
        minter: Address,
        decimal: u32,
        name: String,
        symbol: String,
    ) -> Result<(), AgUsdCoreError> {
        if e.storage().instance().has(&Cfg::Minter) {
            return Err(AgUsdCoreError::AlreadyInitialized);
        }
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
        Ok(())
    }

    // ---- views ----

    /// The only address that can create supply. Fixed at initialization.
    pub fn minter(e: Env) -> Result<Address, AgUsdCoreError> {
        e.storage()
            .instance()
            .get(&Cfg::Minter)
            .ok_or(AgUsdCoreError::NotInitialized)
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
