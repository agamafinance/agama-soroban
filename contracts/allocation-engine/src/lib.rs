#![no_std]
//! Allocation Engine, the constraint layer between the Vault and the pools.
//!
//! # Operational model
//!
//! V1 is admin directed. The Engine does not decide where capital goes: a human
//! operator does, by calling `allocate` with a pool and an amount. What the
//! Engine does is refuse. Every allocation is checked, on-chain and in the same
//! transaction, against four limits, and any one of them failing reverts the
//! call:
//!
//!  - the per-pool cap, so no single pool can take the book
//!  - the per-originator cap, so several pools fronted by the same originator
//!    cannot add up to concentrated counterparty risk
//!  - the per-jurisdiction cap, so the book is not one legal regime deep
//!  - the reserve floor, a minimum share of net assets that has to stay as
//!    free USDC in the Vault
//!
//! The V2 off-chain optimizer changes who proposes an allocation. It does not
//! change who enforces these limits, which is why they live here and not in a
//! backend.
//!
//! # The reserve floor
//!
//! Fast-exit liquidity used to come from a Blend v2 position that could be
//! withdrawn instantly. Blend V2 is being wound down after the Comet BLND-USDC
//! exploit and has been removed from the SCF Integration List, and it is not
//! replaced by another protocol. The role it played is now a property of the
//! Engine instead of a dependency on somebody else's pool: `allocate` reverts
//! if the call would push free reserves below `floor_bps` of net assets.
//!
//! This is a strictly stronger position than the one it replaces. A liquidity
//! buffer parked in a lending protocol is only as instant as that protocol's
//! utilization on the day you need it; USDC that never left the Vault has no
//! such dependency.
//!
//! The floor is measured against free reserves and net assets, never against
//! the Vault's gross balance. A withdrawal request burns its agUSD immediately
//! and leaves the USDC in the Vault until the claim is paid, so between those
//! two moments the money sits on the balance and belongs to somebody already.
//! Measuring against the gross balance counted it twice: 1000 deposited, all
//! 1000 queued for withdrawal, and the Engine would still deploy 400 while the
//! reserve ratio reported a healthy 6000 bps, leaving a claim that could not be
//! paid. `Vault::free_reserves` and `Vault::get_net_assets` are the same book
//! with that liability subtracted, and they are what every limit here reads.
//!
//! The Vault enforces the floor a second time, on its own numbers, when it
//! releases the cash. That is not redundancy to be tidied away: this Engine is
//! an address the Vault authorizes, so a check that lives only here is a check
//! that any contract holding that authorization can skip.
//!
//! A floor is only a constraint if the caps can reach it, and that is a
//! property of the configuration rather than of the code. Two pools capped at
//! 30% of total assets can between them deploy at most 60%, so a 20% floor can
//! never be the reason an allocation is refused: 40% stays idle whatever the
//! operator does, the pool cap always fires first, and the floor passes its own
//! unit test while doing nothing on-chain. The deployed configuration is chosen
//! the other way round, with the registered pool caps summing to more than the
//! floor is willing to release, so there are states reachable by ordinary
//! allocations in which every concentration cap is satisfied and the floor is
//! the only thing saying no. That case is a test, not an assertion.
//!
//! # Fail closed
//!
//! `__constructor` leaves every cap at zero and the reserve floor at 100%, so
//! an Engine that has been deployed but not yet configured cannot deploy
//! capital at all. Opening it up is an explicit admin action with an event
//! attached.
//!
//! # Accounting
//!
//! Exposure records are persistent, not instance state: they have to survive
//! settlement cycles that run for weeks (D+15 to D+90 for private credit) and
//! outlive any single configuration change. Net assets are read as free
//! reserves plus booked exposure, so allocating moves value between the two
//! without changing the denominator the caps are measured against.
//!
//! Exposure comes down in two ways, and both of them are explicit. `deallocate`
//! is capital coming back, and it now proves it: the Vault checks the cash
//! reached it before the book is allowed to fall. `write_down` is capital that
//! is not coming back, admin gated and evented, and it exists because without
//! it a default could not be recognised at all. `deallocate` transfers before
//! it decrements, so a defaulted originator holding no USDC panics the transfer
//! and the exposure reports face value indefinitely, which leaves every reserve
//! ratio derived from it overstated by the size of the loss.
//!
//! A write-down has to be free, in the sense of buying its caller nothing, and
//! for one release of this contract it was not. The floor was a share of total
//! assets, `write_down` lowers total assets with no cash moving, so every
//! write-down created releasable headroom worth `floor_bps` of what was written
//! off. Allocating to the floor and writing the position off, over and over,
//! moved 999.9999999 of 1000 USDC out of a Vault holding a 25% floor, with
//! every call individually inside the limit. `written_off` is the answer: a
//! total no write-down and no allocation can lower, in the denominator of the
//! floor and of `get_reserve_ratio`, and deliberately not in the denominator of
//! the concentration caps, where a larger base would loosen rather than tighten.
//! It comes down in exactly one way, `recover`, which requires the cash to have
//! reached the Vault, and which adds that cash to free reserves in the same
//! transaction, so the base itself still does not fall.
//!
//! # The caps needed the same treatment, in the numerator
//!
//! The floor was fixed and the concentration caps were not, and they had the
//! same hole for the same reason. Every cap was measured against *current*
//! exposure, and `write_down` sets current exposure to zero while the adapter
//! goes on holding every dollar it was ever sent. So the same pool could be
//! filled to its cap, written off, filled to its cap again, and the real
//! concentration behind one originator was bounded by nothing at all while all
//! three caps read as satisfied. Fixing the floor did not touch it: a pool
//! capped at 30% could still take everything the floor was willing to release,
//! and the originator and jurisdiction sums followed it up, because all three
//! are built from the same per-pool numbers.
//!
//! The correction is symmetric with the floor's, on the other side of the
//! ratio: a write-down is charged against the pool's cap permanently, so the
//! quantity the caps measure is `exposure + written_off_pool` rather than
//! exposure alone. The denominator stays real total assets, because adding
//! losses there would loosen a cap rather than tighten it, which is the wrong
//! direction and the reason the floor and the caps take the two terms
//! differently.
//!
//! It is a product decision as much as a fix, and it is worth stating as one,
//! including how strong it is. A pool that has lost `W` cannot take another
//! dollar until `cap_bps` of total assets covers `W` again, and because the
//! loss also lowered total assets, a pool that defaulted at its cap needs the
//! book to grow back to roughly the size it had before the default. That is
//! deliberately the same shape as the floor's relief and deliberately not a
//! prohibition: new deposits raise the denominator and reopen the pool in the
//! ordinary way, `recover` releases the charge outright if the cash comes back,
//! and an operator who has decided the originator is good for it can widen the
//! cap or register a new adapter. What none of those are is automatic. A
//! defaulted originator does not get its limit back as a side effect of the
//! loss being recognised; somebody has to decide to give it back.
//!
//! # Capital that comes back after it was written off
//!
//! A write-down is a statement about what is expected, not a receipt, and
//! private credit recovers. `deallocate` is capped at booked exposure, so once
//! a position is written down to zero there was no entry point that could move
//! the cash home: it sat in the adapter, and because `set_counterparties`
//! refuses an adapter with a non-zero balance, one stroop of it also bricked
//! the adapter's only repair path. That is not hypothetical; it cost this
//! protocol three redeployments of the private credit adapter, each recorded in
//! `deployments/testnet.json`.
//!
//! `recover` is the way out, and its shape is chosen so that it cannot become
//! a way in. The adapter sends its surplus to the Vault it already names, never
//! to an address the caller supplies, so there is no version of this call that
//! extracts anything; the Vault verifies the cash arrived in its own balance
//! before it believes a stroop of it; and what the Vault then does with it is
//! release the loss, not the floor. Recognised losses come down by the recovery,
//! and free reserves go up by the same number in the same transaction, so
//! `floor_base` is unchanged and the C1 invariant, that the base the floor is a
//! percentage of never falls, still holds exactly.

use soroban_sdk::{
    contract, contractclient, contracterror, contractevent, contractimpl, contracttype, Address,
    Env, Map, Symbol, Vec,
};

const BPS: i128 = 10_000;

const DAY_LEDGERS: u32 = 17_280;
const INSTANCE_BUMP: u32 = 30 * DAY_LEDGERS;
const INSTANCE_LIFETIME: u32 = INSTANCE_BUMP - DAY_LEDGERS;
// Exposure records outlive settlement cycles, so they get the longest TTL the
// protocol uses anywhere: a private credit position can be open for 90 days.
const EXPOSURE_BUMP: u32 = 90 * DAY_LEDGERS;
const EXPOSURE_LIFETIME: u32 = EXPOSURE_BUMP - DAY_LEDGERS;

