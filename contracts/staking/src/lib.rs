#![no_std]
//! Staking vault, issuer of the yield-bearing `sagUSD` share token.
//!
//! Users stake agUSD and receive sagUSD shares priced at `NAV / totalShares`
//! (ERC-4626 style). Yield is delivered by the strategist calling
//! `distribute_yield`, which transfers real agUSD into the vault and raises the
//! NAV, so every share appreciates and there is nothing to claim by hand.
//! Unstaking is a two step request then claim with a cooldown (it mirrors the
//! EVM sagYLD flow). `set_allocations` records the off-chain "Kiro" liquidity
//! strategies purely for UI display.
//!
//! # The `distribute_yield` / assets-per-share convention
//!
//! These are the names Agama committed to publicly, in its answer to the SCF
//! panel: sagUSD adopts the `distribute_yield` / assets-per-share accounting
//! convention, as an interface compatibility rather than a protocol-level
//! integration. No DeFindex contract is called, no DeFindex contract is
//! trusted, and nothing here depends on their deployment. This contract now
//! honours that commitment; it previously used `accrue_yield` and `share_price`
//! and so did not.
//!
//! One correction, recorded here because the repository is going to audit and
//! the claim is checkable. DeFindex's own vault does not publish functions
//! under either of these names. Its interface is multi-asset
//! (`fetch_total_managed_funds`, `get_asset_amounts_per_shares`,
//! `distribute_fees`, and strategy level `harvest`), it exposes no scalar
//! price-per-share getter at all, and it has no vault level yield distribution
//! entry point. So this is a naming convention Agama has adopted on its own
//! side, matching DeFindex's economics: shares are never rebased, nothing is
//! pushed to holders, and a position appreciates because the assets behind each
//! share grow. It is not call compatibility with a DeFindex vault, and it
//! should not be described as such.
//!
//! `exchange_rate` is that view: agUSD per sagUSD share, scaled to 7 decimals.
//! `share_price` is kept as an alias of it, returning the same number from the
//! same computation, because the generation 1 agUSD contract
//! (`contracts/agusd`) calls `share_price` on the six deployed credit vaults,
//! which are instances of this contract. Dropping the old name would break a
//! caller that is live on testnet for no gain: a wallet looking for
//! `exchange_rate` does not care that a second name answers as well.
//!
//! The yield entry point is a hard rename rather than an alias. It is a state
//! changing, admin authorized path with no on-chain caller anywhere in this
//! workspace, so there is nothing to break, and keeping two names for one way
//! of moving real money into the contract would mean two entry points an
//! auditor has to check instead of one.
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
//! # Why there is no NAV setter any more
//!
//! There was one. `report_nav(new_nav)` was admin gated, took any non-negative
//! value, checked nothing against the balance the contract actually held, and
//! emitted no event. It was described as being for demo and reconciliation.
//!
//! NAV is the denominator of both directions of the share price: `stake` mints
//! `amount * supply / nav` and `request_unstake` returns `shares * nav /
//! supply`. A setter on that number is not a reporting convenience, it is an
//! instruction to reprice every share in the contract. With 1000 agUSD staked,
//! `report_nav(1)` collapses the NAV to one stroop, staking 99 stroops then
//! buys 99% of the share supply, restoring the NAV restores the value behind
//! those shares, and unstaking walks away with 990 agUSD of somebody else's
//! deposit. Two calls, no cash, no event.
//!
//! `distribute_yield` is the entry point that was always meant to be used: it
//! moves real agUSD in from an account that signed for it, and raises the NAV
//! by exactly what arrived, so it cannot overstate the book. Once it existed
//! there was no remaining reason for a bare setter, and the setter is gone
//! rather than bounded. Nothing in this workspace called it, no script called
//! it, and the six deployed credit vaults are older instances that keep their
//! own copy of it on-chain; removing it here removes it from every instance
//! deployed from this source.
//!
//! NAV now moves in exactly three ways, all of them backed by a transfer:
//! `stake` in, `request_unstake` out, `distribute_yield` in.
//!
//! # What the admin can still do
//!
//! `distribute_yield` moves the admin's own agUSD in, and `set_allocations`
//! writes display metadata. The re-initialization guard below stops a stranger
//! doing either; it does not stop the admin, and it is not sold as doing so. As
//! everywhere else in V1 the mitigation is the multi-signature admin and the
//! timelock on the roadmap. What has changed is that no admin call can now move
//! the share price without moving the assets behind it.

use soroban_sdk::{
    contract, contracterror, contractevent, contractimpl, contracttype, token::TokenClient, Address,
    Env, String, Vec,
};
use token as tok;

