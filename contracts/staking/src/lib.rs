#![no_std]
//! Staking vault — issues the yield-bearing `sagUSD` share token.
//!
//! Users stake agUSD and receive sagUSD shares priced at `NAV / totalShares`
//! (ERC-4626 style). Yield is delivered by the strategist calling `accrue_yield`,
//! which transfers real agUSD into the vault and raises the NAV, so every share
//! appreciates — nothing to claim manually. Unstaking is a two-step
//! request → claim with a cooldown (mirrors the EVM sagYLD flow). `set_allocations`
//! records the off-chain "Kiro" liquidity strategies purely for UI display.

use soroban_sdk::{
    contract, contractimpl, contracttype, token::TokenClient, Address, Env, String, Vec,
};
use token as tok;

const ONE: i128 = 10_000_000; // 1.0 at 7 decimals — share-price scale

#[derive(Clone)]
#[contracttype]
enum Cfg {
    Admin,
    AgUsd,
    Nav,
    Cooldown,
    Allocations,
}

#[derive(Clone)]
#[contracttype]
enum Store {
    Pending(Address),
}

#[derive(Clone)]
#[contracttype]
pub struct Pending {
    pub assets: i128,
    pub claimable_at: u64,
}

#[derive(Clone)]
#[contracttype]
pub struct Allocation {
    pub name: String,
    pub target_bps: u32,
    pub apy_bps: u32,
}

#[contract]
pub struct Staking;

#[contractimpl]
impl Staking {
    pub fn initialize(
        e: Env,
        admin: Address,
        agusd: Address,
        cooldown_seconds: u64,
        decimal: u32,
        name: String,
        symbol: String,
    ) {
        e.storage().instance().set(&Cfg::Admin, &admin);
        e.storage().instance().set(&Cfg::AgUsd, &agusd);
        e.storage().instance().set(&Cfg::Nav, &0i128);
        e.storage().instance().set(&Cfg::Cooldown, &cooldown_seconds);
        tok::set_metadata(&e, decimal, name, symbol);
        tok::bump_instance(&e);
    }

    /// Stake agUSD, mint sagUSD shares at the current share price.
    pub fn stake(e: Env, from: Address, amount: i128) -> i128 {
        from.require_auth();
        if amount <= 0 {
            panic!("amount must be positive");
        }
        let agusd: Address = e.storage().instance().get(&Cfg::AgUsd).unwrap();
        TokenClient::new(&e, &agusd).transfer(&from, &e.current_contract_address(), &amount);

        let nav = Self::nav(e.clone());
        let supply = tok::total_supply(&e);
        let shares = if supply == 0 || nav == 0 {
            amount
        } else {
            amount * supply / nav
        };
        if shares <= 0 {
            panic!("zero shares");
        }
        tok::mint(&e, &from, shares);
        e.storage().instance().set(&Cfg::Nav, &(nav + amount));
        shares
    }

    /// Request to unstake `shares`: burns the shares now, locks the agUSD owed
    /// behind the cooldown. Claimable via `claim` after the cooldown elapses.
    pub fn request_unstake(e: Env, from: Address, shares: i128) -> i128 {
        from.require_auth();
        if shares <= 0 {
            panic!("shares must be positive");
        }
        let supply = tok::total_supply(&e);
        if supply == 0 {
            panic!("no supply");
        }
        let nav = Self::nav(e.clone());
        let assets = shares * nav / supply;
        tok::burn_unchecked(&e, &from, shares);
        e.storage().instance().set(&Cfg::Nav, &(nav - assets));

        let cooldown: u64 = e.storage().instance().get(&Cfg::Cooldown).unwrap();
        let key = Store::Pending(from.clone());
        let mut p: Pending = e
            .storage()
            .persistent()
            .get(&key)
            .unwrap_or(Pending { assets: 0, claimable_at: 0 });
        p.assets += assets;
        p.claimable_at = e.ledger().timestamp() + cooldown;
        e.storage().persistent().set(&key, &p);
        assets
    }

    /// Claim agUSD from a matured unstake request.
    pub fn claim(e: Env, from: Address) -> i128 {
        from.require_auth();
        let key = Store::Pending(from.clone());
        let p: Pending = e
            .storage()
            .persistent()
            .get(&key)
            .unwrap_or(Pending { assets: 0, claimable_at: 0 });
        if p.assets <= 0 {
            panic!("nothing pending");
        }
        if e.ledger().timestamp() < p.claimable_at {
            panic!("still in cooldown");
        }
        let agusd: Address = e.storage().instance().get(&Cfg::AgUsd).unwrap();
        TokenClient::new(&e, &agusd).transfer(&e.current_contract_address(), &from, &p.assets);
        e.storage().persistent().remove(&key);
        p.assets
    }

    /// Strategist delivers yield: transfers agUSD into the vault and raises the NAV.
    /// Every existing share appreciates proportionally.
    pub fn accrue_yield(e: Env, amount: i128) {
        let admin: Address = e.storage().instance().get(&Cfg::Admin).unwrap();
        admin.require_auth();
        if amount <= 0 {
            panic!("amount must be positive");
        }
        let agusd: Address = e.storage().instance().get(&Cfg::AgUsd).unwrap();
        TokenClient::new(&e, &agusd).transfer(&admin, &e.current_contract_address(), &amount);
        let nav = Self::nav(e.clone());
        e.storage().instance().set(&Cfg::Nav, &(nav + amount));
    }

    /// Admin override of the reported NAV (demo / reconciliation). Prefer
    /// `accrue_yield`, which keeps the vault solvent by moving real agUSD.
    pub fn report_nav(e: Env, new_nav: i128) {
        let admin: Address = e.storage().instance().get(&Cfg::Admin).unwrap();
        admin.require_auth();
        if new_nav < 0 {
            panic!("nav must be non-negative");
        }
        e.storage().instance().set(&Cfg::Nav, &new_nav);
    }

    /// Record the off-chain "Kiro" liquidity-strategy allocations (UI display only).
    pub fn set_allocations(e: Env, allocations: Vec<Allocation>) {
        let admin: Address = e.storage().instance().get(&Cfg::Admin).unwrap();
        admin.require_auth();
        e.storage().instance().set(&Cfg::Allocations, &allocations);
    }

    // ---- views ----
    pub fn nav(e: Env) -> i128 {
        e.storage().instance().get(&Cfg::Nav).unwrap_or(0)
    }
    pub fn total_shares(e: Env) -> i128 {
        tok::total_supply(&e)
    }
    /// Share price scaled to 7 decimals (ONE = 1.0). Starts at 1.0.
    pub fn share_price(e: Env) -> i128 {
        let supply = tok::total_supply(&e);
        if supply == 0 {
            ONE
        } else {
            Self::nav(e.clone()) * ONE / supply
        }
    }
    pub fn pending(e: Env, addr: Address) -> Pending {
        e.storage()
            .persistent()
            .get(&Store::Pending(addr))
            .unwrap_or(Pending { assets: 0, claimable_at: 0 })
    }
    pub fn cooldown(e: Env) -> u64 {
        e.storage().instance().get(&Cfg::Cooldown).unwrap_or(0)
    }
    pub fn allocations(e: Env) -> Vec<Allocation> {
        e.storage()
            .instance()
            .get(&Cfg::Allocations)
            .unwrap_or(Vec::new(&e))
    }
    pub fn agusd(e: Env) -> Address {
        e.storage().instance().get(&Cfg::AgUsd).unwrap()
    }
    pub fn admin(e: Env) -> Address {
        e.storage().instance().get(&Cfg::Admin).unwrap()
    }

    // ---- SEP-41 (sagUSD share token) ----
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
