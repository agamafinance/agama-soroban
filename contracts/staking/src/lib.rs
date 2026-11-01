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
//! One correction, recorded here because the claim is checkable and somebody
//! will check it. DeFindex's own vault does not publish functions
//! under either of these names. Its interface is multi-asset
//! (`fetch_total_managed_funds`, `get_asset_amounts_per_shares`,
//! `distribute_fees`, and strategy level `harvest`), it exposes no scalar
//! price-per-share getter at all, and it has no vault level yield distribution
//! entry point. So this is a naming convention Agama has adopted on its own
//! side, matching DeFindex's economics: shares are never rebased, nothing is
//! pushed to holders, and a position appreciates because the assets behind each
//! share grow.
//!
//! Call compatibility is a separate thing, and this contract now has it as well:
//! `get_asset_amounts_per_shares` and `fetch_total_managed_funds` are
//! implemented below under DeFindex's own signatures, with its two model structs
//! replicated field for field. Verified against `defindex-io/stellar-contracts`,
//! the live repository, in October 2026; `paltalabs/defindex` was archived in
//! July 2026 and the two agree on both signatures and both structs.
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
//! of moving real money into the contract would mean two entry points a reader
//! has to check instead of one.
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
    contract, contracterror, contractevent, contractclient, contractimpl, contracttype,
    token::TokenClient, Address, Env, String, Vec,
};
use token as tok;

/// A strategy's slice of one asset, as DeFindex's vault reports it.
///
/// Replicated field for field from `defindex-io/stellar-contracts`,
/// `vault/src/models.rs`, so a caller that already decodes a
/// DeFindex vault's answer decodes this one. sagUSD runs no strategies, so the
/// vector of these is always empty; the type exists because the shape of the
/// reply is part of the interface, not because sagUSD has anything to put in it.
#[contracttype]
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct StrategyAllocation {
    pub strategy_address: Address,
    pub amount: i128,
    pub paused: bool,
}

/// One asset's position in the vault, as DeFindex's vault reports it.
///
/// Also replicated field for field. For sagUSD there is exactly one asset,
/// agUSD, and all of it is idle: nothing is deployed into a strategy from here.
/// Capital that leaves the protocol leaves through the Vault and the Allocation
/// Engine, which are different contracts and not strategies of this one.
#[contracttype]
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct CurrentAssetInvestmentAllocation {
    pub asset: Address,
    pub total_amount: i128,
    pub idle_amount: i128,
    pub invested_amount: i128,
    pub strategy_allocations: Vec<StrategyAllocation>,
}

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

/// The smallest first stake this contract will take, one agUSD.
///
/// With an empty supply the first staker is issued shares one for one, so a
/// first stake of one stroop sets the share price at one stroop and every price
/// after it is measured from there. A distribution into that supply then raises
/// the price by the whole distributed amount: a later stake under the new price
/// rounds to no shares and is refused by `ZeroShares`, and one over it loses the
/// truncation to the incumbent. One stroop of capital buying the right to price
/// everybody else out is the defect, and the minimum is what removes it.
///
/// A minimum rather than the virtual offset an ERC-4626 vault uses, and the
/// reason is arithmetic that is already load bearing here: `exchange_rate` is
/// `nav * ONE / supply` and the Vault, `get_asset_amounts_per_shares` and three
/// on-chain suites compare against exactly that. An offset makes the reported
/// rate stop being that ratio. The minimum leaves the ratio alone and reaches
/// the same place: at a first stake of one agUSD, pricing a 1000 agUSD stake
/// down to zero shares needs the price raised past 1e10, which means donating
/// ten billion agUSD to a pool holding one.
pub const MIN_FIRST_STAKE: i128 = ONE;

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
    /// The agUSD offered counts stroops differently from the sagUSD this
    /// contract issues, so the exchange rate would not start at one.
    DecimalMismatch = 811,
    /// The share token offered does not name this contract as its admin, so
    /// this contract could not mint a share through it.
    SharesMismatch = 812,
    /// A stake or an unstake before `set_shares` named the token to issue.
    SharesNotSet = 813,
    /// The first stake into an empty supply was under `MIN_FIRST_STAKE`. See
    /// that constant for why one stroop is not an acceptable opening price.
    FirstStakeTooSmall = 814,
    /// `set_agusd` found agUSD on this contract that nothing accounts for, and
    /// could not move it to the admin to clear the way for the repoint.
    StrayBalanceStuck = 815,
    /// `migrate_to` was called with nothing to carry. A handover of an empty
    /// book is a handover of the share token alone, which is the one thing this
    /// call must never be usable for.
    NothingToCarry = 816,
    /// The successor names a different agUSD, so the position it would adopt is
    /// denominated in something other than what backs it.
    SuccessorTokenMismatch = 817,
    /// `adopt` was called on a contract that has already taken a stake, or that
    /// already carries a supply. Adopting on top of either would mix two books
    /// into one share price.
    NotAdoptable = 818,
    /// `adopt` ran before the share token's admin was handed over, so the
    /// adopting contract could not mint or burn for the holders it just took on.
    AdoptBeforeHandover = 819,
    /// The backing transferred with an adoption is less than the NAV it claims,
    /// so the position would be short from its first ledger.
    AdoptUnderfunded = 820,
    /// This generation handed its book to a successor. It holds nothing, issues
    /// nothing, and the holders it used to serve are served there.
    AlreadyMigrated = 821,
}

