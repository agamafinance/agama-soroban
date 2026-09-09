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


struct Fix {
    e: Env,
    usdc: MockUsdcClient<'static>,
    adapter: EtherfuseAdapterClient<'static>,
    adapter_id: Address,
    vault: Address,
    admin: Address,
}

/// The Engine and the Vault are plain addresses here: this crate is testing the
/// adapter's own guards, and the Engine to adapter wiring is covered end to end
/// in the allocation-engine tests.
fn setup() -> Fix {
    let e = Env::default();
    e.mock_all_auths();

    let admin = Address::generate(&e);
    let engine = Address::generate(&e);
    let vault = Address::generate(&e);

    let usdc_id = e.register(MockUsdc, ());
    let usdc = MockUsdcClient::new(&e, &usdc_id);
    usdc.initialize(
        &admin,
        &7u32,
        &String::from_str(&e, "USD Coin"),
        &String::from_str(&e, "USDC"),
    );

    let adapter_id = e.register(EtherfuseAdapter, ());
    let adapter = EtherfuseAdapterClient::new(&e, &adapter_id);
    adapter.initialize(&admin, &engine, &vault, &usdc_id);

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

    // Stablebond redemption is on-chain, so a 200 USDC unwind reaches the Vault
    // in the same call that reduces the exposure. No settlement lag to bridge.
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
fn cannot_be_reinitialized() {
    let f = setup();
    let attacker = Address::generate(&f.e);
    assert!(f
        .adapter
        .try_initialize(&attacker, &attacker, &attacker, &attacker)
        .is_err());
    assert_eq!(f.adapter.admin(), f.admin);
}

#[test]
fn metadata_matches_the_feed_the_pool_is_priced_from() {
    let f = setup();
    assert_eq!(f.adapter.pool_kind(), POOL_KIND);
    // EF_BOND is registered in the Oracle Adapter with a 48 hour staleness
    // window and no deviation bound, matching same-block settlement here.
    assert_eq!(f.adapter.oracle_feed(), ORACLE_FEED);
    assert_eq!(f.adapter.settlement_days(), 0);
}


#[test]
fn the_counterparties_move_only_together_and_only_while_the_adapter_is_empty() {
    let f = setup();
    let stranger = Address::generate(&f.e);

    // A replacement Engine that governs a replacement Vault. This is the
    // situation the setter exists for: both addresses written at
    // initialization have been superseded, and an adapter is far too cheap a
    // contract to redeploy over two words of storage.
    let new_vault = Address::generate(&f.e);
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
    let other_vault = Address::generate(&f.e);
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
