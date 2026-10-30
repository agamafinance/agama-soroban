#![no_std]
//! Etherfuse Stablebond adapter.
//!
//! Exposes the same three calls as every other pool type, so the Allocation
//! Engine can route to a tokenized government bond and to an off-chain credit
//! facility through identical code:
//!
//! ```text
//! allocate(amount)      deploy capital into the pool
//! deallocate(amount)    return capital to the Vault
//! get_exposure()        capital currently deployed
//! ```
//!
//! What differs from the private credit adapter is not the interface, it is the
//! settlement and the valuation. Stablebond positions are on-chain and redeem
//! in a block, so `deallocate` returns the USDC to the Vault immediately rather
//! than waiting on an originator. Pricing is deterministic and comes from the
//! Etherfuse feed, registered in the Oracle Adapter with a 48 hour staleness
//! window and no deviation bound: a bond revaluation is not an anomaly to be
//! bounded, it is the instrument doing what it is supposed to do.
//!
//! That difference is why this adapter is the low-risk leg of the book, and why
//! the Engine can size it against a short withdrawal queue while sizing private
//! credit against a long one.
//!
//! Only the Engine can move capital: an admin path here would bypass the
//! concentration caps and the reserve floor the Engine exists to enforce.
//!
//! # Which Engine, and which Vault
//!
//! Both addresses used to be written by `initialize` and never again, and the
//! deployed generation of this adapter is stuck to an Engine and a Vault that
//! have since been superseded. An adapter is the cheapest contract in the
//! stack and it still had to be redeployed, purely because two addresses could
//! not be rewritten.
//!
//! `set_counterparties` moves both at once, admin gated, refused unless the
//! adapter is holding nothing (no booked exposure and no USDC on the balance),
//! and refused unless the Engine offered says it governs the Vault offered.
//! Every one of those conditions is load bearing. Exposure recorded here was
//! authorized by the current Engine against the caps it enforces, so moving
//! the Engine mid-position orphans a book only the old Engine can unwind. And
//! `deallocate` sends capital to the stored Vault address, so moving it
//! while the adapter holds USDC redirects money that belongs to the old Vault.
//! Being empty today says nothing about tomorrow, which is why the symmetry
//! check is there as well: it is what stops an adapter being pointed at a Vault
//! its Engine does not serve, and repaying capital to an address of the admin's
//! choosing one allocation later.
//!
//! The constructor runs the same check. `initialize` was a separate call that
//! took both addresses on trust, so the one call that created the wiring
//! validated nothing while the call that repairs it validated everything, and
//! the gap between the deploy and the wiring was a public window in which
//! somebody else's `initialize` could land first. A constructor closes both:
//! there is no window, and an adapter cannot come into existence pointed at a
//! pair that does not match.
//!
//! # Getting stranded capital home
//!
//! `deallocate` is capped at booked exposure, which is right for a repayment
//! and useless for everything else that can leave USDC sitting here. A position
//! written down to zero leaves the cash with no exposure to return against.
//! Interest paid above principal is surplus the book never expected. In both
//! cases the money was stuck, and because `require_empty` refuses to repoint an
//! adapter holding USDC, one stroop of it also closed the only repair path this
//! contract has. That is not a hypothetical: three generations of this adapter
//! were retired for exactly it, and the deployment record says so each time.
//!
//! `recover_surplus` is the way out, and it is shaped so that it cannot be a
//! way to take anything. The destination is the Vault this adapter already
//! stores, never an address the caller supplies, so there is no parameter for an
//! admin to point somewhere else. The amount is not a parameter either: it is
//! whatever the balance holds above booked exposure, so a live position cannot
//! be swept out from under `deallocate`. Either the Engine or the admin may
//! call it. The Engine is the ordinary path, because the Engine passes the
//! recovery on to the Vault and the three books stay in step; the admin is the
//! path that still works when the Engine an adapter is stuck to has itself been
//! superseded, which is the state that caused the retirements.

use soroban_sdk::auth::{ContractContext, InvokerContractAuthEntry, SubContractInvocation};
use soroban_sdk::{
    contract, contractclient, contracterror, contractevent, contractimpl, contracttype,
    symbol_short, token::TokenClient, vec, Address, Env, IntoVal, Symbol,
};

/// The Allocation Engine, as seen from the adapter. Only `set_counterparties`
/// calls it, to check that an Engine it is about to answer to governs the Vault
/// it is about to repay.
#[contractclient(name = "EngineClient")]
pub trait AllocationEngineInterface {
    fn vault(e: Env) -> Address;
}

/// The one thing this adapter needs to ask the Vault: which token it custodies.
/// Every transfer in this contract uses the token stored here, and a token that
/// is not the Vault's is a one way door for anything the Vault sends.
#[contractclient(name = "VaultTokenClient")]
pub trait VaultTokenInterface {
    fn usdc(e: Env) -> Address;
}

