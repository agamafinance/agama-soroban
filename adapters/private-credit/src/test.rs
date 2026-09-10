#![cfg(test)]
use super::*;
use mock_usdc::{MockUsdc, MockUsdcClient};
use soroban_sdk::testutils::{Address as _, MockAuth, MockAuthInvoke};
use soroban_sdk::IntoVal;
use soroban_sdk::{contract, contractimpl, symbol_short, Address, Env, String};

const USDC: i128 = 10_000_000; // 1 USDC at 7 decimals

/// The one call `set_counterparties` makes on an Allocation Engine. The real
/// Engine has its own suite; standing it up here would drag the whole stack
/// into a crate that is testing two words of storage.
#[contract]
pub struct MockEngine;

#[contractimpl]
impl MockEngine {
    pub fn initialize(e: Env, vault: Address) {
        e.storage().instance().set(&symbol_short!("vault"), &vault);
    }
    pub fn vault(e: Env) -> Address {
        e.storage().instance().get(&symbol_short!("vault")).unwrap()
    }
}


/// Stand-in for the Vault. It custodies nothing and enforces nothing; the only
/// thing the adapter asks it is which token it holds, because an adapter wired
/// to a Vault that custodies a different asset is a one way door for everything
/// that Vault sends it.
#[contract]
pub struct MockVault;

#[contractimpl]
impl MockVault {
    pub fn initialize(e: Env, usdc: Address) {
        e.storage().instance().set(&symbol_short!("usdc"), &usdc);
    }
    pub fn usdc(e: Env) -> Address {
        e.storage().instance().get(&symbol_short!("usdc")).unwrap()
    }
}

/// A Vault stand-in custodying `usdc`, which is what the adapter checks itself
/// against at construction and at every repointing.
fn mock_vault(e: &Env, usdc: &Address) -> Address {
    let id = e.register(MockVault, ());
    MockVaultClient::new(e, &id).initialize(usdc);
    id
}

struct Fix {
    e: Env,
    usdc: MockUsdcClient<'static>,
    adapter: PrivateCreditAdapterClient<'static>,
    adapter_id: Address,
    vault: Address,
    admin: Address,
}

/// Both counterparties are the smallest contracts that can answer what the
/// adapter asks of them: the Engine which Vault it governs, and the Vault which
/// token it custodies. The Vault used to be a plain generated address, which
/// stopped being enough once the adapter started checking that the asset it
/// transfers with is the asset that Vault holds. The full Engine to adapter
/// wiring is still covered end to end in the allocation-engine tests.
fn setup() -> Fix {
    let e = Env::default();
    e.mock_all_auths();

    let admin = Address::generate(&e);

    let usdc_id = e.register(MockUsdc, ());
    let usdc = MockUsdcClient::new(&e, &usdc_id);
    usdc.initialize(
        &admin,
        &7u32,
        &String::from_str(&e, "USD Coin"),
        &String::from_str(&e, "USDC"),
    );
    let vault = mock_vault(&e, &usdc_id);

    // The constructor interrogates the Engine, so the Engine has to be a
    // contract that answers `vault()` with the Vault this adapter is given.
    let engine = e.register(MockEngine, ());
    MockEngineClient::new(&e, &engine).initialize(&vault);

    let adapter_id = e.register(
        PrivateCreditAdapter,
        (
            admin.clone(),
            engine.clone(),
            vault.clone(),
            usdc_id.clone(),
        ),
    );
    let adapter = PrivateCreditAdapterClient::new(&e, &adapter_id);

    Fix {
        e,
        usdc,
        adapter,
        adapter_id,
        vault,
        admin,
    }
}

#[test]
fn allocate_books_exposure() {
    let f = setup();
    assert_eq!(f.adapter.get_exposure(), 0);
    f.adapter.allocate(&(500 * USDC));
    assert_eq!(f.adapter.get_exposure(), 500 * USDC);
    f.adapter.allocate(&(250 * USDC));
    assert_eq!(f.adapter.get_exposure(), 750 * USDC);
}

#[test]
fn deallocate_returns_capital_and_reduces_exposure_together() {
    let f = setup();
    // The Vault has released 500 USDC to the adapter, the Engine books it.
    f.usdc.faucet(&f.adapter_id, &(500 * USDC));
    f.adapter.allocate(&(500 * USDC));

    // A 200 USDC repayment: the cash reaches the Vault and the exposure drops
    // by the same amount in the same call, so the two cannot drift apart.
    f.adapter.deallocate(&(200 * USDC));
    assert_eq!(f.adapter.get_exposure(), 300 * USDC);
    assert_eq!(f.usdc.balance(&f.vault), 200 * USDC);
    assert_eq!(f.usdc.balance(&f.adapter_id), 300 * USDC);
}

