#![no_std]
//! Vault contract, the entry point for capital.
//!
//! USDC comes in, agUSD goes out 1:1, and the USDC stays here until the
//! Allocation Engine instructs a release. The Vault is the protocol's only
//! custodian: the Engine decides nothing about custody and holds nothing, it
//! calls `settle_allocation` and the funds move from here.
//!
//! # Deposits and withdrawals are asymmetric on purpose
//!
//! Depositing is instant, because taking cash in is always possible.
//! Withdrawing is two steps, `request_withdrawal` then `claim_withdrawal`,
//! because the assets backing agUSD are private credit positions that settle in
//! D+15 to D+90. A vault that promised instant redemption against that book
//! would be promising something it can only honour while nobody asks.
//!
//! agUSD is a synthetic dollar, not a yield-bearing share: a withdrawal returns
//! one USDC per agUSD burned. Yield accrues to sagUSD, in the staking contract,
//! by share price appreciation. NAV from the Oracle Adapter is therefore read
//! for reporting and monitoring, not applied to the redemption rate.
//!
//! # The queue is strictly first in, first out
//!
//! Claims are numbered in the order they are requested and paid in that order.
//! `claim_withdrawal` refuses anything that is not at the head of the queue,
//! and there is no admin path around it: a protocol that can reorder its own
//! withdrawal queue under stress has not really got one.
//!
//! FIFO does not depend on the head claimant showing up, though.
//! `settle_withdrawal` pays whichever claim sits at `queue_head` to the owner
//! recorded on it, and any address may call it. That is not a privileged path
//! around the ordering, because the caller chooses neither the claim nor the
//! recipient: both are read from the queue rather than supplied, so the only
//! thing calling `settle_withdrawal` can do is what the owner's own
//! `claim_withdrawal` would have done. Without it, one 1 agUSD claim whose
//! owner simply never returns freezes every withdrawal behind it forever, and
//! the attacker keeps their agUSD.
//!
//! That covered the claimant who will not come back. It did not cover the
//! claimant who cannot be paid, which is worse, because the owner cannot fix it
//! by showing up either. The Vault's USDC is a Stellar Asset Contract over a
//! classic asset, so a payout fails whenever the destination has no trustline,
//! has had it frozen by the issuer, has a limit below the claim, or no longer
//! exists, and a failed payout used to trap the whole call and leave the head
//! pointer where it was. One USDC and a lowered trustline limit stopped every
//! withdrawal in the protocol permanently. `settle_withdrawal` now attempts the
//! delivery instead of assuming it: if the token refuses, the claim is marked
//! deferred and stepped over, unpaid and still owed, and its owner collects it
//! through `claim_withdrawal` whenever the obstruction is gone. A deferred
//! claim loses its place in the queue, which is a real cost and falls on the
//! only party who can do anything about the cause of it.
//!
//! # A queued claim is a liability, and the Vault counts it
//!
//! `request_withdrawal` burns the agUSD immediately and leaves the USDC here,
//! so between the request and the payment the money is still on the Vault's
//! balance but is no longer anybody's to lend out. `outstanding_liabilities`
//! is the running total of it, and `free_reserves` is what is left after
//! subtracting it. Every limit that asks how much capital may be deployed is
//! measured against free reserves and net assets, never against the gross
//! balance, because the gross balance counts money that has already been
//! promised to somebody.
//!
//! # The two pointers that decide whether the Vault works at all
//!
//! `initialize` writes the agUSD address and the Allocation Engine address,
//! and the Vault is not upgradeable, so both of them used to be one way doors.
//! Both of them have now been through one: the first Vault pointed at a token
//! with no `mint` and could never issue agUSD, and the second pointed at an
//! Engine that governs a different Vault and could never release a dollar of
//! capital. Each mistake cost a redeployment, and because the token names the
//! Vault as its only minter, the second one cost two contracts rather than
//! one.
//!
//! `set_agusd` and `set_engine` are that lesson. Both are admin gated, for the
//! same reason re-initialization is blocked: between them they are the
//! authority to mint against the Vault's reserves and the authority to release
//! them. Both stop working once the contract holds state that the move would
//! invalidate, which is the only version of a setter worth having on a
//! custodian. For agUSD that line is the first deposit, because repointing a
//! Vault that has already issued agUSD would strand the holders against a
//! token it no longer mints. For the Engine it is capital this Vault has
//! released and not seen back, because the USDC behind it is out in the pool
//! adapters and only the Engine that put it there can call it back.
//!
//! # The Vault does not trust the Engine for its own solvency
//!
//! `set_engine` asks the incoming address whether it governs this Vault, and
//! that check is worth having, but it is worth exactly what it can prove, which
//! is less than it looks. Any contract can answer the question correctly: forty
//! lines that store one address, return it from `vault()`, return zero from
//! `total_allocated()` and expose a `steal()` that calls `settle_allocation`
//! pass it without difficulty. A guard that interrogates a counterparty can
//! rule out an address that cannot answer, and nothing more.
//!
//! So the Vault stopped relying on it. `settle_allocation` used to release USDC
//! on the Engine's say-so and check nothing itself, on the reasoning that
//! duplicating the Engine's limits would mean two implementations that can
//! disagree. That reasoning was wrong in one specific way: it is the Vault that
//! holds the money, so it is the Vault that has to be the last word on how much
//! of it may leave. The Vault now keeps three numbers of its own, none of them
//! read from the Engine:
//!
//!  - `deployed_capital`, incremented by every release it performs and reduced
//!    only by a repayment it can see in its own balance or by an admin
//!    authorized write-down
//!  - `outstanding_liabilities`, the queued withdrawals it already owes
//!  - `recognised_losses`, everything it has written off, which never falls
//!  - `reserve_floor_bps`, its own copy of the floor, admin set and fail closed
//!    at 100% until it is configured
//!
//! and `settle_allocation` refuses any release that would take free reserves
//! below that floor, or below the queued claims, whoever is asking. An honest
//! Engine never meets this check, because it applies the same arithmetic to the
//! same book one call earlier. A hostile one meets it on the first call and
//! cannot get past it on any subsequent one, because the Vault's own record of
//! what it has released is not something the Engine can rewrite.
//!
//! The floor is a share of `floor_base`, not of net assets, and the difference
//! between those two is the whole of the second review's first finding.
//! `record_writedown` lowers `deployed_capital` with no cash moving, so a floor
//! measured against net assets is a floor whose absolute size the admin can
//! lower at will: allocate to the floor, write the position down, and the floor
//! has come down with it. Forty rounds of that took all but one stroop of a
//! 1000 USDC book out of a Vault holding a 25% floor, with every individual
//! call inside the limit and the pool adapter keeping every dollar. Recognised
//! losses therefore stay in the base for good, which makes a write-down buy
//! nothing, and which is also the more honest base: agUSD redeems one for one,
//! so a default does not reduce by a stroop what this Vault owes.
//!
//! # What the admin can still do, stated plainly
//!
//! None of that makes the admin harmless, and this contract does not pretend
//! otherwise. V1 allocation is admin directed: the admin sets the caps and the
//! reserve floor, chooses which pools are registered, and decides how much goes
//! to each. An admin willing to register a pool it controls can move up to what
//! the floor releases to itself, and the floor is a limit on the size of that,
//! not a prohibition. What protects depositors from the admin is the
//! multi-signature admin in V1 and governance with a timelock in V2, not a
//! guard in this file. What the guards here protect is everything else: the
//! withdrawal queue cannot be reordered or stalled, agUSD cannot be minted by
//! anyone but this Vault, the reserve floor holds against any Engine, and no
//! counterparty pointer can be moved into a state that silently misreports the
//! book.
//!
//! # Circuit breaker
//!
//! `set_paused` blocks deposits, withdrawal requests and new allocations. It
//! does not block payouts, and that asymmetry is deliberate: by the time a
//! claim is in the queue the agUSD backing it has already been burned, so a
//! pause that stopped payments would leave a user holding neither the token nor
//! the cash for as long as the admin chose. Stopping the flows that create new
//! obligations is what a circuit breaker is for; refusing to honour the
//! obligations already recorded is something else. It does not touch the
//! staking contract or the Oracle Adapter either: during an incident, NAV
//! reporting is exactly what should keep running.