/// The sagUSD share token, as seen from here.
///
/// A Stellar Asset Contract, so that sagUSD is a classic Stellar asset as well
/// as a Soroban one and the classic orderbook can hold it. The entry points are
/// the SAC's own; note what is absent, because it shapes this contract: a SAC
/// publishes no total supply. There is no call to read one, so the share count
/// is kept here and moved by hand on every mint and burn.
#[contractclient(name = "SharesClient")]
pub trait ShareToken {
    fn mint(e: Env, to: Address, amount: i128);
    fn burn(e: Env, from: Address, amount: i128);
    fn balance(e: Env, id: Address) -> i128;
    fn decimals(e: Env) -> u32;
    /// The address whose authorization `mint` requires. `set_shares` reads it,
    /// because a contract that points at a token which does not name it back
    /// is a contract whose `stake` cannot issue a share.
    fn admin(e: Env) -> Address;
    /// Hand the mint authority on. A Stellar Asset Contract takes this from its
    /// current admin, which is this contract, and that is what makes a
    /// generation handover possible at all: the holders keep the same asset and
    /// a different contract starts honouring it.
    fn set_admin(e: Env, new_admin: Address);
}

/// A successor staking generation, as seen from the one handing over.
#[contractclient(name = "SuccessorClient")]
pub trait Successor {
    fn agusd(e: Env) -> Address;
    fn adopt(e: Env, predecessor: Address, shares_token: Address, supply: i128, nav: i128);
}

/// Emitted when a generation hands its share token and position to a successor.
///
/// Carries the backing as well as the NAV, because the two are not the same
/// number and the difference is the stray surplus that moved with the book.
#[contractevent]
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct BookMigrated {
    pub successor: Address,
    pub shares: Address,
    pub supply: i128,
    pub nav: i128,
    pub backing: i128,
}

/// Emitted by the successor, from inside the same transaction.
///
/// Both sides publish, so a reader reconciling the handover has the predecessor's
/// account of what it sent and the successor's account of what it found, rather
/// than one contract's word for both.
#[contractevent]
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct BookAdopted {
    pub predecessor: Address,
    pub shares: Address,
    pub supply: i128,
    pub nav: i128,
    pub backing: i128,
}

/// Emitted when an exit inside the cooldown was priced at the rate the position
/// entered at rather than the current one.
///
/// In the stream because it is money a staker expected and did not get, and the
/// difference between the two numbers is exactly what stayed with the holders
/// who were there for the distribution. A holder who sees this should be able to
/// read why without asking anybody.
#[contractevent]
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct EarlyExitPricedAtEntry {
    #[topic]
    pub staker: Address,
    pub shares: i128,
    pub at_entry: i128,
    pub at_current: i128,
}

/// Emitted when `set_agusd` finds agUSD on this contract that nothing accounts
/// for and moves it to the admin to clear the way for the repoint.
///
/// It is in the stream because a sweep moves somebody's money, even if that
/// somebody sent it here with no claim on it: a donation with no claimant is
/// still a transfer out of this contract, and the one thing worse than an
/// unexplained balance is an unexplained balance that quietly left.
#[contractevent]
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct StrayBalanceSwept {
    #[topic]
    pub token: Address,
    pub amount: i128,
    pub to: Address,
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
    /// The sagUSD share token: a Stellar Asset Contract this contract is the
    /// admin of, rather than a balance ledger kept in here.
    Shares,
    /// Shares issued less shares burned, counted here because a Stellar Asset
    /// Contract publishes no total supply and there is nothing to read it from.
    Supply,
    Nav,
    Cooldown,
    Allocations,
    Stakes,
    /// Half finished admin handover: proposed, not yet accepted.
    PendingAdmin,
    /// The sum of every unclaimed `Pending`, kept because the individual
    /// records are per address and nothing could add them up.
    ///
    /// `request_unstake` takes its assets out of the NAV immediately and leaves
    /// the agUSD here to pay the claim with, so the balance held is the NAV plus
    /// this. Without the aggregate a handover would carry the whole balance to a
    /// successor, including money that is already somebody else's, and every
    /// pending claim here would become unpayable.
    PendingTotal,
    /// Set once this generation has handed its book to a successor. Nothing
    /// after that point may stake, unstake or distribute here: the share token
    /// answers to the successor, so a mint from here would fail and a burn
    /// would destroy somebody's balance without paying for it.
    Migrated,
}

