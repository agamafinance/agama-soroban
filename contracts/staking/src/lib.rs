#![no_std]
//! Staking vault, issuer of the yield-bearing `sagUSD` share token.
//!
//! Users stake agUSD and receive sagUSD shares priced at `NAV / totalShares`
//! (ERC-4626 style). Yield is delivered by the strategist calling
//! `accrue_yield`, which transfers real agUSD into the vault and raises the
//! NAV, so every share appreciates and there is nothing to claim by hand.
//! Unstaking is a two step request then claim with a cooldown (it mirrors the
//! EVM sagYLD flow). `set_allocations` records the off-chain "Kiro" liquidity
//! strategies purely for UI display.
//!
//! # The agUSD pointer
//!
//! This contract accepts exactly one token, written at initialization. The
//! deployed generation of it accepts the generation 1 agUSD and has no setter,
//! so when the Vault started minting a different agUSD, the staking contract
//! was left accepting a token nobody is issuing any more: a holder of the new
//! agUSD cannot stake at all, and the failure looks like an insufficient
//! balance rather than like a wiring mistake.
//!
//! `set_agusd` fixes that, gated the way the Vault's own token pointer is:
//! admin only, and closed the moment this contract has taken custody of
//! anything, by a stake or by delivered yield. Once it holds a balance, the
//! share price is a claim on it and the pending unstake queue is denominated in
//! it, so repointing would leave both denominated in a token the contract does
//! not hold. Before that there is nothing to strand.
//!
//! # What the admin can still do
//!
//! `report_nav` overwrites the reported NAV outright, which is the denominator
//! every share is redeemed against, and `accrue_yield` moves the admin's own
//! agUSD in. The re-initialization guard below stops a stranger doing either;
//! it does not stop the admin, and it is not sold as doing so. As everywhere
//! else in V1 the mitigation is the multi-signature admin and the timelock on
//! the roadmap. `report_nav` exists for demo and reconciliation, and
//! `accrue_yield`, which moves real agUSD and cannot overstate the book, is the
//! path that should be used.

use soroban_sdk::{
    contract, contracterror, contractevent, contractimpl, contracttype, token::TokenClient, Address,
    Env, String, Vec,
};
use token as tok;

const ONE: i128 = 10_000_000; // 1.0 at 7 decimals, the share-price scale

#[contracterror]
#[derive(Copy, Clone, Debug, Eq, PartialEq)]
#[repr(u32)]
pub enum StakingError {
    AlreadyInitialized = 800,
    NotInitialized = 801,
    NotAdmin = 802,
    /// The contract has taken custody of agUSD, through a stake or through
    /// delivered yield, so the token it accepts is fixed.
    CustodyTaken = 803,
}

/// Emitted when the staked asset is repointed. It can only happen before the
/// contract has taken custody of anything, and it is the one change that
/// decides what every future share is a claim on, so it goes in the event
/// stream.
#[contractevent]
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct AgUsdRepointed {
    #[topic]
    pub agusd: Address,
}

#[derive(Clone)]
#[contracttype]
enum Cfg {
    Admin,
    AgUsd,
    Nav,
    Cooldown,
    Allocations,
    Stakes,
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
    /// One time setup.
    ///
    /// Re-initialization is rejected. Without that guard anyone could call this
    /// a second time, name themselves admin, repoint the staked asset and reset
    /// the NAV, which between them are enough to drain the contract: the NAV is
    /// the denominator every share is redeemed against.
    pub fn initialize(
        e: Env,
        admin: Address,
        agusd: Address,
        cooldown_seconds: u64,
        decimal: u32,
        name: String,
        symbol: String,
    ) -> Result<(), StakingError> {
        if e.storage().instance().has(&Cfg::Admin) {
            return Err(StakingError::AlreadyInitialized);
        }
        admin.require_auth();
        e.storage().instance().set(&Cfg::Admin, &admin);
        e.storage().instance().set(&Cfg::AgUsd, &agusd);
        e.storage().instance().set(&Cfg::Nav, &0i128);
        e.storage().instance().set(&Cfg::Cooldown, &cooldown_seconds);
        tok::set_metadata(&e, decimal, name, symbol);
        tok::bump_instance(&e);
        Ok(())
    }

    /// Point the contract at a different agUSD, before anybody has staked.
    ///
    /// The deployed generation of this contract did not have this, so when the
    /// Vault moved to a new agUSD the staking contract stayed on the old one
    /// and simply stopped being reachable: staking the token the protocol now
    /// issues fails on a balance the contract is not even looking at.
    ///
    /// It closes the moment the contract has taken custody of anything. From
    /// then on the share price is a claim on a real balance and the pending
    /// unstake queue is denominated in it, so a repointed contract would owe
    /// its stakers a token it never took in.
    ///
    /// Three conditions, because there are three ways in. The stake counter
    /// records that a stake has happened rather than what the balance is now,
    /// since unwinding to zero is not the same thing as never having taken
    /// custody and the pending queue can be non-empty while the share supply is
    /// nil. The NAV and the balance are checked as well because `accrue_yield`
    /// takes custody without going near the counter: a contract holding a
    /// thousand agUSD of undistributed yield and no shares would otherwise
    /// still look untouched, and the first staker after a repoint would be
    /// issued shares against a NAV denominated in a token the contract no
    /// longer holds.
    pub fn set_agusd(e: Env, admin: Address, agusd: Address) -> Result<(), StakingError> {
        Self::require_admin(&e, &admin)?;
        if Self::stakes(e.clone()) > 0 || Self::nav(e.clone()) != 0 {
            return Err(StakingError::CustodyTaken);
        }
        let current: Address = e
            .storage()
            .instance()
            .get(&Cfg::AgUsd)
            .ok_or(StakingError::NotInitialized)?;
        if TokenClient::new(&e, &current).balance(&e.current_contract_address()) != 0 {
            return Err(StakingError::CustodyTaken);
        }
        e.storage().instance().set(&Cfg::AgUsd, &agusd);
        tok::bump_instance(&e);
        AgUsdRepointed { agusd }.publish(&e);
        Ok(())
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
        e.storage()
            .instance()
            .set(&Cfg::Stakes, &(Self::stakes(e.clone()) + 1));
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
    /// Stakes taken since deployment. Counted rather than derived from the
    /// share supply because it is what `set_agusd` keys off: the question is
    /// whether this contract has ever custodied agUSD, and a position that has
    /// been fully unstaked would answer it wrongly.
    pub fn stakes(e: Env) -> u64 {
        e.storage().instance().get(&Cfg::Stakes).unwrap_or(0)
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

    // ---- internals ----

    fn require_admin(e: &Env, admin: &Address) -> Result<(), StakingError> {
        let stored: Address = e
            .storage()
            .instance()
            .get(&Cfg::Admin)
            .ok_or(StakingError::NotInitialized)?;
        if stored != *admin {
            return Err(StakingError::NotAdmin);
        }
        admin.require_auth();
        Ok(())
    }
}

mod test;