use soroban_sdk::{
    contract, contractclient, contracterror, contractevent, contractimpl, contracttype,
    token::TokenClient, Address, Env, Symbol,
};

const BPS: i128 = 10_000;

const DAY_LEDGERS: u32 = 17_280;
const INSTANCE_BUMP: u32 = 30 * DAY_LEDGERS;
const INSTANCE_LIFETIME: u32 = INSTANCE_BUMP - DAY_LEDGERS;
// Claims sit in the queue until the positions behind them settle, which for
// private credit runs to 90 days, so they get the longest TTL in the protocol.
const CLAIM_BUMP: u32 = 90 * DAY_LEDGERS;
const CLAIM_LIFETIME: u32 = CLAIM_BUMP - DAY_LEDGERS;

/// Anti-dust floor on withdrawals: 1 agUSD, at 7 decimals.
///
/// Every request costs a persistent storage entry and a slot in a queue that
/// is paid strictly in order, so a stream of one-stroop requests is a cheap
/// way to push real withdrawals behind thousands of dust claims. The floor
/// makes that attack cost the attacker as much as it costs everyone else.
pub const MIN_WITHDRAWAL: i128 = 10_000_000;

/// agUSD, as seen from the Vault. The Vault is the token's admin, so it is the
/// only address that can mint against a deposit or burn against a withdrawal.
#[contractclient(name = "AgUsdClient")]
pub trait ShareToken {
    fn mint(e: Env, to: Address, amount: i128);
    fn burn(e: Env, from: Address, amount: i128);
    fn balance(e: Env, id: Address) -> i128;
}

/// The Allocation Engine, as seen from the Vault.
#[contractclient(name = "EngineClient")]
pub trait AllocationEngineInterface {
    fn total_allocated(e: Env) -> i128;
    /// The Vault the Engine governs. `set_engine` reads it to tell an Engine
    /// whose exposure book is this Vault's capital from one whose book belongs
    /// to a different Vault entirely.
    fn vault(e: Env) -> Address;
}

/// The Oracle Adapter, as seen from the Vault. `get_nav` fails rather than
/// returning a stale number, and the Vault lets that failure propagate.
#[contractclient(name = "OracleClient")]
pub trait OracleInterface {
    fn get_nav(e: Env, feed_id: Symbol) -> i128;
}

#[contracterror]
#[derive(Copy, Clone, Debug, Eq, PartialEq)]
#[repr(u32)]
pub enum VaultError {
    AlreadyInitialized = 300,
    NotInitialized = 301,
    NotAdmin = 302,
    /// The circuit breaker is on.
    Paused = 303,
    /// Zero or negative amount.
    InvalidAmount = 304,
    /// Withdrawal below the anti-dust minimum.
    BelowMinWithdrawal = 305,
    ClaimNotFound = 306,
    NotClaimOwner = 307,
    AlreadyClaimed = 308,
    /// The claim is not at the head of the FIFO queue yet.
    NotAtQueueHead = 309,
    /// The claim is at the head but the Vault does not hold enough idle USDC.
    InsufficientLiquidity = 310,
    /// `set_oracle` has not been called yet.
    OracleNotConfigured = 311,
    /// The Vault has already taken a deposit, so its agUSD is fixed.
    DepositsExist = 312,
    /// The Engine the Vault currently points at holds a non-empty exposure
    /// book funded by this Vault, so the pointer cannot move.
    CapitalDeployed = 313,
    /// The proposed Allocation Engine does not answer that it governs this
    /// Vault, so it cannot be given the authority to release its reserves.
    EngineMismatch = 314,
    /// `settle_withdrawal` was called with nothing queued to pay.
    QueueEmpty = 315,
    /// The release would take free reserves below the Vault's own floor.
    ReserveFloorBreached = 316,
    /// A repayment was reported that the Vault cannot see in its own balance.
    RepaymentNotReceived = 317,
    /// More was written down or repaid than the Vault has recorded as deployed.
    DeployedUnderflow = 318,
    /// A floor outside 0 to 10000 bps.
    InvalidFloor = 319,
    /// `accept_admin` was called with no handover in flight.
    NoPendingAdmin = 320,
    /// `accept_admin` was called by an address that was not the one proposed.
    NotPendingAdmin = 321,
    /// The Vault holds the cash and tried to send it, and the token refused to
    /// deliver it to the claim's owner.
    PaymentRejected = 322,
}

/// A queued withdrawal. The agUSD is burned at request time, so this record is
/// the user's only claim on the USDC and has to be durable.
#[derive(Clone, Debug, Eq, PartialEq)]
#[contracttype]
pub struct Claim {
    pub owner: Address,
    pub amount: i128,
    pub requested_at: u64,
    pub claimed: bool,
}

/// Where a claim stands. `Ready` is derived rather than stored: a claim is
/// ready exactly when it is at the head of the queue and the Vault holds the
/// cash, and both of those change without anyone touching the claim.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
#[contracttype]
pub enum ClaimStatus {
    Pending,
    Ready,
    Claimed,
}

/// Instance storage: addresses, the pause flag and the two queue pointers.
#[derive(Clone)]
#[contracttype]
enum Cfg {
    Admin,
    Usdc,
    AgUsd,
    Engine,
    Oracle,
    OracleFeed,
    Paused,
    QueueHead,
    QueueTail,
    Deposits,
    /// The Vault's own copy of the reserve floor, in bps of net assets. Fail
    /// closed at 10000 until an admin sets it.
    FloorBps,
    /// USDC this Vault has released to pools and not seen come back. Kept here
    /// rather than read from the Engine because it is the denominator of the
    /// Vault's own floor check, and a number the Engine can rewrite is not a
    /// constraint on the Engine.
    Deployed,
    /// USDC owed to queued withdrawal claims that have burned their agUSD and
    /// not been paid.
    Queued,
    /// The idle balance the Vault can account for from its own flows: deposits
    /// in, claims and releases out, repayments recorded. Anything the real
    /// balance holds above this arrived without the Vault being told, which is
    /// exactly what a pool repayment looks like from in here, and is what
    /// `record_repayment` is checked against.
    Booked,
    /// Deployed capital written off since deployment, cumulative and never
    /// reduced. It is not an asset and it is not counted as one; it stays on
    /// the books because it is the denominator of the reserve floor, and a
    /// denominator a write-down can shrink is a floor a write-down can walk
    /// through.
    WrittenOff,
    /// Half finished admin handover: proposed, not yet accepted.
    PendingAdmin,
}