#[test]
fn deallocate_beyond_exposure_is_rejected() {
    let f = setup();
    f.usdc.faucet(&f.adapter_id, &(500 * USDC));
    f.adapter.allocate(&(100 * USDC));

    // The adapter holds more USDC than it has booked exposure for, and must
    // still refuse to return capital it never recorded as deployed.
    assert_eq!(
        f.adapter.try_deallocate(&(200 * USDC)),
        Err(Ok(AdapterError::ExposureUnderflow))
    );
    assert_eq!(f.adapter.get_exposure(), 100 * USDC);
    assert_eq!(f.usdc.balance(&f.vault), 0);
}

#[test]
fn non_positive_amounts_are_rejected() {
    let f = setup();
    assert_eq!(
        f.adapter.try_allocate(&0),
        Err(Ok(AdapterError::InvalidAmount))
    );
    assert_eq!(
        f.adapter.try_allocate(&(-100 * USDC)),
        Err(Ok(AdapterError::InvalidAmount))
    );
    assert_eq!(
        f.adapter.try_deallocate(&0),
        Err(Ok(AdapterError::InvalidAmount))
    );
}

#[test]
fn only_the_engine_can_move_capital() {
    let f = setup();
    f.usdc.faucet(&f.adapter_id, &(500 * USDC));
    f.adapter.allocate(&(500 * USDC));

    // Drop the blanket auth mock: without the Engine's authorization neither
    // side of the interface moves, so no admin or third party can allocate
    // around the concentration caps or drain the position.
    f.e.mock_auths(&[]);
    assert!(f.adapter.try_allocate(&(100 * USDC)).is_err());
    assert!(f.adapter.try_deallocate(&(100 * USDC)).is_err());
    assert_eq!(f.adapter.get_exposure(), 500 * USDC);
}

#[test]
fn metadata_matches_the_feed_the_pool_is_priced_from() {
    let f = setup();
    assert_eq!(f.adapter.pool_kind(), POOL_KIND);
    // The Oracle Adapter registers PC_NAV with a 7 day staleness window, which
    // is the on-chain counterpart of this settlement window.
    assert_eq!(f.adapter.oracle_feed(), ORACLE_FEED);
    assert_eq!(f.adapter.settlement_window(), (15, 90));
}


#[test]
fn the_counterparties_move_only_together_and_only_while_the_adapter_is_empty() {
    let f = setup();
    let stranger = Address::generate(&f.e);

    // A replacement Engine that governs a replacement Vault. This is the
    // situation the setter exists for: both addresses written at
    // initialization have been superseded, and an adapter is far too cheap a
    // contract to redeploy over two words of storage.
    let new_vault = mock_vault(&f.e, &f.usdc.address);
    let new_engine = f.e.register(MockEngine, ());
    MockEngineClient::new(&f.e, &new_engine).initialize(&new_vault);

    assert_eq!(
        f.adapter
            .try_set_counterparties(&stranger, &new_engine, &new_vault),
        Err(Ok(AdapterError::NotAdmin))
    );

    // An Engine that governs somebody else is refused, and so is an address
    // that cannot answer the question at all. Without this the Vault pointer
    // would be free: the adapter is empty, so the balance check passes, and
    // the misdirection would only show up at the first repayment.
    assert_eq!(
        f.adapter
            .try_set_counterparties(&f.admin, &new_engine, &stranger),
        Err(Ok(AdapterError::CounterpartyMismatch))
    );
    assert_eq!(
        f.adapter
            .try_set_counterparties(&f.admin, &stranger, &new_vault),
        Err(Ok(AdapterError::CounterpartyMismatch))
    );

    f.adapter
        .set_counterparties(&f.admin, &new_engine, &new_vault);
    assert_eq!(f.adapter.engine(), new_engine);
    assert_eq!(f.adapter.vault(), new_vault);

    // Book a position: exposure recorded here was authorized by this Engine
    // against its caps, and only this Engine can unwind it.
    f.usdc.faucet(&f.adapter_id, &(500 * USDC));
    f.adapter.allocate(&(500 * USDC));
    let other_vault = mock_vault(&f.e, &f.usdc.address);
    let other_engine = f.e.register(MockEngine, ());
    MockEngineClient::new(&f.e, &other_engine).initialize(&other_vault);
    assert_eq!(
        f.adapter
            .try_set_counterparties(&f.admin, &other_engine, &other_vault),
        Err(Ok(AdapterError::NotEmpty))
    );

    // Unwinding the book is not enough on its own. A repayment that has
    // arrived but not been booked is still money owed to the Vault the adapter
    // is pointed at, and `deallocate` sends it wherever that pointer says.
    f.adapter.deallocate(&(500 * USDC));
    assert_eq!(f.adapter.get_exposure(), 0);
    f.usdc.faucet(&f.adapter_id, &(10 * USDC));
    assert_eq!(
        f.adapter
            .try_set_counterparties(&f.admin, &other_engine, &other_vault),
        Err(Ok(AdapterError::NotEmpty))
    );

    // Empty on both counts, and it opens again.
    f.adapter.allocate(&(10 * USDC));
    f.adapter.deallocate(&(10 * USDC));
    assert_eq!(f.usdc.balance(&f.adapter_id), 0);
    f.adapter
        .set_counterparties(&f.admin, &other_engine, &other_vault);
    assert_eq!(f.adapter.engine(), other_engine);
    assert_eq!(f.adapter.vault(), other_vault);
}

