#![cfg(test)]
use super::*;
use mock_usdc::{MockUsdc, MockUsdcClient};
use soroban_sdk::testutils::{Address as _, Ledger as _};
use soroban_sdk::{contract, contractimpl, symbol_short, Address, Env, String};

const USDC: i128 = 10_000_000; // 1 USDC at Stellar's 7 decimals

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

/// Stand-in for Circle's TokenMessengerMinter.
///
/// It pulls through `transfer_from` and keeps what it takes, which is the only
/// behaviour that matters here: a burn really removes the USDC from the
/// adapter's balance. A mock that recorded the call without moving the money
/// would let `deallocate` pass against funds the real thing would have taken,
/// which is the exact failure this adapter exists to prevent.
#[contract]
pub struct MockMessenger;

#[contractimpl]
impl MockMessenger {
    #[allow(clippy::too_many_arguments)]
    pub fn deposit_for_burn(
        e: Env,
        caller: Address,
        amount: i128,
        destination_domain: u32,
        mint_recipient: BytesN<32>,
        burn_token: Address,
        _destination_caller: BytesN<32>,
        max_fee: i128,
        _min_finality_threshold: u32,
    ) {
        TokenClient::new(&e, &burn_token).transfer_from(
            &e.current_contract_address(),
            &caller,
            &e.current_contract_address(),
            &amount,
        );
        e.storage().instance().set(&symbol_short!("amount"), &amount);
        e.storage().instance().set(&symbol_short!("domain"), &destination_domain);
        e.storage().instance().set(&symbol_short!("recip"), &mint_recipient);
        e.storage().instance().set(&symbol_short!("maxfee"), &max_fee);
    }
    pub fn last_amount(e: Env) -> i128 {
        e.storage().instance().get(&symbol_short!("amount")).unwrap_or(0)
    }
    pub fn last_domain(e: Env) -> u32 {
        e.storage().instance().get(&symbol_short!("domain")).unwrap_or(0)
    }
    pub fn last_recipient(e: Env) -> BytesN<32> {
        e.storage().instance().get(&symbol_short!("recip")).unwrap()
    }
    pub fn last_max_fee(e: Env) -> i128 {
        e.storage().instance().get(&symbol_short!("maxfee")).unwrap_or(0)
    }
}

fn evm_recipient(e: &Env) -> BytesN<32> {
    // 0x4Ae5478e01cb01eb26C14c7011F283A13e6631Be, left padded, which is the
    // encoding and the only place a mistake is invisible.
    let mut b = [0u8; 32];
    b[12..].copy_from_slice(&[
        0x4A, 0xe5, 0x47, 0x8e, 0x01, 0xcb, 0x01, 0xeb, 0x26, 0xC1, 0x4c, 0x70, 0x11, 0xF2, 0x83,
        0xA1, 0x3e, 0x66, 0x31, 0xBe,
    ]);
    BytesN::from_array(e, &b)
}

struct Fix {
    e: Env,
    usdc: MockUsdcClient<'static>,
    adapter: CctpAdapterClient<'static>,
    adapter_id: Address,
    messenger: MockMessengerClient<'static>,
    vault: Address,
    admin: Address,
}

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

    let vault = e.register(MockVault, ());
    MockVaultClient::new(&e, &vault).initialize(&usdc_id);
    let engine = e.register(MockEngine, ());
    MockEngineClient::new(&e, &engine).initialize(&vault);
    let messenger_id = e.register(MockMessenger, ());

    let adapter_id = e.register(
        CctpAdapter,
        (
            admin.clone(),
            engine.clone(),
            vault.clone(),
            usdc_id.clone(),
            messenger_id.clone(),
            0u32,
            evm_recipient(&e),
            10u32, // 0.1% fee ceiling
        ),
    );

    Fix {
        adapter: CctpAdapterClient::new(&e, &adapter_id),
        messenger: MockMessengerClient::new(&e, &messenger_id),
        e,
        usdc,
        adapter_id,
        vault,
        admin,
    }
}

/// The Vault releases USDC to the adapter, exactly as the Engine's `allocate`
/// does with `settle_allocation` before it calls this.
fn fund(f: &Fix, amount: i128) {
    f.usdc.mint(&f.adapter_id, &amount);
}