/// Persistent storage: the claim records, keyed by claim id, and the flag that
/// marks one the queue has stepped over.
#[derive(Clone)]
#[contracttype]
enum Store {
    Claim(u64),
    /// Set on a claim `settle_withdrawal` could not deliver. The claim is still
    /// owed and still counted; what it has lost is its place in the queue.
    Deferred(u64),
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
pub struct Vault;

#[contractimpl]
impl Vault {
    /// Wire the Vault to its token contracts and to the Allocation Engine.
    ///
    /// Re-initialization is rejected. Without that guard, anyone able to call
    /// `initialize` a second time could repoint `agusd_token` at a contract
    /// they control and mint against the Vault's reserves.
    pub fn initialize(
        e: Env,
        admin: Address,
        usdc_token: Address,
        agusd_token: Address,
        allocation_engine: Address,
    ) -> Result<(), VaultError> {
        if e.storage().instance().has(&Cfg::Admin) {
            return Err(VaultError::AlreadyInitialized);
        }
        admin.require_auth();
        e.storage().instance().set(&Cfg::Admin, &admin);
        e.storage().instance().set(&Cfg::Usdc, &usdc_token);
        e.storage().instance().set(&Cfg::AgUsd, &agusd_token);
        e.storage().instance().set(&Cfg::Engine, &allocation_engine);
        e.storage().instance().set(&Cfg::Paused, &false);
        // Claim ids start at 1 so that 0 can never be a valid claim.
        e.storage().instance().set(&Cfg::QueueHead, &1u64);
        e.storage().instance().set(&Cfg::QueueTail, &1u64);
        // Fail closed, the same way the Engine does: a Vault that has been
        // deployed but not yet given a floor releases nothing at all, so a
        // forgotten configuration step cannot be mistaken for an intended one.
        e.storage().instance().set(&Cfg::FloorBps, &(BPS as u32));
        Self::bump_instance(&e);
        Ok(())
    }

    /// Set the share of net assets the Vault will not release, in bps.
    ///
    /// This is the Vault's own copy of the number the Engine also enforces, and
    /// the duplication is the point rather than an oversight. The Engine checks
    /// it because it is the contract that decides whether an allocation is a
    /// good idea; the Vault checks it because it is the contract that holds the
    /// money, and an invariant enforced only by the party asking for the funds
    /// is not an invariant. The two are set to the same number at deployment;
    /// if they ever differ, the tighter of them is what actually binds, which is
    /// the safe direction for them to differ in.
    pub fn set_reserve_floor(e: Env, admin: Address, floor_bps: u32) -> Result<(), VaultError> {
        Self::require_admin(&e, &admin)?;
        if floor_bps as i128 > BPS {
            return Err(VaultError::InvalidFloor);
        }
        e.storage().instance().set(&Cfg::FloorBps, &floor_bps);
        Self::bump_instance(&e);
        ReserveFloorSet { floor_bps }.publish(&e);
        Ok(())
    }

    /// Point the Vault at the Oracle Adapter and the feed it reads NAV from.
    ///
    /// Separate from `initialize` because the two contracts ship in different
    /// tranches: the Vault has to be deployable and usable before the Oracle
    /// Adapter exists. Until this is called, `get_nav` returns
    /// `OracleNotConfigured` rather than a made up number.
    pub fn set_oracle(
        e: Env,
        admin: Address,
        oracle: Address,
        feed_id: Symbol,
    ) -> Result<(), VaultError> {
        Self::require_admin(&e, &admin)?;
        e.storage().instance().set(&Cfg::Oracle, &oracle);
        e.storage().instance().set(&Cfg::OracleFeed, &feed_id);
        Self::bump_instance(&e);
        Ok(())
    }

    /// Point the Vault at a different agUSD contract, before it has taken any
    /// money.
    ///
    /// The Vault deployed before this one did not have this, which made the
    /// token pointer a one way door: `initialize` writes the address, every
    /// deposit mints through it, and the contract is not upgradeable, so a
    /// token that turns out to expose no `mint` costs a whole redeployment.
    /// This setter is that lesson, and it is admin gated for the same reason
    /// re-initialization is blocked: repointing agUSD is the authority to mint
    /// against the Vault's reserves.
    ///
    /// It stops working at the first deposit, and that limit is the point. A
    /// Vault repointed while agUSD is outstanding would leave holders backed
    /// by a token it no longer mints or burns, and they would find out at the
    /// withdrawal queue. Before the first deposit there is nothing to strand.
    pub fn set_agusd(e: Env, admin: Address, agusd_token: Address) -> Result<(), VaultError> {
        Self::require_admin(&e, &admin)?;
        if Self::deposits(e.clone()) > 0 {
            return Err(VaultError::DepositsExist);
        }
        e.storage().instance().set(&Cfg::AgUsd, &agusd_token);
        Self::bump_instance(&e);
        AgUsdRepointed {
            agusd: agusd_token,
        }
        .publish(&e);
        Ok(())
    }

    /// Point the Vault at a different Allocation Engine, while no capital of
    /// this Vault's is deployed.
    ///
    /// This is the setter whose absence cost the protocol a whole generation
    /// of contracts. `settle_allocation` is the only way USDC leaves the Vault
    /// other than a withdrawal claim, and it authorizes the Engine address
    /// written by `initialize`. A Vault wired to an Engine that turns out to
    /// govern a different Vault can therefore never deploy a single dollar: a
    /// replacement Engine, however correctly configured, is not the address
    /// the Vault will accept a release from. That is not a misconfiguration
    /// that can be corrected, it is a redeployment, and because the token this
    /// Vault mints names the Vault as its only minter, the redeployment is two
    /// contracts, not one.
    ///
    /// The guard is the same shape as `set_agusd`: the pointer moves only while
    /// nothing depends on it. Here that means this Vault must have no capital
    /// out at a pool. If it has, the USDC is in the adapters and only the Engine
    /// that put it there can call it back, so repointing would leave the Vault's
    /// own book carrying capital nobody it points at can unwind.
    ///
    /// That question is answered from the Vault's own `deployed_capital`, not
    /// by asking the outgoing Engine. Asking it was the previous version of this
    /// guard and it got the important case right for the wrong reason: an Engine
    /// that governs some other Vault has a real, non-empty book, none of which
    /// is this Vault's money, and this Vault is free to leave. Reading the local
    /// counter says that directly, and it also cannot be lied to by an Engine
    /// that would rather not be replaced.
    ///
    /// The replacement has to answer that it governs this Vault.
    /// `settle_allocation` hands the Vault's USDC to whatever this pointer
    /// names, so without that check the setter would be a one call instruction
    /// to release the reserves to an ordinary account: an account has no
    /// `vault()` to answer with, so it cannot be named here.
    ///
    /// What that check does not do is tell an Engine from a contract pretending
    /// to be one. A hostile contract answers `vault()` with whatever address it
    /// was built to answer, and `total_allocated()` with whatever number suits
    /// it, so it passes every interrogation this function could run. Asking for
    /// both, and requiring the book to be empty, raises the cost of writing the
    /// impostor from forty lines to fifty. It is worth doing because it catches
    /// the realistic case, which is a mis-wiring rather than an attack, and it
    /// is not worth believing in: what actually bounds a hostile Engine is that
    /// `settle_allocation` enforces the reserve floor itself, against the
    /// Vault's own numbers, whoever is calling.
    ///
    /// It does not make the admin harmless and it is not sold as doing so. An
    /// admin can register a pool of its own choosing with the Engine and
    /// allocate to it, up to the floor; V1 allocation is admin directed by
    /// construction, and what protects depositors from the admin is the
    /// multi-signature admin and the timelock on the roadmap, not a check in
    /// this function.
    pub fn set_engine(
        e: Env,
        admin: Address,
        allocation_engine: Address,
    ) -> Result<(), VaultError> {
        Self::require_admin(&e, &admin)?;
        if !e.storage().instance().has(&Cfg::Engine) {
            return Err(VaultError::NotInitialized);
        }
        // This Vault's own record of what it has released and not seen back.
        // Nothing else is consulted: the outgoing Engine has no say in whether
        // it is replaced.
        if Self::deployed_capital(e.clone()) > 0 {
            return Err(VaultError::CapitalDeployed);
        }

        // The replacement must answer both halves of the Engine interface, and
        // must arrive with an empty book: an Engine already carrying exposure
        // is one whose caps were measured against somebody else's balance
        // sheet. Neither condition proves the address is honest, and neither is
        // relied on for that.
        let incoming = EngineClient::new(&e, &allocation_engine);
        match (incoming.try_vault(), incoming.try_total_allocated()) {
            (Ok(Ok(governed)), Ok(Ok(booked)))
                if governed == e.current_contract_address() && booked == 0 => {}
            _ => return Err(VaultError::EngineMismatch),
        }

        e.storage().instance().set(&Cfg::Engine, &allocation_engine);
        Self::bump_instance(&e);
        EngineRepointed {
            engine: allocation_engine,
        }
        .publish(&e);
        Ok(())
    }

