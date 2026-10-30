#![no_std]
//! A mock Etherfuse Stablebond pool, standing in for the real one so the
//! Etherfuse adapter can be unit tested against a subscription and a
//! redemption rather than against a counter.
//!
//! Tranche 2, Deliverable 1 of the SCF #45 award asks for the Etherfuse adapter
//! to pass its unit test suite "against mock pool contracts", and the real
//! Stablebonds are on mainnet, so there is nothing on testnet to subscribe
//! into. This is that mock. It is deliberately not a faithful reimplementation
//! of Etherfuse: it is the smallest contract that makes the adapter's two
//! money-moving paths real, which are
//!
//!   subscribe  USDC in,  bond units out at the current price
//!   redeem     units in, USDC out at the current price
//!
//! Three properties are modelled on purpose, because each one is a way the
//! adapter can be wrong and a counter cannot show it.
//!
//! 1. The price moves. `set_price` is how a test makes the bond accrue, and it
//!    is what separates the adapter's cost basis from its market value. An
//!    adapter that reports market value as its exposure would let the Engine's
//!    concentration caps drift with the bond price, so the two numbers are kept
//!    apart and both are readable.
//!
//! 2. Units are integral and the conversion rounds down. A subscription of an
//!    amount that is not a whole number of units leaves a remainder, and the
//!    adapter has to account for it rather than assume the round trip is exact.
//!
//! 3. The pool can be short of cash. `redeem` fails if the pool does not hold
//!    the USDC, which is the mock's version of an illiquid bond, and it is the
//!    case that tells the difference between an adapter that checks and one
//!    that panics four frames down inside a token transfer.
//!
//! Decimals are 7 everywhere, matching USDC on Stellar. `price` is USDC per
//! bond unit at that scale, so a price of 1_0000000 is one USDC per unit.

use soroban_sdk::{
    contract, contracterror, contractevent, contractimpl, contracttype, token::TokenClient,
    Address, Env,
};

/// One unit, at 7 decimals. The scale of `price`.
pub const ONE: i128 = 1_0000000;

/// How long an instance entry lives before it has to be bumped again.
const BUMP_TO: u32 = 518_400; // 30 days of ledgers at 5 seconds
const BUMP_AT: u32 = 69_120; // 4 days

#[contracterror]
#[derive(Copy, Clone, Debug, Eq, PartialEq, PartialOrd, Ord)]
#[repr(u32)]
pub enum PoolError {
    NotInitialized = 1,
    InvalidAmount = 2,
    InvalidPrice = 3,
    /// The holder does not have that many units.
    InsufficientUnits = 4,
    /// The pool itself does not hold the USDC this redemption owes. The real
    /// Stablebond answer to this is a settlement delay, not a failure, but a
    /// failure is the honest mock: it refuses rather than paying with money
    /// that is not there.
    PoolIlliquid = 5,
    /// The subscription was too small to buy a single unit at this price.
    DustSubscription = 6,
}

#[derive(Clone)]
#[contracttype]
enum Cfg {
    Admin,
    Usdc,
    Price,
    TotalUnits,
}

#[derive(Clone)]
#[contracttype]
enum Holder {
    Units(Address),
}

#[contractevent]
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct Subscribed {
    #[topic]
    pub holder: Address,
    pub usdc: i128,
    pub units: i128,
    pub price: i128,
}

#[contractevent]
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct Redeemed {
    #[topic]
    pub holder: Address,
    pub units: i128,
    pub usdc: i128,
    pub price: i128,
}

#[contractevent]
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct Repriced {
    pub from: i128,
    pub to: i128,
}

#[contract]
pub struct MockStablebond;

#[contractimpl]
impl MockStablebond {
    pub fn __constructor(e: Env, admin: Address, usdc: Address, price: i128) {
        if price <= 0 {
            panic_with(&e, PoolError::InvalidPrice);
        }
        e.storage().instance().set(&Cfg::Admin, &admin);
        e.storage().instance().set(&Cfg::Usdc, &usdc);
        e.storage().instance().set(&Cfg::Price, &price);
        e.storage().instance().set(&Cfg::TotalUnits, &0i128);
        bump(&e);
    }

    /// USDC in, bond units out, at the current price.
    ///
    /// `from` authorizes, which for a contract caller is satisfied by being the
    /// invoker, so the adapter subscribes with its own address and no allowance
    /// is involved.
    pub fn subscribe(e: Env, from: Address, usdc_amount: i128) -> Result<i128, PoolError> {
        from.require_auth();
        if usdc_amount <= 0 {
            return Err(PoolError::InvalidAmount);
        }
        let price = Self::price(e.clone())?;
        let units = usdc_amount * ONE / price;
        if units == 0 {
            // Taking the USDC and issuing nothing would be a silent confiscation.
            return Err(PoolError::DustSubscription);
        }
        // Only the USDC that bought whole units is taken. The remainder stays
        // with the caller, so the adapter's cost basis and the units it holds
        // describe the same money and a round trip does not leak dust into the
        // pool.
        let charged = units * price / ONE;
        let usdc = Self::usdc(e.clone())?;
        TokenClient::new(&e, &usdc).transfer(&from, &e.current_contract_address(), &charged);

        Self::credit(&e, &from, units);
        let total: i128 = e.storage().instance().get(&Cfg::TotalUnits).unwrap_or(0);
        e.storage().instance().set(&Cfg::TotalUnits, &(total + units));
        bump(&e);
        Subscribed {
            holder: from,
            usdc: charged,
            units,
            price,
        }
        .publish(&e);
        Ok(units)
    }

