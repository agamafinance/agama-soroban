#![cfg(test)]
use super::*;
use mock_usdc::{MockUsdc, MockUsdcClient};
use soroban_sdk::testutils::{Address as _, MockAuth, MockAuthInvoke};
use soroban_sdk::IntoVal;
use vault::{Vault, VaultClient};

const UNIT: i128 = 10_000_000; // 1 agUSD at 7 decimals

struct Fix {
    e: Env,
    token: AgUsdCoreClient<'static>,
    admin: Address,
    minter: Address,
}

/// The token on its own, with a plain account standing in for the Vault so the
/// minter's authorization can be granted and withheld one call at a time.
fn setup() -> Fix {
    let e = Env::default();
    e.mock_all_auths();
    let admin = Address::generate(&e);
    let minter = Address::generate(&e);

    let id = e.register(
        AgUsdCore,
        (
            admin.clone(),
            minter.clone(),
            7u32,
            String::from_str(&e, "Agama USD"),
            String::from_str(&e, "agUSD"),
        ),
    );
    let token = AgUsdCoreClient::new(&e, &id);

    Fix {
        e,
        token,
        admin,
        minter,
    }
}

#[test]
fn the_constructor_records_the_minter_and_the_metadata() {
    let f = setup();
    assert_eq!(f.token.minter(), f.minter);
    assert_eq!(f.token.admin(), f.admin);
    assert_eq!(f.token.decimals(), 7);
    assert_eq!(f.token.name(), String::from_str(&f.e, "Agama USD"));
    assert_eq!(f.token.symbol(), String::from_str(&f.e, "agUSD"));
    assert_eq!(f.token.total_supply(), 0);
}

#[test]
fn the_minter_creates_supply() {
    let f = setup();
    let alice = Address::generate(&f.e);

    f.token.mint(&alice, &(400 * UNIT));
    assert_eq!(f.token.balance(&alice), 400 * UNIT);
    assert_eq!(f.token.total_supply(), 400 * UNIT);

    f.token.mint(&alice, &(100 * UNIT));
    assert_eq!(f.token.total_supply(), 500 * UNIT);
}

#[test]
fn nobody_but_the_minter_creates_supply() {
    let f = setup();
    let attacker = Address::generate(&f.e);

    // Drop the blanket auth mock: with nothing signed, minting is refused.
    f.e.mock_auths(&[]);
    assert!(f.token.try_mint(&attacker, &(100 * UNIT)).is_err());

    // And the admin's own signature does not help, because there is no admin
    // mint: the check is against the stored minter and nothing else. This is
    // the security claim of the contract, so it is asserted rather than
    // assumed.
    let args = (attacker.clone(), 100 * UNIT).into_val(&f.e);
    f.e.mock_auths(&[MockAuth {
        address: &f.admin,
        invoke: &MockAuthInvoke {
            contract: &f.token.address,
            fn_name: "mint",
            args,
            sub_invokes: &[],
        },
    }]);
    assert!(f.token.try_mint(&attacker, &(100 * UNIT)).is_err());
    assert_eq!(f.token.total_supply(), 0);
    assert_eq!(f.token.balance(&attacker), 0);
}

#[test]
fn the_minter_is_correctable_until_the_first_mint_and_frozen_after() {
    let f = setup();
    assert_eq!(f.token.mints(), 0);
    let replacement = Address::generate(&f.e);
    let stranger = Address::generate(&f.e);

    assert_eq!(
        f.token.try_set_minter(&stranger, &replacement),
        Err(Ok(AgUsdCoreError::NotAdmin))
    );

    // The repair this exists for: the Vault named at initialization turned out
    // to be unusable, and issuance has to follow it to its replacement rather
    // than force a second token and a migration.
    f.token.set_minter(&f.admin, &replacement);
    assert_eq!(f.token.minter(), replacement);

    // The old minter is now nobody. Its signature buys it nothing.
    let alice = Address::generate(&f.e);
    let args = (alice.clone(), 100 * UNIT).into_val(&f.e);
    f.e.mock_auths(&[MockAuth {
        address: &f.minter,
        invoke: &MockAuthInvoke {
            contract: &f.token.address,
            fn_name: "mint",
            args,
            sub_invokes: &[],
        },
    }]);
    assert!(f.token.try_mint(&alice, &(100 * UNIT)).is_err());
    assert_eq!(f.token.total_supply(), 0);

    // One mint, and the pointer is a promise to the holder rather than a
    // setting. The admin cannot rotate the minter to itself and print.
    f.e.mock_all_auths();
    f.token.mint(&alice, &(100 * UNIT));
    assert_eq!(f.token.mints(), 1);
    assert_eq!(
        f.token.try_set_minter(&f.admin, &f.admin),
        Err(Ok(AgUsdCoreError::MinterFrozen))
    );
    assert_eq!(f.token.minter(), replacement);

    // Burning the supply back to zero does not reopen it: the counter records
    // that the token has issued, not what is outstanding today.
    f.token.burn(&alice, &(100 * UNIT));
    assert_eq!(f.token.total_supply(), 0);
    assert_eq!(
        f.token.try_set_minter(&f.admin, &f.admin),
        Err(Ok(AgUsdCoreError::MinterFrozen))
    );
}