#[derive(Clone)]
#[contracttype]
enum Store {
    Pending(Address),
    /// When a staker last staked and the share price they staked at. Read by
    /// `request_unstake` to decide whether an exit is being priced on
    /// appreciation the position was present for. Absent for anybody who
    /// staked before this was recorded, which is read as "long ago": the cap
    /// below must not reach backwards into positions that predate it.
    Entry(Address),
}

/// A staker's entry point into the pool.
#[derive(Clone)]
#[contracttype]
pub struct Entry {
    pub staked_at: u64,
    /// `exchange_rate` at the moment of the stake, which is the price the
    /// shares were bought at.
    pub rate: i128,
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
    /// No share token yet, and that is not an oversight.
    ///
    /// The share token has to name this contract as its admin, and this
    /// contract has no address until the deploy that runs this constructor has
    /// finished. So the order is fixed by the chain: deploy, hand the token's
    /// admin over to the address that comes back, then `set_shares`. The same
    /// shape as the Vault and its agUSD, for the same reason.
    pub fn __constructor(
        e: Env,
        admin: Address,
        agusd: Address,
        cooldown_seconds: u64,
    ) -> Result<(), StakingError> {
        admin.require_auth();
        e.storage().instance().set(&Cfg::Admin, &admin);
        e.storage().instance().set(&Cfg::AgUsd, &agusd);
        e.storage().instance().set(&Cfg::Nav, &0i128);
        e.storage().instance().set(&Cfg::Supply, &0i128);
        e.storage().instance().set(&Cfg::Cooldown, &cooldown_seconds);
        tok::bump_instance(&e);
        Ok(())
    }

    /// Name the token this contract issues shares in, before anybody has staked.
    ///
    /// Guarded the way the Vault guards `set_agusd`, and for the failure that
    /// actually happened there: a contract pointed at a token it cannot mint is
    /// a contract whose `stake` reverts, and the cheapest way to rule that out
    /// is to ask the token who its admin is and refuse any answer but this
    /// address.
    ///
    /// Shut once a stake has been taken. Shares outstanding are denominated in
    /// this token, and repointing underneath them would leave holders with a
    /// balance in a token this contract no longer burns.
    pub fn set_shares(e: Env, admin: Address, shares_token: Address) -> Result<(), StakingError> {
        Self::require_admin(&e, &admin)?;
        Self::require_live(&e)?;
        if Self::stakes(e.clone()) > 0 {
            return Err(StakingError::CustodyTaken);
        }
        let shares = SharesClient::new(&e, &shares_token);
        match shares.try_admin() {
            Ok(Ok(a)) if a == e.current_contract_address() => {}
            _ => return Err(StakingError::SharesMismatch),
        }
        // Both sides have to count stroops the same way, for the reason spelled
        // out under `set_agusd`: the first staker is priced one for one, so a
        // mismatch makes an exchange rate of 1.0 not one to one in value.
        let agusd: Address = e
            .storage()
            .instance()
            .get(&Cfg::AgUsd)
            .ok_or(StakingError::NotInitialized)?;
        let theirs = match TokenClient::new(&e, &agusd).try_decimals() {
            Ok(Ok(d)) => d,
            _ => return Err(StakingError::DecimalMismatch),
        };
        match shares.try_decimals() {
            Ok(Ok(d)) if d == theirs => {}
            _ => return Err(StakingError::DecimalMismatch),
        }
        e.storage().instance().set(&Cfg::Shares, &shares_token);
        tok::bump_instance(&e);
        Ok(())
    }