/// The Stablebond pool this adapter subscribes into.
///
/// Declared here rather than imported so the adapter depends on the shape of
/// the pool and not on any particular pool contract: the mock used by the unit
/// tests and the real Etherfuse pool on mainnet answer the same four calls.
#[contractclient(name = "StablebondClient")]
pub trait StablebondInterface {
    fn subscribe(e: Env, from: Address, usdc_amount: i128) -> i128;
    fn redeem(e: Env, from: Address, units: i128) -> i128;
    fn price(e: Env) -> i128;
}

/// The Oracle Adapter, for the one question this adapter asks it.
#[contractclient(name = "OracleClient")]
pub trait OracleInterface {
    fn get_nav(e: Env, feed_id: Symbol) -> i128;
    fn get_feed(e: Env, feed_id: Symbol) -> soroban_sdk::Val;
}

/// Scale of the Stablebond price: USDC per bond unit at 7 decimals.
pub const PRICE_ONE: i128 = 1_0000000;

const DAY_LEDGERS: u32 = 17_280;
const INSTANCE_BUMP: u32 = 30 * DAY_LEDGERS;
const INSTANCE_LIFETIME: u32 = INSTANCE_BUMP - DAY_LEDGERS;

/// Identifies the pool type to anything reading the adapter generically.
pub const POOL_KIND: Symbol = symbol_short!("ETHERFUS");
/// Oracle Adapter feed this pool is valued from.
pub const ORACLE_FEED: Symbol = symbol_short!("EF_BOND");
/// Stablebond redemptions are on-chain, so capital comes back in the same call.
pub const SETTLEMENT_DAYS: u32 = 0;

#[contracterror]
#[derive(Copy, Clone, Debug, Eq, PartialEq)]
#[repr(u32)]
pub enum AdapterError {
    /// Retired with `initialize`, which a `__constructor` replaced. The host
    /// runs a constructor exactly once, inside the deploy, so there is no
    /// second call for this to be the answer to. The number is kept rather than
    /// reused so that an old error code never means something new.
    AlreadyInitialized = 700,
    NotInitialized = 701,
    InvalidAmount = 702,
    /// Deallocating more than is currently deployed.
    ExposureUnderflow = 703,
    NotAdmin = 704,
    /// The Engine and Vault pointers cannot move while the adapter holds
    /// booked exposure or USDC.
    NotEmpty = 705,
    /// The proposed Engine does not answer that it governs the proposed Vault.
    CounterpartyMismatch = 706,
    /// Writing down more than the adapter has booked as deployed.
    WriteDownExceedsExposure = 707,
    /// `accept_admin` was called with no handover in flight.
    NoPendingAdmin = 708,
    /// `accept_admin` was called by an address that was not the one proposed.
    NotPendingAdmin = 709,
    /// `recover_surplus` was called by an address that is neither this
    /// adapter's Engine nor its admin.
    NotAuthorized = 710,
    /// The adapter holds nothing above its booked exposure, so there is nothing
    /// to send home.
    NothingToRecover = 711,
    /// `allocate` was called before a Stablebond pool was named. The adapter
    /// refuses rather than booking exposure it has not invested: an adapter
    /// that accepts the Vault's money with nowhere to put it is the counter
    /// this entry point used to be.
    PoolNotSet = 712,
    /// The pool paid out less than the redemption needed to cover, so the
    /// Vault would have been repaid out of the adapter's other cash.
    RedemptionShort = 713,
    /// `oracle_value` was called before an Oracle Adapter was named.
    OracleNotSet = 714,
    /// The address offered as an oracle does not answer for `EF_BOND`.
    OracleMismatch = 715,
}

#[derive(Clone)]
#[contracttype]
enum Cfg {
    Admin,
    Engine,
    Vault,
    Usdc,
    Exposure,
    /// The Stablebond pool `allocate` subscribes into.
    Pool,
    /// Oracle Adapter this adapter prices its position from, for `oracle_value`.
    Oracle,
    /// Bond units currently held. Distinct from `Exposure`, which is the cost
    /// basis the Engine's caps are measured on: units times the pool price is
    /// a mark to market, and letting a concentration cap drift with a bond
    /// price would make the cap mean something different every day.
    Units,
    /// Half finished admin handover: proposed, not yet accepted.
    PendingAdmin,
}

/// Emitted when the adapter is repointed. Which Engine may move this pool's
/// capital and which Vault it is repaid to are the only two things the adapter
/// decides, so a change to either belongs in the event stream.
#[contractevent]
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct CounterpartiesSet {
    #[topic]
    pub engine: Address,
    #[topic]
    pub vault: Address,
}

/// Emitted when exposure is written off. It is the only way this adapter's book
/// falls with no capital moving, so an observer should never have to infer it
/// from the absence of a transfer.
#[contractevent]
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct WrittenDown {
    pub amount: i128,
    /// Exposure still booked after the write-down.
    pub exposure: i128,
}