/// A pending unstake is the only record that says a departed staker is still
/// owed anything: the shares are burned and the assets are out of `nav`, so if
/// the record archives the money belongs to nobody and sits here. It is given
/// the same horizon the Vault gives a withdrawal claim, and for the same
/// reason, because it is the same kind of thing.
///
/// Written with `set` alone it got 4095 ledgers, under six hours, which is a
/// strange amount of time to give somebody a cooldown has just told to come
/// back later.
const DAY_LEDGERS: u32 = 17_280;
const PENDING_BUMP: u32 = 90 * DAY_LEDGERS;
const PENDING_LIFETIME: u32 = PENDING_BUMP - DAY_LEDGERS;


const ONE: i128 = 10_000_000; // 1.0 at 7 decimals, the share-price scale

#[contracterror]
#[derive(Copy, Clone, Debug, Eq, PartialEq)]
#[repr(u32)]
pub enum StakingError {
    /// Retired with `initialize`, which a `__constructor` replaced. The host
    /// runs a constructor exactly once, inside the deploy, so there is no
    /// second call for this to be the answer to. The number is kept rather than
    /// reused so that an old error code never means something new.
    AlreadyInitialized = 800,
    NotInitialized = 801,
    NotAdmin = 802,
    /// The contract has taken custody of agUSD, through a stake or through
    /// delivered yield, so the token it accepts is fixed.
    CustodyTaken = 803,
    /// `accept_admin` was called with no handover in flight.
    NoPendingAdmin = 804,
    /// `accept_admin` was called by an address that was not the one proposed.
    NotPendingAdmin = 805,
    /// A stake, an unstake or a yield distribution of zero or less.
    InvalidAmount = 806,
    /// The stake was large enough to be a positive number of assets and small
    /// enough to round to no shares at all. Refused rather than taken, because
    /// taking it is taking a deposit and giving nothing back for it.
    ZeroShares = 807,
    /// An unstake with no shares in existence to price it against.
    NoSupply = 808,
    /// `claim` with nothing recorded as owed.
    NothingPending = 809,
    /// `claim` before the cooldown on the pending balance has run out.
    StillInCooldown = 810,
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
    /// Half finished admin handover: proposed, not yet accepted.
    PendingAdmin,
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

/// Emitted when an admin handover is proposed. The role has not moved yet: this
/// is the first half of a two step transfer, and it is in the event stream so
/// that a pending handover is visible to anyone watching rather than only to
/// whoever thinks to read the state.
/// Emitted when agUSD is staked.
///
/// It carries `nav` and `supply` as they stand after the call, not because a
/// reader could not fetch them but because it could not fetch them *as they
/// were*. The share price is `nav / supply`, and an indexer building a price
/// history from the event stream has no way back to a past pair. Carrying both
/// makes every price in the history a fact from the ledger rather than a sample
/// somebody happened to take.
#[contractevent]
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct Staked {
    #[topic]
    pub staker: Address,
    /// agUSD in.
    pub assets: i128,
    /// sagUSD minted for it.
    pub shares: i128,
    pub nav: i128,
    pub supply: i128,
}

/// Emitted when an unstake is requested, which is where the shares are burned
/// and the assets leave the share price. The claim is payable at
/// `claimable_at`, and a second request before then restarts the cooldown on
/// the whole pending balance, which is why the field is absolute rather than a
/// duration.
#[contractevent]
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct UnstakeRequested {
    #[topic]
    pub staker: Address,
    pub shares: i128,
    /// agUSD owed, priced at the moment of the request and fixed from then on.
    pub assets: i128,
    pub claimable_at: u64,
    pub nav: i128,
    pub supply: i128,
}

/// Emitted when a matured unstake is paid out. The shares were burned at
/// request time, so nothing about the share price moves here and neither `nav`
/// nor `supply` is carried: this is the cash leaving, and the accounting for it
/// already happened.
#[contractevent]
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct UnstakeClaimed {
    #[topic]
    pub staker: Address,
    pub assets: i128,
}

/// Emitted when yield is distributed. This is the only call that raises the
/// share price, so without it in the stream a price history has gaps it cannot
/// explain: the number moves and nothing says why.
#[contractevent]
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct YieldDistributed {
    pub amount: i128,
    pub nav: i128,
    pub supply: i128,
}

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
pub struct Staking;

#[contractimpl]
impl Staking {
    /// One time setup.
    ///
    /// Re-initialization is rejected. Without that guard anyone could call this
    /// a second time, name themselves admin and repoint the staked asset, which
    /// between them are enough to strand every share against a token the
    /// contract does not hold.
    /// Record the admin, the agUSD this contract accepts, the unstake cooldown and the sagUSD SEP-41 metadata, in the transaction that deploys it.
    ///
    /// This was `initialize`, a separate call, and being separate was the
    /// problem. A contract sitting deployed and uninitialized is a contract
    /// whose admin is whoever sends the next transaction, and the deployer's
    /// own call is public before it is mined, so it can be front-run by an
    /// identical one naming somebody else. On this contract that is the authority over the yield the share price is moved by. A constructor runs inside
    /// the deploy, so there is no window to race, and the host runs it exactly
    /// once, which is what used to need a re-initialization guard.
    pub fn __constructor(
        e: Env,
        admin: Address,
        agusd: Address,
        cooldown_seconds: u64,
        decimal: u32,
        name: String,
        symbol: String,
    ) -> Result<(), StakingError> {
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
    /// nil. The NAV and the balance are checked as well because `distribute_yield`
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
    pub fn stake(e: Env, from: Address, amount: i128) -> Result<i128, StakingError> {
        from.require_auth();
        if amount <= 0 {
            return Err(StakingError::InvalidAmount);
        }
        let agusd: Address = e
            .storage()
            .instance()
            .get(&Cfg::AgUsd)
            .ok_or(StakingError::NotInitialized)?;
        TokenClient::new(&e, &agusd).transfer(&from, &e.current_contract_address(), &amount);

        let nav = Self::nav(e.clone());
        let supply = tok::total_supply(&e);
        let shares = if supply == 0 || nav == 0 {
            amount
        } else {
            amount * supply / nav
        };
        if shares <= 0 {
            return Err(StakingError::ZeroShares);
        }
        tok::mint(&e, &from, shares);
        e.storage().instance().set(&Cfg::Nav, &(nav + amount));
        e.storage()
            .instance()
            .set(&Cfg::Stakes, &(Self::stakes(e.clone()) + 1));
        Staked {
            staker: from,
            assets: amount,
            shares,
            nav: Self::nav(e.clone()),
            supply: tok::total_supply(&e),
        }
        .publish(&e);
        Ok(shares)
    }

    /// Request to unstake `shares`: burns the shares now, locks the agUSD owed
    /// behind the cooldown. Claimable via `claim` after the cooldown elapses.
    pub fn request_unstake(e: Env, from: Address, shares: i128) -> Result<i128, StakingError> {
        from.require_auth();
        if shares <= 0 {
            return Err(StakingError::InvalidAmount);
        }
        let supply = tok::total_supply(&e);
        if supply == 0 {
            return Err(StakingError::NoSupply);
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
        Self::write_pending(&e, &from, &p);
        UnstakeRequested {
            staker: from,
            shares,
            assets,
            claimable_at: p.claimable_at,
            nav: Self::nav(e.clone()),
            supply: tok::total_supply(&e),
        }
        .publish(&e);
        Ok(assets)
    }

    /// Postpone the archival of a pending unstake. Callable by anyone.
    ///
    /// The record is written once, when the unstake is requested, and nothing
    /// writes to it again until it is claimed. So nothing extends it either,
    /// and a cooldown is by construction a period the staker has been told to
    /// go away for. The Vault has `bump_claim` for the identical situation and
    /// this contract had nothing, which meant the only way to refresh a pending
    /// unstake was to request another one, using shares that have already been
    /// burned.
    ///
    /// Permissionless for the reason `bump_claim` is: it cannot shorten a TTL,
    /// it cannot alter what is owed or who it is owed to, and the caller pays
    /// the rent. There is nothing here for a stranger to gain and nothing for
    /// them to damage, and requiring a signature would mean the one person who
    /// might have lost their key is the only one who can keep their claim
    /// alive.
    pub fn bump_pending(e: Env, addr: Address) -> Result<(), StakingError> {
        let key = Store::Pending(addr.clone());
        let p: Pending = e
            .storage()
            .persistent()
            .get(&key)
            .ok_or(StakingError::NothingPending)?;
        if p.assets <= 0 {
            return Err(StakingError::NothingPending);
        }
        Self::write_pending(&e, &addr, &p);
        Ok(())
    }

    /// Claim agUSD from a matured unstake request.
    pub fn claim(e: Env, from: Address) -> Result<i128, StakingError> {
        from.require_auth();
        let key = Store::Pending(from.clone());
        let p: Pending = e
            .storage()
            .persistent()
            .get(&key)
            .unwrap_or(Pending { assets: 0, claimable_at: 0 });
        if p.assets <= 0 {
            return Err(StakingError::NothingPending);
        }
        if e.ledger().timestamp() < p.claimable_at {
            return Err(StakingError::StillInCooldown);
        }
        let agusd: Address = e
            .storage()
            .instance()
            .get(&Cfg::AgUsd)
            .ok_or(StakingError::NotInitialized)?;
        TokenClient::new(&e, &agusd).transfer(&e.current_contract_address(), &from, &p.assets);
        e.storage().persistent().remove(&key);
        UnstakeClaimed {
            staker: from,
            assets: p.assets,
        }
        .publish(&e);
        Ok(p.assets)
    }

    /// Strategist delivers yield: transfers agUSD into the vault and raises the
    /// NAV. Every existing share appreciates proportionally, so there is
    /// nothing to claim by hand and no rebasing.
    ///
    /// Named for the convention Agama committed to. The distributor is the
    /// stored admin and authorizes the call itself, so the agUSD comes out of
    /// an account that signed for it: this cannot mint value, only move it in.
    pub fn distribute_yield(e: Env, amount: i128) -> Result<(), StakingError> {
        let admin: Address = e.storage().instance().get(&Cfg::Admin).unwrap();
        admin.require_auth();
        if amount <= 0 {
            return Err(StakingError::InvalidAmount);
        }
        let agusd: Address = e
            .storage()
            .instance()
            .get(&Cfg::AgUsd)
            .ok_or(StakingError::NotInitialized)?;
        TokenClient::new(&e, &agusd).transfer(&admin, &e.current_contract_address(), &amount);
        let nav = Self::nav(e.clone());
        e.storage().instance().set(&Cfg::Nav, &(nav + amount));
        YieldDistributed {
            amount,
            nav: nav + amount,
            supply: tok::total_supply(&e),
        }
        .publish(&e);
        Ok(())
    }

    /// Record the off-chain "Kiro" liquidity-strategy allocations (UI display only).
    pub fn set_allocations(e: Env, allocations: Vec<Allocation>) {
        let admin: Address = e.storage().instance().get(&Cfg::Admin).unwrap();
        admin.require_auth();
        e.storage().instance().set(&Cfg::Allocations, &allocations);
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
    pub fn propose_admin(e: Env, admin: Address, new_admin: Address) -> Result<(), StakingError> {
        Self::require_admin(&e, &admin)?;
        e.storage().instance().set(&Cfg::PendingAdmin, &new_admin);
        tok::bump_instance(&e);
        AdminProposed { new_admin }.publish(&e);
        Ok(())
    }

    /// Complete a handover. Only the proposed address can call it, and it has
    /// to authorize the call itself: that authorization is the entire point of
    /// the second step.
    pub fn accept_admin(e: Env, new_admin: Address) -> Result<(), StakingError> {
        let pending: Address = e
            .storage()
            .instance()
            .get(&Cfg::PendingAdmin)
            .ok_or(StakingError::NoPendingAdmin)?;
        if pending != new_admin {
            return Err(StakingError::NotPendingAdmin);
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
    pub fn nav(e: Env) -> i128 {
        e.storage().instance().get(&Cfg::Nav).unwrap_or(0)
    }
    pub fn total_shares(e: Env) -> i128 {
        tok::total_supply(&e)
    }
    /// agUSD per sagUSD share, scaled to 7 decimals (ONE = 1.0). Starts at 1.0
    /// and only ever moves with the NAV, which is what makes yield passive.
    ///
    /// This is the assets-per-share view under the name Agama committed to. It
    /// is the canonical one; `share_price` below is an alias.
    pub fn exchange_rate(e: Env) -> i128 {
        let supply = tok::total_supply(&e);
        if supply == 0 {
            ONE
        } else {
            Self::nav(e.clone()) * ONE / supply
        }
    }

    /// Alias of [`Staking::exchange_rate`], under the name this contract
    /// carried before it took the DeFindex one.
    ///
    /// Kept rather than renamed away because it has a live on-chain caller:
    /// the generation 1 agUSD contract (`contracts/agusd`) prices its
    /// positions in the six deployed credit vaults through `share_price`, and
    /// those vaults are instances of this contract. One computation, two
    /// names, no second source of truth.
    pub fn share_price(e: Env) -> i128 {
        Self::exchange_rate(e)
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

    /// One place that writes a pending record, so there is one place that can
    /// forget to extend it.
    fn write_pending(e: &Env, addr: &Address, p: &Pending) {
        let key = Store::Pending(addr.clone());
        e.storage().persistent().set(&key, p);
        e.storage()
            .persistent()
            .extend_ttl(&key, PENDING_LIFETIME, PENDING_BUMP);
    }

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
mod fuzz;