    /// The share token, or `SharesNotSet` if `set_shares` has not run.
    pub fn shares(e: Env) -> Result<Address, StakingError> {
        e.storage()
            .instance()
            .get(&Cfg::Shares)
            .ok_or(StakingError::SharesNotSet)
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
        Self::require_live(&e)?;
        if Self::stakes(e.clone()) > 0 || Self::nav(e.clone()) != 0 {
            return Err(StakingError::CustodyTaken);
        }
        let current: Address = e
            .storage()
            .instance()
            .get(&Cfg::AgUsd)
            .ok_or(StakingError::NotInitialized)?;
        // A stray balance is swept, not treated as custody.
        //
        // This read used to refuse the repoint outright, which handed anybody a
        // permanent veto over it: one stroop of the current agUSD sent to this
        // address, by a stranger, for the cost of a transaction, and the pointer
        // that decides what every future share is a claim on could never move
        // again. The two checks above already establish that nothing is owed,
        // `stakes` at zero meaning nothing was ever staked and `nav` at zero
        // meaning nothing was ever distributed, and with no stake there can be
        // no pending unstake either. So a balance here is a donation with no
        // claimant, and the right thing is to move it out of the way rather than
        // to let it wedge the contract.
        //
        // It goes to the admin, who is authorizing this call and is the only
        // address this contract knows. If it cannot be moved, the repoint is
        // refused with a code that says which of the two it was, instead of
        // reporting a grief as custody.
        let stray = TokenClient::new(&e, &current).balance(&e.current_contract_address());
        if stray > 0 {
            match TokenClient::new(&e, &current).try_transfer(
                &e.current_contract_address(),
                &admin,
                &stray,
            ) {
                Ok(Ok(())) => StrayBalanceSwept {
                    token: current.clone(),
                    amount: stray,
                    to: admin.clone(),
                }
                .publish(&e),
                _ => return Err(StakingError::StrayBalanceStuck),
            }
        }
        // And it has to count stroops the way sagUSD does.
        //
        // The first staker gets shares one for one, raw stroop for raw stroop,
        // and every share price after that is measured from there. Accept an
        // agUSD with different decimals and the exchange rate this contract
        // reports as 1.0 is not one to one in value, and nothing downstream can
        // tell, because the internal arithmetic stays perfectly consistent in
        // stroops. It is the same check the Vault makes on the token it mints,
        // for the same reason: an integer ratio is only a price while both
        // sides agree what the integers mean.
        // Measured against the share token rather than against a decimals
        // field kept in here, because the share token is what the rate is
        // denominated in now.
        if let Ok(shares_token) = Self::shares(e.clone()) {
            let mine = match SharesClient::new(&e, &shares_token).try_decimals() {
                Ok(Ok(d)) => d,
                _ => return Err(StakingError::DecimalMismatch),
            };
            match TokenClient::new(&e, &agusd).try_decimals() {
                Ok(Ok(d)) if d == mine => {}
                _ => return Err(StakingError::DecimalMismatch),
            }
        }
        e.storage().instance().set(&Cfg::AgUsd, &agusd);
        tok::bump_instance(&e);
        AgUsdRepointed { agusd }.publish(&e);
        Ok(())
    }

    /// Hand this generation's share token and its whole position to a successor.
    ///
    /// This exists because of a finding, and the finding was that there was no
    /// way out. A replacement generation starts its supply at zero, nothing in
    /// here lets an admin seed one, and a holder redeeming against a supply of
    /// zero divides by it. So retiring a generation meant every holder
    /// unstaking first, and any holder who stopped answering pinned every
    /// future fix behind them indefinitely. Three accounts holding 8.19 sagUSD
    /// did exactly that and cost a generation that had to be deployed beside
    /// the old one rather than in place of it.
    ///
    /// The handover is the whole position and nothing less: the agUSD backing
    /// moves first, then the share token's mint authority, and only then does
    /// the successor book what it now owns. A holder does nothing and notices
    /// nothing. Their sagUSD is the same asset, with the same issuer, and a
    /// different contract honours it.
    ///
    /// The order matters and it is not interchangeable. Backing before
    /// authority, because a contract that can mint a share it cannot pay for is
    /// worse than one that can pay for shares it cannot mint. Authority before
    /// `adopt`, because `adopt` refuses to book a position on a token that does
    /// not already name it. And this generation closes last, so a failure
    /// anywhere above leaves it still able to serve its holders.
    pub fn migrate_to(e: Env, admin: Address, successor: Address) -> Result<(), StakingError> {
        Self::require_admin(&e, &admin)?;
        Self::require_live(&e)?;
        let supply = Self::total_supply(e.clone());
        let nav = Self::nav(e.clone());
        // An empty book has no position to carry, and a handover of nothing is
        // a handover of the share token alone. That is the one use this call
        // must not have: it would let an admin move the mint authority for an
        // asset holders are still holding, with no obligation following it.
        if supply <= 0 || nav <= 0 {
            return Err(StakingError::NothingToCarry);
        }
        let shares = Self::shares(e.clone())?;
        let agusd: Address = e
            .storage()
            .instance()
            .get(&Cfg::AgUsd)
            .ok_or(StakingError::NotInitialized)?;
        // The successor has to be denominated in the same token. Asked of the
        // successor rather than assumed, because a position carried into a
        // contract that prices in something else is a position whose share
        // price is wrong from its first ledger and right in nobody's books.
        let succ = SuccessorClient::new(&e, &successor);
        match succ.try_agusd() {
            Ok(Ok(a)) if a == agusd => {}
            _ => return Err(StakingError::SuccessorTokenMismatch),
        }
        // Everything held, not just the NAV. A stray surplus belongs with the
        // position it accumulated against, and leaving it here would strand it
        // in a contract that can no longer pay anybody.
        // Everything except what is already owed to somebody who asked to
        // leave before this was called. Their claim was priced and their shares
        // burned at request time, so the agUSD behind it is theirs and not part
        // of the book being carried. Carrying it would leave them with a claim
        // against a contract holding nothing.
        let owed: i128 = e
            .storage()
            .instance()
            .get(&Cfg::PendingTotal)
            .unwrap_or(0i128);
        let held = TokenClient::new(&e, &agusd).balance(&e.current_contract_address());
        let carry = held - owed;
        if carry < nav {
            return Err(StakingError::AdoptUnderfunded);
        }
        TokenClient::new(&e, &agusd).transfer(&e.current_contract_address(), &successor, &carry);
        SharesClient::new(&e, &shares).set_admin(&successor);
        succ.adopt(&e.current_contract_address(), &shares, &supply, &nav);
        e.storage().instance().set(&Cfg::Migrated, &true);
        e.storage().instance().set(&Cfg::Supply, &0i128);
        e.storage().instance().set(&Cfg::Nav, &0i128);
        tok::bump_instance(&e);
        BookMigrated {
            successor,
            shares,
            supply,
            nav,
            backing: carry,
        }
        .publish(&e);
        Ok(())
    }