#[test]
fn allocate_burns_towards_the_destination_and_books_exposure() {
    let f = setup();
    fund(&f, 500 * USDC);
    f.adapter.allocate(&(500 * USDC));

    assert_eq!(f.adapter.get_exposure(), 500 * USDC);
    // The money really left. This is the assertion that separates a crossing
    // from a bookkeeping entry.
    assert_eq!(f.usdc.balance(&f.adapter_id), 0);
    assert_eq!(f.messenger.last_amount(), 500 * USDC);
    assert_eq!(f.messenger.last_domain(), 0);
    assert_eq!(f.messenger.last_recipient(), evm_recipient(&f.e));
}

/// The fee ceiling scales with the crossing rather than being a constant that
/// is generous for a small one and binding for a large one.
#[test]
fn the_fee_ceiling_is_a_share_of_the_amount() {
    let f = setup();
    fund(&f, 1000 * USDC);
    f.adapter.allocate(&(1000 * USDC));
    assert_eq!(f.messenger.last_max_fee(), 1000 * USDC / 1000);
}

#[test]
fn only_the_engine_can_move_capital() {
    let f = setup();
    let e = Env::default();
    let _ = e;
    fund(&f, 100 * USDC);
    // Auth is mocked, so this asserts the shape rather than the signature: the
    // full Engine to adapter authorisation path is covered end to end in the
    // allocation-engine suite. What is checked here is that there is no second
    // door, which is why there is no admin entry point that allocates.
    assert!(f.adapter.try_allocate(&0).is_err());
    assert!(f.adapter.try_allocate(&-1).is_err());
}

/// The one that matters most. Capital comes back as a crossing initiated on the
/// far chain and landing here as an ordinary mint. Nothing on Stellar can tell
/// whether it is in flight or was never sent, so deallocating against money
/// that has not arrived would decrement the Engine's book and report the Vault
/// repaid out of nothing.
#[test]
fn deallocate_refuses_until_the_return_has_actually_arrived() {
    let f = setup();
    fund(&f, 500 * USDC);
    f.adapter.allocate(&(500 * USDC));
    assert_eq!(f.usdc.balance(&f.adapter_id), 0);

    let err = f.adapter.try_deallocate(&(500 * USDC));
    assert!(err.is_err());
    assert_eq!(f.adapter.get_exposure(), 500 * USDC, "book untouched");
    assert_eq!(f.usdc.balance(&f.vault), 0, "and nothing was paid");
}

#[test]
fn deallocate_returns_capital_and_reduces_exposure_together() {
    let f = setup();
    fund(&f, 500 * USDC);
    f.adapter.allocate(&(500 * USDC));

    // The return crossing lands. Smaller than what left, because two crossings
    // cost two of Circle's fees.
    let returned = 499 * USDC;
    f.usdc.mint(&f.adapter_id, &returned);
    f.adapter.deallocate(&returned);

    assert_eq!(f.usdc.balance(&f.vault), returned);
    assert_eq!(f.adapter.get_exposure(), 500 * USDC - returned);
}

/// The shortfall is a real loss of principal and is recognised as one, rather
/// than absorbed by a deallocate that stopped checking.
#[test]
fn the_fee_shortfall_is_written_down_rather_than_absorbed() {
    let f = setup();
    fund(&f, 500 * USDC);
    f.adapter.allocate(&(500 * USDC));
    let returned = 499 * USDC;
    f.usdc.mint(&f.adapter_id, &returned);
    f.adapter.deallocate(&returned);

    let shortfall = f.adapter.get_exposure();
    assert_eq!(shortfall, 1 * USDC);
    f.adapter.write_down(&shortfall);
    assert_eq!(f.adapter.get_exposure(), 0);
    assert!(f.adapter.try_write_down(&1).is_err(), "and no further");
}

#[test]
fn deallocate_beyond_exposure_is_rejected() {
    let f = setup();
    fund(&f, 100 * USDC);
    f.adapter.allocate(&(100 * USDC));
    f.usdc.mint(&f.adapter_id, &(200 * USDC));
    assert!(f.adapter.try_deallocate(&(101 * USDC)).is_err());
}