/// The part of the Vault the Engine talks to. Declared here rather than taken
/// as a crate dependency so the two contracts stay independently deployable.
#[contractclient(name = "VaultClient")]
pub trait VaultInterface {
    /// USDC sitting in the Vault that the withdrawal queue has no claim on.
    /// This is the quantity the reserve floor protects: the gross balance
    /// includes claims whose agUSD has already been burned, and lending those
    /// out is how a queued claim becomes unpayable.
    fn free_reserves(e: Env) -> i128;
    /// The same quantity measured on the cash the Vault can account for from
    /// its own flows, rather than on the balance it happens to hold. This is
    /// what `settle_allocation` checks a release against, so it is what this
    /// Engine has to check it against too, or the Engine permits allocations
    /// the Vault then refuses and the two limits stop being one limit.
    fn accounted_free_reserves(e: Env) -> i128;
    /// The reserve floor's denominator, taken from the Vault rather than
    /// rebuilt here. Rebuilding it from this Engine's own books reproduces it
    /// only while no term is clamped, and the Vault clamps the sum once at the
    /// end precisely because clamping a term first drifts the base down a
    /// stroop per deallocation. One number, read from the contract that owns
    /// it, cannot drift from itself.
    fn floor_base(e: Env) -> i128;
    /// Move `amount` of that USDC to `pool`. The Vault is the only custodian;
    /// the Engine can instruct a release but never holds the funds itself. The
    /// Vault applies its own floor to this and can refuse.
    fn settle_allocation(e: Env, pool: Address, amount: i128);
    /// The token the Vault custodies, which is the one an adapter has to be
    /// holding for anything it is sent to be able to come back.
    fn usdc(e: Env) -> Address;
    /// Tell the Vault that `amount` has come back from a pool. The Vault
    /// verifies it against its own balance before believing it.
    fn record_repayment(e: Env, amount: i128);
    /// Tell the Vault that `amount` of deployed capital is not coming back.
    /// Needs the Vault admin's signature as well as this Engine's call.
    fn record_writedown(e: Env, admin: Address, amount: i128);
    /// Tell the Vault that `amount` of capital it had already written off has
    /// come back. Needs the Vault admin's signature as well as this Engine's
    /// call, and the Vault checks the cash against its own balance.
    fn record_recovery(e: Env, admin: Address, amount: i128);
    /// The Vault's admin. Read rather than assumed, because `record_writedown`
    /// and `record_recovery` are authorized by it and this Engine's admin is a
    /// separate role that rotates separately.
    fn admin(e: Env) -> Address;
}

/// The uniform pool interface. Every adapter implements exactly this, which is
/// what lets the Engine route to an off-chain credit facility and to a
/// tokenized bond with the same code path.
#[contractclient(name = "PoolAdapterClient")]
pub trait PoolAdapter {
    fn allocate(e: Env, amount: i128);
    fn deallocate(e: Env, amount: i128);
    /// Reduce the booked exposure without returning capital, for a loss that
    /// has been recognised.
    fn write_down(e: Env, amount: i128);
    /// Send whatever USDC the adapter holds above its booked exposure to the
    /// Vault it names. The destination is the adapter's own stored Vault and
    /// not a parameter, which is what makes this a way home for stranded
    /// capital rather than a withdrawal.
    fn recover_surplus(e: Env, caller: Address) -> i128;
    fn get_exposure(e: Env) -> i128;
    /// The token this adapter transfers with. Checked against the Vault's,
    /// because an adapter wired to the right contracts and the wrong asset
    /// takes the Vault's USDC and can never send it back.
    fn usdc(e: Env) -> Address;
    /// The Engine this adapter takes instructions from.
    fn engine(e: Env) -> Address;
    /// The Vault this adapter repays. `register_pool` checks both, because an
    /// adapter that repays somewhere else settles the Engine's book against
    /// cash that went to a third party.
    fn vault(e: Env) -> Address;
}

#[contracterror]
#[derive(Copy, Clone, Debug, Eq, PartialEq)]
#[repr(u32)]
pub enum EngineError {
    /// Retired with `initialize`, which a `__constructor` replaced. The host
    /// runs a constructor exactly once, inside the deploy, so there is no
    /// second call for this to be the answer to. The number is kept rather than
    /// reused so that an old error code never means something new.
    AlreadyInitialized = 400,
    NotInitialized = 401,
    NotAdmin = 402,
    PoolAlreadyRegistered = 403,
    PoolNotRegistered = 404,
    /// A cap or floor outside 0 to 10000 bps.
    InvalidCap = 405,
    InvalidAmount = 406,
    /// This pool would hold more than its cap allows.
    PoolCapExceeded = 407,
    /// The pools fronted by this originator would exceed the originator cap.
    OriginatorCapExceeded = 408,
    /// The pools in this jurisdiction would exceed the jurisdiction cap.
    JurisdictionCapExceeded = 409,
    /// The call would push idle Vault reserves below the floor.
    ReserveFloorBreached = 410,
    /// The Vault does not hold enough idle USDC to fund the allocation at all.
    InsufficientReserves = 411,
    /// Deallocating more than the pool has booked as deployed.
    ExposureUnderflow = 412,
    /// The Vault pointer cannot move while the exposure book is non-empty.
    CapitalDeployed = 413,
    /// The adapter offered does not name this Engine and this Vault back.
    AdapterMismatch = 414,
    /// Writing down more than the pool has booked as deployed.
    WriteDownExceedsExposure = 415,
    /// `accept_admin` was called with no handover in flight.
    NoPendingAdmin = 416,
    /// `accept_admin` was called by an address that was not the one proposed.
    NotPendingAdmin = 417,
    /// This Engine's admin and the Vault's admin are not the same address, so
    /// the calls that need both signatures cannot be made at all.
    AdminMismatch = 418,
    /// The address offered as this Engine's Vault does not answer the Vault
    /// interface, or answers it with a different admin.
    VaultMismatch = 419,
    /// A pool cannot leave the registry while this Engine or its adapter still
    /// books capital in it.
    PoolHasExposure = 420,
    /// A pool cannot leave the registry while a write-down is still charged
    /// against it, because the aggregate caps are built by walking the registry
    /// and the charge would leave the originator's and the jurisdiction's sums
    /// with it. Freeze it with `set_pool_cap(pool, 0)` instead, or recover the
    /// loss first.
    PoolHasWrittenOffCharge = 421,
}

/// Whitelist entry for a pool. `originator` and `jurisdiction` are the keys the
/// concentration caps aggregate over, so two pools sharing an originator are
/// counted together even though they are separate contracts.
#[derive(Clone, Debug, Eq, PartialEq)]
#[contracttype]
pub struct Pool {
    pub originator: Symbol,
    pub jurisdiction: Symbol,
    /// This pool's own limit, in bps of total assets. The effective limit is
    /// the tighter of this and the global per-pool cap.
    pub cap_bps: u32,
}

/// Global concentration limits, in bps of total assets.
#[derive(Clone, Debug, Eq, PartialEq)]
#[contracttype]
pub struct Caps {
    pub pool_bps: u32,
    pub originator_bps: u32,
    pub jurisdiction_bps: u32,
}

/// Instance storage: admin, Vault address, caps, reserve floor and the pool
/// registry. Configuration, read on every allocation.
#[derive(Clone)]
#[contracttype]
enum Cfg {
    Admin,
    Vault,
    Caps,
    ReserveFloorBps,
    Pools,
    /// Half finished admin handover: proposed, not yet accepted.
    PendingAdmin,
}

/// Persistent storage: the exposure book. These records have to survive
/// settlement cycles measured in months, so they never live in temporary or
/// instance storage.
#[derive(Clone)]
#[contracttype]
enum Store {
    Exposure(Address),
    TotalAllocated,
    /// Exposure written off and not recovered. It is not an asset and it is not
    /// counted as one; it stays on the books because it is part of the
    /// denominator of the reserve floor, and a denominator a write-down can
    /// shrink is a floor a write-down can walk through. `recover` is the only
    /// thing that lowers it, and it has to bring the cash with it.
    WrittenOff,
    /// Exposure written off against one pool, cumulative. It is charged against
    /// that pool's concentration cap, and against its originator's and its
    /// jurisdiction's, for as long as it stands: a cap measured on current
    /// exposure alone is a cap a write-down resets, and the capital behind the
    /// written-off exposure is still sitting in the adapter.
    ///
    /// Unlike `WrittenOff` this one does come down, and only in the one way
    /// that is not a statement: `recover`, which requires the cash to have
    /// reached the Vault. A loss that turns out not to have happened should not
    /// go on consuming a limit.
    WrittenOffPool(Address),
}

#[contractevent]
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct PoolRegistered {
    #[topic]
    pub pool: Address,
    pub originator: Symbol,
    pub jurisdiction: Symbol,
    pub cap_bps: u32,
}

#[contractevent]
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct CapsUpdated {
    pub pool_bps: u32,
    pub originator_bps: u32,
    pub jurisdiction_bps: u32,
}

#[contractevent]
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ReserveFloorUpdated {
    pub floor_bps: u32,
}

