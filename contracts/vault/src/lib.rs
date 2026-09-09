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
//! FIFO does not depend on the head claimant showing up, either.
//! `settle_withdrawal` pays whichever claim sits at `queue_head` to the
//! owner recorded on it, and any address may call it. That is not a
//! privileged path around the ordering, because the caller never chooses the
//! claim or the recipient: both are read from the queue, not supplied by the
//! caller, so the only thing calling `settle_withdrawal` can do is exactly
//! what the owner's own `claim_withdrawal` would have done. A claimant who
//! never returns therefore no longer blocks everyone behind them; a bot, a
//! relayer, or another claimant impatient for their own turn can advance the
//! queue on the absent owner's behalf, and the money still lands only where
//! it was always going to land.
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
//! token it no longer mints. For the Engine it is an exposure book funded by
//! this Vault, because the USDC behind it is out in the pool adapters and only
//! the Engine that put it there can call it back. `set_engine` additionally
//! refuses any address that does not name this Vault back, so the pointer that
//! releases the reserves cannot be aimed at an ordinary account.
//!
//! # What the admin can do, stated plainly
//!
//! None of that makes the admin harmless, and this contract does not pretend
//! otherwise. V1 allocation is admin directed: the admin sets the Engine's
//! caps and reserve floor, chooses which pools are registered, and decides how
//! much goes to each. An admin willing to register a pool it controls can
//! therefore move the Vault's capital to itself, and no check inside the Vault
//! prevents that, because the Vault deliberately does not duplicate the
//! Engine's limits. What protects depositors from the admin is the
//! multi-signature admin in V1 and governance with a timelock in V2, not a
//! guard in this file. What the guards here protect is everything else: the
//! withdrawal queue cannot be reordered, agUSD cannot be minted by anyone but
//! this Vault, and no counterparty pointer can be moved into a state that
//! silently misreports the book.
//!
//! # Circuit breaker
//!
//! `set_paused` blocks deposits, withdrawal requests, claims and new
//! allocations. It does not touch the staking contract or the Oracle Adapter:
//! during an incident, NAV reporting is exactly what should keep running.
//! Pausing allocations goes slightly beyond blocking user flows, and is
//! deliberate: deploying more capital into pools during an emergency stop is
//! the opposite of what the stop is for.

use soroban_sdk::{
    contract, contractclient, contracterror, contractevent, contractimpl, contracttype,
    token::TokenClient, Address, Env, Symbol,
};

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
}