    /// Circuit breaker. Blocks deposits, withdrawal requests and new
    /// allocations; leaves payouts, staking and NAV reporting untouched.
    ///
    /// Payouts are deliberately outside it. `request_withdrawal` burns the
    /// agUSD as it queues the claim, so a paused payout path leaves the holder
    /// with no token and no cash, for as long as the admin leaves the switch on.
    /// A breaker that stops new obligations being created is a breaker; one
    /// that also refuses to honour the obligations already on the books is a
    /// freeze, and it is not what this switch is for.
    pub fn set_paused(e: Env, admin: Address, paused: bool) -> Result<(), VaultError> {
        Self::require_admin(&e, &admin)?;
        e.storage().instance().set(&Cfg::Paused, &paused);
        Self::bump_instance(&e);
        PauseToggled { paused }.publish(&e);
        Ok(())
    }

    /// Deposit USDC and receive agUSD 1:1. Returns the amount minted.
    ///
    /// The USDC lands before the agUSD is minted, so a token transfer that
    /// fails for any reason (insufficient balance, missing trustline, a frozen
    /// account) fails the whole call rather than minting against money that
    /// never arrived.
    ///
    /// 1:1 is the right rate because agUSD is a synthetic dollar, not a share
    /// in the book. Yield reaches holders through sagUSD's share price, not
    /// through a moving deposit rate, which is what keeps agUSD usable as a
    /// unit of account in the pools it is composed into.
    pub fn deposit(e: Env, from: Address, amount: i128) -> Result<i128, VaultError> {
        Self::require_not_paused(&e)?;
        from.require_auth();
        if amount <= 0 {
            return Err(VaultError::InvalidAmount);
        }
        let usdc = Self::usdc(e.clone())?;
        let agusd = Self::agusd(e.clone())?;

        TokenClient::new(&e, &usdc).transfer(&from, &e.current_contract_address(), &amount);
        AgUsdClient::new(&e, &agusd).mint(&from, &amount);
        e.storage()
            .instance()
            .set(&Cfg::Deposits, &(Self::deposits(e.clone()) + 1));
        Self::add_booked(&e, amount);
        Self::bump_instance(&e);

        Deposit {
            user: from,
            amount,
            minted: amount,
        }
        .publish(&e);
        Ok(amount)
    }

    /// Burn agUSD now, join the withdrawal queue, and return the claim id.
    ///
    /// The agUSD is burned at request time rather than at claim time. That is
    /// what makes the queue meaningful: once the tokens are gone the holder
    /// cannot sell, stake or re-request the same position while waiting, and
    /// the supply already reflects the exit. The claim record is from then on
    /// the user's only title to the USDC, which is why it is persistent and
    /// TTL bumped for 90 days rather than kept in temporary storage.
    ///
    /// The queue is a pair of monotonic pointers rather than a list: `tail` is
    /// the next id to hand out, `head` is the next id that may be paid. Two
    /// integers cannot be reordered, which is a cheaper guarantee of FIFO than
    /// any structure that would have to be walked.
    pub fn request_withdrawal(e: Env, from: Address, amount: i128) -> Result<u64, VaultError> {
        Self::require_not_paused(&e)?;
        from.require_auth();
        if amount <= 0 {
            return Err(VaultError::InvalidAmount);
        }
        if amount < MIN_WITHDRAWAL {
            return Err(VaultError::BelowMinWithdrawal);
        }
        let agusd = Self::agusd(e.clone())?;
        AgUsdClient::new(&e, &agusd).burn(&from, &amount);

        let claim_id = Self::queue_tail(e.clone());
        let claim = Claim {
            owner: from.clone(),
            amount,
            requested_at: e.ledger().timestamp(),
            claimed: false,
        };
        Self::write_claim(&e, claim_id, &claim);
        e.storage().instance().set(&Cfg::QueueTail, &(claim_id + 1));
        // The USDC behind this claim is still on the balance sheet but is no
        // longer free: the agUSD that entitled anyone else to it has just been
        // burned. Recording it here is what keeps the reserve floor measuring
        // liquidity the protocol can actually deploy.
        Self::set_queued(&e, Self::outstanding_liabilities(e.clone()) + amount);
        Self::bump_instance(&e);

        WithdrawalRequested {
            user: from,
            claim_id,
            amount,
            queue_position: claim_id - Self::queue_head(e.clone()),
        }
        .publish(&e);
        Ok(claim_id)
    }