/// Emitted when the Engine is repointed at a different Vault. Which Vault an
/// Engine governs is the most consequential thing about it, so the move is in
/// the event stream rather than only readable from state.
#[contractevent]
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct VaultRepointed {
    #[topic]
    pub vault: Address,
}

#[contractevent]
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct Allocated {
    #[topic]
    pub pool: Address,
    pub amount: i128,
    pub pool_exposure: i128,
    /// Idle USDC left in the Vault after the release, so the reserve position
    /// after every allocation is in the event stream and not only derivable.
    pub idle_after: i128,
}

#[contractevent]
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct Deallocated {
    #[topic]
    pub pool: Address,
    pub amount: i128,
    pub pool_exposure: i128,
}

/// Emitted when exposure is written off. A write-down is the only way the book
/// falls without capital coming back, so it carries a reason and goes in the
/// event stream: an exposure that drops with no matching cash movement should
/// never be something an observer has to infer.
#[contractevent]
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct WrittenDown {
    #[topic]
    pub pool: Address,
    pub amount: i128,
    pub pool_exposure: i128,
    /// Short code for why, recorded on-chain next to the number.
    pub reason: Symbol,
}

/// Emitted when a registered pool's own concentration cap moves. The global
/// caps have carried an event since they existed; this is the per-pool figure,
/// which is the tighter of the two wherever it binds, and a limit that can
/// change without saying so is a limit nobody can reconstruct after the fact.
#[contractevent]
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct PoolCapSet {
    #[topic]
    pub pool: Address,
    pub cap_bps: u32,
}

/// Emitted when a pool leaves the registry. It carries the originator and the
/// jurisdiction because those are what the entry was contributing to: the
/// aggregate caps are built by walking the registry, so a removal moves two
/// sums that nothing else in the event stream would explain.
#[contractevent]
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct PoolUnregistered {
    #[topic]
    pub pool: Address,
    pub originator: Symbol,
    pub jurisdiction: Symbol,
}