    /// Take on a predecessor's share token and position.
    ///
    /// Called by the predecessor inside `migrate_to`, never by a person, and it
    /// checks the two things the predecessor cannot be trusted to have done:
    /// that the share token already names this contract as its admin, and that
    /// the backing arrived before the claim on it was booked.
    pub fn adopt(
        e: Env,
        predecessor: Address,
        shares_token: Address,
        supply: i128,
        nav: i128,
    ) -> Result<(), StakingError> {
        predecessor.require_auth();
        Self::require_live(&e)?;
        // A fresh generation only. Adopting onto a contract that already has a
        // book would merge two share prices into one, and every holder on both
        // sides would be repriced without having done anything.
        if Self::stakes(e.clone()) > 0 || Self::total_supply(e.clone()) != 0 {
            return Err(StakingError::NotAdoptable);
        }
        if supply <= 0 || nav <= 0 {
            return Err(StakingError::NothingToCarry);
        }
        let shares = SharesClient::new(&e, &shares_token);
        match shares.try_admin() {
            Ok(Ok(a)) if a == e.current_contract_address() => {}
            _ => return Err(StakingError::AdoptBeforeHandover),
        }
        let agusd: Address = e
            .storage()
            .instance()
            .get(&Cfg::AgUsd)
            .ok_or(StakingError::NotInitialized)?;
        match TokenClient::new(&e, &agusd).try_decimals() {
            Ok(Ok(d)) => match shares.try_decimals() {
                Ok(Ok(sd)) if sd == d => {}
                _ => return Err(StakingError::DecimalMismatch),
            },
            _ => return Err(StakingError::DecimalMismatch),
        }
        // The claim is only booked against backing that is already here. Read
        // from the token rather than taken on the predecessor's word, which is
        // the difference between an adoption and an assertion.
        let held = TokenClient::new(&e, &agusd).balance(&e.current_contract_address());
        if held < nav {
            return Err(StakingError::AdoptUnderfunded);
        }
        e.storage().instance().set(&Cfg::Shares, &shares_token);
        e.storage().instance().set(&Cfg::Supply, &supply);
        e.storage().instance().set(&Cfg::Nav, &nav);
        tok::bump_instance(&e);
        BookAdopted {
            predecessor,
            shares: shares_token,
            supply,
            nav,
            backing: held,
        }
        .publish(&e);
        Ok(())
    }

    /// The agUSD held here that is already owed to pending claims.
    ///
    /// Held balance less this is what backs the share price, and it is what a
    /// handover carries. Readable because a depositor comparing the contract's
    /// balance to its NAV would otherwise find a surplus that is not one.
    pub fn pending_total(e: Env) -> i128 {
        e.storage()
            .instance()
            .get(&Cfg::PendingTotal)
            .unwrap_or(0i128)
    }

    /// Whether this generation has handed its book on.
    pub fn migrated(e: Env) -> bool {
        e.storage().instance().get(&Cfg::Migrated).unwrap_or(false)
    }