#[test]
fn minting_zero_or_a_negative_amount_is_rejected() {
    let f = setup();
    let alice = Address::generate(&f.e);

    assert_eq!(
        f.token.try_mint(&alice, &0),
        Err(Ok(AgUsdCoreError::InvalidAmount))
    );
    assert_eq!(
        f.token.try_mint(&alice, &(-100 * UNIT)),
        Err(Ok(AgUsdCoreError::InvalidAmount))
    );
    assert_eq!(f.token.total_supply(), 0);
}

#[test]
fn the_sep41_surface_moves_balances_and_supply() {
    let f = setup();
    let alice = Address::generate(&f.e);
    let bob = Address::generate(&f.e);
    f.token.mint(&alice, &(400 * UNIT));

    f.token.transfer(&alice, &bob, &(100 * UNIT));
    assert_eq!(f.token.balance(&alice), 300 * UNIT);
    assert_eq!(f.token.balance(&bob), 100 * UNIT);
    // Moving tokens around never changes how many exist.
    assert_eq!(f.token.total_supply(), 400 * UNIT);

    f.token
        .approve(&alice, &bob, &(50 * UNIT), &(f.e.ledger().sequence() + 100));
    assert_eq!(f.token.allowance(&alice, &bob), 50 * UNIT);
    f.token.transfer_from(&bob, &alice, &bob, &(50 * UNIT));
    assert_eq!(f.token.balance(&bob), 150 * UNIT);
    assert_eq!(f.token.allowance(&alice, &bob), 0);
}

#[test]
fn holders_can_burn_and_supply_falls() {
    let f = setup();
    let alice = Address::generate(&f.e);
    let bob = Address::generate(&f.e);
    f.token.mint(&alice, &(400 * UNIT));

    f.token.burn(&alice, &(100 * UNIT));
    assert_eq!(f.token.balance(&alice), 300 * UNIT);
    assert_eq!(f.token.total_supply(), 300 * UNIT);

    f.token
        .approve(&alice, &bob, &(50 * UNIT), &(f.e.ledger().sequence() + 100));
    f.token.burn_from(&bob, &alice, &(50 * UNIT));
    assert_eq!(f.token.balance(&alice), 250 * UNIT);
    assert_eq!(f.token.total_supply(), 250 * UNIT);
}

