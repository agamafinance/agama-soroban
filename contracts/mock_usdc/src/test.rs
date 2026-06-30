#![cfg(test)]
use super::*;
use soroban_sdk::{testutils::Address as _, Address, Env, String};

fn setup(e: &Env) -> MockUsdcClient {
    let admin = Address::generate(e);
    let id = e.register(MockUsdc, ());
    let c = MockUsdcClient::new(e, &id);
    c.initialize(
        &admin,
        &7u32,
        &String::from_str(e, "USD Coin"),
        &String::from_str(e, "USDC"),
    );
    c
}

#[test]
fn faucet_mints_capped() {
    let e = Env::default();
    e.mock_all_auths();
    let c = setup(&e);
    let user = Address::generate(&e);
    c.faucet(&user, &1_000_0000000);
    assert_eq!(c.balance(&user), 1_000_0000000);
    assert_eq!(c.total_supply(), 1_000_0000000);
}

#[test]
#[should_panic]
fn faucet_rejects_over_cap() {
    let e = Env::default();
    e.mock_all_auths();
    let c = setup(&e);
    let user = Address::generate(&e);
    c.faucet(&user, &1_000_000_0000000); // > cap
}

#[test]
fn transfer_works() {
    let e = Env::default();
    e.mock_all_auths();
    let c = setup(&e);
    let a = Address::generate(&e);
    let b = Address::generate(&e);
    c.faucet(&a, &500_0000000);
    c.transfer(&a, &b, &200_0000000);
    assert_eq!(c.balance(&a), 300_0000000);
    assert_eq!(c.balance(&b), 200_0000000);
}