    /// Stake agUSD, mint sagUSD shares at the current share price.
    pub fn stake(e: Env, from: Address, amount: i128) -> Result<i128, StakingError> {
        from.require_auth();
        Self::require_live(&e)?;
        if amount <= 0 {
            return Err(StakingError::InvalidAmount);
        }
        // Read before the transfer, and refuse before it. Both numbers come out
        // of instance storage rather than off a balance, so reading them here
        // is the same read it was below; what changes is that an opening stake
        // this contract will not accept is now refused before it has taken the
        // money, instead of after.
        let nav = Self::nav(e.clone());
        let supply = Self::total_supply(e.clone());
        if supply == 0 && amount < MIN_FIRST_STAKE {
            return Err(StakingError::FirstStakeTooSmall);
        }
        let agusd: Address = e
            .storage()
            .instance()
            .get(&Cfg::AgUsd)
            .ok_or(StakingError::NotInitialized)?;
        TokenClient::new(&e, &agusd).transfer(&from, &e.current_contract_address(), &amount);

        let shares = if supply == 0 || nav == 0 {
            amount
        } else {
            amount * supply / nav
        };
        if shares <= 0 {
            return Err(StakingError::ZeroShares);
        }
        let shares_token = Self::shares(e.clone())?;
        SharesClient::new(&e, &shares_token).mint(&from, &shares);
        e.storage().instance().set(&Cfg::Supply, &(supply + shares));
        e.storage().instance().set(&Cfg::Nav, &(nav + amount));
        e.storage()
            .instance()
            .set(&Cfg::Stakes, &(Self::stakes(e.clone()) + 1));
        // The Vault extends its instance TTL on every one of its user paths and
        // this contract extended it on none of them, so a contract nobody
        // configured for ninety days could archive itself while people were
        // still staking in it. Four paths move value here and all four bump now.
        tok::bump_instance(&e);
        // The price this position was bought at, and when. See `request_unstake`
        // for what it is for. Written after the mint, so the rate it records is
        // the one the stake has already been priced into, which is the same
        // number as before it: staking at the current rate does not move the
        // rate, and that is the property this relies on.
        Self::write_entry(
            &e,
            &from,
            &Entry {
                staked_at: e.ledger().timestamp(),
                rate: Self::exchange_rate(e.clone()),
            },
        );
        Staked {
            staker: from,
            assets: amount,
            shares,
            nav: Self::nav(e.clone()),
            supply: Self::total_supply(e.clone()),
        }
        .publish(&e);
        Ok(shares)
    }