    /// Pay a claim that is at the head of the queue and covered by idle
    /// reserves.
    ///
    /// Four checks, and the third is the one that matters: the claim must be
    /// at `queue_head`. Not "near the head", not "the oldest ready claim", not
    /// "the head unless the admin says otherwise". There is no privileged path
    /// through this function, which is the only version of a FIFO queue worth
    /// having: one that cannot be reordered by whoever is running the protocol
    /// on the day it is under stress.
    ///
    /// The head advances only when a claim is paid or stepped over. If its
    /// owner never returns to call this, `settle_withdrawal` is how the queue
    /// moves on without them: same recipient, same amount, same position,
    /// different caller.
    ///
    /// There is a second door into this function, and it is not a way round the
    /// ordering. A claim `settle_withdrawal` could not deliver is marked
    /// deferred and left unpaid, and its owner collects it here whenever the
    /// obstruction is gone, which by then is no longer at the head. Only a
    /// claim the queue has already stepped over can arrive that way, only its
    /// recorded owner can take it, and it can only be taken once.
    ///
    /// If the token refuses to deliver, this call fails rather than deferring.
    /// The owner is the party who can fix a missing trustline, a frozen one or
    /// one whose limit is too low, so the owner is the party who should be told
    /// about it, by a named error rather than a trap.
    pub fn claim_withdrawal(e: Env, from: Address, claim_id: u64) -> Result<(), VaultError> {
        from.require_auth();

        let claim = Self::read_claim(&e, claim_id)?;
        if claim.owner != from {
            return Err(VaultError::NotClaimOwner);
        }
        if claim.claimed {
            return Err(VaultError::AlreadyClaimed);
        }
        let at_head = claim_id == Self::queue_head(e.clone());
        let deferred = Self::is_deferred(e.clone(), claim_id);
        if !at_head && !deferred {
            return Err(VaultError::NotAtQueueHead);
        }
        if !Self::deliver(&e, claim_id, claim)? {
            return Err(VaultError::PaymentRejected);
        }
        if deferred {
            e.storage().persistent().remove(&Store::Deferred(claim_id));
        } else {
            e.storage().instance().set(&Cfg::QueueHead, &(claim_id + 1));
        }
        Self::bump_instance(&e);
        Ok(())
    }

    /// Pay the claim at the head of the queue to its recorded owner, and
    /// advance the queue. Callable by anyone, on behalf of no one.
    ///
    /// This is `claim_withdrawal` with both levers taken away from the caller.
    /// There is no `claim_id` argument, so nothing can be pointed at a claim
    /// other than the one already at `queue_head`, and the payment always goes
    /// to `claim.owner`, never to whoever sent the transaction. Redirecting
    /// funds or jumping the queue would need this function to accept a target
    /// it does not accept, so the only thing it can be used for is doing, for a
    /// stalled claimant, exactly what they could have done for themselves.
    ///
    /// That is what makes it safe to leave unauthenticated, and leaving it
    /// unauthenticated is what fixes the queue. Before it existed, the head
    /// holder had a veto over everyone behind them and exercised it by doing
    /// nothing: one claim at the anti-dust minimum, never claimed, froze every
    /// withdrawal in the protocol for as long as its owner cared to wait, and
    /// the owner kept the agUSD's worth of USDC at the end of it.
    ///
    /// # The head that cannot be paid, rather than will not
    ///
    /// Paying the head is a token transfer, and the Vault's USDC is a Stellar
    /// Asset Contract over a classic asset, so the transfer fails whenever the
    /// destination account has no trustline for USDC, has had it frozen by the
    /// issuer, has a limit below the claim, or no longer exists. Any one of
    /// those used to trap the whole invocation, which meant the head never
    /// advanced and every withdrawal behind it stopped for good, with no admin
    /// path around it because there deliberately is not one. It cost an
    /// attacker one USDC and a lowered trustline limit, and it happened by
    /// accident the first time an issuer froze a claimant.
    ///
    /// So delivery is attempted rather than assumed. If the token refuses, this
    /// call writes nothing about the payment, marks the claim deferred,
    /// advances the head over it and says so in an event. The claim stays unpaid
    /// and stays counted in `outstanding_liabilities`, so its cash stays
    /// reserved and undeployable, and its owner collects it through
    /// `claim_withdrawal` once the obstruction is gone.
    ///
    /// The trade is real and it is worth stating: a deferred claim loses its
    /// place in the queue, so claims behind it may be paid first. That cost
    /// falls on the only party who can do anything about the cause of it, which
    /// is the right party to bear it, and the alternative is letting one
    /// unpayable claimant hold every other depositor hostage indefinitely.
    pub fn settle_withdrawal(e: Env) -> Result<u64, VaultError> {
        let claim_id = Self::queue_head(e.clone());
        if claim_id >= Self::queue_tail(e.clone()) {
            return Err(VaultError::QueueEmpty);
        }
        let claim = Self::read_claim(&e, claim_id)?;
        if claim.claimed {
            // Unreachable while the head pointer and the claimed flag are
            // written together, and checked anyway: the invariant that makes it
            // unreachable is the one an audit should not have to take on trust.
            return Err(VaultError::AlreadyClaimed);
        }
        let owner = claim.owner.clone();
        let amount = claim.amount;
        let delivered = Self::deliver(&e, claim_id, claim)?;
        e.storage().instance().set(&Cfg::QueueHead, &(claim_id + 1));
        if !delivered {
            Self::set_deferred(&e, claim_id);
            WithdrawalDeferred {
                user: owner,
                claim_id,
                amount,
            }
            .publish(&e);
        }
        Self::bump_instance(&e);
        Ok(claim_id)
    }

    /// Release idle USDC to a pool, on the Allocation Engine's instruction and
    /// within the Vault's own limits.
    ///
    /// The Engine has already checked the concentration caps and the reserve
    /// floor by the time this is called, and this function checks the floor
    /// again anyway. That is not a duplicated implementation for its own sake,
    /// it is where the invariant belongs. The Engine is the address this
    /// function authorizes, so "the Engine checked it" is only ever as good as
    /// the Engine, and `set_engine` cannot prove that an address that answers
    /// `vault()` correctly is the contract it claims to be. The Vault holds the
    /// USDC, so the Vault is the last word on how much of it may leave.
    ///
    /// Two limits, both measured against the Vault's own numbers:
    ///
    ///  - free reserves after the release cannot go negative. Queued claims
    ///    have already burned their agUSD and are owed this cash; lending it
    ///    out is how a claim becomes unpayable.
    ///  - free reserves after the release cannot fall below `reserve_floor_bps`
    ///    of `floor_base`, which is free reserves, plus the capital this Vault
    ///    has released and not seen back, plus everything it has ever written
    ///    off.
    ///
    /// The base is invariant under an allocation, which is what makes the second
    /// limit hold across repeated calls rather than only within one. A hostile
    /// Engine gets the first release an honest one would have been allowed, and
    /// then gets nothing, because `deployed_capital` went up by exactly what it
    /// took and is not a number the Engine can write.
    ///
    /// The write-off term is why the base is not simply net assets, and it is
    /// the whole of the second review's first finding. `record_writedown` is
    /// the one call that lowers `deployed_capital` with no cash moving, so if
    /// the floor were a percentage of net assets it would be a percentage of a
    /// number the admin can lower at will. Allocate to the floor, write the
    /// position down, and the floor has moved down with it; forty rounds of
    /// that took 999.9999999 of 1000 USDC out of a Vault holding a 25% floor
    /// while the adapter kept every dollar. Keeping recognised losses in the
    /// base makes a write-down buy exactly nothing.
    ///
    /// It is also the more correct base under a real default, which is the test
    /// of whether a guard is a hack. agUSD is redeemed one for one, so the
    /// protocol's nominal liability does not shrink when its assets do: a book
    /// that has just lost a quarter of itself owes precisely what it owed
    /// before and has less to pay it with, and the last thing it should do is
    /// conclude that it may now lend out more. New deposits raise the base and
    /// restore deployable headroom in the ordinary way, so this fails closed
    /// without stranding the contract.
    pub fn settle_allocation(e: Env, pool: Address, amount: i128) -> Result<(), VaultError> {
        let engine: Address = e
            .storage()
            .instance()
            .get(&Cfg::Engine)
            .ok_or(VaultError::NotInitialized)?;
        engine.require_auth();
        Self::require_not_paused(&e)?;
        if amount <= 0 {
            return Err(VaultError::InvalidAmount);
        }

        let free_after = Self::free_reserves(e.clone()) - amount;
        if free_after < 0 {
            return Err(VaultError::InsufficientLiquidity);
        }
        let deployed_after = Self::deployed_capital(e.clone()) + amount;
        let base = free_after + deployed_after + Self::recognised_losses(e.clone());
        if free_after * BPS < Self::reserve_floor_bps(e.clone()) as i128 * base {
            return Err(VaultError::ReserveFloorBreached);
        }

        let usdc = Self::usdc(e.clone())?;
        e.storage().instance().set(&Cfg::Deployed, &deployed_after);
        Self::add_booked(&e, -amount);
        Self::bump_instance(&e);
        TokenClient::new(&e, &usdc).transfer(&e.current_contract_address(), &pool, &amount);
        Ok(())
    }

