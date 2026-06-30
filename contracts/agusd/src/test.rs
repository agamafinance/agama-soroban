#![cfg(test)]
use super::*;
use mock_usdc::{MockUsdc, MockUsdcClient};
use soroban_sdk::testutils::{Address as _, Ledger as _};
use soroban_sdk::{vec as svec, Address, Env};
use staking::{Staking, StakingClient};

const BUF: u32 = 2000; // 20% buffer
const COOLDOWN: u64 = 10;

struct Fix {
    e: Env,
    usdc: MockUsdcClient<'static>,
    ag: AgUsdClient<'static>,
    v1: StakingClient<'static>,
    v2: StakingClient<'static>,
    treasury: Address,
}

fn setup() -> Fix {
    let e = Env::default();
    e.mock_all_auths_allowing_non_root_auth();
    e.ledger().set_timestamp(1_000);
    let admin = Address::generate(&e);
    let treasury = Address::generate(&e);

    let usdc_id = e.register(MockUsdc, ());
    let usdc = MockUsdcClient::new(&e, &usdc_id);
    usdc.initialize(&admin, &7u32, &String::from_str(&e, "USD Coin"), &String::from_str(&e, "USDC"));

    let ag_id = e.register(AgUsd, ());
    let ag = AgUsdClient::new(&e, &ag_id);
    ag.initialize(
        &admin, &usdc_id, &treasury, &BUF, &7u32,
        &String::from_str(&e, "Agama USD"), &String::from_str(&e, "agUSD"),
    );

    // two credit vaults, 60/40 target weights
    let mk = |name: &str, sym: &str| {
        let id = e.register(Staking, ());
        let c = StakingClient::new(&e, &id);
        c.initialize(&admin, &usdc_id, &COOLDOWN, &7u32,
            &String::from_str(&e, name), &String::from_str(&e, sym));
        (id, c)
    };
    let (v1_id, v1) = mk("Vault One", "V1");
    let (v2_id, v2) = mk("Vault Two", "V2");

    ag.set_targets(&svec![
        &e,
        Target { vault: v1_id, weight_bps: 6000 },
        Target { vault: v2_id, weight_bps: 4000 },
    ]);

    Fix { e, usdc, ag, v1, v2, treasury }
}

#[test]
fn deposit_auto_allocates_above_buffer() {
    let f = setup();
    let user = Address::generate(&f.e);
    f.usdc.faucet(&user, &100_0000000);

    f.ag.deposit(&user, &100_0000000); // 100 USDC in
    assert_eq!(f.ag.balance(&user), 100_0000000); // 1:1 mint

    // 20% buffer kept, 80% deployed 60/40
    assert_eq!(f.ag.reserve(), 20_0000000);
    assert_eq!(f.ag.deployed(), 80_0000000);
    let me = &f.ag.address;
    assert_eq!(f.v1.balance(me), 48_0000000); // 80 * 60%
    assert_eq!(f.v2.balance(me), 32_0000000); // 80 * 40%
}

#[test]
fn redeem_within_buffer_then_refill() {
    let f = setup();
    let user = Address::generate(&f.e);
    f.usdc.faucet(&user, &100_0000000);
    f.ag.deposit(&user, &100_0000000);
    assert_eq!(f.ag.reserve(), 20_0000000);

    // Redeem 15 (within the 20 buffer) -> instant; refill requested from vaults.
    f.ag.redeem(&user, &15_0000000);
    assert_eq!(f.usdc.balance(&user), 15_0000000);
    assert_eq!(f.ag.balance(&user), 85_0000000);
    assert_eq!(f.ag.reserve(), 5_0000000);

    // After the vault cooldown, any movement harvests the refill.
    f.e.ledger().set_timestamp(1_000 + COOLDOWN + 1);
    f.ag.rebalance();
    // target buffer = 20% of 85 = 17; harvested requests bring reserve back up.
    assert!(f.ag.reserve() >= 16_0000000, "reserve={}", f.ag.reserve());
}

#[test]
fn redeem_beyond_buffer_fails_with_clear_error() {
    let f = setup();
    let user = Address::generate(&f.e);
    f.usdc.faucet(&user, &100_0000000);
    f.ag.deposit(&user, &100_0000000);

    // 50 > 20 buffer -> InsufficientBuffer
    let r = f.ag.try_redeem(&user, &50_0000000);
    assert!(r.is_err());
}

#[test]
fn sweep_still_works_for_offchain_leg() {
    let f = setup();
    let user = Address::generate(&f.e);
    f.usdc.faucet(&user, &10_0000000);
    f.ag.deposit(&user, &10_0000000); // below MIN_ALLOC excess thresholds matter less here
    let r0 = f.ag.reserve();
    let take = r0 / 2;
    f.ag.sweep(&take);
    assert_eq!(f.ag.reserve(), r0 - take);
    assert_eq!(f.usdc.balance(&f.treasury), take);
}