/// A defaulted position cannot be deallocated: `deallocate` transfers the USDC
/// before it decrements the book, and there is no USDC. Without a write-down
/// the exposure reports face value for the life of the contract.
#[test]
fn a_defaulted_position_can_be_written_off_without_returning_capital() {
    let f = setup();
    f.usdc.faucet(&f.adapter_id, &(500 * USDC));
    f.adapter.allocate(&(500 * USDC));

    // The originator draws down and defaults: the cash is gone from here.
    f.usdc.burn(&f.adapter_id, &(500 * USDC));
    assert!(f.adapter.try_deallocate(&(500 * USDC)).is_err());
    assert_eq!(f.adapter.get_exposure(), 500 * USDC);

    // The write-down moves the book and nothing else.
    f.adapter.write_down(&(200 * USDC));
    assert_eq!(f.adapter.get_exposure(), 300 * USDC);
    assert_eq!(f.usdc.balance(&f.vault), 0);

    // It cannot write off more than is booked, and it is not a way to move
    // capital: zero and negative are refused like everywhere else.
    assert_eq!(
        f.adapter.try_write_down(&(301 * USDC)),
        Err(Ok(AdapterError::WriteDownExceedsExposure))
    );
    assert_eq!(
        f.adapter.try_write_down(&0),
        Err(Ok(AdapterError::InvalidAmount))
    );

    // And it is the Engine's call, not anybody's: same gate as allocate.
    f.e.mock_auths(&[]);
    assert!(f.adapter.try_write_down(&(100 * USDC)).is_err());
    assert_eq!(f.adapter.get_exposure(), 300 * USDC);
}

/// Admin rotation, in the two steps that make it safe: a proposal that changes
/// nothing, and an acceptance signed by the address it hands the role to. An
/// unreachable key can therefore never be handed the role, which is the
/// unrecoverable state a one call setter would create in one transaction.
#[test]
fn the_admin_role_moves_only_to_an_address_that_signs_for_it() {
    let f = setup();
    let successor = Address::generate(&f.e);
    let mallory = Address::generate(&f.e);
    assert_eq!(f.adapter.pending_admin(), None);

    // A stranger cannot propose.
    assert_eq!(
        f.adapter.try_propose_admin(&mallory, &mallory),
        Err(Ok(AdapterError::NotAdmin))
    );

    // The admin proposes and nothing moves yet.
    f.adapter.propose_admin(&f.admin, &successor);
    assert_eq!(f.adapter.pending_admin(), Some(successor.clone()));
    assert_eq!(f.adapter.admin(), f.admin);

    // Only the proposed address can accept, and it has to sign for itself.
    assert_eq!(
        f.adapter.try_accept_admin(&mallory),
        Err(Ok(AdapterError::NotPendingAdmin))
    );
    f.e.mock_auths(&[MockAuth {
        address: &mallory,
        invoke: &MockAuthInvoke {
            contract: &f.adapter.address,
            fn_name: "accept_admin",
            args: (successor.clone(),).into_val(&f.e),
            sub_invokes: &[],
        },
    }]);
    assert!(f.adapter.try_accept_admin(&successor).is_err());
    assert_eq!(f.adapter.admin(), f.admin);

    f.e.mock_all_auths();
    f.adapter.accept_admin(&successor);
    assert_eq!(f.adapter.admin(), successor);
    assert_eq!(f.adapter.pending_admin(), None);
    assert_eq!(
        f.adapter.try_accept_admin(&successor),
        Err(Ok(AdapterError::NoPendingAdmin))
    );
}