/// The reason this contract exists: the Vault's `deposit` and
/// `request_withdrawal` call `mint` and `burn` on it, and neither one works
/// against the generation 1 agUSD.
#[test]
fn the_vault_mints_on_deposit_and_burns_on_a_withdrawal_request() {
    let e = Env::default();
    e.mock_all_auths();
    let admin = Address::generate(&e);
    let alice = Address::generate(&e);

    let usdc_id = e.register(MockUsdc, ());
    let usdc = MockUsdcClient::new(&e, &usdc_id);
    usdc.initialize(
        &admin,
        &7u32,
        &String::from_str(&e, "USD Coin"),
        &String::from_str(&e, "USDC"),
    );

    let vault_id = e.register(Vault, (admin.clone(), usdc_id.clone()));
    let vault = VaultClient::new(&e, &vault_id);

    // The Vault is the minter, so the token is deployed after it and wired to
    // its address. There is no setter to fix this up later, on purpose.
    let agusd_id = e.register(
        AgUsdCore,
        (
            admin.clone(),
            vault_id.clone(),
            7u32,
            String::from_str(&e, "Agama USD"),
            String::from_str(&e, "agUSD"),
        ),
    );
    let agusd = AgUsdCoreClient::new(&e, &agusd_id);
    // The Vault takes its token through the setter now, which is also the call
    // that checks the token names this Vault as its minter.
    vault.set_agusd(&admin, &agusd_id);

    usdc.faucet(&alice, &(1_000 * UNIT));
    assert_eq!(vault.deposit(&alice, &(400 * UNIT)), 400 * UNIT);
    assert_eq!(agusd.balance(&alice), 400 * UNIT);
    assert_eq!(agusd.total_supply(), 400 * UNIT);
    assert_eq!(usdc.balance(&alice), 600 * UNIT);
    assert_eq!(vault.idle_reserves(), 400 * UNIT);

    // The agUSD goes at request time, not at claim time.
    let claim_id = vault.request_withdrawal(&alice, &(100 * UNIT));
    assert_eq!(agusd.balance(&alice), 300 * UNIT);
    assert_eq!(agusd.total_supply(), 300 * UNIT);

    vault.claim_withdrawal(&alice, &claim_id);
    assert_eq!(usdc.balance(&alice), 700 * UNIT);
    // One agUSD in circulation, one USDC still in the Vault.
    assert_eq!(agusd.total_supply(), vault.idle_reserves());
}

/// The Vault is the minter, so nobody else can mint even when the Vault is the
/// one holding the mandate: the auth check is on the stored address, not on
/// whoever is calling.
#[test]
fn a_stranger_cannot_mint_the_vaults_token() {
    let e = Env::default();
    e.mock_all_auths();
    let admin = Address::generate(&e);
    let usdc_id = e.register(MockUsdc, ());
    MockUsdcClient::new(&e, &usdc_id).initialize(
        &admin,
        &7u32,
        &String::from_str(&e, "USD Coin"),
        &String::from_str(&e, "USDC"),
    );
    let vault_id = e.register(Vault, (admin.clone(), usdc_id.clone()));
    let mallory = Address::generate(&e);

    let agusd_id = e.register(
        AgUsdCore,
        (
            admin.clone(),
            vault_id.clone(),
            7u32,
            String::from_str(&e, "Agama USD"),
            String::from_str(&e, "agUSD"),
        ),
    );
    let agusd = AgUsdCoreClient::new(&e, &agusd_id);

    let args = (mallory.clone(), 100 * UNIT).into_val(&e);
    e.mock_auths(&[MockAuth {
        address: &mallory,
        invoke: &MockAuthInvoke {
            contract: &agusd_id,
            fn_name: "mint",
            args,
            sub_invokes: &[],
        },
    }]);
    assert!(agusd.try_mint(&mallory, &(100 * UNIT)).is_err());
    assert_eq!(agusd.total_supply(), 0);
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
    assert_eq!(f.token.pending_admin(), None);

    // A stranger cannot propose.
    assert_eq!(
        f.token.try_propose_admin(&mallory, &mallory),
        Err(Ok(AgUsdCoreError::NotAdmin))
    );

    // The admin proposes and nothing moves yet.
    f.token.propose_admin(&f.admin, &successor);
    assert_eq!(f.token.pending_admin(), Some(successor.clone()));
    assert_eq!(f.token.admin(), f.admin);

    // Only the proposed address can accept, and it has to sign for itself.
    assert_eq!(
        f.token.try_accept_admin(&mallory),
        Err(Ok(AgUsdCoreError::NotPendingAdmin))
    );
    f.e.mock_auths(&[MockAuth {
        address: &mallory,
        invoke: &MockAuthInvoke {
            contract: &f.token.address,
            fn_name: "accept_admin",
            args: (successor.clone(),).into_val(&f.e),
            sub_invokes: &[],
        },
    }]);
    assert!(f.token.try_accept_admin(&successor).is_err());
    assert_eq!(f.token.admin(), f.admin);

    f.e.mock_all_auths();
    f.token.accept_admin(&successor);
    assert_eq!(f.token.admin(), successor);
    assert_eq!(f.token.pending_admin(), None);
    assert_eq!(
        f.token.try_accept_admin(&successor),
        Err(Ok(AgUsdCoreError::NoPendingAdmin))
    );
}