/// Emitted when USDC held above the booked exposure is sent home. It is the
/// only way capital leaves this adapter without the exposure moving, so it
/// belongs in the stream, and it carries the destination so that an observer can
/// see it was the stored Vault rather than take it on trust.
#[contractevent]
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct SurplusRecovered {
    #[topic]
    pub vault: Address,
    pub amount: i128,
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

/// Emitted when the Vault's capital is actually subscribed into the pool.
///
/// `amount` is the USDC the Vault released, `units` the bond units it bought,
/// and `units_held` the position afterwards. The three together are what makes
/// an allocation auditable without trusting this contract's own exposure
/// number: the units are in the pool's ledger too.
#[contractevent]
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct Subscribed {
    pub amount: i128,
    pub units: i128,
    pub units_held: i128,
}

/// Emitted when capital is raised and sent home. `units_sold` is zero when the
/// adapter had enough idle cash and no bond had to be touched.
#[contractevent]
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct Redeemed {
    pub amount: i128,
    pub units_sold: i128,
    pub units_held: i128,
}

/// Emitted when the Oracle Adapter this position is priced from is named.
#[contractevent]
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct OracleSet {
    #[topic]
    pub oracle: Address,
}

/// Emitted when the pool this adapter subscribes into is named or changed.
#[contractevent]
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct PoolSet {
    #[topic]
    pub pool: Address,
}

#[contract]
pub struct EtherfuseAdapter;

#[contractimpl]
impl EtherfuseAdapter {
    /// Wire the adapter to the Engine that may move its capital and the Vault
    /// it repays, in the transaction that deploys it.
    ///
    /// The pair is checked here exactly as `set_counterparties` checks it: the
    /// Engine has to answer that it governs the Vault. `initialize` took both
    /// on trust and could be front-run besides, which made the call that
    /// created the wiring the only one that validated none of it.
    pub fn __constructor(
        e: Env,
        admin: Address,
        engine: Address,
        vault: Address,
        usdc: Address,
    ) -> Result<(), AdapterError> {
        admin.require_auth();
        Self::require_symmetry(&e, &engine, &vault, &usdc)?;
        e.storage().instance().set(&Cfg::Admin, &admin);
        e.storage().instance().set(&Cfg::Engine, &engine);
        e.storage().instance().set(&Cfg::Vault, &vault);
        e.storage().instance().set(&Cfg::Usdc, &usdc);
        e.storage().instance().set(&Cfg::Exposure, &0i128);
        Self::bump(&e);
        Ok(())
    }

    /// Point the adapter at a replacement Engine and Vault, together.
    ///
    /// One call, not two, because the two addresses are only meaningful as a
    /// pair: the Engine says what may be allocated here and the Vault says
    /// where `deallocate` sends it back to, and an adapter halfway between two
    /// generations is a contract that takes capital on one authority and
    /// returns it to another. So the Engine has to name the Vault, and both
    /// move in the same transaction or neither does.
    ///
    /// The symmetry check is the one that matters. Repointing the Vault while
    /// the adapter is empty looks harmless and is not: exposure booked
    /// afterwards would be repaid to whatever address was written here, with
    /// the Engine's book decrementing all the same, so the cash and the book
    /// would part company one repayment later and nothing would revert. An
    /// adapter that only accepts a Vault its own Engine governs cannot be aimed
    /// somewhere else.
    pub fn set_counterparties(
        e: Env,
        admin: Address,
        engine: Address,
        vault: Address,
    ) -> Result<(), AdapterError> {
        Self::require_admin(&e, &admin)?;
        Self::require_empty(&e)?;
        // The token is not a parameter here and never becomes one: it is fixed
        // at construction, so a repointing has to land on a Vault that
        // custodies the asset this adapter already transfers with.
        let usdc: Address = e
            .storage()
            .instance()
            .get(&Cfg::Usdc)
            .ok_or(AdapterError::NotInitialized)?;
        Self::require_symmetry(&e, &engine, &vault, &usdc)?;
        e.storage().instance().set(&Cfg::Engine, &engine);
        e.storage().instance().set(&Cfg::Vault, &vault);
        Self::bump(&e);
        CounterpartiesSet { engine, vault }.publish(&e);
        Ok(())
    }

    /// Book capital released by the Vault into Stablebond exposure. Called by
    /// the Engine, which has already checked it against the concentration caps
    /// and the reserve floor.
    pub fn allocate(e: Env, amount: i128) -> Result<(), AdapterError> {
        Self::require_engine(&e)?;
        if amount <= 0 {
            return Err(AdapterError::InvalidAmount);
        }
        // The pool is named before any of the Vault's money is accepted. This
        // entry point used to increment a counter and return, which booked
        // exposure against a Stablebond position that did not exist: the USDC
        // the Vault had just released sat on this adapter earning nothing while
        // the Engine's book, the NAV and the yield keeper all read it as
        // deployed into bonds.
        let pool: Address = e
            .storage()
            .instance()
            .get(&Cfg::Pool)
            .ok_or(AdapterError::PoolNotSet)?;

        let me = e.current_contract_address();
        let bond = StablebondClient::new(&e, &pool);

        // The pool pulls the USDC out of this adapter, which means a token
        // transfer two frames down with this contract as `from`. A contract is
        // only the implicit authorizer of the calls it makes itself, so that
        // nested transfer has to be authorized explicitly, for exactly the
        // amount the pool will charge and no more. A blanket authorization
        // would let a pool take the whole balance.
        //
        // The charge is recomputed here rather than taken on trust: units are
        // integral, so a subscription that is not a whole number of units is
        // charged for the units it bought, and the remainder stays here.
        let price = bond.price();
        if price <= 0 {
            return Err(AdapterError::RedemptionShort);
        }
        let charged = (amount * PRICE_ONE / price) * price / PRICE_ONE;
        let usdc: Address = e
            .storage()
            .instance()
            .get(&Cfg::Usdc)
            .ok_or(AdapterError::NotInitialized)?;
        e.authorize_as_current_contract(vec![
            &e,
            InvokerContractAuthEntry::Contract(SubContractInvocation {
                context: ContractContext {
                    contract: usdc,
                    fn_name: Symbol::new(&e, "transfer"),
                    args: (me.clone(), pool.clone(), charged).into_val(&e),
                },
                sub_invocations: vec![&e],
            }),
        ]);

        // Subscribe first, book second. A pool that refuses leaves this
        // adapter holding the cash and no exposure, which `recover_surplus`
        // sends home; the reverse order would leave a book entry for a
        // subscription that never happened.
        let minted = bond.subscribe(&me, &amount);

        let units = Self::units(e.clone()) + minted;
        e.storage().instance().set(&Cfg::Units, &units);
        // Cost basis, not market value: this is the number the Engine's
        // concentration caps and the Vault's deployed capital are measured on,
        // and it is the amount the Vault actually released.
        let exposure = Self::get_exposure(e.clone()) + amount;
        e.storage().instance().set(&Cfg::Exposure, &exposure);
        Self::bump(&e);
        Subscribed {
            amount,
            units: minted,
            units_held: units,
        }
        .publish(&e);
        Ok(())
    }

    /// Redeem and return capital to the Vault, reducing the exposure by the
    /// same amount in the same call so the two cannot disagree.
    pub fn deallocate(e: Env, amount: i128) -> Result<(), AdapterError> {
        Self::require_engine(&e)?;
        if amount <= 0 {
            return Err(AdapterError::InvalidAmount);
        }
        let exposure = Self::get_exposure(e.clone());
        if amount > exposure {
            return Err(AdapterError::ExposureUnderflow);
        }
        let usdc: Address = e
            .storage()
            .instance()
            .get(&Cfg::Usdc)
            .ok_or(AdapterError::NotInitialized)?;
        let vault: Address = e
            .storage()
            .instance()
            .get(&Cfg::Vault)
            .ok_or(AdapterError::NotInitialized)?;
        let token = TokenClient::new(&e, &usdc);
        let me = e.current_contract_address();

        // Idle cash first, bonds only for the shortfall. A redemption that is
        // not needed is a round trip through the pool's rounding, and on a real
        // Stablebond it is also a spread paid for nothing.
        let idle = token.balance(&me);
        let mut redeemed = 0i128;
        let mut sold = 0i128;
        if idle < amount {
            let pool: Address = e
                .storage()
                .instance()
                .get(&Cfg::Pool)
                .ok_or(AdapterError::PoolNotSet)?;
            let bond = StablebondClient::new(&e, &pool);
            let price = bond.price();
            if price <= 0 {
                return Err(AdapterError::RedemptionShort);
            }
            let short = amount - idle;
            // Rounded up, so the redemption covers the shortfall rather than
            // landing a stroop below it. Any surplus stays here as idle cash
            // and is spent by the next deallocation.
            let mut want = (short * PRICE_ONE + price - 1) / price;
            let held = Self::units(e.clone());
            if want > held {
                want = held;
            }
            if want > 0 {
                redeemed = bond.redeem(&me, &want);
                sold = want;
                e.storage().instance().set(&Cfg::Units, &(held - want));
            }
            if idle + redeemed < amount {
                // The position could not raise the cash. Said here, rather than
                // letting the transfer below pay the Vault out of whatever else
                // this adapter happens to hold.
                return Err(AdapterError::RedemptionShort);
            }
        }

        token.transfer(&me, &vault, &amount);
        e.storage()
            .instance()
            .set(&Cfg::Exposure, &(exposure - amount));
        Self::bump(&e);
        Redeemed {
            amount,
            units_sold: sold,
            units_held: Self::units(e.clone()),
        }
        .publish(&e);
        Ok(())
    }

    /// Write off booked exposure that is not coming back, without moving any
    /// capital.
    ///
    /// `deallocate` transfers the USDC before it decrements the book, which is
    /// the right order when there is USDC to transfer and no help at all when
    /// there is not: a defaulted originator leaves this adapter holding
    /// nothing, the transfer panics, and the exposure goes on reporting full
    /// face value forever. This is the entry point that lets the loss be
    /// recognised instead.
    ///
    /// Called by the Engine, in the same transaction as the Engine's own
    /// write-down and the Vault's, so the three books cannot disagree about how
    /// much of this position still exists. The Engine requires its admin for
    /// it, and so does the Vault; there is no path from here to reducing an
    /// exposure on the adapter alone.
    pub fn write_down(e: Env, amount: i128) -> Result<(), AdapterError> {
        Self::require_engine(&e)?;
        if amount <= 0 {
            return Err(AdapterError::InvalidAmount);
        }
        let exposure = Self::get_exposure(e.clone());
        if amount > exposure {
            return Err(AdapterError::WriteDownExceedsExposure);
        }
        e.storage()
            .instance()
            .set(&Cfg::Exposure, &(exposure - amount));
        Self::bump(&e);
        WrittenDown {
            amount,
            exposure: exposure - amount,
        }
        .publish(&e);
        Ok(())
    }

    /// Send everything the adapter holds above its booked exposure to the Vault
    /// it names, and return how much that was.
    ///
    /// This is the way home for capital `deallocate` cannot move: a recovery on
    /// a position that was written down to zero, and interest paid above
    /// principal. Both used to stay here forever, and because
    /// `set_counterparties` refuses an adapter with a non-zero balance, both
    /// also bricked the adapter's only repair path. It cost three redeployments
    /// of this contract before it was worth fixing.
    ///
    /// It cannot be used to take anything, and the reason is structural rather
    /// than a permission check. There is no destination parameter: the USDC goes
    /// to the Vault this adapter already stores, which `register_pool` and
    /// `set_counterparties` have both checked is the Vault its Engine governs.
    /// There is no amount parameter either: it is the balance less the booked
    /// exposure, so capital backing a live position is never swept and
    /// `deallocate` stays funded for exactly what it owes.
    ///
    /// Either the Engine or the admin may call it. The Engine is the ordinary
    /// path, and the only one that keeps the books in step, because the Engine
    /// passes the amount to the Vault, which verifies the arrival and releases
    /// the loss against it. The admin path exists because the failure this fixes
    /// is an adapter stuck to counterparties that have been superseded, and
    /// requiring a working Engine to unstick it would be requiring the thing
    /// that is broken. Taken that way the cash still reaches the Vault; what it
    /// does not do is update anybody's book, which is the conservative
    /// direction and is why it is the fallback rather than the path.
    pub fn recover_surplus(e: Env, caller: Address) -> Result<i128, AdapterError> {
        let engine: Address = e
            .storage()
            .instance()
            .get(&Cfg::Engine)
            .ok_or(AdapterError::NotInitialized)?;
        let admin: Address = e
            .storage()
            .instance()
            .get(&Cfg::Admin)
            .ok_or(AdapterError::NotInitialized)?;
        if caller != engine && caller != admin {
            return Err(AdapterError::NotAuthorized);
        }
        caller.require_auth();

        let usdc: Address = e
            .storage()
            .instance()
            .get(&Cfg::Usdc)
            .ok_or(AdapterError::NotInitialized)?;
        let vault: Address = e
            .storage()
            .instance()
            .get(&Cfg::Vault)
            .ok_or(AdapterError::NotInitialized)?;
        let token = TokenClient::new(&e, &usdc);
        let cash = token.balance(&e.current_contract_address());
        // The booked exposure is backed by bond units now, not by cash sitting
        // here, so the surplus is what this adapter holds in excess of that
        // backing once the units are counted towards it. Measuring cash against
        // exposure alone would have called the whole position a shortfall the
        // moment `allocate` started subscribing, and refused every sweep.
        //
        // Capped at the cash, because only cash can be sent: a bond price that
        // has risen above cost makes the position worth more than it was
        // bought for, and that gain is not a surplus until it is redeemed.
        let backing = cash + Self::bonds_value(&e);
        let surplus = backing - Self::get_exposure(e.clone());
        if surplus <= 0 {
            return Err(AdapterError::NothingToRecover);
        }
        // The surplus can be sitting in bonds rather than in cash, and that is
        // the ordinary case now: a position written down to zero leaves units
        // backing nothing, and a bond price above cost leaves a gain that no
        // `deallocate` will ever ask for. Redeem exactly what the sweep is
        // short of, so the cash that goes home is the cash the position no
        // longer needs and not a stroop more.
        let mut raised = cash;
        if surplus > cash {
            let pool: Address = e
                .storage()
                .instance()
                .get(&Cfg::Pool)
                .ok_or(AdapterError::PoolNotSet)?;
            let bond = StablebondClient::new(&e, &pool);
            let price = bond.price();
            if price <= 0 {
                return Err(AdapterError::NothingToRecover);
            }
            let short = surplus - cash;
            let mut want = (short * PRICE_ONE + price - 1) / price;
            let held = Self::units(e.clone());
            if want > held {
                want = held;
            }
            if want > 0 {
                let got = bond.redeem(&e.current_contract_address(), &want);
                e.storage().instance().set(&Cfg::Units, &(held - want));
                raised = cash + got;
            }
        }
        // Whichever is smaller: what the position does not need, and what this
        // adapter could actually raise. A pool that cannot pay caps the sweep
        // instead of failing it.
        let surplus = if surplus < raised { surplus } else { raised };
        if surplus <= 0 {
            return Err(AdapterError::NothingToRecover);
        }
        token.transfer(&e.current_contract_address(), &vault, &surplus);
        Self::bump(&e);
        SurplusRecovered {
            vault,
            amount: surplus,
        }
        .publish(&e);
        Ok(surplus)
    }

    /// Capital currently deployed into this pool, in USDC.
    /// Name the Stablebond pool this adapter subscribes into.
    ///
    /// Only while the adapter is empty, for the same reason `set_counterparties`
    /// is: moving the pool under a live position would orphan bond units in a
    /// contract this adapter no longer calls, and go on reporting them as
    /// exposure.
    pub fn set_pool(e: Env, admin: Address, pool: Address) -> Result<(), AdapterError> {
        Self::require_admin(&e, &admin)?;
        Self::require_empty(&e)?;
        if Self::units(e.clone()) != 0 {
            return Err(AdapterError::NotEmpty);
        }
        e.storage().instance().set(&Cfg::Pool, &pool);
        Self::bump(&e);
        PoolSet { pool }.publish(&e);
        Ok(())
    }

    /// The Stablebond pool, or `PoolNotSet` if none has been named.
    pub fn pool(e: Env) -> Result<Address, AdapterError> {
        e.storage()
            .instance()
            .get(&Cfg::Pool)
            .ok_or(AdapterError::PoolNotSet)
    }

    /// Bond units held. Zero before the first allocation.
    pub fn units(e: Env) -> i128 {
        e.storage().instance().get(&Cfg::Units).unwrap_or(0)
    }

    /// What the position is worth now: units at the pool's current price, plus
    /// any idle USDC sitting here.
    ///
    /// This is the number that moves with the bond and the one the yield keeper
    /// should value this pool from. `get_exposure` deliberately does not move
    /// with it, so the Engine's caps keep measuring the capital that was
    /// committed rather than its latest mark.
    pub fn market_value(e: Env) -> Result<i128, AdapterError> {
        let pool: Address = e
            .storage()
            .instance()
            .get(&Cfg::Pool)
            .ok_or(AdapterError::PoolNotSet)?;
        let usdc: Address = e
            .storage()
            .instance()
            .get(&Cfg::Usdc)
            .ok_or(AdapterError::NotInitialized)?;
        let price = StablebondClient::new(&e, &pool).price();
        let bonds = Self::units(e.clone()) * price / PRICE_ONE;
        let idle = TokenClient::new(&e, &usdc).balance(&e.current_contract_address());
        Ok(bonds + idle)
    }

    /// USDC held here rather than in the pool. Non-zero only between a failed
    /// subscription and a `recover_surplus`, or after a redemption rounded up.
    pub fn uninvested(e: Env) -> Result<i128, AdapterError> {
        let usdc: Address = e
            .storage()
            .instance()
            .get(&Cfg::Usdc)
            .ok_or(AdapterError::NotInitialized)?;
        Ok(TokenClient::new(&e, &usdc).balance(&e.current_contract_address()))
    }

    /// Name the Oracle Adapter this position is priced from.
    ///
    /// Tranche 2, Deliverable 2 of the award registers three feeds, and
    /// `EF_BOND` is the one that prices this pool: 48 hours of staleness and no
    /// deviation bound, because a government bond NAV is deterministic. It was
    /// a symbol the Oracle Adapter knew and that no contract read, so the feed
    /// existed and validated nothing. This is the read.
    ///
    /// The oracle is a separate question from the pool, and the two can
    /// disagree. `market_value` is what a redemption would actually pay, taken
    /// from the pool itself. `oracle_value` is what the protocol books, taken
    /// from the validated feed. On a healthy position they agree; when they do
    /// not, one of the two is wrong and the gap is the signal, which is why
    /// both are readable rather than reconciled into one number here.
    pub fn set_oracle(e: Env, admin: Address, oracle: Address) -> Result<(), AdapterError> {
        Self::require_admin(&e, &admin)?;
        // Interrogated, like every other counterparty: an address that is not
        // an oracle cannot answer, and an oracle that has never heard of
        // EF_BOND would turn every valuation into a FeedNotRegistered.
        match OracleClient::new(&e, &oracle).try_get_feed(&ORACLE_FEED) {
            Ok(_) => {}
            Err(_) => return Err(AdapterError::OracleMismatch),
        }
        e.storage().instance().set(&Cfg::Oracle, &oracle);
        Self::bump(&e);
        OracleSet { oracle }.publish(&e);
        Ok(())
    }

    /// The Oracle Adapter, or `OracleNotSet`.
    pub fn oracle(e: Env) -> Result<Address, AdapterError> {
        e.storage()
            .instance()
            .get(&Cfg::Oracle)
            .ok_or(AdapterError::OracleNotSet)
    }

    /// What this position is worth at the validated `EF_BOND` price, plus any
    /// cash not yet invested.
    ///
    /// A stale feed surfaces as the Oracle Adapter's own `OracleStale` rather
    /// than as an old number, so a valuation nobody has updated for 48 hours
    /// fails loudly instead of quietly reporting Tuesday's price.
    pub fn oracle_value(e: Env) -> Result<i128, AdapterError> {
        let oracle = Self::oracle(e.clone())?;
        let usdc: Address = e
            .storage()
            .instance()
            .get(&Cfg::Usdc)
            .ok_or(AdapterError::NotInitialized)?;
        let price = OracleClient::new(&e, &oracle).get_nav(&ORACLE_FEED);
        let bonds = Self::units(e.clone()) * price / PRICE_ONE;
        let idle = TokenClient::new(&e, &usdc).balance(&e.current_contract_address());
        Ok(bonds + idle)
    }

    /// How far the pool's own price has drifted from the validated feed, in
    /// basis points of the feed. Zero when they agree, and the sign says which
    /// way: positive means the pool claims more than the oracle validates.
    ///
    /// This is the number an operator watches. A pool quoting above the feed is
    /// the shape of an issuer marking its own book up, and a pool quoting below
    /// it is the shape of a redemption that will not pay what the protocol has
    /// booked.
    pub fn price_drift_bps(e: Env) -> Result<i128, AdapterError> {
        let oracle = Self::oracle(e.clone())?;
        let pool: Address = e
            .storage()
            .instance()
            .get(&Cfg::Pool)
            .ok_or(AdapterError::PoolNotSet)?;
        let feed = OracleClient::new(&e, &oracle).get_nav(&ORACLE_FEED);
        if feed <= 0 {
            return Err(AdapterError::OracleMismatch);
        }
        let quoted = StablebondClient::new(&e, &pool).price();
        Ok((quoted - feed) * 10_000 / feed)
    }

    pub fn get_exposure(e: Env) -> i128 {
        e.storage().instance().get(&Cfg::Exposure).unwrap_or(0)
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
    pub fn propose_admin(e: Env, admin: Address, new_admin: Address) -> Result<(), AdapterError> {
        Self::require_admin(&e, &admin)?;
        e.storage().instance().set(&Cfg::PendingAdmin, &new_admin);
        Self::bump(&e);
        AdminProposed { new_admin }.publish(&e);
        Ok(())
    }

    /// Complete a handover. Only the proposed address can call it, and it has
    /// to authorize the call itself: that authorization is the entire point of
    /// the second step.
    pub fn accept_admin(e: Env, new_admin: Address) -> Result<(), AdapterError> {
        let pending: Address = e
            .storage()
            .instance()
            .get(&Cfg::PendingAdmin)
            .ok_or(AdapterError::NoPendingAdmin)?;
        if pending != new_admin {
            return Err(AdapterError::NotPendingAdmin);
        }
        new_admin.require_auth();
        e.storage().instance().set(&Cfg::Admin, &new_admin);
        e.storage().instance().remove(&Cfg::PendingAdmin);
        Self::bump(&e);
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

    // ---- metadata, read by the Engine and the UI ----

    pub fn pool_kind(_e: Env) -> Symbol {
        POOL_KIND
    }

    pub fn oracle_feed(_e: Env) -> Symbol {
        ORACLE_FEED
    }

    /// Days from `deallocate` to cash in the Vault. Zero: on-chain redemption.
    ///
    /// Kept because it is what this adapter shipped with and something may be
    /// reading it. `settlement_window` is the one to call.
    pub fn settlement_days(_e: Env) -> u32 {
        SETTLEMENT_DAYS
    }

    /// Settlement window in days, as `(min, max)`, the same question the private
    /// credit adapter answers under the same name.
    ///
    /// The two adapters answered it differently: `settlement_days() -> u32` here
    /// and `settlement_window() -> (u32, u32)` there. Nothing on-chain enforces
    /// either, so nothing broke, and that is the problem with it: a caller
    /// sizing the withdrawal queue against the book has to know which adapter it
    /// is holding and call a different name with a different return type for
    /// each, and the one that gets added next is a third case. Redemption here
    /// is on-chain and immediate, so both ends of the window are zero, which is
    /// a narrower and truer statement than a single scalar that happens to be
    /// the same number.
    pub fn settlement_window(_e: Env) -> (u32, u32) {
        (SETTLEMENT_DAYS, SETTLEMENT_DAYS)
    }

    pub fn engine(e: Env) -> Result<Address, AdapterError> {
        e.storage()
            .instance()
            .get(&Cfg::Engine)
            .ok_or(AdapterError::NotInitialized)
    }

    /// The token this adapter transfers with. It is a constructor argument that
    /// nothing could read back, so nothing could check it either, and it is the
    /// address every `transfer` in this contract uses.
    pub fn usdc(e: Env) -> Result<Address, AdapterError> {
        e.storage()
            .instance()
            .get(&Cfg::Usdc)
            .ok_or(AdapterError::NotInitialized)
    }

    pub fn vault(e: Env) -> Result<Address, AdapterError> {
        e.storage()
            .instance()
            .get(&Cfg::Vault)
            .ok_or(AdapterError::NotInitialized)
    }

    pub fn admin(e: Env) -> Result<Address, AdapterError> {
        e.storage()
            .instance()
            .get(&Cfg::Admin)
            .ok_or(AdapterError::NotInitialized)
    }

    // ---- internals ----

    /// Bond units at the pool's current price, or zero when no pool is named.
    /// Used where a missing pool must read as no bonds rather than as an error.
    fn bonds_value(e: &Env) -> i128 {
        match e.storage().instance().get::<Cfg, Address>(&Cfg::Pool) {
            Some(pool) => {
                let price = StablebondClient::new(e, &pool).price();
                Self::units(e.clone()) * price / PRICE_ONE
            }
            None => 0,
        }
    }

    fn require_admin(e: &Env, admin: &Address) -> Result<(), AdapterError> {
        let stored: Address = e
            .storage()
            .instance()
            .get(&Cfg::Admin)
            .ok_or(AdapterError::NotInitialized)?;
        if stored != *admin {
            return Err(AdapterError::NotAdmin);
        }
        admin.require_auth();
        Ok(())
    }

    /// Neither pointer moves while the adapter is holding anything. Exposure
    /// booked here was authorized by the current Engine, and USDC sitting here
    /// is owed to the current Vault, so an empty adapter is the only state in
    /// which repointing strands nothing. The balance is checked as well as the
    /// book because a repayment can arrive before it is recorded.
    fn require_empty(e: &Env) -> Result<(), AdapterError> {
        if Self::get_exposure(e.clone()) != 0 {
            return Err(AdapterError::NotEmpty);
        }
        let usdc: Address = e
            .storage()
            .instance()
            .get(&Cfg::Usdc)
            .ok_or(AdapterError::NotInitialized)?;
        if TokenClient::new(e, &usdc).balance(&e.current_contract_address()) != 0 {
            return Err(AdapterError::NotEmpty);
        }
        // Bond units too. Cash and booked exposure can both be zero while this
        // adapter still holds a Stablebond position, and repointing it there
        // would strand units in a pool the new Engine never learns about.
        if Self::units(e.clone()) != 0 {
            return Err(AdapterError::NotEmpty);
        }
        Ok(())
    }

    /// The Engine offered has to answer that it governs the Vault offered.
    ///
    /// What this rules out is an address that cannot answer the question, or
    /// answers it with a different Vault: a plain account, and a real Engine
    /// that governs somebody else. What it cannot rule out is a contract built
    /// to answer it, which returns whatever address it was written to return and
    /// passes without difficulty. The check is worth running because the
    /// realistic failure here is a mis-wiring rather than an attack, and both
    /// callers are admin gated either way; it is not worth reading as proof that
    /// the counterparty is what it says it is.
    fn require_symmetry(
        e: &Env,
        engine: &Address,
        vault: &Address,
        usdc: &Address,
    ) -> Result<(), AdapterError> {
        match EngineClient::new(e, engine).try_vault() {
            Ok(Ok(governed)) if governed == *vault => {}
            _ => return Err(AdapterError::CounterpartyMismatch),
        }
        // The third edge of the same triangle, and the one that used to be
        // missing. Both checks above are about which contracts are wired
        // together; this one is about the asset, and the asset is what every
        // transfer here actually moves. An adapter storing a token that is not
        // the Vault's is a one way door: the Vault sends what the Vault holds,
        // so real USDC arrives, and `deallocate` then tries to send back the
        // token this contract stores, of which it holds none, and traps.
        // `recover_surplus` measures its surplus in that same token and sees
        // nothing above the exposure. The books can be cleared with a
        // write-down and the money stays exactly where it is.
        match VaultTokenClient::new(e, vault).try_usdc() {
            Ok(Ok(custodied)) if custodied == *usdc => Ok(()),
            _ => Err(AdapterError::CounterpartyMismatch),
        }
    }

    fn require_engine(e: &Env) -> Result<(), AdapterError> {
        let engine: Address = e
            .storage()
            .instance()
            .get(&Cfg::Engine)
            .ok_or(AdapterError::NotInitialized)?;
        engine.require_auth();
        Ok(())
    }

    fn bump(e: &Env) {
        e.storage()
            .instance()
            .extend_ttl(INSTANCE_LIFETIME, INSTANCE_BUMP);
    }
}

mod test;