/// Persistent storage: the claim records, keyed by claim id.
#[derive(Clone)]
#[contracttype]
enum Store {
    Claim(u64),
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
        Self::bump_instance(&e);
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
    /// The guard is the same shape as `set_agusd`: the pointer moves only
    /// while nothing depends on it. Here that means the Engine currently
    /// pointed at must not be holding an exposure book funded by this Vault.
    /// If it is, the USDC is already out in the pool adapters and only that
    /// Engine can call them back, so repointing would leave `get_total_assets`
    /// understating the book by exactly the amount still deployed.
    ///
    /// An Engine that governs some other Vault is not that: its exposure is
    /// somebody else's capital, and this Vault is free to leave. That is the
    /// case this deployment was actually stuck in, and refusing it would have
    /// made the setter useless in the one situation it exists for.
    ///
    /// The replacement has to answer that it governs this Vault.
    /// `settle_allocation` hands the Vault's USDC to whatever this pointer
    /// names, so without that check the setter would be a one call instruction
    /// to release the reserves to an ordinary account: an account has no
    /// `vault()` to answer with, so it cannot be named here, and neither can an
    /// Engine that governs somebody else. It also means the setter that exists
    /// to undo a mis-wiring cannot be used to create one, which is worth having
    /// on the only pointer both contracts have already been wrong about.
    ///
    /// It does not make the admin harmless and it is not sold as doing so. An
    /// admin can register a pool of its own choosing with the Engine and
    /// allocate to it; V1 allocation is admin directed by construction, and
    /// what protects depositors from the admin is the multi-signature admin and
    /// the timelock on the roadmap, not a check in this function. What this
    /// check buys is that the short path is no shorter than the long one.
    pub fn set_engine(
        e: Env,
        admin: Address,
        allocation_engine: Address,
    ) -> Result<(), VaultError> {
        Self::require_admin(&e, &admin)?;
        let current: Address = e
            .storage()
            .instance()
            .get(&Cfg::Engine)
            .ok_or(VaultError::NotInitialized)?;

        // Leaving an Engine that cannot answer is always safe: whatever it has
        // done with this Vault's USDC, it can do no more once it is no longer
        // named here, and there is no book to reconcile because there is no
        // book to read. Refusing in that case would freeze the pointer exactly
        // when moving it is the remedy.
        let outgoing = EngineClient::new(&e, &current);
        if let (Ok(Ok(governed)), Ok(Ok(deployed))) =
            (outgoing.try_vault(), outgoing.try_total_allocated())
        {
            if governed == e.current_contract_address() && deployed > 0 {
                return Err(VaultError::CapitalDeployed);
            }
        }

        // An address that cannot answer the question is refused along with one
        // that answers wrongly, so a plain account and a hostile contract fail
        // here identically rather than one of them failing later, in a release.
        let incoming = EngineClient::new(&e, &allocation_engine);
        match incoming.try_vault() {
            Ok(Ok(governed)) if governed == e.current_contract_address() => {}
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

    /// Circuit breaker. Blocks deposits, withdrawal requests, claims and new
    /// allocations; leaves staking and NAV reporting untouched.
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
    /// The head advances only when a claim is paid. If its owner never
    /// returns to call this, `settle_withdrawal` is the way the queue moves
    /// on without them: same recipient, same amount, same position, just a
    /// different caller.
    pub fn claim_withdrawal(e: Env, from: Address, claim_id: u64) -> Result<(), VaultError> {
        Self::require_not_paused(&e)?;
        from.require_auth();

        let mut claim = Self::read_claim(&e, claim_id)?;
        if claim.owner != from {
            return Err(VaultError::NotClaimOwner);
        }
        if claim.claimed {
            return Err(VaultError::AlreadyClaimed);
        }
        if claim_id != Self::queue_head(e.clone()) {
            return Err(VaultError::NotAtQueueHead);
        }
        if Self::idle_reserves(e.clone()) < claim.amount {
            return Err(VaultError::InsufficientLiquidity);
        }

        let usdc = Self::usdc(e.clone())?;
        TokenClient::new(&e, &usdc).transfer(
            &e.current_contract_address(),
            &claim.owner,
            &claim.amount,
        );

        claim.claimed = true;
        Self::write_claim(&e, claim_id, &claim);
        e.storage().instance().set(&Cfg::QueueHead, &(claim_id + 1));
        Self::bump_instance(&e);

        WithdrawalClaimed {
            user: from,
            claim_id,
            amount: claim.amount,
        }
        .publish(&e);
        Ok(())
    }

    /// Pay the claim at the head of the queue to its recorded owner, and
    /// advance the queue. Callable by anyone, on behalf of no one.
    ///
    /// This is `claim_withdrawal` with the caller and the claim both taken
    /// away from the caller's control: there is no `claim_id` argument, so
    /// there is nothing to point at a claim other than the one already at
    /// `queue_head`, and the payment always goes to `claim.owner`, never to
    /// whoever sent the transaction. A caller who wanted to redirect funds or
    /// jump the queue would need this function to accept a target it does
    /// not accept, so the only thing it can be used for is doing, for a
    /// stalled claimant, exactly what they could have done for themselves.
    ///
    /// That is what makes it safe to leave unauthenticated. It settles the
    /// same guards `claim_withdrawal` does: paused blocks it, and reserves
    /// short of the claim's amount fail it with the same error rather than
    /// paying a partial amount.
    pub fn settle_withdrawal(e: Env) -> Result<u64, VaultError> {
        Self::require_not_paused(&e)?;

        let claim_id = Self::queue_head(e.clone());
        if claim_id == Self::queue_tail(e.clone()) {
            return Err(VaultError::QueueEmpty);
        }
        let mut claim = Self::read_claim(&e, claim_id)?;
        if Self::idle_reserves(e.clone()) < claim.amount {
            return Err(VaultError::InsufficientLiquidity);
        }

        let usdc = Self::usdc(e.clone())?;
        TokenClient::new(&e, &usdc).transfer(
            &e.current_contract_address(),
            &claim.owner,
            &claim.amount,
        );

        claim.claimed = true;
        Self::write_claim(&e, claim_id, &claim);
        e.storage().instance().set(&Cfg::QueueHead, &(claim_id + 1));
        Self::bump_instance(&e);

        WithdrawalClaimed {
            user: claim.owner,
            claim_id,
            amount: claim.amount,
        }
        .publish(&e);
        Ok(claim_id)
    }

    /// Release idle USDC to a pool. Callable only by the Allocation Engine,
    /// which has already checked the concentration caps and the reserve floor.
    /// The Vault does not re-derive those limits: duplicating them here would
    /// mean two implementations that can disagree.
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
        let usdc = Self::usdc(e.clone())?;
        TokenClient::new(&e, &usdc).transfer(&e.current_contract_address(), &pool, &amount);
        Self::bump_instance(&e);
        Ok(())
    }

    // ---- views ----

    /// USDC held by the Vault. This is what the Engine's reserve floor
    /// protects and what claims are paid from.
    pub fn idle_reserves(e: Env) -> i128 {
        let Ok(usdc) = Self::usdc(e.clone()) else {
            return 0;
        };
        TokenClient::new(&e, &usdc).balance(&e.current_contract_address())
    }

    /// Idle reserves plus everything the Engine has booked as deployed.
    pub fn get_total_assets(e: Env) -> Result<i128, VaultError> {
        let engine: Address = e
            .storage()
            .instance()
            .get(&Cfg::Engine)
            .ok_or(VaultError::NotInitialized)?;
        Ok(Self::idle_reserves(e.clone()) + EngineClient::new(&e, &engine).total_allocated())
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
    pub fn claim_status(e: Env, claim_id: u64) -> Result<ClaimStatus, VaultError> {
        let claim = Self::read_claim(&e, claim_id)?;
        if claim.claimed {
            return Ok(ClaimStatus::Claimed);
        }
        if claim_id == Self::queue_head(e.clone())
            && Self::idle_reserves(e.clone()) >= claim.amount
        {
            return Ok(ClaimStatus::Ready);
        }
        Ok(ClaimStatus::Pending)
    }

    /// Next claim id that may be paid. Nothing behind it can be paid first.
    pub fn queue_head(e: Env) -> u64 {
        e.storage().instance().get(&Cfg::QueueHead).unwrap_or(1)
    }

    /// Next claim id to be handed out.
    pub fn queue_tail(e: Env) -> u64 {
        e.storage().instance().get(&Cfg::QueueTail).unwrap_or(1)
    }

    /// Claims requested and not yet paid.
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

#[contractevent]
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct PauseToggled {
    pub paused: bool,
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
