#![no_std]
//! Mock USDC — a SEP-41 token with an open faucet, used as the base asset of the
//! Agama Stellar POC. Anyone can call `faucet` to receive test USDC (capped per call).

use soroban_sdk::{contract, contractimpl, contracttype, Address, Env, String};
use token as tok;

const FAUCET_CAP: i128 = 100_000_0000000; // 100k USDC (7 decimals) max per faucet call

#[derive(Clone)]
#[contracttype]
enum Cfg {
    Admin,
}

#[contract]
pub struct MockUsdc;

#[contractimpl]
impl MockUsdc {
    /// Initialize metadata. `admin` may also mint arbitrarily (for seeding the demo).
    pub fn initialize(e: Env, admin: Address, decimal: u32, name: String, symbol: String) {
        e.storage().instance().set(&Cfg::Admin, &admin);
        tok::set_metadata(&e, decimal, name, symbol);
        tok::bump_instance(&e);
    }

    /// Open faucet: anyone can mint up to `FAUCET_CAP` test USDC to `to`.
    pub fn faucet(e: Env, to: Address, amount: i128) {
        if amount <= 0 || amount > FAUCET_CAP {
            panic!("amount out of faucet range");
        }
        tok::mint(&e, &to, amount);
    }

    /// Admin mint (seed treasury / yield buffer during the demo).
    pub fn mint(e: Env, to: Address, amount: i128) {
        let admin: Address = e.storage().instance().get(&Cfg::Admin).unwrap();
        admin.require_auth();
        tok::mint(&e, &to, amount);
    }

    pub fn admin(e: Env) -> Address {
        e.storage().instance().get(&Cfg::Admin).unwrap()
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
