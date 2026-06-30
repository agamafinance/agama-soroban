#![no_std]
//! Reusable SEP-41 fungible-token logic shared by the Agama Stellar POC contracts.
//!
//! This is NOT a contract itself — it is a plain library crate that exposes storage
//! helpers and high-level token operations. Each token contract (`mock_usdc`, `agusd`)
//! and the `staking` vault (for its `sagUSD` share token) embeds this module and
//! delegates the standard SEP-41 entrypoints to it.

use soroban_sdk::{contracttype, panic_with_error, Address, Env, String};
use soroban_sdk::contracterror;

// Bump TTLs generously so POC state does not expire mid-demo.
const DAY_LEDGERS: u32 = 17280; // ~ledgers per day at 5s
const INSTANCE_BUMP: u32 = 30 * DAY_LEDGERS;
const INSTANCE_LIFETIME: u32 = INSTANCE_BUMP - DAY_LEDGERS;
const PERSIST_BUMP: u32 = 30 * DAY_LEDGERS;
const PERSIST_LIFETIME: u32 = PERSIST_BUMP - DAY_LEDGERS;

#[contracterror]
#[derive(Copy, Clone, Debug, Eq, PartialEq)]
#[repr(u32)]
pub enum TokenError {
    InsufficientBalance = 1,
    InsufficientAllowance = 2,
    NegativeAmount = 3,
    AllowanceExpired = 4,
}

#[derive(Clone)]
#[contracttype]
pub struct AllowanceDataKey {
    pub from: Address,
    pub spender: Address,
}

#[derive(Clone)]
#[contracttype]
pub struct AllowanceValue {
    pub amount: i128,
    pub expiration_ledger: u32,
}

#[derive(Clone)]
#[contracttype]
pub struct TokenMetadata {
    pub decimal: u32,
    pub name: String,
    pub symbol: String,
}

#[derive(Clone)]
#[contracttype]
pub enum TokenKey {
    Allowance(AllowanceDataKey),
    Balance(Address),
    Metadata,
    TotalSupply,
}

fn check_nonneg(e: &Env, amount: i128) {
    if amount < 0 {
        panic_with_error!(e, TokenError::NegativeAmount);
    }
}

pub fn bump_instance(e: &Env) {
    e.storage()
        .instance()
        .extend_ttl(INSTANCE_LIFETIME, INSTANCE_BUMP);
}

// ---- metadata ----
pub fn set_metadata(e: &Env, decimal: u32, name: String, symbol: String) {
    e.storage()
        .instance()
        .set(&TokenKey::Metadata, &TokenMetadata { decimal, name, symbol });
}

pub fn read_metadata(e: &Env) -> TokenMetadata {
    bump_instance(e);
    e.storage().instance().get(&TokenKey::Metadata).unwrap()
}

pub fn decimals(e: &Env) -> u32 {
    read_metadata(e).decimal
}
pub fn name(e: &Env) -> String {
    read_metadata(e).name
}
pub fn symbol(e: &Env) -> String {
    read_metadata(e).symbol
}

// ---- total supply ----
pub fn total_supply(e: &Env) -> i128 {
    bump_instance(e);
    e.storage()
        .instance()
        .get(&TokenKey::TotalSupply)
        .unwrap_or(0)
}

fn set_total_supply(e: &Env, amount: i128) {
    e.storage().instance().set(&TokenKey::TotalSupply, &amount);
}

// ---- balances ----
pub fn balance(e: &Env, addr: &Address) -> i128 {
    let key = TokenKey::Balance(addr.clone());
    if let Some(b) = e.storage().persistent().get::<TokenKey, i128>(&key) {
        e.storage()
            .persistent()
            .extend_ttl(&key, PERSIST_LIFETIME, PERSIST_BUMP);
        b
    } else {
        0
    }
}

fn write_balance(e: &Env, addr: &Address, amount: i128) {
    let key = TokenKey::Balance(addr.clone());
    e.storage().persistent().set(&key, &amount);
    e.storage()
        .persistent()
        .extend_ttl(&key, PERSIST_LIFETIME, PERSIST_BUMP);
}

fn receive_balance(e: &Env, addr: &Address, amount: i128) {
    let b = balance(e, addr);
    write_balance(e, addr, b + amount);
}