    /// Record capital coming back from a pool, and take it off the Vault's
    /// deployed book.
    ///
    /// Called by the Engine, in the same transaction as the adapter's
    /// repayment, and not believed. The Vault compares its own idle balance
    /// against the balance it can account for from its own flows, and refuses
    /// any repayment larger than the difference. So the counter that bounds
    /// every future release can only be reduced by USDC that has genuinely
    /// arrived here, which is what stops an Engine from resetting its own
    /// limit and calling `settle_allocation` again.
    ///
    /// It also means the Engine's book cannot decrement against a repayment
    /// that went somewhere else: an adapter pointed at the wrong Vault fails
    /// this check, and the whole deallocation reverts rather than quietly
    /// writing off capital that is still outstanding.
    pub fn record_repayment(e: Env, amount: i128) -> Result<(), VaultError> {
        let engine: Address = e
            .storage()
            .instance()
            .get(&Cfg::Engine)
            .ok_or(VaultError::NotInitialized)?;
        engine.require_auth();
        if amount <= 0 {
            return Err(VaultError::InvalidAmount);
        }
        if amount > Self::deployed_capital(e.clone()) {
            return Err(VaultError::DeployedUnderflow);
        }
        let unaccounted = Self::idle_reserves(e.clone()) - Self::booked_reserves(e.clone());
        if amount > unaccounted {
            return Err(VaultError::RepaymentNotReceived);
        }

        e.storage()
            .instance()
            .set(&Cfg::Deployed, &(Self::deployed_capital(e.clone()) - amount));
        Self::add_booked(&e, amount);
        Self::bump_instance(&e);
        RepaymentRecorded {
            amount,
            deployed: Self::deployed_capital(e.clone()),
        }
        .publish(&e);
        Ok(())
    }