    /// Request to unstake `shares`: burns the shares now, locks the agUSD owed
    /// behind the cooldown. Claimable via `claim` after the cooldown elapses.
    pub fn request_unstake(e: Env, from: Address, shares: i128) -> Result<i128, StakingError> {
        from.require_auth();
        Self::require_live(&e)?;
        if shares <= 0 {
            return Err(StakingError::InvalidAmount);
        }
        let supply = Self::total_supply(e.clone());
        if supply == 0 {
            return Err(StakingError::NoSupply);
        }
        let nav = Self::nav(e.clone());
        let mut assets = shares * nav / supply;

        // An exit inside the cooldown is priced at no better than the price it
        // entered at.
        //
        // The cooldown delays the cash and it did not delay the pricing, so the
        // two were different guards and only one of them was there. Stake, wait
        // for `distribute_yield`, request immediately: the shares appreciated
        // for the whole distribution while the capital was present for a block
        // of it, and the cooldown then made the sniper wait for money they had
        // already been credited with. Every other holder paid for that, because
        // a distribution is a fixed amount divided by a supply that just grew.
        //
        // So a short held position cannot leave on a rate above the one it
        // arrived at. The difference stays in `nav`, which means it stays with
        // the holders who were actually there, rather than being burned or
        // skimmed somewhere. The cap is one sided on purpose: a position whose
        // price **fell** inside the window takes that loss at the current rate,
        // because protecting it from a fall would be the same unfairness
        // pointing the other way.
        //
        // Measured against the feed's own cooldown rather than a new constant.
        // If the protocol's answer to "how long is too short to be paid" is the
        // cooldown, then it is the same number here, and a deployment that
        // changes one changes both.
        //
        // Two deliberate limits. A staker with no entry recorded is read as
        // having staked long ago and is not capped, so this cannot reach back
        // into a position that predates it. And a top-up re-arms the window for
        // the whole position rather than for the amount added, which is the
        // conservative direction and costs a long-term holder who tops up the
        // appreciation of one cooldown; pricing each tranche separately is a
        // lot of per-staker state for a small gain, and the state is the thing
        // this contract is careful with.
        if let Some(en) = e
            .storage()
            .persistent()
            .get::<Store, Entry>(&Store::Entry(from.clone()))
        {
            let cooldown: u64 = e.storage().instance().get(&Cfg::Cooldown).unwrap();
            if e.ledger().timestamp() < en.staked_at.saturating_add(cooldown) {
                let capped = shares * en.rate / ONE;
                if capped < assets {
                    EarlyExitPricedAtEntry {
                        staker: from.clone(),
                        shares,
                        at_entry: capped,
                        at_current: assets,
                    }
                    .publish(&e);
                    assets = capped;
                }
            }
        }

        let shares_token = Self::shares(e.clone())?;
        SharesClient::new(&e, &shares_token).burn(&from, &shares);
        e.storage().instance().set(&Cfg::Supply, &(supply - shares));
        e.storage().instance().set(&Cfg::Nav, &(nav - assets));
        let owed: i128 = e
            .storage()
            .instance()
            .get(&Cfg::PendingTotal)
            .unwrap_or(0i128);
        e.storage().instance().set(&Cfg::PendingTotal, &(owed + assets));

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
        tok::bump_instance(&e);
        UnstakeRequested {
            staker: from,
            shares,
            assets,
            claimable_at: p.claimable_at,
            nav: Self::nav(e.clone()),
            supply: Self::total_supply(e.clone()),
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
        // The claim is paid, so it stops being owed. Decremented here and
        // nowhere else: `bump_pending` moves a horizon and pays nobody, and an
        // earlier version of this counter was decremented there instead, which
        // reported the contract as holding a surplus it did not have.
        let owed: i128 = e
            .storage()
            .instance()
            .get(&Cfg::PendingTotal)
            .unwrap_or(0i128);
        // Floored, because a contract deployed before this counter existed
        // starts it at zero with claims already in flight, and going negative
        // would be worse than undercounting.
        e.storage()
            .instance()
            .set(&Cfg::PendingTotal, &(owed - p.assets).max(0));
        e.storage().persistent().remove(&key);
        tok::bump_instance(&e);
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
        Self::require_live(&e)?;
        let admin: Address = e.storage().instance().get(&Cfg::Admin).unwrap();
        admin.require_auth();
        if amount <= 0 {
            return Err(StakingError::InvalidAmount);
        }
        // Nothing to distribute to. Raising the NAV over an empty supply does
        // not make anybody richer: it sets the opening share price to the whole
        // distributed amount, and the next staker to arrive takes all of it for
        // whatever they put in. The yield has to wait for somebody to own a
        // share of it, and refusing is how it waits. Checked before the
        // transfer, so a refused distribution has not moved the admin's money.
        if Self::total_supply(e.clone()) == 0 {
            return Err(StakingError::NoSupply);
        }
        let agusd: Address = e
            .storage()
            .instance()
            .get(&Cfg::AgUsd)
            .ok_or(StakingError::NotInitialized)?;
        TokenClient::new(&e, &agusd).transfer(&admin, &e.current_contract_address(), &amount);
        let nav = Self::nav(e.clone());
        e.storage().instance().set(&Cfg::Nav, &(nav + amount));
        tok::bump_instance(&e);
        YieldDistributed {
            amount,
            nav: nav + amount,
            supply: Self::total_supply(e.clone()),
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
        Self::total_supply(e)
    }
    /// agUSD per sagUSD share, scaled to 7 decimals (ONE = 1.0). Starts at 1.0
    /// and only ever moves with the NAV, which is what makes yield passive.
    ///
    /// This is the assets-per-share view under the name Agama committed to. It
    /// is the canonical one; `share_price` below is an alias.
    pub fn exchange_rate(e: Env) -> i128 {
        let supply = Self::total_supply(e.clone());
        if supply == 0 {
            ONE
        } else {
            Self::nav(e.clone()) * ONE / supply
        }
    }

    /// How much of each underlying asset `vault_shares` are worth, in
    /// DeFindex's own entry point and under its own signature.
    ///
    /// `exchange_rate` above is a scalar and a convention Agama named itself.
    /// This is the call a DeFindex-integrated wallet actually makes, taken from
    /// `defindex-io/stellar-contracts`, `vault/src/interface.rs`:
    ///
    /// ```ignore
    /// fn get_asset_amounts_per_shares(e: Env, vault_shares: i128)
    ///     -> Result<Vec<i128>, ContractError>;
    /// ```
    ///
    /// One asset, so one element: the agUSD those shares redeem for. It is
    /// deliberately the same arithmetic as `request_unstake`, truncating toward
    /// zero, rather than the scalar rate multiplied out. A wallet that showed a
    /// number the contract would not pay would be worse than one that showed
    /// nothing, and multiplying a rounded rate by a share count reintroduces
    /// exactly that gap: the rate itself is already a quotient.
    ///
    /// Zero shares are worth zero. A negative count is not a question, so it
    /// answers `InvalidAmount` rather than a negative amount.
    pub fn get_asset_amounts_per_shares(
        e: Env,
        vault_shares: i128,
    ) -> Result<Vec<i128>, StakingError> {
        if vault_shares < 0 {
            return Err(StakingError::InvalidAmount);
        }
        let supply = Self::total_supply(e.clone());
        let assets = if supply == 0 || vault_shares == 0 {
            0
        } else {
            vault_shares * Self::nav(e.clone()) / supply
        };
        Ok(Vec::from_array(&e, [assets]))
    }

    /// The vault's position per underlying asset, in DeFindex's entry point and
    /// under its shape.
    ///
    /// One asset, agUSD, and all of it idle. sagUSD holds the agUSD staked with
    /// it and deploys none of it: what leaves the protocol leaves through the
    /// Vault and the Allocation Engine, which are separate contracts and not
    /// strategies of this one, so `invested_amount` is zero and
    /// `strategy_allocations` is empty rather than a summary of somebody else's
    /// book.
    ///
    /// `total_amount` is the NAV this contract accounts for, not its token
    /// balance. The two differ by any agUSD owed to a pending unstake, which has
    /// already left the NAV and not yet left the contract, and by anything sent
    /// here without staking.
    pub fn fetch_total_managed_funds(e: Env) -> Vec<CurrentAssetInvestmentAllocation> {
        let nav = Self::nav(e.clone());
        let agusd: Address = e.storage().instance().get(&Cfg::AgUsd).unwrap();
        Vec::from_array(
            &e,
            [CurrentAssetInvestmentAllocation {
                asset: agusd,
                total_amount: nav,
                idle_amount: nav,
                invested_amount: 0,
                strategy_allocations: Vec::new(&e),
            }],
        )
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

    // ---- share token views ----
    //
    // Transfer, approve, allowance and transfer_from are gone from here. They
    // belong to the share token now, and a shadow copy on this contract would
    // be a second answer to a question the ledger already answers, free to
    // disagree with it.

    /// Delegated, so it is the token's own answer rather than a second ledger.
    pub fn balance(e: Env, id: Address) -> i128 {
        match Self::shares(e.clone()) {
            Ok(t) => SharesClient::new(&e, &t).balance(&id),
            Err(_) => 0,
        }
    }

    pub fn decimals(e: Env) -> u32 {
        match Self::shares(e.clone()) {
            Ok(t) => SharesClient::new(&e, &t).decimals(),
            Err(_) => 0,
        }
    }

    /// Shares issued less shares burned, as counted here.
    ///
    /// Kept rather than read, because a Stellar Asset Contract publishes no
    /// total supply and there is no call that would return one. Only this
    /// contract can mint, so the count cannot be low. It can be high: a holder
    /// may call `burn` on the share token directly and destroy shares without
    /// unstaking, which this contract has no way to observe. That direction is
    /// the safe one. A supply read too high prices every share too low, so
    /// redemptions pay less than the assets behind them and the surplus stays
    /// in the contract; it can never pay out more than it holds. The indexer
    /// can see what this contract cannot, by comparing Horizon's figure for the
    /// classic asset against this one.
    pub fn total_supply(e: Env) -> i128 {
        e.storage().instance().get(&Cfg::Supply).unwrap_or(0)
    }

    // ---- internals ----

    /// One place that writes a pending record, so there is one place that can
    /// forget to extend it.
    fn write_entry(e: &Env, addr: &Address, en: &Entry) {
        let key = Store::Entry(addr.clone());
        e.storage().persistent().set(&key, en);
        e.storage()
            .persistent()
            .extend_ttl(&key, PENDING_LIFETIME, PENDING_BUMP);
    }

    fn write_pending(e: &Env, addr: &Address, p: &Pending) {
        let key = Store::Pending(addr.clone());
        e.storage().persistent().set(&key, p);
        e.storage()
            .persistent()
            .extend_ttl(&key, PENDING_LIFETIME, PENDING_BUMP);
    }

    /// Refuse anything that mints, burns or reprices after a handover.
    ///
    /// The share token answers to the successor from that moment, so a mint
    /// here fails and, worse, a burn here would destroy a holder's balance
    /// without this contract having anything to pay them with.
    fn require_live(e: &Env) -> Result<(), StakingError> {
        if e.storage()
            .instance()
            .get(&Cfg::Migrated)
            .unwrap_or(false)
        {
            return Err(StakingError::AlreadyMigrated);
        }
        Ok(())
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