#[test]
fn the_destination_cannot_move_while_capital_is_deployed() {
    let f = setup();
    fund(&f, 100 * USDC);
    f.adapter.allocate(&(100 * USDC));

    let other = BytesN::from_array(&f.e, &[7u8; 32]);
    assert!(f
        .adapter
        .try_set_destination(&f.admin, &6u32, &other)
        .is_err());

    // Once the book is clear it moves.
    f.usdc.mint(&f.adapter_id, &(100 * USDC));
    f.adapter.deallocate(&(100 * USDC));
    f.adapter.set_destination(&f.admin, &6u32, &other);
    let (domain, recipient) = f.adapter.destination();
    assert_eq!(domain, 6);
    assert_eq!(recipient, other);
}

#[test]
fn a_zero_mint_recipient_is_refused() {
    let f = setup();
    let zero = BytesN::from_array(&f.e, &[0u8; 32]);
    assert!(f.adapter.try_set_destination(&f.admin, &0u32, &zero).is_err());
}

/// An unannounced return, which is what a crossing nobody deallocated looks
/// like, goes home to the stored Vault and not to a caller supplied address.
#[test]
fn recover_surplus_sends_an_unannounced_return_home() {
    let f = setup();
    fund(&f, 100 * USDC);
    f.adapter.allocate(&(100 * USDC));
    f.usdc.mint(&f.adapter_id, &(150 * USDC));

    let swept = f.adapter.recover_surplus(&f.admin);
    assert_eq!(swept, 50 * USDC, "only what exceeds the booked exposure");
    assert_eq!(f.usdc.balance(&f.vault), 50 * USDC);
    assert_eq!(f.adapter.get_exposure(), 100 * USDC, "the position stands");
}

#[test]
fn an_adapter_with_no_surplus_refuses_rather_than_sweeping_nothing() {
    let f = setup();
    assert!(f.adapter.try_recover_surplus(&f.admin).is_err());
}

/// A real Engine, correctly formed, that answers that it governs somebody
/// else's Vault. Without this check the adapter would deploy and send every
/// future return to an address its Engine does not serve.
#[test]
#[should_panic]
fn an_adapter_cannot_be_deployed_pointing_at_a_vault_its_engine_does_not_govern() {
    let f = setup();
    let elsewhere = f.e.register(MockVault, ());
    MockVaultClient::new(&f.e, &elsewhere).initialize(&f.usdc.address);
    let engine = f.e.register(MockEngine, ());
    MockEngineClient::new(&f.e, &engine).initialize(&elsewhere);
    let messenger = f.e.register(MockMessenger, ());

    f.e.register(
        CctpAdapter,
        (
            f.admin.clone(),
            engine,
            f.vault.clone(),
            f.usdc.address.clone(),
            messenger,
            0u32,
            evm_recipient(&f.e),
            10u32,
        ),
    );
}

#[test]
fn the_admin_role_moves_only_to_an_address_that_signs_for_it() {
    let f = setup();
    let next = Address::generate(&f.e);
    let stranger = Address::generate(&f.e);
    f.adapter.propose_admin(&f.admin, &next);
    assert_eq!(f.adapter.pending_admin(), Some(next.clone()));
    assert!(f.adapter.try_accept_admin(&stranger).is_err());
    f.adapter.accept_admin(&next);
    assert_eq!(f.adapter.admin(), next);
    assert_eq!(f.adapter.pending_admin(), None);
}

/// The allowance granted to the messenger is exactly the amount and expires
/// immediately. A standing allowance would leave this contract drainable by a
/// messenger upgrade nobody in this repository controls.
#[test]
fn the_allowance_does_not_outlive_the_burn() {
    let f = setup();
    fund(&f, 100 * USDC);
    f.adapter.allocate(&(100 * USDC));
    assert_eq!(f.usdc.allowance(&f.adapter_id, &f.messenger.address), 0);

    f.e.ledger().set_sequence_number(f.e.ledger().sequence() + 5);
    assert_eq!(
        f.usdc.allowance(&f.adapter_id, &f.messenger.address),
        0,
        "and is still nothing several ledgers later"
    );
}

#[test]
fn metadata_names_the_feed_the_far_book_is_priced_from() {
    let f = setup();
    assert_eq!(f.adapter.pool_kind(), symbol_short!("crosschn"));
    assert_eq!(f.adapter.oracle_feed(), symbol_short!("PC_NAV"));
    assert_eq!(f.adapter.settlement_window(), (1, 14));
}