    /// Recognise that deployed capital is not coming back, and reduce the
    /// Vault's book by it without requiring the cash.
    ///
    /// This is the one path that lowers `deployed_capital` with nothing
    /// arriving, so it is the one path a hostile Engine would use to reset the
    /// limit that bounds `settle_allocation`. It therefore needs two
    /// authorizations, not one: the caller must be the Engine this Vault points
    /// at, and the Vault's own admin must have signed for it. An Engine cannot
    /// produce the second, which is what keeps the reserve floor standing
    /// against an Engine while still letting a real default be recognised.
    ///
    /// Recognising a loss is the honest action, not the suspicious one. Until
    /// it happens the Vault reports capital it does not have, and the reserve
    /// ratio is overstated by exactly the size of the loss.
    ///
    /// What the loss must not do is buy the caller anything. The amount is
    /// added to `recognised_losses`, which never falls, and which stays in the
    /// denominator of the reserve floor for the life of the contract. Without
    /// that, this call lowered the base the floor is a percentage of, so
    /// alternating `allocate` and `write_down` walked the whole of the reserves
    /// out of the Vault a slice at a time with every individual call inside the
    /// floor. Two authorizations were never going to be enough on their own,
    /// because both of them are the same key, and a guard that a legitimate
    /// operation and an attack pass identically is not a guard: the arithmetic
    /// has to be the thing that says no.
    pub fn record_writedown(e: Env, admin: Address, amount: i128) -> Result<(), VaultError> {
        let engine: Address = e
            .storage()
            .instance()
            .get(&Cfg::Engine)
            .ok_or(VaultError::NotInitialized)?;
        engine.require_auth();
        Self::require_admin(&e, &admin)?;
        if amount <= 0 {
            return Err(VaultError::InvalidAmount);
        }
        let deployed = Self::deployed_capital(e.clone());
        if amount > deployed {
            return Err(VaultError::DeployedUnderflow);
        }
        let losses = Self::recognised_losses(e.clone()) + amount;
        e.storage().instance().set(&Cfg::Deployed, &(deployed - amount));
        e.storage().instance().set(&Cfg::WrittenOff, &losses);
        Self::bump_instance(&e);
        WriteDownRecorded {
            amount,
            deployed: deployed - amount,
            recognised_losses: losses,
        }
        .publish(&e);
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
    pub fn propose_admin(e: Env, admin: Address, new_admin: Address) -> Result<(), VaultError> {
        Self::require_admin(&e, &admin)?;
        e.storage().instance().set(&Cfg::PendingAdmin, &new_admin);
        Self::bump_instance(&e);
        AdminProposed { new_admin }.publish(&e);
        Ok(())
    }

    /// Complete a handover. Only the proposed address can call it, and it has
    /// to authorize the call itself: that authorization is the entire point of
    /// the second step.
    pub fn accept_admin(e: Env, new_admin: Address) -> Result<(), VaultError> {
        let pending: Address = e
            .storage()
            .instance()
            .get(&Cfg::PendingAdmin)
            .ok_or(VaultError::NoPendingAdmin)?;
        if pending != new_admin {
            return Err(VaultError::NotPendingAdmin);
        }
        new_admin.require_auth();
        e.storage().instance().set(&Cfg::Admin, &new_admin);
        e.storage().instance().remove(&Cfg::PendingAdmin);
        Self::bump_instance(&e);
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

    /// USDC held by the Vault, gross. This is what claims are paid from, and
    /// it counts money already owed to the withdrawal queue, so it is not the
    /// quantity any deployment limit is measured against. `free_reserves` is.
    pub fn idle_reserves(e: Env) -> i128 {
        let Ok(usdc) = Self::usdc(e.clone()) else {
            return 0;
        };
        TokenClient::new(&e, &usdc).balance(&e.current_contract_address())
    }

    /// USDC owed to withdrawal claims that have burned their agUSD and have
    /// not been paid.
    ///
    /// This is a real liability that used to appear in no on-chain quantity at
    /// all. `request_withdrawal` burns the agUSD immediately, so the supply
    /// stops counting it; the USDC stays here, so the balance goes on counting
    /// it as free. Deposit 1000, queue all 1000, and the reserve ratio still
    /// read 10000 bps against a book that owed every stroop of it.
    pub fn outstanding_liabilities(e: Env) -> i128 {
        e.storage().instance().get(&Cfg::Queued).unwrap_or(0)
    }

    /// Idle reserves less what the withdrawal queue is owed: the cash the
    /// protocol may actually deploy. Never negative.
    pub fn free_reserves(e: Env) -> i128 {
        let free = Self::idle_reserves(e.clone()) - Self::outstanding_liabilities(e.clone());
        if free < 0 {
            0
        } else {
            free
        }
    }

    /// USDC this Vault has released to pools and not seen back, from its own
    /// records rather than the Engine's.
    ///
    /// It rises on every `settle_allocation` and falls in exactly two ways: a
    /// repayment the Vault can see in its own balance, or an admin authorized
    /// write-down. Reading it here rather than calling the Engine is what makes
    /// the reserve floor an actual constraint on the Engine.
    pub fn deployed_capital(e: Env) -> i128 {
        e.storage().instance().get(&Cfg::Deployed).unwrap_or(0)
    }

    /// The idle balance the Vault can account for from its own flows. Anything
    /// the real balance holds above this arrived unannounced, which is what a
    /// pool repayment looks like from in here.
    pub fn booked_reserves(e: Env) -> i128 {
        e.storage().instance().get(&Cfg::Booked).unwrap_or(0)
    }

    /// The share of net assets the Vault will not release, in bps.
    pub fn reserve_floor_bps(e: Env) -> u32 {
        e.storage()
            .instance()
            .get(&Cfg::FloorBps)
            .unwrap_or(BPS as u32)
    }

    /// Gross assets: idle reserves plus capital out at the pools. It counts the
    /// USDC owed to the withdrawal queue, because that money is still an asset
    /// of the Vault until it is paid. `get_net_assets` is the figure the floor
    /// and the caps use.
    pub fn get_total_assets(e: Env) -> Result<i128, VaultError> {
        if !e.storage().instance().has(&Cfg::Engine) {
            return Err(VaultError::NotInitialized);
        }
        Ok(Self::idle_reserves(e.clone()) + Self::deployed_capital(e))
    }

    /// Assets the queued withdrawals have no claim on: free reserves plus
    /// deployed capital. The honest measure of what the Vault is worth, and for
    /// that reason not the denominator of the reserve floor: see `floor_base`.
    pub fn get_net_assets(e: Env) -> Result<i128, VaultError> {
        if !e.storage().instance().has(&Cfg::Engine) {
            return Err(VaultError::NotInitialized);
        }
        Ok(Self::free_reserves(e.clone()) + Self::deployed_capital(e))
    }

    /// Deployed capital written off since deployment, cumulative. It only ever
    /// rises, and there is no entry point that lowers it.
    ///
    /// It is not an asset and `get_net_assets` correctly excludes it. It exists
    /// because the reserve floor needs a base that a write-down cannot move: a
    /// floor measured as a share of net assets is a floor whose absolute size
    /// falls every time the admin recognises a loss, real or otherwise, and
    /// that is enough to walk the whole of the reserves out of the contract in
    /// slices that are each individually within the floor.
    pub fn recognised_losses(e: Env) -> i128 {
        e.storage().instance().get(&Cfg::WrittenOff).unwrap_or(0)
    }

    /// The denominator `reserve_floor_bps` is a share of: net assets plus
    /// everything ever written off.
    ///
    /// Under a protocol that has never taken a loss this is exactly
    /// `get_net_assets`, which is the ordinary case and the one the deployed
    /// configuration is sized against. After a loss the two part company, and
    /// the floor keeps asking for a buffer against the book as it was rather
    /// than the book as it is. That is the conservative direction and it is
    /// also the correct one: agUSD redeems one for one, so a default does not
    /// reduce by one stroop what the Vault owes.
    pub fn floor_base(e: Env) -> Result<i128, VaultError> {
        Ok(Self::get_net_assets(e.clone())? + Self::recognised_losses(e))
    }

    /// NAV for the Vault's feed, straight from the Oracle Adapter. A stale feed
    /// surfaces here as the adapter's `OracleStale` error rather than as an old
    /// number, because the failure is propagated instead of swallowed.
    pub fn get_nav(e: Env) -> Result<i128, VaultError> {
        let oracle: Address = e
            .storage()
            .instance()
            .get(&Cfg::Oracle)
            .ok_or(VaultError::OracleNotConfigured)?;
        let feed_id: Symbol = e
            .storage()
            .instance()
            .get(&Cfg::OracleFeed)
            .ok_or(VaultError::OracleNotConfigured)?;
        Ok(OracleClient::new(&e, &oracle).get_nav(&feed_id))
    }

    pub fn get_claim(e: Env, claim_id: u64) -> Result<Claim, VaultError> {
        Self::read_claim(&e, claim_id)
    }

    /// Where a claim stands right now.
    ///
    /// `Ready` is computed rather than stored, because both conditions for it
    /// change without anyone touching the claim: the queue reaches it when the
    /// claim in front is paid, and the Vault becomes able to cover it when a
    /// pool repays. Storing a flag would mean someone has to remember to
    /// refresh it, and a claim that is payable but marked pending is worse
    /// than no status at all.
    /// A deferred claim is one `settle_withdrawal` could not deliver, because
    /// the token refused to hand the USDC to its owner. It is unpaid, still
    /// owed, still counted in `outstanding_liabilities`, and no longer in the
    /// way of anybody else. Its owner collects it through `claim_withdrawal`,
    /// out of head order, once whatever blocked the delivery is gone.
    pub fn is_deferred(e: Env, claim_id: u64) -> bool {
        e.storage()
            .persistent()
            .get(&Store::Deferred(claim_id))
            .unwrap_or(false)
    }

    pub fn claim_status(e: Env, claim_id: u64) -> Result<ClaimStatus, VaultError> {
        let claim = Self::read_claim(&e, claim_id)?;
        if claim.claimed {
            return Ok(ClaimStatus::Claimed);
        }
        let collectable =
            claim_id == Self::queue_head(e.clone()) || Self::is_deferred(e.clone(), claim_id);
        if collectable && Self::idle_reserves(e.clone()) >= claim.amount {
            return Ok(ClaimStatus::Ready);
        }
        Ok(ClaimStatus::Pending)
    }

    /// Next claim id the queue has not reached. Nothing behind it can be paid
    /// first, and the only claims in front of it that can still be paid are the
    /// deferred ones, which are out of everyone else's way by construction.
    pub fn queue_head(e: Env) -> u64 {
        e.storage().instance().get(&Cfg::QueueHead).unwrap_or(1)
    }

    /// Next claim id to be handed out.
    pub fn queue_tail(e: Env) -> u64 {
        e.storage().instance().get(&Cfg::QueueTail).unwrap_or(1)
    }

    /// Claims the queue has not reached yet. A deferred claim is not counted
    /// here, because it is no longer in the queue; it is still owed, and
    /// `outstanding_liabilities` is the number that says so.
    pub fn queue_length(e: Env) -> u64 {
        Self::queue_tail(e.clone()) - Self::queue_head(e)
    }

    /// Deposits taken since deployment. Counted rather than derived from the
    /// balance sheet because it is what `set_agusd` keys off: the question is
    /// whether this Vault has ever issued agUSD, and reserves that have been
    /// withdrawn back to zero would answer it wrongly.
    pub fn deposits(e: Env) -> u64 {
        e.storage().instance().get(&Cfg::Deposits).unwrap_or(0)
    }

    pub fn paused(e: Env) -> bool {
        e.storage().instance().get(&Cfg::Paused).unwrap_or(false)
    }

    pub fn admin(e: Env) -> Result<Address, VaultError> {
        e.storage()
            .instance()
            .get(&Cfg::Admin)
            .ok_or(VaultError::NotInitialized)
    }

    pub fn usdc(e: Env) -> Result<Address, VaultError> {
        e.storage()
            .instance()
            .get(&Cfg::Usdc)
            .ok_or(VaultError::NotInitialized)
    }

    pub fn agusd(e: Env) -> Result<Address, VaultError> {
        e.storage()
            .instance()
            .get(&Cfg::AgUsd)
            .ok_or(VaultError::NotInitialized)
    }

    pub fn allocation_engine(e: Env) -> Result<Address, VaultError> {
        e.storage()
            .instance()
            .get(&Cfg::Engine)
            .ok_or(VaultError::NotInitialized)
    }

    // ---- internals ----

    fn require_admin(e: &Env, admin: &Address) -> Result<(), VaultError> {
        let stored: Address = e
            .storage()
            .instance()
            .get(&Cfg::Admin)
            .ok_or(VaultError::NotInitialized)?;
        if stored != *admin {
            return Err(VaultError::NotAdmin);
        }
        admin.require_auth();
        Ok(())
    }

    fn require_not_paused(e: &Env) -> Result<(), VaultError> {
        if Self::paused(e.clone()) {
            return Err(VaultError::Paused);
        }
        Ok(())
    }

    fn read_claim(e: &Env, claim_id: u64) -> Result<Claim, VaultError> {
        e.storage()
            .persistent()
            .get(&Store::Claim(claim_id))
            .ok_or(VaultError::ClaimNotFound)
    }

    /// Try to hand `claim` to its owner, and book the payment only if the USDC
    /// actually moved. `Ok(true)` means paid, `Ok(false)` means the token
    /// refused and nothing at all has been written. Shared by
    /// `claim_withdrawal` and `settle_withdrawal` so the two cannot drift: the
    /// caller differs, the payment does not.
    ///
    /// The transfer happens before the bookkeeping, which is the reverse of the
    /// usual advice and is the only order that can work here, because the
    /// bookkeeping is what the outcome of the transfer decides. It is safe for
    /// a reason specific to this platform rather than by luck: the Soroban host
    /// refuses to re-enter a contract that is already on the call stack, so a
    /// token that tried to call back into the Vault mid-payment would abort the
    /// invocation rather than observe a half-written queue. Everything written
    /// after a failed transfer is written after the host has already rolled the
    /// failed frame back.
    ///
    /// Advancing the head is deliberately not done here. A deferred claim is
    /// collected long after the head has moved past it, and paying one must not
    /// drag the pointer backwards, so the two callers each move it or do not.
    fn deliver(e: &Env, claim_id: u64, mut claim: Claim) -> Result<bool, VaultError> {
        if Self::idle_reserves(e.clone()) < claim.amount {
            return Err(VaultError::InsufficientLiquidity);
        }
        let usdc = Self::usdc(e.clone())?;
        let delivered = matches!(
            TokenClient::new(e, &usdc).try_transfer(
                &e.current_contract_address(),
                &claim.owner,
                &claim.amount,
            ),
            Ok(Ok(()))
        );
        if !delivered {
            return Ok(false);
        }

        claim.claimed = true;
        Self::write_claim(e, claim_id, &claim);
        Self::set_queued(
            e,
            Self::outstanding_liabilities(e.clone()) - claim.amount,
        );
        Self::add_booked(e, -claim.amount);

        WithdrawalClaimed {
            user: claim.owner,
            claim_id,
            amount: claim.amount,
        }
        .publish(e);
        Ok(true)
    }

    fn set_deferred(e: &Env, claim_id: u64) {
        let key = Store::Deferred(claim_id);
        e.storage().persistent().set(&key, &true);
        e.storage()
            .persistent()
            .extend_ttl(&key, CLAIM_LIFETIME, CLAIM_BUMP);
    }

    fn set_queued(e: &Env, value: i128) {
        e.storage()
            .instance()
            .set(&Cfg::Queued, &if value < 0 { 0 } else { value });
    }

    fn add_booked(e: &Env, delta: i128) {
        let booked = Self::booked_reserves(e.clone()) + delta;
        e.storage().instance().set(&Cfg::Booked, &booked);
    }

    fn write_claim(e: &Env, claim_id: u64, claim: &Claim) {
        let key = Store::Claim(claim_id);
        e.storage().persistent().set(&key, claim);
        e.storage()
            .persistent()
            .extend_ttl(&key, CLAIM_LIFETIME, CLAIM_BUMP);
    }

    fn bump_instance(e: &Env) {
        e.storage()
            .instance()
            .extend_ttl(INSTANCE_LIFETIME, INSTANCE_BUMP);
    }
}

#[contractevent]
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct Deposit {
    #[topic]
    pub user: Address,
    pub amount: i128,
    pub minted: i128,
}

#[contractevent]
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct WithdrawalRequested {
    #[topic]
    pub user: Address,
    #[topic]
    pub claim_id: u64,
    pub amount: i128,
    /// How many claims are ahead of this one at request time.
    pub queue_position: u64,
}

#[contractevent]
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct WithdrawalClaimed {
    #[topic]
    pub user: Address,
    #[topic]
    pub claim_id: u64,
    pub amount: i128,
}

/// Emitted when `settle_withdrawal` could not hand a claim to its owner and
/// stepped over it. The claim is unpaid and still owed; what has changed is
/// that it is no longer blocking the queue. It belongs in the event stream
/// because it is the only way a claim leaves the queue without being paid, and
/// because the owner needs to know their payment bounced.
#[contractevent]
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct WithdrawalDeferred {
    #[topic]
    pub user: Address,
    #[topic]
    pub claim_id: u64,
    pub amount: i128,
}

#[contractevent]
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct PauseToggled {
    pub paused: bool,
}

/// Emitted when the Vault's own reserve floor moves. The floor is the limit
/// `settle_allocation` enforces against every Engine, so a change to it is a
/// change to how much of the reserves can leave.
#[contractevent]
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ReserveFloorSet {
    pub floor_bps: u32,
}

/// Emitted when capital comes back from a pool and the Vault has verified it
/// arrived.
#[contractevent]
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct RepaymentRecorded {
    pub amount: i128,
    /// Capital still out at the pools after this repayment.
    pub deployed: i128,
}

/// Emitted when deployed capital is written off. This is the only way the
/// Vault's deployed book falls without cash arriving, so it belongs in the
/// event stream rather than only in state a monitor has to poll.
#[contractevent]
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct WriteDownRecorded {
    pub amount: i128,
    /// Capital still out at the pools after the write-down.
    pub deployed: i128,
    /// Everything written off since deployment, after this one. It never falls,
    /// and it stays in the denominator of the reserve floor, so the event
    /// carries the number that says how much of the floor's base is a memory of
    /// capital rather than capital.
    pub recognised_losses: i128,
}

/// Emitted when the Vault is repointed at a different agUSD. Repointing the
/// token is the authority to mint against the Vault's reserves, so the move
/// belongs in the event stream and not only in state a monitor has to poll.
#[contractevent]
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct AgUsdRepointed {
    #[topic]
    pub agusd: Address,
}

/// Emitted when the Vault is repointed at a different Allocation Engine.
/// Repointing the Engine is the authority to release those reserves.
#[contractevent]
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct EngineRepointed {
    #[topic]
    pub engine: Address,
}

mod test;
