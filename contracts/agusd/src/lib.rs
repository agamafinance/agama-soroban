#![no_std]
//! agUSD — Agama's synthetic dollar on Stellar (SEP-41).
//!
//! Minted 1:1 by depositing the base USDC. The contract keeps a liquidity
//! buffer (`buffer_bps` of supply) for instant redemptions; ON EVERY DEPOSIT,
//! the excess above the buffer is auto-allocated into the curated credit
//! vaults according to the Allocation Engine's target weights — in the same
//! transaction. The contract itself holds the vault shares, so the backing is
//! fully traceable on-chain: backing = reserve buffer + deployed positions.
//!
//! Instant redemption is served from the buffer only (clear error beyond it);
//! `deallocate` + `claim_alloc` bring capital back. `sweep` to the treasury
//! remains for off-chain strategy legs.

use soroban_sdk::{
    auth::{ContractContext, InvokerContractAuthEntry, SubContractInvocation},
    contract, contractclient, contractimpl, contracttype, panic_with_error, symbol_short,
    token::TokenClient, vec, Address, Env, IntoVal, String, Vec,
};
use soroban_sdk::contracterror;
use token as tok;

#[contracterror]
#[derive(Copy, Clone, Debug, Eq, PartialEq)]
#[repr(u32)]
pub enum AgUsdError {
    /// Redemption exceeds the instant-liquidity buffer; the rest of the
    /// backing is working in strategies. Redeem less or wait for deallocation.
    InsufficientBuffer = 100,
}

/// Minimal client for the credit-vault (staking) contracts.
#[contractclient(name = "VaultClient")]
pub trait VaultInterface {
    fn stake(e: Env, from: Address, amount: i128) -> i128;
    fn request_unstake(e: Env, from: Address, shares: i128) -> i128;
    fn claim(e: Env, from: Address) -> i128;
    fn balance(e: Env, id: Address) -> i128;
    fn share_price(e: Env) -> i128;
}

const SHARE_ONE: i128 = 10_000_000; // vault share-price scale (7dp)
const BPS: i128 = 10_000;
const MIN_ALLOC: i128 = 1_000_000; // don't bother moving dust < 0.1 USDC

#[derive(Clone)]
#[contracttype]
pub struct Target {
    pub vault: Address,
    pub weight_bps: u32,
}

#[derive(Clone)]
#[contracttype]
enum Cfg {
    Admin,
    Usdc,
    Treasury,
    Targets,   // Vec<Target> — allocation weights set by the Allocation Engine
    BufferBps, // liquidity buffer kept for instant redemptions
}

#[contract]
pub struct AgUsd;

#[contractimpl]
impl AgUsd {
    /// Wire up the synthetic dollar. `usdc` is the base-asset token contract,
    /// `treasury` the strategist address for off-chain legs.
    pub fn initialize(
        e: Env,
        admin: Address,
        usdc: Address,
        treasury: Address,
        buffer_bps: u32,
        decimal: u32,
        name: String,
        symbol: String,
    ) {
        e.storage().instance().set(&Cfg::Admin, &admin);
        e.storage().instance().set(&Cfg::Usdc, &usdc);
        e.storage().instance().set(&Cfg::Treasury, &treasury);
        e.storage().instance().set(&Cfg::BufferBps, &buffer_bps);
        tok::set_metadata(&e, decimal, name, symbol);
        tok::bump_instance(&e);
    }

    /// Allocation Engine targets: which credit vaults and at which weights the
    /// excess liquidity is deployed. Weights in bps (should sum to 10000).
    pub fn set_targets(e: Env, targets: Vec<Target>) {
        Self::admin(e.clone()).require_auth();
        e.storage().instance().set(&Cfg::Targets, &targets);
    }

    pub fn set_buffer_bps(e: Env, buffer_bps: u32) {
        Self::admin(e.clone()).require_auth();
        e.storage().instance().set(&Cfg::BufferBps, &buffer_bps);
    }

    /// Deposit USDC and mint agUSD 1:1. Then — the Allocation Engine hook —
    /// any reserve above the liquidity buffer is auto-deployed into the
    /// credit vaults at the target weights, in this same transaction.
    pub fn deposit(e: Env, from: Address, amount: i128) {
        from.require_auth();
        if amount <= 0 {
            panic!("amount must be positive");
        }
        let usdc: Address = e.storage().instance().get(&Cfg::Usdc).unwrap();
        TokenClient::new(&e, &usdc).transfer(&from, &e.current_contract_address(), &amount);
        tok::mint(&e, &from, amount);
        Self::rebalance(e);
    }

    /// Redeem agUSD for USDC 1:1 from the liquidity buffer. If the request
    /// exceeds the buffer, fails with InsufficientBuffer — the remainder of
    /// the backing is working in strategies.
    pub fn redeem(e: Env, from: Address, amount: i128) {
        from.require_auth();
        if amount <= 0 {
            panic!("amount must be positive");
        }
        if amount > Self::reserve(e.clone()) {
            panic_with_error!(&e, AgUsdError::InsufficientBuffer);
        }
        tok::burn_unchecked(&e, &from, amount);
        let usdc: Address = e.storage().instance().get(&Cfg::Usdc).unwrap();
        TokenClient::new(&e, &usdc).transfer(&e.current_contract_address(), &from, &amount);
        // Movement out — start pulling capital back so the buffer returns to target.
        Self::rebalance(e);
    }