/// The sweep is the surplus and only the surplus, which is what makes it a way
/// home for stranded capital rather than a way to empty a live position. There
/// is no amount parameter to get wrong: what leaves is the balance less the
/// booked exposure, so `deallocate` stays funded for exactly what it owes.
#[test]
fn recover_surplus_sends_the_surplus_home_and_leaves_the_position_funded() {
    let f = setup();
    // The Vault has released 500 USDC and the Engine has booked it.
    f.usdc.faucet(&f.adapter_id, &(500 * USDC));
    f.adapter.allocate(&(500 * USDC));

    // Interest above principal arrives from the originator: cash the book never
    // expected, with no exposure for `deallocate` to return it against.
    f.usdc.faucet(&f.adapter_id, &(40 * USDC));
    assert_eq!(f.usdc.balance(&f.adapter_id), 540 * USDC);

    let engine = f.adapter.engine();
    assert_eq!(f.adapter.recover_surplus(&engine), 40 * USDC);

    // Exactly the surplus moved, it went to the Vault this adapter stores, and
    // the book did not shift by a stroop: a recovery is not a repayment.
    assert_eq!(f.usdc.balance(&f.vault), 40 * USDC);
    assert_eq!(f.usdc.balance(&f.adapter_id), 500 * USDC);
    assert_eq!(f.adapter.get_exposure(), 500 * USDC);

    // Which is the whole reason the amount is the surplus rather than the
    // balance. The position is still fully funded, so it can still be repaid in
    // full through the ordinary path.
    f.adapter.deallocate(&(500 * USDC));
    assert_eq!(f.adapter.get_exposure(), 0);
    assert_eq!(f.usdc.balance(&f.vault), 540 * USDC);
    assert_eq!(f.usdc.balance(&f.adapter_id), 0);
}

/// There is no destination parameter, so the admin path cannot be a path to
/// anywhere except the Vault the adapter already names. That is structural
/// rather than a permission check, and it is what makes it safe to let the
/// admin call this at all.
#[test]
fn the_recovery_has_no_destination_for_the_admin_to_choose() {
    let f = setup();
    // A position written down to zero, whose cash then came back. There is no
    // exposure left for `deallocate` to return it against, and a single stroop
    // of it also closes `set_counterparties`. This is the state that retired
    // three generations of this adapter.
    f.adapter.allocate(&(200 * USDC));
    f.adapter.write_down(&(200 * USDC));
    f.usdc.faucet(&f.adapter_id, &(200 * USDC));
    assert_eq!(f.adapter.get_exposure(), 0);
    assert_eq!(f.usdc.balance(&f.admin), 0);

    assert_eq!(f.adapter.recover_surplus(&f.admin), 200 * USDC);

    // The money is at the stored Vault, and the admin who called for it is no
    // richer than before.
    assert_eq!(f.adapter.vault(), f.vault);
    assert_eq!(f.usdc.balance(&f.adapter.vault()), 200 * USDC);
    assert_eq!(
        f.usdc.balance(&f.admin),
        0,
        "the caller is not a destination this call has"
    );
    assert_eq!(f.usdc.balance(&f.adapter_id), 0);

    // And with the balance clear the adapter can be repointed again, which is
    // the repair path the stranded cash used to close.
    let new_vault = mock_vault(&f.e, &f.usdc.address);
    let new_engine = f.e.register(MockEngine, ());
    MockEngineClient::new(&f.e, &new_engine).initialize(&new_vault);
    f.adapter
        .set_counterparties(&f.admin, &new_engine, &new_vault);
    assert_eq!(f.adapter.vault(), new_vault);
}

