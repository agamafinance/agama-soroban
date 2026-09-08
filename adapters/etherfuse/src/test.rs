#![cfg(test)]
use super::*;
use mock_usdc::{MockUsdc, MockUsdcClient};
use soroban_sdk::testutils::Address as _;
use soroban_sdk::{Address, Env, String};

const USDC: i128 = 10_000_000; // 1 USDC at 7 decimals

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
fn the_engine_and_vault_pointers_move_only_while_the_adapter_holds_nothing() {
    let f = setup();
    let stranger = Address::generate(&f.e);
    let new_engine = Address::generate(&f.e);
    let new_vault = Address::generate(&f.e);

    assert_eq!(
        f.adapter.try_set_engine(&stranger, &new_engine),
        Err(Ok(AdapterError::NotAdmin))
    );
    assert_eq!(
        f.adapter.try_set_vault(&stranger, &new_vault),
        Err(Ok(AdapterError::NotAdmin))
    );

    // Empty adapter, so both pointers follow their contracts to the
    // replacements. This is the whole reason the deployed generation had to be
    // thrown away rather than rewired.
    f.adapter.set_engine(&f.admin, &new_engine);
    f.adapter.set_vault(&f.admin, &new_vault);
    assert_eq!(f.adapter.engine(), new_engine);
    assert_eq!(f.adapter.vault(), new_vault);

    // Book a position: exposure recorded here was authorized by this Engine
    // against its caps, and only this Engine can unwind it.
    f.usdc.faucet(&f.adapter_id, &(500 * USDC));
    f.adapter.allocate(&(500 * USDC));
    assert_eq!(
        f.adapter.try_set_engine(&f.admin, &stranger),
        Err(Ok(AdapterError::NotEmpty))
    );
    assert_eq!(
        f.adapter.try_set_vault(&f.admin, &stranger),
        Err(Ok(AdapterError::NotEmpty))
    );

    // Unwinding the book is not enough on its own. A repayment that has
    // arrived but not been booked is still money owed to the Vault the
    // adapter is pointed at, and `deallocate` sends it wherever that pointer
    // says, so an unbooked balance keeps the door shut too.
    f.adapter.deallocate(&(500 * USDC));
    assert_eq!(f.adapter.get_exposure(), 0);
    f.usdc.faucet(&f.adapter_id, &(10 * USDC));
    assert_eq!(
        f.adapter.try_set_vault(&f.admin, &stranger),
        Err(Ok(AdapterError::NotEmpty))
    );

    // Both empty, and it opens again.
    f.adapter.allocate(&(10 * USDC));
    f.adapter.deallocate(&(10 * USDC));
    assert_eq!(f.usdc.balance(&f.adapter_id), 0);
    f.adapter.set_vault(&f.admin, &stranger);
    assert_eq!(f.adapter.vault(), stranger);
}
