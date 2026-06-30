#![cfg(test)]
use super::*;
use agusd::{AgUsd, AgUsdClient};
use mock_usdc::{MockUsdc, MockUsdcClient};
use soroban_sdk::{
    testutils::{Address as _, Ledger as _},
    vec, Address, Env, String,
};

const COOLDOWN: u64 = 300; // 5 min

struct Fix {
    e: Env,
    usdc: MockUsdcClient<'static>,
    ag: AgUsdClient<'static>,
    vault: StakingClient<'static>,
    admin: Address,
}

fn setup() -> Fix {
    let e = Env::default();
    e.mock_all_auths();
    e.ledger().set_timestamp(1_000);
    let admin = Address::generate(&e);
    let treasury = Address::generate(&e);

    let usdc_id = e.register(MockUsdc, ());
    let usdc = MockUsdcClient::new(&e, &usdc_id);
    usdc.initialize(
        &admin,
        &7u32,
        &String::from_str(&e, "USD Coin"),
        &String::from_str(&e, "USDC"),
    );

    let ag_id = e.register(AgUsd, ());
    let ag = AgUsdClient::new(&e, &ag_id);
    ag.initialize(
        &admin,
        &usdc_id,
        &treasury,
        &2000u32,
        &7u32,
        &String::from_str(&e, "Agama USD"),
        &String::from_str(&e, "agUSD"),
    );

    let v_id = e.register(Staking, ());
    let vault = StakingClient::new(&e, &v_id);
    vault.initialize(
        &admin,
        &ag_id,
        &COOLDOWN,
        &7u32,
        &String::from_str(&e, "Staked agUSD"),
        &String::from_str(&e, "sagUSD"),
    );

    Fix { e, usdc, ag, vault, admin }
}

/// Helper: give `who` `amount` agUSD via faucet+deposit.
fn fund_agusd(f: &Fix, who: &Address, amount: i128) {
    f.usdc.faucet(who, &amount);
    f.ag.deposit(who, &amount);
}

#[test]
fn full_yield_flow() {
    let f = setup();
    let alice = Address::generate(&f.e);
    fund_agusd(&f, &alice, 1_000_0000000);

    // First stake: 1 share per agUSD.
    let shares = f.vault.stake(&alice, &1_000_0000000);
    assert_eq!(shares, 1_000_0000000);
    assert_eq!(f.vault.total_shares(), 1_000_0000000);
    assert_eq!(f.vault.share_price(), ONE); // 1.0
    assert_eq!(f.vault.nav(), 1_000_0000000);

    // Strategist delivers 100 agUSD of yield -> share price +10%.
    fund_agusd(&f, &f.admin, 100_0000000);
    f.vault.accrue_yield(&100_0000000);
    assert_eq!(f.vault.nav(), 1_100_0000000);
    assert_eq!(f.vault.share_price(), 11_000_000); // 1.1

    // Bob stakes 110 agUSD after the appreciation -> gets 100 shares.
    let bob = Address::generate(&f.e);
    fund_agusd(&f, &bob, 110_0000000);
    let bob_shares = f.vault.stake(&bob, &110_0000000);
    assert_eq!(bob_shares, 100_0000000);

    // Alice unstakes all her shares: 1000 shares now worth 1100 agUSD.
    let assets = f.vault.request_unstake(&alice, &1_000_0000000);
    assert_eq!(assets, 1_100_0000000);
    let p = f.vault.pending(&alice);
    assert_eq!(p.assets, 1_100_0000000);
    assert_eq!(p.claimable_at, 1_000 + COOLDOWN);

    // Cooldown not elapsed -> claim must fail.
    assert!(f.vault.try_claim(&alice).is_err());

    // Advance past cooldown and claim.
    f.e.ledger().set_timestamp(1_000 + COOLDOWN + 1);
    let claimed = f.vault.claim(&alice);
    assert_eq!(claimed, 1_100_0000000);
    assert_eq!(f.ag.balance(&alice), 1_100_0000000);
    assert_eq!(f.vault.pending(&alice).assets, 0);
}

#[test]
fn allocations_roundtrip() {
    let f = setup();
    let allocs = vec![
        &f.e,
        Allocation {
            name: String::from_str(&f.e, "Kiro Core"),
            target_bps: 6000,
            apy_bps: 1200,
        },
        Allocation {
            name: String::from_str(&f.e, "Kiro Edge"),
            target_bps: 4000,
            apy_bps: 1800,
        },
    ];
    f.vault.set_allocations(&allocs);
    let got = f.vault.allocations();
    assert_eq!(got.len(), 2);
    assert_eq!(got.get(0).unwrap().target_bps, 6000);
}

#[test]
fn report_nav_overrides() {
    let f = setup();
    let alice = Address::generate(&f.e);
    fund_agusd(&f, &alice, 500_0000000);
    f.vault.stake(&alice, &500_0000000);
    f.vault.report_nav(&750_0000000); // +50% on paper
    assert_eq!(f.vault.share_price(), 15_000_000); // 1.5
}