/// Emitted when stranded capital is brought back from an adapter. It is the
/// mirror of `WrittenDown` and belongs in the stream for the same reason: an
/// exposure book that moves without an allocation or a repayment should never
/// be something an observer has to infer.
#[contractevent]
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct Recovered {
    #[topic]
    pub pool: Address,
    /// USDC the adapter sent to the Vault.
    pub amount: i128,
    /// How much of that was applied against this pool's written-off charge, and
    /// so released from its concentration cap. Anything above it is surplus
    /// over principal, which was never written off and never charged.
    pub released: i128,
    /// Everything still written off across every pool, after this recovery.
    /// It is reduced by the recovery in full where there is a loss to reduce,
    /// which is the same rule the Vault applies, so the two stay equal.
    pub written_off: i128,
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
pub struct AllocationEngine;

#[contractimpl]
impl AllocationEngine {
    /// Wire the Engine to the Vault whose capital it governs, in the
    /// transaction that deploys it.
    ///
    /// This was `initialize`, a separate call, and being separate was the
    /// problem. A contract sitting deployed and uninitialized is a contract
    /// whose admin is whoever sends the next transaction, and the gap between
    /// the deploy and the wiring is a public one: the deployer's `initialize`
    /// can be front-run by an identical call naming somebody else as admin,
    /// which on this contract is the authority to register pools and move the
    /// Vault's capital into them. A constructor runs inside the deploy, so
    /// there is no gap to race.
    ///
    /// It also runs the check the repair path runs, which `initialize` did not.
    /// `set_vault` interrogates its counterparty and `initialize` took the same
    /// address on trust, so the one call that creates the wiring was the one
    /// call that validated nothing, on a protocol whose deployment record is a
    /// list of mis-wirings. The Vault has to answer `admin()`, which rules out
    /// an ordinary account and a mistyped contract, and it has to answer with
    /// this Engine's own admin.
    ///
    /// That last condition is finding M4 made structural rather than
    /// documented. `write_down` needs this Engine's admin and the Vault's admin
    /// to be the same signature, so an Engine wired to a Vault with a different
    /// admin is an Engine that can never recognise a loss. Refusing the wiring
    /// at deploy time is cheaper than discovering it during a default.
    ///
    /// Deliberately fail closed: caps start at zero and the reserve floor at
    /// 100%, so a deployed but unconfigured Engine refuses every allocation.
    /// The alternative, defaulting to unlimited, would make a forgotten
    /// configuration step indistinguishable from an intentional one.
    pub fn __constructor(e: Env, admin: Address, vault: Address) -> Result<(), EngineError> {
        admin.require_auth();
        Self::require_vault_answers(&e, &vault, &admin)?;
        e.storage().instance().set(&Cfg::Admin, &admin);
        e.storage().instance().set(&Cfg::Vault, &vault);
        e.storage().instance().set(
            &Cfg::Caps,
            &Caps {
                pool_bps: 0,
                originator_bps: 0,
                jurisdiction_bps: 0,
            },
        );
        e.storage()
            .instance()
            .set(&Cfg::ReserveFloorBps, &(BPS as u32));
        e.storage()
            .instance()
            .set(&Cfg::Pools, &Map::<Address, Pool>::new(&e));
        Self::bump_instance(&e);
        Ok(())
    }

    /// Point the Engine at a different Vault, while its book is empty.
    ///
    /// `initialize` wrote the Vault address and there was no way back, which is
    /// how the live Engine came to be guarding a Vault that had already been
    /// superseded: the Vault that replaced it took deposits and paid its queue
    /// while the Engine went on measuring caps against the old one's balance
    /// sheet and could deploy nothing at all. Two contracts, both working, both
    /// pointed at the wrong counterparty, and no transaction that could fix it.
    ///
    /// The guard is the exposure book. Every cap and the reserve floor are
    /// measured against total assets, which is the Vault's idle USDC plus what
    /// this Engine has booked as deployed. Moving the Vault while anything is
    /// deployed would leave exposure recorded here that was funded by a balance
    /// sheet the Engine no longer reads, so the caps would be enforced against
    /// one Vault's assets and the exposure would belong to another's. Unwinding
    /// to zero first is not a formality; it is what makes the two halves of the
    /// ratio belong to the same book again.
    /// The incoming Vault is interrogated exactly as the constructor
    /// interrogates it: it has to answer `admin()`, and it has to answer with
    /// this Engine's admin, so a repair cannot leave the pair in the state the
    /// constructor refuses to create.
    ///
    /// What this call cannot do is repair the pools that are already
    /// registered, and that is the reason the adapter check is not only run at
    /// registration. `register_pool` requires an adapter to name this Engine
    /// **and this Engine's Vault**, and moving the pointer here invalidates the
    /// second half of it for every entry already in the map: the whitelist goes
    /// on holding adapters that repay the Vault this Engine has just stopped
    /// governing. Re-validating the map here is not the answer, because it
    /// would fail the repair on exactly the adapters the operator is on their
    /// way to repointing, and there is no `unregister_pool` to clear it with.
    /// So the check is a condition of use rather than of registration:
    /// `allocate`, `deallocate` and `recover` each re-run it on the pool they
    /// touch, and an adapter left behind by this call can be neither funded nor
    /// settled against until `set_counterparties` brings it across.
    pub fn set_vault(e: Env, admin: Address, vault: Address) -> Result<(), EngineError> {
        Self::require_admin(&e, &admin)?;
        if Self::total_allocated(e.clone()) > 0 {
            return Err(EngineError::CapitalDeployed);
        }
        Self::require_vault_answers(&e, &vault, &admin)?;
        e.storage().instance().set(&Cfg::Vault, &vault);
        Self::bump_instance(&e);
        VaultRepointed { vault }.publish(&e);
        Ok(())
    }

    /// Whitelist a pool adapter along with the metadata the caps aggregate
    /// over. A pool that is not registered cannot receive capital at all, so
    /// this is the first of the four gates.
    ///
    /// The adapter has to name this Engine and this Engine's Vault back. An
    /// adapter takes `allocate` and `deallocate` from the Engine it stores and
    /// sends repayments to the Vault it stores, and neither of those has to be
    /// the pair registering it. Registered without the check, an adapter
    /// pointed at somebody else's Vault takes capital from this one and repays
    /// it to a third party, while `deallocate` here decrements the book as if
    /// the money had come home. Nothing reverts and the exposure reads as
    /// settled. It is a wiring mistake rather than an attack, which is exactly
    /// the kind of thing registration should be catching.
    ///
    /// Registration is not the only place it is caught, and it could never have
    /// been. The condition is a statement about two contracts, and one of the
    /// two addresses in it belongs to this Engine and can move afterwards:
    /// `set_vault` repoints the Vault and every entry already in the registry
    /// goes on naming the one before it. So `allocate`, `deallocate` and
    /// `recover` re-run exactly this check on the pool they are about to touch,
    /// through the same helper, and this call is the first time it runs rather
    /// than the only time.
    pub fn register_pool(
        e: Env,
        admin: Address,
        pool_id: Address,
        originator: Symbol,
        jurisdiction: Symbol,
        cap_bps: u32,
    ) -> Result<(), EngineError> {
        Self::require_admin(&e, &admin)?;
        if cap_bps as i128 > BPS {
            return Err(EngineError::InvalidCap);
        }
        let mut pools = Self::pool_map(&e);
        if pools.contains_key(pool_id.clone()) {
            return Err(EngineError::PoolAlreadyRegistered);
        }
        Self::require_adapter_matches(&e, &pool_id)?;
        pools.set(
            pool_id.clone(),
            Pool {
                originator: originator.clone(),
                jurisdiction: jurisdiction.clone(),
                cap_bps,
            },
        );
        e.storage().instance().set(&Cfg::Pools, &pools);
        Self::bump_instance(&e);
        PoolRegistered {
            pool: pool_id,
            originator,
            jurisdiction,
            cap_bps,
        }
        .publish(&e);
        Ok(())
    }

    /// Change a registered pool's own concentration cap.
    ///
    /// A pool's effective limit is the tighter of its own `cap_bps` and the
    /// global `caps().pool_bps`, and until this existed only the second of
    /// those could move. Where a pool's own figure was the binding one it was
    /// binding for the life of the Engine, whatever happened to the pool: the
    /// module doc said of a defaulted originator that an operator who has
    /// decided the originator is good for it can widen the cap, and that was
    /// true only when the global cap happened to be the one doing the work.
    ///
    /// The interesting direction is down rather than up. `set_pool_cap(pool, 0)`
    /// stops new capital reaching a pool without touching a stroop of what it
    /// already holds and without releasing a stroop of what it has been charged,
    /// which is the delisting that works on a pool in default. `unregister_pool`
    /// deliberately refuses that pool, because dropping it from the registry
    /// would drop its write-off out of its originator's and its jurisdiction's
    /// sums, and a defaulted originator getting its limit back by defaulting is
    /// the thing the charge exists to prevent. A cap of zero freezes it in
    /// place instead, which is the honest version of the same intent.
    ///
    /// Lowering below what the pool currently holds is allowed and is not an
    /// oversight. The caps are checked when capital is deployed, so a pool over
    /// its new cap simply receives nothing more, and refusing the call would
    /// mean an operator watching a position deteriorate could not stop it
    /// growing until it had already shrunk.
    pub fn set_pool_cap(
        e: Env,
        admin: Address,
        pool_id: Address,
        cap_bps: u32,
    ) -> Result<(), EngineError> {
        Self::require_admin(&e, &admin)?;
        if cap_bps as i128 > BPS {
            return Err(EngineError::InvalidCap);
        }
        let mut pools = Self::pool_map(&e);
        let mut pool = pools
            .get(pool_id.clone())
            .ok_or(EngineError::PoolNotRegistered)?;
        pool.cap_bps = cap_bps;
        pools.set(pool_id.clone(), pool);
        e.storage().instance().set(&Cfg::Pools, &pools);
        Self::bump_instance(&e);
        PoolCapSet {
            pool: pool_id,
            cap_bps,
        }
        .publish(&e);
        Ok(())
    }

    /// Take a pool out of the registry.
    ///
    /// The registry was a map with no way to remove an entry, and that is not
    /// only an operational inconvenience. It is half of the third review's one
    /// High finding: `register_pool` proves an adapter names this Engine and
    /// this Engine's Vault, `set_vault` can falsify the second half of that for
    /// every entry at once, and with no way to clear the registry the answer had
    /// to be re-running the check on every call that moves capital. That fix
    /// stands and is the right one, because a check that has to hold at the
    /// moment of use should be run at the moment of use. This is the other half:
    /// an entry that has gone stale can now be removed rather than defended
    /// against forever.
    ///
    /// Three conditions, and the third is the one that matters.
    ///
    /// The Engine's exposure for the pool has to be zero, or the Engine would
    /// forget capital that is still out. The adapter's own book has to agree,
    /// because two books disagreeing at the moment one of them stops being read
    /// is how a discrepancy becomes permanent.
    ///
    /// And the pool's written-off charge has to be zero. A write-down is charged
    /// against the pool's cap, and through it against its originator's and its
    /// jurisdiction's, until the cash comes back; those sums are built by walking
    /// this registry, so an entry leaving it takes its charge out of them. A
    /// defaulted pool could then be delisted and a fresh adapter registered under
    /// the same originator with the whole limit available again, which is the
    /// concentration cap being worked around rather than raised, and it is
    /// exactly what charging the write-off was introduced to stop. So a pool in
    /// default cannot be delisted, only frozen with `set_pool_cap(pool, 0)`, and
    /// it becomes delistable when the loss is recovered rather than when it is
    /// forgotten.
    ///
    /// There is no counterparty check, and its absence is the point rather than
    /// an omission: the entry most worth removing is the one whose adapter no
    /// longer names this Engine's Vault, and a check would refuse precisely that
    /// one.
    ///
    /// What this does not reach is USDC sitting in the adapter that no book
    /// knows about, because the Engine cannot see a token balance. Sweep before
    /// delisting: `recover` needs the pool registered, and it attributes the
    /// recovery to the pool the cash actually came from, which nothing can do
    /// afterwards.
    pub fn unregister_pool(
        e: Env,
        admin: Address,
        pool_id: Address,
    ) -> Result<(), EngineError> {
        Self::require_admin(&e, &admin)?;
        let mut pools = Self::pool_map(&e);
        let pool = pools
            .get(pool_id.clone())
            .ok_or(EngineError::PoolNotRegistered)?;

        if Self::get_exposure(e.clone(), pool_id.clone()) > 0 {
            return Err(EngineError::PoolHasExposure);
        }
        // The adapter is asked rather than assumed. It is a read, so it answers
        // even for an adapter this Engine no longer governs, which is the entry
        // this call exists to remove.
        if PoolAdapterClient::new(&e, &pool_id).get_exposure() > 0 {
            return Err(EngineError::PoolHasExposure);
        }
        if Self::written_off_pool(e.clone(), pool_id.clone()) > 0 {
            return Err(EngineError::PoolHasWrittenOffCharge);
        }

        pools.remove(pool_id.clone());
        e.storage().instance().set(&Cfg::Pools, &pools);
        // Both are zero or this call would have refused, so removing them
        // changes no number. It stops the Engine paying rent on two entries
        // nothing reads, and it means a pool registered again later starts from
        // storage that is absent rather than storage that happens to hold zero.
        e.storage()
            .persistent()
            .remove(&Store::Exposure(pool_id.clone()));
        e.storage()
            .persistent()
            .remove(&Store::WrittenOffPool(pool_id.clone()));
        Self::bump_instance(&e);

        PoolUnregistered {
            pool: pool_id,
            originator: pool.originator,
            jurisdiction: pool.jurisdiction,
        }
        .publish(&e);
        Ok(())
    }

    /// Set the global concentration limits, in bps of total assets.
    ///
    /// The per-pool figure here is an upper bound on every pool: a pool's
    /// effective limit is the tighter of its own `cap_bps` and this one, so
    /// tightening globally cannot be undone by a generous per-pool entry.
    pub fn set_caps(
        e: Env,
        admin: Address,
        pool_cap_bps: u32,
        originator_cap_bps: u32,
        jurisdiction_cap_bps: u32,
    ) -> Result<(), EngineError> {
        Self::require_admin(&e, &admin)?;
        if pool_cap_bps as i128 > BPS
            || originator_cap_bps as i128 > BPS
            || jurisdiction_cap_bps as i128 > BPS
        {
            return Err(EngineError::InvalidCap);
        }
        e.storage().instance().set(
            &Cfg::Caps,
            &Caps {
                pool_bps: pool_cap_bps,
                originator_bps: originator_cap_bps,
                jurisdiction_bps: jurisdiction_cap_bps,
            },
        );
        Self::bump_instance(&e);
        CapsUpdated {
            pool_bps: pool_cap_bps,
            originator_bps: originator_cap_bps,
            jurisdiction_bps: jurisdiction_cap_bps,
        }
        .publish(&e);
        Ok(())
    }

    /// Set the minimum share of total assets that must stay as idle USDC in the
    /// Vault. This is the protocol's fast-exit liquidity, held as cash rather
    /// than as a position in someone else's lending market.
    pub fn set_reserve_floor(e: Env, admin: Address, floor_bps: u32) -> Result<(), EngineError> {
        Self::require_admin(&e, &admin)?;
        if floor_bps as i128 > BPS {
            return Err(EngineError::InvalidCap);
        }
        e.storage().instance().set(&Cfg::ReserveFloorBps, &floor_bps);
        Self::bump_instance(&e);
        ReserveFloorUpdated { floor_bps }.publish(&e);
        Ok(())
    }

    /// Route `amount` of Vault capital into `pool_id`.
    ///
    /// Admin directed and admin authorized: the operator chooses the pool and
    /// the size, the Engine decides whether that is allowed. Four limits are
    /// checked against total assets (idle reserves plus everything already
    /// deployed), and any one of them failing reverts the whole call, so a
    /// rejected allocation moves no funds and books no exposure.
    ///
    /// Total assets are the denominator on purpose. Allocating moves value
    /// from idle to deployed without changing the total, so the caps measure a
    /// share of the book rather than a share of whatever happens to be liquid,
    /// and cannot be gamed by allocating in small pieces.
    ///
    /// The reserve floor is checked last and is the guard that replaces the
    /// removed Blend liquidity buffer: whatever the caps allow, the Vault has
    /// to be left holding at least `floor_bps` of total assets in idle USDC.
    ///
    /// On success the Vault releases the USDC to the pool and the adapter
    /// books it, in the same transaction as the check. There is no window in
    /// which the Engine has approved an allocation that has not settled.
    pub fn allocate(
        e: Env,
        admin: Address,
        pool_id: Address,
        amount: i128,
    ) -> Result<(), EngineError> {
        Self::require_admin(&e, &admin)?;
        if amount <= 0 {
            return Err(EngineError::InvalidAmount);
        }
        let pools = Self::pool_map(&e);
        let pool = pools
            .get(pool_id.clone())
            .ok_or(EngineError::PoolNotRegistered)?;
        // Registration proved the adapter named this Engine and this Engine's
        // Vault on the day it was registered. `set_vault` can have moved the
        // second half of that since, so it is proved again here, before a
        // stroop of the Vault's money is committed to it.
        Self::require_adapter_matches(&e, &pool_id)?;

        let vault_address = Self::vault(e.clone())?;
        let vault = VaultClient::new(&e, &vault_address);
        // Free reserves, not the gross balance. USDC owed to a queued
        // withdrawal is on the Vault's balance and is not the protocol's to
        // deploy: counting it made the floor measure cash the Vault was already
        // committed to paying out, so a book with every dollar queued for
        // withdrawal still reported a healthy reserve ratio and still let the
        // Engine deploy against it.
        let idle = vault.accounted_free_reserves();
        let deployed = Self::total_allocated(e.clone());
        let total_assets = idle + deployed;
        if amount > idle {
            return Err(EngineError::InsufficientReserves);
        }

        let caps = Self::caps(e.clone());

        // Every cap below is measured on `charged_exposure`, which is live
        // exposure plus everything ever written off against that pool and not
        // recovered, rather than on live exposure alone.
        //
        // Live exposure alone is a quantity `write_down` sets to zero while the
        // adapter goes on holding the cash, so the same pool could be filled to
        // its cap, written off, and filled again without limit: a pool capped
        // at 40% of the book took everything the reserve floor would release,
        // in slices that each read as inside the cap, and the originator and
        // jurisdiction sums followed it up because they are built from the same
        // per-pool numbers. Charging the write-off against the cap is the
        // numerator half of the fix the floor got in its denominator.
        //
        // The denominator stays real total assets. Losses belong in the floor's
        // base, where a bigger base is a tighter constraint, and not in a cap's,
        // where a bigger base is a looser one.
        let pool_cap_bps = pool.cap_bps.min(caps.pool_bps) as i128;
        let pool_exposure = Self::get_exposure(e.clone(), pool_id.clone()) + amount;
        let pool_charged = Self::charged_exposure(e.clone(), pool_id.clone()) + amount;
        if pool_charged * BPS > pool_cap_bps * total_assets {
            return Err(EngineError::PoolCapExceeded);
        }

        // Per originator: summed across every pool that counterparty fronts.
        let originator_charged =
            Self::charged_where_originator(&e, &pools, &pool.originator) + amount;
        if originator_charged * BPS > caps.originator_bps as i128 * total_assets {
            return Err(EngineError::OriginatorCapExceeded);
        }

        // Per jurisdiction: summed across every pool under that legal regime.
        let jurisdiction_charged =
            Self::charged_where_jurisdiction(&e, &pools, &pool.jurisdiction) + amount;
        if jurisdiction_charged * BPS > caps.jurisdiction_bps as i128 * total_assets {
            return Err(EngineError::JurisdictionCapExceeded);
        }

        // Reserve floor: what the Vault is left holding as instantly available
        // cash once this release settles.
        //
        // Measured against total assets plus everything ever written off, and
        // not against total assets alone. `write_down` lowers total assets with
        // no cash moving, so a floor that is a share of total assets is a floor
        // whose absolute size a write-down lowers: allocate to the floor, write
        // the position off, allocate to the new floor, and the whole of the
        // reserves walks out in slices that are each individually inside the
        // limit. Keeping recognised losses in the base makes a write-down buy
        // nothing.
        //
        // The concentration caps above deliberately do not do this. Their
        // denominator is the same total assets, and adding to a cap's
        // denominator loosens the cap, which is the wrong direction; the floor
        // is the only limit here that a larger base makes tighter.
        let idle_after = idle - amount;
        let floor_base = vault.floor_base();
        if idle_after * BPS < Self::reserve_floor_bps(e.clone()) as i128 * floor_base {
            return Err(EngineError::ReserveFloorBreached);
        }

        Self::write_exposure(&e, &pool_id, pool_exposure);
        Self::write_total_allocated(&e, deployed + amount);
        Self::bump_instance(&e);

        vault.settle_allocation(&pool_id, &amount);
        PoolAdapterClient::new(&e, &pool_id).allocate(&amount);

        Allocated {
            pool: pool_id,
            amount,
            pool_exposure,
            idle_after,
        }
        .publish(&e);
        Ok(())
    }

    /// Record capital returning from a pool to the Vault.
    ///
    /// Authorized by the stored admin rather than by an address argument: the
    /// signature carries no admin parameter, and letting anyone trigger a
    /// repayment would let a third party force an early unwind. The adapter
    /// moves the USDC back to the Vault in the same call that reduces the
    /// exposure, so the book and the cash cannot diverge.
    ///
    /// No cap is checked here. Deallocating always moves the book towards the
    /// reserve floor and away from every concentration limit, so it can never
    /// be the operation that breaches one.
    pub fn deallocate(e: Env, pool_id: Address, amount: i128) -> Result<(), EngineError> {
        Self::admin(e.clone())?.require_auth();
        if amount <= 0 {
            return Err(EngineError::InvalidAmount);
        }
        if !Self::pool_map(&e).contains_key(pool_id.clone()) {
            return Err(EngineError::PoolNotRegistered);
        }
        // The adapter sends the cash to the Vault it stores, and the Vault this
        // Engine points at is asked to confirm it arrived. If those two have
        // parted company since registration, the confirmation would fail four
        // frames down with the Vault's own error, or, where the Vault happens
        // to be holding unannounced cash of the same size, not fail at all and
        // settle this book against somebody else's money. Say so here instead.
        Self::require_adapter_matches(&e, &pool_id)?;
        let exposure = Self::get_exposure(e.clone(), pool_id.clone());
        if amount > exposure {
            return Err(EngineError::ExposureUnderflow);
        }

        PoolAdapterClient::new(&e, &pool_id).deallocate(&amount);
        // The adapter has just moved the USDC to the Vault. Telling the Vault
        // is not bookkeeping politeness: the Vault checks the money actually
        // landed before it takes the amount off its own deployed book, so a
        // repayment that went anywhere else fails here and takes the whole
        // deallocation with it rather than settling the Engine's book against
        // cash the protocol never received.
        VaultClient::new(&e, &Self::vault(e.clone())?).record_repayment(&amount);

        let pool_exposure = exposure - amount;
        Self::write_exposure(&e, &pool_id, pool_exposure);
        Self::write_total_allocated(&e, Self::total_allocated(e.clone()) - amount);
        Self::bump_instance(&e);

        Deallocated {
            pool: pool_id,
            amount,
            pool_exposure,
        }
        .publish(&e);
        Ok(())
    }

    /// Recognise that `amount` of a pool's exposure is not coming back.
    ///
    /// Until this existed there was no way to say it. `total_allocated` moved
    /// only through `allocate` and `deallocate`, and `deallocate` transfers
    /// real USDC before it decrements the book, so a defaulted originator left
    /// the adapter holding no cash, the transfer panicking, and the exposure
    /// reporting full face value for as long as the contract lived. Every
    /// reserve ratio computed afterwards was overstated by the size of the
    /// loss, and the number that was wrong was the one the caps and the floor
    /// are measured against.
    ///
    /// It writes down three books in one call so they cannot disagree: this
    /// Engine's exposure record, the adapter's own, and the Vault's deployed
    /// capital. The Vault leg needs the admin's signature as well as this
    /// Engine's call, because reducing the Vault's deployed book without cash
    /// arriving is the one move that would otherwise let an Engine reset the
    /// limit its releases are measured against.
    ///
    /// What it must not do is buy the caller anything, and until the second
    /// review it did. The reserve floor was a share of total assets, a
    /// write-down lowers total assets, so every write-down created fresh
    /// releasable headroom worth `floor_bps` of what was written off. Allocate
    /// to the floor, write the position down, allocate to the new floor:
    /// forty rounds of that moved 999.9999999 of 1000 USDC out of a Vault
    /// holding a 25% floor, with every call inside the limit and the adapter
    /// keeping every dollar. `written_off` is the answer, and both this
    /// contract and the Vault now keep one: a cumulative total that never
    /// falls, sitting in the denominator of the floor for good.
    ///
    /// It does not decide who bears the loss. Nothing here touches agUSD
    /// supply, the withdrawal queue or the sagUSD share price, because agUSD is
    /// a synthetic dollar redeemed one for one and the queue is paid in order:
    /// as the code stands, a shortfall lands on whoever is at the back of the
    /// queue when the cash runs out. Recording the loss makes that visible
    /// instead of hidden. Choosing to distribute it differently is a product
    /// decision that has not been made, and inventing one here would be putting
    /// an answer on-chain that nobody has agreed to.
    pub fn write_down(
        e: Env,
        admin: Address,
        pool_id: Address,
        amount: i128,
        reason: Symbol,
    ) -> Result<(), EngineError> {
        Self::require_admin(&e, &admin)?;

        // The Vault leg needs the Vault's admin signature, and this Engine's
        // admin is a separate role that rotates separately. If the two have
        // diverged, say so here, with an error that names the cause, rather
        // than letting the call trap on the Vault's own NotAdmin four frames
        // down. The failure was never silent; it was illegible, which during an
        // incident is close enough to the same thing.
        //
        // It is checked before the arguments and not after, because it is a
        // condition on the wiring rather than on the call. An operator whose
        // rotation is half finished should be told that, whatever amount they
        // happened to pass; being told the amount is wrong instead sends them
        // to look at the position.
        let vault_address = Self::vault(e.clone())?;
        let vault = VaultClient::new(&e, &vault_address);
        if vault.admin() != admin {
            return Err(EngineError::AdminMismatch);
        }

        if amount <= 0 {
            return Err(EngineError::InvalidAmount);
        }
        if !Self::pool_map(&e).contains_key(pool_id.clone()) {
            return Err(EngineError::PoolNotRegistered);
        }
        let exposure = Self::get_exposure(e.clone(), pool_id.clone());
        if amount > exposure {
            return Err(EngineError::WriteDownExceedsExposure);
        }

        PoolAdapterClient::new(&e, &pool_id).write_down(&amount);
        vault.record_writedown(&admin, &amount);

        let pool_exposure = exposure - amount;
        Self::write_exposure(&e, &pool_id, pool_exposure);
        Self::write_total_allocated(&e, Self::total_allocated(e.clone()) - amount);
        Self::write_written_off(&e, Self::written_off(e.clone()) + amount);
        // Charged against this pool's cap, and through it against its
        // originator's and its jurisdiction's, until the cash comes back.
        Self::write_written_off_pool(
            &e,
            &pool_id,
            Self::written_off_pool(e.clone(), pool_id.clone()) + amount,
        );
        Self::bump_instance(&e);

        WrittenDown {
            pool: pool_id,
            amount,
            pool_exposure,
            reason,
        }
        .publish(&e);
        Ok(())
    }

    /// Bring capital home from an adapter that is holding more USDC than it has
    /// booked as exposure, and release the loss it was written off against.
    ///
    /// A write-down is a forecast, not a receipt. Private credit recovers, and
    /// until this existed a recovery had nowhere to go: `deallocate` is capped
    /// at booked exposure, a written-off position has none, and interest above
    /// principal was in the same position for the same reason. The cash sat in
    /// the adapter, and because `set_counterparties` correctly refuses to
    /// repoint an adapter holding USDC, a single stroop of it also closed the
    /// adapter's only repair path. Three generations of the private credit
    /// adapter were retired over exactly this, each one recorded in
    /// `deployments/testnet.json`.
    ///
    /// The design constraint is that a way out for stranded capital must not be
    /// a way out for anything else, so the caller chooses nothing except which
    /// pool to sweep:
    ///
    ///  - the destination is not a parameter. The adapter sends to the Vault
    ///    address it already stores, and this call checks that it is still the
    ///    Vault this Engine governs rather than resting on the check
    ///    `register_pool` ran, because `set_vault` can have moved the Engine's
    ///    end of that pairing since.
    ///  - the amount is not a parameter either. It is whatever the adapter holds
    ///    above its booked exposure, so a live position cannot be swept out from
    ///    under itself and `deallocate` stays funded.
    ///  - the Vault verifies the money reached its own balance before it changes
    ///    a number, the same way it verifies a repayment.
    ///
    /// What the Vault then does with it is release the loss, not the floor.
    /// `recognised_losses` falls by the recovery and free reserves rise by the
    /// same number in the same transaction, so `floor_base` does not move and
    /// the invariant the first Critical finding was fixed to establish, that the
    /// base the floor is a percentage of never falls, is preserved exactly. An
    /// admin who donates USDC to an adapter and sweeps it gets back the
    /// deployable headroom their own dollars just bought, and not a stroop more.
    ///
    /// The pool's concentration charge is released by the same amount, because
    /// a loss that did not happen should not go on consuming a limit.
    pub fn recover(e: Env, admin: Address, pool_id: Address) -> Result<i128, EngineError> {
        Self::require_admin(&e, &admin)?;
        if !Self::pool_map(&e).contains_key(pool_id.clone()) {
            return Err(EngineError::PoolNotRegistered);
        }
        let vault_address = Self::vault(e.clone())?;
        let vault = VaultClient::new(&e, &vault_address);
        if vault.admin() != admin {
            return Err(EngineError::AdminMismatch);
        }
        // "The destination is not a parameter" is only a safety property while
        // the Vault the adapter stores is the Vault this Engine governs. After
        // a `set_vault` that an adapter has not followed, the sweep would go to
        // the previous Vault while this one is asked to book the recovery
        // against it.
        Self::require_adapter_matches(&e, &pool_id)?;

        // The adapter moves the cash to the Vault it names and tells us how
        // much. It refuses if there is nothing above its booked exposure.
        let amount = PoolAdapterClient::new(&e, &pool_id)
            .recover_surplus(&e.current_contract_address());
        vault.record_recovery(&admin, &amount);

        // Two counters, each reduced against itself rather than against the
        // other, because they answer different questions and can legitimately
        // disagree. The global total is reduced by exactly the rule the Vault
        // applies to `recognised_losses`, which is what keeps the Engine's copy
        // of the floor's base equal to the Vault's; the pool's charge is
        // reduced by what this pool actually had against it, so a recovery that
        // exceeds one pool's write-off does not release another pool's cap.
        // Where they differ the caps stay the tighter of the two, which is the
        // direction to differ in.
        let charged = Self::written_off_pool(e.clone(), pool_id.clone());
        let released = if amount < charged { amount } else { charged };
        Self::write_written_off_pool(&e, &pool_id, charged - released);

        let total = Self::written_off(e.clone());
        let applied = if amount < total { amount } else { total };
        Self::write_written_off(&e, total - applied);
        Self::bump_instance(&e);

        Recovered {
            pool: pool_id,
            amount,
            released,
            written_off: total - applied,
        }
        .publish(&e);
        Ok(amount)
    }


    /// Book a recovery against cash that is already in the Vault, for a pool
    /// whose adapter can no longer deliver it.
    ///
    /// `recover` sweeps the adapter and books what it swept, in one call, and
    /// that is the path. The gap is on the far side of it. The adapter's
    /// `recover_surplus` may also be taken by the adapter's own admin, which
    /// exists so that an adapter stuck to superseded counterparties can be
    /// unstuck without a working Engine. Taken that way the cash reaches the
    /// Vault and no book moves, which the adapter calls the conservative
    /// direction: true of the money, false of the consequences. The adapter's
    /// surplus is now zero, so `recover` answers `NothingToRecover` and the
    /// whole call reverts, and `record_recovery` is reachable from nowhere
    /// else. The write-down that sweep was going to release then stays on
    /// `recognised_losses` for the life of the Vault, freezing the floor's
    /// share of it as permanently undeployable reserves, and stays on the
    /// pool's concentration charge for the life of the Engine. The operator can
    /// lower the floor or widen the global caps to work around it, which is a
    /// parameter change standing in for a correction.
    ///
    /// So the sweep and the booking come apart, and this is the booking alone.
    /// It asserts nothing. The amount is bounded by the Vault's own unaccounted
    /// balance, exactly as it is when `recover` supplies it, and `floor_base`
    /// is unchanged where the recovery lands against a loss and rises where it
    /// exceeds one, exactly as it is when `recover` supplies it. What a
    /// write-down cannot buy, this cannot buy back.
    ///
    /// It grants no authority that did not already exist, and the third review
    /// is why that is worth stating rather than assuming. An admin can send
    /// USDC to an adapter and sweep it through `recover` today, and the
    /// headroom that buys back is exactly the headroom their own dollars just
    /// bought. Where the cash came from was already irrelevant to the
    /// arithmetic. This takes the adapter out of a path the adapter was not the
    /// thing securing.
    ///
    /// There is no counterparty check here, for the reason `write_down` does
    /// not have one: nothing moves through the adapter, and an adapter left
    /// behind by a `set_vault` is precisely the case this has to keep serving,
    /// because it is the one whose charge nothing else can release.
    ///
    /// What it does take, and `recover` does not, is the pool as a parameter.
    /// In `recover` the pool decides which adapter is swept, so the cash and
    /// the attribution come from the same place and the caller cannot separate
    /// them. Here the cash is already in the Vault and unattributed by
    /// construction, because being unable to say where it came from is the
    /// whole reason this call exists. So which pool gets its concentration
    /// charge back is something the admin asserts, and there is nothing
    /// on-chain to check it against.
    ///
    /// Worth stating rather than leaving to be found. The global loss book and
    /// the Vault's both move by exactly the cash that arrived whatever pool is
    /// named, so solvency does not rest on the assertion being honest. The
    /// per-pool concentration charge does: a recovery booked against the wrong
    /// pool frees a cap for a pool whose loss did not come home. That is not a
    /// privilege escalation, since `set_caps` already lets this same admin
    /// widen the same limit outright, and it is not something a guard could
    /// fix, since there is no fact here to check the claim against. It is a
    /// disclosure. `a_booked_recovery_releases_the_cap_of_whichever_pool_the_admin_names`
    /// is the case, so it is a property of the suite rather than a claim in a
    /// comment.
    /// Removed once, and back for a reason that is checkable rather than an
    /// opinion. An invariant fuzzer showed it could lower `floor_base` in four
    /// operations: a donation straight to the Vault, an allocation, a
    /// write-down, a booking. The base read the real token balance then, so
    /// unannounced cash raised it the moment it landed, and booking the same
    /// cash afterwards lowered `recognised_losses` by the same amount with no
    /// further cash moving. One dollar, counted on arrival and spent again on
    /// booking.
    ///
    /// The base is `booked_reserves` based now, and both halves are neutral
    /// under it. An unannounced arrival moves no term. A booking moves
    /// `booked_reserves` up by exactly what it moves `recognised_losses` down,
    /// and both sit in the base, so their sum does not change. The defect was a
    /// property of the basis rather than of this call, and the basis is gone.
    /// The fuzzer drives this operation again, with the base invariant switched
    /// on for it, so the claim is checked on every run rather than argued here.

    pub fn book_recovery(
        e: Env,
        admin: Address,
        pool_id: Address,
        amount: i128,
    ) -> Result<(), EngineError> {
        Self::require_admin(&e, &admin)?;
        if amount <= 0 {
            return Err(EngineError::InvalidAmount);
        }
        if !Self::pool_map(&e).contains_key(pool_id.clone()) {
            return Err(EngineError::PoolNotRegistered);
        }
        let vault_address = Self::vault(e.clone())?;
        let vault = VaultClient::new(&e, &vault_address);
        if vault.admin() != admin {
            return Err(EngineError::AdminMismatch);
        }

        vault.record_recovery(&admin, &amount);

        // The same two counters `recover` moves, reduced by the same rule, so
        // that a recovery booked this way and a recovery swept through the
        // adapter leave the Engine in states that cannot be told apart.
        let charged = Self::written_off_pool(e.clone(), pool_id.clone());
        let released = if amount < charged { amount } else { charged };
        Self::write_written_off_pool(&e, &pool_id, charged - released);

        let total = Self::written_off(e.clone());
        let applied = if amount < total { amount } else { total };
        Self::write_written_off(&e, total - applied);
        Self::bump_instance(&e);

        Recovered {
            pool: pool_id,
            amount,
            released,
            written_off: total - applied,
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
    pub fn propose_admin(e: Env, admin: Address, new_admin: Address) -> Result<(), EngineError> {
        Self::require_admin(&e, &admin)?;
        e.storage().instance().set(&Cfg::PendingAdmin, &new_admin);
        Self::bump_instance(&e);
        AdminProposed { new_admin }.publish(&e);
        Ok(())
    }

    /// Complete a handover. Only the proposed address can call it, and it has
    /// to authorize the call itself: that authorization is the entire point of
    /// the second step.
    pub fn accept_admin(e: Env, new_admin: Address) -> Result<(), EngineError> {
        let pending: Address = e
            .storage()
            .instance()
            .get(&Cfg::PendingAdmin)
            .ok_or(EngineError::NoPendingAdmin)?;
        if pending != new_admin {
            return Err(EngineError::NotPendingAdmin);
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

    /// Free Vault reserves as a share of the floor's base, in bps. This is the
    /// number `set_reserve_floor` sets a lower bound on, and it is measured
    /// against the same base `allocate` measures the floor against, so the
    /// sentence stays true after a loss as well as before one.
    ///
    /// Free, not gross: USDC owed to a queued withdrawal is not reserve, it is
    /// a payment that has not happened yet. Counting it was what let a Vault
    /// with every dollar queued for withdrawal report a healthy ratio.
    ///
    /// Over the floor's base, not over net assets, for the same reason. With
    /// net assets underneath it, recognising a loss made this number go *up*,
    /// which is the opposite of what losing money should do to a liquidity
    /// ratio: 800 idle against a 1000 book that had just lost 200 reported
    /// 8888 bps rather than 8000. `floor_base` keeps the loss in the
    /// denominator, so the ratio holds still when a loss is recognised and
    /// falls when cash actually leaves.
    pub fn get_reserve_ratio(e: Env) -> Result<u32, EngineError> {
        let vault_address = Self::vault(e.clone())?;
        let vault = VaultClient::new(&e, &vault_address);
        let idle = vault.accounted_free_reserves();
        let base = vault.floor_base();
        if base <= 0 {
            // No assets means nothing is at risk, so the reserve is complete.
            return Ok(BPS as u32);
        }
        Ok((idle * BPS / base) as u32)
    }

    /// Exposure written off since deployment and not recovered. It rises on a
    /// write-down and falls only when `recover` brings the cash back to the
    /// Vault, which is the one event that is a receipt rather than a statement.
    ///
    /// It is not an asset and `total_allocated` correctly excludes it. It
    /// exists because the reserve floor needs a base a write-down cannot move,
    /// and `recover` cannot move it either: what a recovery takes out of this
    /// number it puts into the Vault's free reserves in the same transaction.
    pub fn written_off(e: Env) -> i128 {
        e.storage()
            .persistent()
            .get(&Store::WrittenOff)
            .unwrap_or(0)
    }

    /// Exposure written off against one pool and not recovered. This is what a
    /// write-down costs the pool permanently: it is charged against the pool's
    /// concentration cap, and against its originator's and its jurisdiction's,
    /// exactly as if the capital were still deployed there, because it is.
    pub fn written_off_pool(e: Env, pool_id: Address) -> i128 {
        e.storage()
            .persistent()
            .get(&Store::WrittenOffPool(pool_id))
            .unwrap_or(0)
    }

    /// The quantity the three concentration caps are actually measured on: what
    /// is deployed into this pool plus what has been written off against it.
    ///
    /// It differs from `get_exposure` only after a write-down, and that
    /// difference is the finding. `get_exposure` is what the pool owes; this is
    /// what the pool has had, which is what a concentration limit is a limit
    /// on while the adapter is still holding the money.
    pub fn charged_exposure(e: Env, pool_id: Address) -> i128 {
        Self::get_exposure(e.clone(), pool_id.clone()) + Self::written_off_pool(e, pool_id)
    }

    /// The Vault's admin, as the Vault reports it.
    pub fn vault_admin(e: Env) -> Result<Address, EngineError> {
        Ok(VaultClient::new(&e, &Self::vault(e.clone())?).admin())
    }

    /// Whether this Engine's admin and the Vault's admin are the same address.
    ///
    /// `write_down` and `recover` both need one signature that satisfies both
    /// contracts, and the two admin roles rotate independently, so a handover
    /// completed on one side and not the other leaves loss recognition
    /// impossible until it is completed on the other. Nothing can stop the
    /// operator rotating one at a time, and nothing should: an admin rotation
    /// that required a counterparty's cooperation would be a rotation that a
    /// hostile counterparty could block. What was missing was any way to see
    /// the divergence before an incident put a number on it. This is that way,
    /// it is one call, and it is false exactly when the two calls that need
    /// both keys will refuse.
    pub fn admin_aligned(e: Env) -> bool {
        let Ok(vault_address) = Self::vault(e.clone()) else {
            return false;
        };
        let Ok(admin) = Self::admin(e.clone()) else {
            return false;
        };
        matches!(
            VaultClient::new(&e, &vault_address).try_admin(),
            Ok(Ok(vault_admin)) if vault_admin == admin
        )
    }

    /// The denominator `reserve_floor_bps` is a share of: the Vault's free
    /// reserves, plus what this Engine has booked as deployed, plus everything
    /// it has ever written off.
    pub fn floor_base(e: Env) -> Result<i128, EngineError> {
        let vault_address = Self::vault(e.clone())?;
        Ok(VaultClient::new(&e, &vault_address).floor_base())
    }

    /// Capital currently deployed into `pool_id`, in USDC.
    pub fn get_exposure(e: Env, pool_id: Address) -> i128 {
        e.storage()
            .persistent()
            .get(&Store::Exposure(pool_id))
            .unwrap_or(0)
    }

    /// The whole exposure book, keyed by pool. Registered pools with no
    /// exposure are included as zero, so the map doubles as the whitelist.
    pub fn get_exposures(e: Env) -> Map<Address, i128> {
        let mut out = Map::new(&e);
        for pool_id in Self::pool_map(&e).keys().iter() {
            out.set(pool_id.clone(), Self::get_exposure(e.clone(), pool_id));
        }
        out
    }

    /// Total capital booked as deployed across every pool. The Vault reads this
    /// to compute total assets.
    pub fn total_allocated(e: Env) -> i128 {
        e.storage()
            .persistent()
            .get(&Store::TotalAllocated)
            .unwrap_or(0)
    }

    pub fn caps(e: Env) -> Caps {
        e.storage().instance().get(&Cfg::Caps).unwrap_or(Caps {
            pool_bps: 0,
            originator_bps: 0,
            jurisdiction_bps: 0,
        })
    }

    pub fn reserve_floor_bps(e: Env) -> u32 {
        e.storage()
            .instance()
            .get(&Cfg::ReserveFloorBps)
            .unwrap_or(BPS as u32)
    }

    pub fn get_pool(e: Env, pool_id: Address) -> Result<Pool, EngineError> {
        Self::pool_map(&e)
            .get(pool_id)
            .ok_or(EngineError::PoolNotRegistered)
    }

    pub fn pools(e: Env) -> Vec<Address> {
        Self::pool_map(&e).keys()
    }

    pub fn vault(e: Env) -> Result<Address, EngineError> {
        e.storage()
            .instance()
            .get(&Cfg::Vault)
            .ok_or(EngineError::NotInitialized)
    }

    pub fn admin(e: Env) -> Result<Address, EngineError> {
        e.storage()
            .instance()
            .get(&Cfg::Admin)
            .ok_or(EngineError::NotInitialized)
    }

    // ---- internals ----

    fn require_admin(e: &Env, admin: &Address) -> Result<(), EngineError> {
        let stored: Address = e
            .storage()
            .instance()
            .get(&Cfg::Admin)
            .ok_or(EngineError::NotInitialized)?;
        if stored != *admin {
            return Err(EngineError::NotAdmin);
        }
        admin.require_auth();
        Ok(())
    }

    /// The Vault offered has to answer `admin()`, which an ordinary account
    /// cannot do, and it has to answer with `admin`. See `__constructor` for
    /// why the second half is a wiring condition rather than a preference.
    ///
    /// The two halves refuse differently, and it is worth knowing which is
    /// which when reading a failure. A contract that answers with the wrong
    /// address returns `VaultMismatch` from here. An ordinary account does not
    /// return anything: the host refuses to invoke a non-contract address at
    /// all, so the call fails with `InvalidInput` before `try_admin` has an
    /// error to catch. Both are refusals and the guard holds either way; only
    /// one of them is legible, and `try_` cannot make the other one so.
    fn require_vault_answers(e: &Env, vault: &Address, admin: &Address) -> Result<(), EngineError> {
        match VaultClient::new(e, vault).try_admin() {
            Ok(Ok(vault_admin)) if vault_admin == *admin => Ok(()),
            _ => Err(EngineError::VaultMismatch),
        }
    }

    /// The adapter has to name this Engine and this Engine's Vault, right now.
    ///
    /// This is `register_pool`'s check, factored out because registration is
    /// not the only moment it has to hold. Half of the condition is a fact
    /// about this Engine, and `set_vault` can change that fact: the registry is
    /// a map with no way to clear it, so the moment the Vault pointer moves,
    /// every pool already in it names the Vault this Engine no longer governs.
    ///
    /// Left unchecked, the next `allocate` releases the **new** Vault's USDC to
    /// an adapter that repays the **old** one. The adapter accepts it, because
    /// its Engine pointer is the one thing that did not change; and the capital
    /// is then unrecoverable to the Vault that funded it, because `deallocate`
    /// sends the cash to the old Vault and then asks the new one to confirm it
    /// arrived, which it cannot, so the call reverts and the position can never
    /// be unwound. In this protocol the old Vault is a superseded one, where
    /// nothing can move USDC at all. Every other edge of the wiring is checked
    /// on both sides; this was the one checked once.
    ///
    /// It costs two cross-contract reads on every call that moves capital, and
    /// it is worth them: the entire deployment record of this repository is a
    /// list of contracts pointed at counterparties that had moved on.
    ///
    /// The refusals differ and it is worth knowing which is which. An adapter
    /// naming a different Engine or a different Vault returns `AdapterMismatch`
    /// from here. An address that is not a contract at all is refused by the
    /// host, which will not invoke one, so the call fails with `InvalidInput`
    /// before `try_` has a contract error to catch.
    fn require_adapter_matches(e: &Env, pool_id: &Address) -> Result<(), EngineError> {
        let vault_address = Self::vault(e.clone())?;
        let adapter = PoolAdapterClient::new(e, pool_id);
        match (adapter.try_engine(), adapter.try_vault()) {
            (Ok(Ok(engine)), Ok(Ok(vault)))
                if engine == e.current_contract_address() && vault == vault_address => {}
            _ => return Err(EngineError::AdapterMismatch),
        }
        // Two edges of the triangle were checked and the third was not. Both of
        // the above are about which contracts are wired together; this one is
        // about the asset, and the asset is what the transfers actually move.
        //
        // An adapter holding the right pointers and the wrong token passes
        // everything else and is a one way door. `settle_allocation` sends what
        // the Vault holds, so real USDC arrives; `deallocate` sends back the
        // token the adapter stores, of which it has none, and traps;
        // `recover_surplus` measures its surplus in that same token and reports
        // nothing to recover. A write-down clears all three books and the money
        // stays where it is. That is the failure that retired three generations
        // of the private credit adapter, reachable here through a constructor
        // argument nothing interrogated.
        match (
            adapter.try_usdc(),
            VaultClient::new(e, &vault_address).try_usdc(),
        ) {
            (Ok(Ok(held)), Ok(Ok(custodied))) if held == custodied => Ok(()),
            _ => Err(EngineError::AdapterMismatch),
        }
    }

    /// Charged exposure summed across every registered pool fronted by
    /// `originator`. The cap is on the counterparty, not on the contract, so
    /// three pools from the same originator count as one position, and a
    /// position written off at one of them goes on counting against all three.
    fn charged_where_originator(
        e: &Env,
        pools: &Map<Address, Pool>,
        originator: &Symbol,
    ) -> i128 {
        let mut total: i128 = 0;
        for (pool_id, pool) in pools.iter() {
            if pool.originator == *originator {
                total += Self::charged_exposure(e.clone(), pool_id);
            }
        }
        total
    }

    /// Charged exposure summed across every registered pool in `jurisdiction`.
    fn charged_where_jurisdiction(
        e: &Env,
        pools: &Map<Address, Pool>,
        jurisdiction: &Symbol,
    ) -> i128 {
        let mut total: i128 = 0;
        for (pool_id, pool) in pools.iter() {
            if pool.jurisdiction == *jurisdiction {
                total += Self::charged_exposure(e.clone(), pool_id);
            }
        }
        total
    }

    fn write_exposure(e: &Env, pool_id: &Address, value: i128) {
        let key = Store::Exposure(pool_id.clone());
        e.storage().persistent().set(&key, &value);
        e.storage()
            .persistent()
            .extend_ttl(&key, EXPOSURE_LIFETIME, EXPOSURE_BUMP);
    }

    fn write_total_allocated(e: &Env, value: i128) {
        e.storage().persistent().set(&Store::TotalAllocated, &value);
        e.storage().persistent().extend_ttl(
            &Store::TotalAllocated,
            EXPOSURE_LIFETIME,
            EXPOSURE_BUMP,
        );
    }

    fn write_written_off(e: &Env, value: i128) {
        e.storage().persistent().set(&Store::WrittenOff, &value);
        e.storage()
            .persistent()
            .extend_ttl(&Store::WrittenOff, EXPOSURE_LIFETIME, EXPOSURE_BUMP);
    }

    fn write_written_off_pool(e: &Env, pool_id: &Address, value: i128) {
        let key = Store::WrittenOffPool(pool_id.clone());
        e.storage().persistent().set(&key, &value);
        e.storage()
            .persistent()
            .extend_ttl(&key, EXPOSURE_LIFETIME, EXPOSURE_BUMP);
    }

    fn pool_map(e: &Env) -> Map<Address, Pool> {
        e.storage()
            .instance()
            .get(&Cfg::Pools)
            .unwrap_or(Map::new(e))
    }

    fn bump_instance(e: &Env) {
        e.storage()
            .instance()
            .extend_ttl(INSTANCE_LIFETIME, INSTANCE_BUMP);
    }
}

mod test;