fn spend_balance(e: &Env, addr: &Address, amount: i128) {
    let b = balance(e, addr);
    if b < amount {
        panic_with_error!(e, TokenError::InsufficientBalance);
    }
    write_balance(e, addr, b - amount);
}

// ---- allowances ----
pub fn allowance(e: &Env, from: &Address, spender: &Address) -> i128 {
    let key = TokenKey::Allowance(AllowanceDataKey {
        from: from.clone(),
        spender: spender.clone(),
    });
    if let Some(v) = e.storage().temporary().get::<TokenKey, AllowanceValue>(&key) {
        if v.expiration_ledger < e.ledger().sequence() {
            0
        } else {
            v.amount
        }
    } else {
        0
    }
}

pub fn approve(e: &Env, from: Address, spender: Address, amount: i128, expiration_ledger: u32) {
    from.require_auth();
    check_nonneg(e, amount);
    if amount > 0 && expiration_ledger < e.ledger().sequence() {
        panic_with_error!(e, TokenError::AllowanceExpired);
    }
    let key = TokenKey::Allowance(AllowanceDataKey {
        from: from.clone(),
        spender: spender.clone(),
    });
    e.storage().temporary().set(
        &key,
        &AllowanceValue {
            amount,
            expiration_ledger,
        },
    );
    if amount > 0 {
        let live = expiration_ledger
            .checked_sub(e.ledger().sequence())
            .unwrap_or(0);
        if live > 0 {
            e.storage().temporary().extend_ttl(&key, live, live);
        }
    }
    e.events()
        .publish((soroban_sdk::symbol_short!("approve"), from, spender), (amount, expiration_ledger));
}

fn spend_allowance(e: &Env, from: &Address, spender: &Address, amount: i128) {
    let cur = allowance(e, from, spender);
    if cur < amount {
        panic_with_error!(e, TokenError::InsufficientAllowance);
    }
    let key = TokenKey::Allowance(AllowanceDataKey {
        from: from.clone(),
        spender: spender.clone(),
    });
    let exp = e
        .storage()
        .temporary()
        .get::<TokenKey, AllowanceValue>(&key)
        .map(|v| v.expiration_ledger)
        .unwrap_or(0);
    e.storage().temporary().set(
        &key,
        &AllowanceValue {
            amount: cur - amount,
            expiration_ledger: exp,
        },
    );
}

// ---- high-level operations (SEP-41 entrypoints delegate here) ----
pub fn transfer(e: &Env, from: Address, to: Address, amount: i128) {
    from.require_auth();
    check_nonneg(e, amount);
    bump_instance(e);
    spend_balance(e, &from, amount);
    receive_balance(e, &to, amount);
    e.events()
        .publish((soroban_sdk::symbol_short!("transfer"), from, to), amount);
}

pub fn transfer_from(e: &Env, spender: Address, from: Address, to: Address, amount: i128) {
    spender.require_auth();
    check_nonneg(e, amount);
    bump_instance(e);
    spend_allowance(e, &from, &spender, amount);
    spend_balance(e, &from, amount);
    receive_balance(e, &to, amount);
    e.events()
        .publish((soroban_sdk::symbol_short!("transfer"), from, to), amount);
}

pub fn burn(e: &Env, from: Address, amount: i128) {
    from.require_auth();
    burn_unchecked(e, &from, amount);
}

pub fn burn_from(e: &Env, spender: Address, from: Address, amount: i128) {
    spender.require_auth();
    check_nonneg(e, amount);
    spend_allowance(e, &from, &spender, amount);
    burn_unchecked(e, &from, amount);
}

/// Burn without an auth check — for callers in the same contract frame that have
/// already authorized the enclosing invocation (e.g. agUSD `redeem`, vault unstake).
pub fn burn_unchecked(e: &Env, from: &Address, amount: i128) {
    check_nonneg(e, amount);
    bump_instance(e);
    spend_balance(e, from, amount);
    set_total_supply(e, total_supply(e) - amount);
    e.events()
        .publish((soroban_sdk::symbol_short!("burn"), from.clone()), amount);
}

/// Mint new tokens. Authorization (admin check) is the caller contract's responsibility.
pub fn mint(e: &Env, to: &Address, amount: i128) {
    check_nonneg(e, amount);
    bump_instance(e);
    receive_balance(e, to, amount);
    set_total_supply(e, total_supply(e) + amount);
    e.events()
        .publish((soroban_sdk::symbol_short!("mint"), to.clone()), amount);
}