    /// The Allocation Engine hook: bring the liquidity buffer back to target
    /// after ANY movement. Called automatically on deposit and redeem;
    /// callable by anyone (it only ever moves funds between the reserve and
    /// the engine's target vaults).
    ///
    ///  - harvests matured withdrawal requests from the vaults
    ///  - buffer above target  -> allocates the excess at the target weights
    ///  - buffer below target  -> requests withdrawals from the vaults
    ///    (claimable after the vault cooldown, harvested on the next movement)
    pub fn rebalance(e: Env) {
        let targets: Vec<Target> = e
            .storage()
            .instance()
            .get(&Cfg::Targets)
            .unwrap_or(Vec::new(&e));
        if targets.is_empty() {
            return;
        }
        let me = e.current_contract_address();

        // 1) Harvest any matured withdrawal requests (ignore not-ready/empty).
        for t in targets.iter() {
            let _ = VaultClient::new(&e, &t.vault).try_claim(&me);
        }

        let buffer_bps: u32 = e.storage().instance().get(&Cfg::BufferBps).unwrap_or(2000);
        let supply = tok::total_supply(&e);
        let reserve = Self::reserve(e.clone());
        let buffer_target = supply * (buffer_bps as i128) / BPS;
        let usdc: Address = e.storage().instance().get(&Cfg::Usdc).unwrap();

        let excess = reserve - buffer_target;
        if excess >= MIN_ALLOC {
            // 2a) Deploy the excess into the vaults at target weights.
            for t in targets.iter() {
                let part = excess * (t.weight_bps as i128) / BPS;
                if part <= 0 {
                    continue;
                }
                // Authorize the vault's inner usdc.transfer(self -> vault, part).
                e.authorize_as_current_contract(vec![
                    &e,
                    InvokerContractAuthEntry::Contract(SubContractInvocation {
                        context: ContractContext {
                            contract: usdc.clone(),
                            fn_name: symbol_short!("transfer"),
                            args: (me.clone(), t.vault.clone(), part).into_val(&e),
                        },
                        sub_invocations: vec![&e],
                    }),
                ]);
                VaultClient::new(&e, &t.vault).stake(&me, &part);
            }
        } else if excess <= -MIN_ALLOC {
            // 2b) Buffer below target: request withdrawals proportionally.
            let shortfall = -excess;
            for t in targets.iter() {
                let part = shortfall * (t.weight_bps as i128) / BPS;
                if part <= 0 {
                    continue;
                }
                let c = VaultClient::new(&e, &t.vault);
                let sp = c.share_price();
                let held = c.balance(&me);
                if sp <= 0 || held <= 0 {
                    continue;
                }
                let mut shares = part * SHARE_ONE / sp;
                if shares > held {
                    shares = held;
                }
                if shares > 0 {
                    let _ = c.try_request_unstake(&me, &shares);
                }
            }
        }
    }

    /// Engine pulls capital back from a vault (two-step: request, then claim
    /// after the vault cooldown) to refill the redemption buffer.
    pub fn deallocate(e: Env, vault: Address, shares: i128) -> i128 {
        Self::admin(e.clone()).require_auth();
        VaultClient::new(&e, &vault).request_unstake(&e.current_contract_address(), &shares)
    }

    pub fn claim_alloc(e: Env, vault: Address) -> i128 {
        Self::admin(e.clone()).require_auth();
        VaultClient::new(&e, &vault).claim(&e.current_contract_address())
    }

    /// Admin moves part of the USDC reserve to the treasury (off-chain leg).
    pub fn sweep(e: Env, amount: i128) {
        Self::admin(e.clone()).require_auth();
        let usdc: Address = e.storage().instance().get(&Cfg::Usdc).unwrap();
        let treasury: Address = e.storage().instance().get(&Cfg::Treasury).unwrap();
        TokenClient::new(&e, &usdc).transfer(&e.current_contract_address(), &treasury, &amount);
    }

    /// Treasury returns USDC to the reserve.
    pub fn refund_reserve(e: Env, from: Address, amount: i128) {
        from.require_auth();
        let usdc: Address = e.storage().instance().get(&Cfg::Usdc).unwrap();
        TokenClient::new(&e, &usdc).transfer(&from, &e.current_contract_address(), &amount);
    }

    // ---- views ----
    /// USDC sitting in the contract = instant redemption capacity.
    pub fn reserve(e: Env) -> i128 {
        let usdc: Address = e.storage().instance().get(&Cfg::Usdc).unwrap();
        TokenClient::new(&e, &usdc).balance(&e.current_contract_address())
    }

    /// Value (in USDC) of the reserve deployed into the credit vaults.
    pub fn deployed(e: Env) -> i128 {
        let targets: Vec<Target> = e
            .storage()
            .instance()
            .get(&Cfg::Targets)
            .unwrap_or(Vec::new(&e));
        let me = e.current_contract_address();
        let mut total: i128 = 0;
        for t in targets.iter() {
            let c = VaultClient::new(&e, &t.vault);
            total += c.balance(&me) * c.share_price() / SHARE_ONE;
        }
        total
    }

    pub fn targets(e: Env) -> Vec<Target> {
        e.storage()
            .instance()
            .get(&Cfg::Targets)
            .unwrap_or(Vec::new(&e))
    }
    pub fn buffer_bps(e: Env) -> u32 {
        e.storage().instance().get(&Cfg::BufferBps).unwrap_or(2000)
    }
    pub fn admin(e: Env) -> Address {
        e.storage().instance().get(&Cfg::Admin).unwrap()
    }
    pub fn treasury(e: Env) -> Address {
        e.storage().instance().get(&Cfg::Treasury).unwrap()
    }
    pub fn usdc(e: Env) -> Address {
        e.storage().instance().get(&Cfg::Usdc).unwrap()
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