    /// Units in, USDC out, at the current price. Returns the USDC paid.
    pub fn redeem(e: Env, from: Address, units: i128) -> Result<i128, PoolError> {
        from.require_auth();
        if units <= 0 {
            return Err(PoolError::InvalidAmount);
        }
        let held = Self::units(e.clone(), from.clone());
        if units > held {
            return Err(PoolError::InsufficientUnits);
        }
        let price = Self::price(e.clone())?;
        let usdc_out = units * price / ONE;
        let usdc = Self::usdc(e.clone())?;
        let token = TokenClient::new(&e, &usdc);
        // Checked here rather than left to the transfer, so the caller gets
        // PoolIlliquid instead of a token error from a frame it did not write.
        if token.balance(&e.current_contract_address()) < usdc_out {
            return Err(PoolError::PoolIlliquid);
        }
        Self::credit(&e, &from, -units);
        let total: i128 = e.storage().instance().get(&Cfg::TotalUnits).unwrap_or(0);
        e.storage().instance().set(&Cfg::TotalUnits, &(total - units));
        token.transfer(&e.current_contract_address(), &from, &usdc_out);
        bump(&e);
        Redeemed {
            holder: from,
            units,
            usdc: usdc_out,
            price,
        }
        .publish(&e);
        Ok(usdc_out)
    }

    /// Move the bond price. This is the mock's accrual: the real Stablebond
    /// price comes from Etherfuse, and the point of exposing it here is that a
    /// test can make the bond earn without minting anything.
    ///
    /// Repricing upward does not fund the pool. A pool whose price has doubled
    /// and whose USDC balance has not owes more than it holds, and `redeem`
    /// says so with `PoolIlliquid` rather than paying the first holder out of
    /// the second holder's principal. Funding it is `fund`, below.
    pub fn set_price(e: Env, admin: Address, price: i128) -> Result<(), PoolError> {
        Self::require_admin(&e, &admin)?;
        if price <= 0 {
            return Err(PoolError::InvalidPrice);
        }
        let from = Self::price(e.clone())?;
        e.storage().instance().set(&Cfg::Price, &price);
        bump(&e);
        Repriced { from, to: price }.publish(&e);
        Ok(())
    }

    /// Pay the coupon in. Anyone may call it: this is a mock, the money is test
    /// money, and a faucet that needs an admin is a faucet a test has to
    /// impersonate.
    pub fn fund(e: Env, from: Address, amount: i128) -> Result<(), PoolError> {
        from.require_auth();
        if amount <= 0 {
            return Err(PoolError::InvalidAmount);
        }
        let usdc = Self::usdc(e.clone())?;
        TokenClient::new(&e, &usdc).transfer(&from, &e.current_contract_address(), &amount);
        bump(&e);
        Ok(())
    }

    /// Bond units held by `holder`. Zero for an address that never subscribed.
    pub fn units(e: Env, holder: Address) -> i128 {
        e.storage()
            .persistent()
            .get(&Holder::Units(holder))
            .unwrap_or(0)
    }

    pub fn total_units(e: Env) -> i128 {
        e.storage().instance().get(&Cfg::TotalUnits).unwrap_or(0)
    }

    /// USDC per bond unit, at 7 decimals.
    pub fn price(e: Env) -> Result<i128, PoolError> {
        e.storage()
            .instance()
            .get(&Cfg::Price)
            .ok_or(PoolError::NotInitialized)
    }

    /// What `units` are worth at the current price, which is what a redemption
    /// of them would pay if the pool is liquid.
    pub fn value_of(e: Env, units: i128) -> Result<i128, PoolError> {
        Ok(units * Self::price(e)? / ONE)
    }

    pub fn usdc(e: Env) -> Result<Address, PoolError> {
        e.storage()
            .instance()
            .get(&Cfg::Usdc)
            .ok_or(PoolError::NotInitialized)
    }

    pub fn admin(e: Env) -> Result<Address, PoolError> {
        e.storage()
            .instance()
            .get(&Cfg::Admin)
            .ok_or(PoolError::NotInitialized)
    }

    fn credit(e: &Env, holder: &Address, delta: i128) {
        let key = Holder::Units(holder.clone());
        let now: i128 = e.storage().persistent().get(&key).unwrap_or(0);
        e.storage().persistent().set(&key, &(now + delta));
        e.storage().persistent().extend_ttl(&key, BUMP_AT, BUMP_TO);
    }

    fn require_admin(e: &Env, admin: &Address) -> Result<(), PoolError> {
        let stored = Self::admin(e.clone())?;
        if stored != *admin {
            return Err(PoolError::NotInitialized);
        }
        admin.require_auth();
        Ok(())
    }
}

fn bump(e: &Env) {
    e.storage().instance().extend_ttl(BUMP_AT, BUMP_TO);
}

fn panic_with(e: &Env, err: PoolError) -> ! {
    soroban_sdk::panic_with_error!(e, err)
}

#[cfg(test)]
mod test;