/// An address that is neither this adapter's Engine nor its admin is refused,
/// and refused on identity rather than on a missing signature. The
/// authorization is mocked for this one call and this one caller, so the
/// stranger genuinely signs for it and the contract turns it down anyway.
#[test]
fn a_stranger_cannot_sweep_the_adapter_even_holding_a_valid_signature() {
    let f = setup();
    f.usdc.faucet(&f.adapter_id, &(100 * USDC));
    let mallory = Address::generate(&f.e);

    f.e.mock_auths(&[MockAuth {
        address: &mallory,
        invoke: &MockAuthInvoke {
            contract: &f.adapter.address,
            fn_name: "recover_surplus",
            args: (mallory.clone(),).into_val(&f.e),
            sub_invokes: &[],
        },
    }]);
    assert_eq!(
        f.adapter.try_recover_surplus(&mallory),
        Err(Ok(AdapterError::NotAuthorized))
    );
    assert_eq!(f.usdc.balance(&f.adapter_id), 100 * USDC);
    assert_eq!(f.usdc.balance(&f.vault), 0);
    assert_eq!(f.usdc.balance(&mallory), 0);
}

/// Both of the two addresses that may call it can, and the admin is not there
/// as a convenience. The failure this entry point exists to fix is an adapter
/// stuck to counterparties that have been superseded, so requiring a working
/// Engine to unstick it would be requiring the thing that is broken. The Engine
/// is still the ordinary path, because only the Engine passes the recovery on
/// to the Vault and keeps the three books in step.
#[test]
fn both_the_engine_and_the_admin_can_bring_stranded_capital_home() {
    let f = setup();
    let engine = f.adapter.engine();

    f.usdc.faucet(&f.adapter_id, &(30 * USDC));
    assert_eq!(f.adapter.recover_surplus(&engine), 30 * USDC);

    f.usdc.faucet(&f.adapter_id, &(20 * USDC));
    assert_eq!(f.adapter.recover_surplus(&f.admin), 20 * USDC);

    // Both routes end at the same address, because neither of them chooses it.
    assert_eq!(f.usdc.balance(&f.vault), 50 * USDC);
    assert_eq!(f.usdc.balance(&f.adapter_id), 0);
}

/// Holding nothing above the book is an error rather than a silent zero. The
/// Engine hands whatever this returns straight to the Vault's `record_recovery`,
/// so a sweep of nothing that reported success would be a recovery of nothing
/// recorded as a recovery.
#[test]
fn an_adapter_with_no_surplus_refuses_rather_than_sweeping_nothing() {
    let f = setup();

    // Empty on both counts.
    assert_eq!(
        f.adapter.try_recover_surplus(&f.admin),
        Err(Ok(AdapterError::NothingToRecover))
    );

    // Fully funded and fully booked: every dollar here is backing a live
    // position and belongs to `deallocate`.
    f.usdc.faucet(&f.adapter_id, &(500 * USDC));
    f.adapter.allocate(&(500 * USDC));
    assert_eq!(
        f.adapter.try_recover_surplus(&f.admin),
        Err(Ok(AdapterError::NothingToRecover))
    );
    assert_eq!(f.usdc.balance(&f.adapter_id), 500 * USDC);
    assert_eq!(f.adapter.get_exposure(), 500 * USDC);

    // And a position the originator has drawn down sits below its book rather
    // than above it, so the subtraction is negative and there is still nothing
    // to send home.
    f.usdc.burn(&f.adapter_id, &(200 * USDC));
    assert_eq!(
        f.adapter.try_recover_surplus(&f.admin),
        Err(Ok(AdapterError::NothingToRecover))
    );
    assert_eq!(f.usdc.balance(&f.vault), 0);
}

/// The constructor runs the symmetry check `set_counterparties` runs, so an
/// adapter cannot come into existence pointed at a pair that does not match.
/// `initialize` was a separate call that took both addresses on trust, which
/// made the one call that created the wiring the only one that validated none
/// of it, and left a public window in which somebody else's `initialize` could
/// land first. A constructor closes both.
#[test]
#[should_panic(expected = "#606")]
fn an_adapter_cannot_be_deployed_pointing_at_a_vault_its_engine_does_not_govern() {
    let f = setup();
    // A real Engine, correctly formed, that answers that it governs somebody
    // else's Vault. Without this check the adapter would deploy and repay every
    // future allocation to an address its Engine does not serve.
    let elsewhere = Address::generate(&f.e);
    let engine = f.e.register(MockEngine, ());
    MockEngineClient::new(&f.e, &engine).initialize(&elsewhere);

    f.e.register(
        PrivateCreditAdapter,
        (
            f.admin.clone(),
            engine,
            f.vault.clone(),
            f.usdc.address.clone(),
        ),
    );
}
