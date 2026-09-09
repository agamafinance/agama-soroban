#![cfg(test)]
use super::*;
use agusd::{AgUsd, AgUsdClient};
use mock_usdc::{MockUsdc, MockUsdcClient};
use soroban_sdk::{
    testutils::{Address as _, Ledger as _, MockAuth, MockAuthInvoke},
    vec, Address, Env, IntoVal, String,
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
    assert_eq!(f.vault.exchange_rate(), ONE); // 1.0
    assert_eq!(f.vault.nav(), 1_000_0000000);

    // Strategist delivers 100 agUSD of yield -> share price +10%.
    fund_agusd(&f, &f.admin, 100_0000000);
    f.vault.distribute_yield(&100_0000000);
    assert_eq!(f.vault.nav(), 1_100_0000000);
    assert_eq!(f.vault.exchange_rate(), 11_000_000); // 1.1

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
fn cannot_be_reinitialized() {
    let f = setup();
    let attacker = Address::generate(&f.e);
    // The attack this blocks is naming yourself admin, repointing the staked
    // asset and resetting the NAV, which is the denominator every share is
    // redeemed against.
    assert_eq!(
        f.vault.try_initialize(
            &attacker,
            &attacker,
            &COOLDOWN,
            &7u32,
            &String::from_str(&f.e, "Staked agUSD"),
            &String::from_str(&f.e, "sagUSD"),
        ),
        Err(Ok(StakingError::AlreadyInitialized))
    );
    assert_eq!(f.vault.admin(), f.admin);
    assert_eq!(f.vault.agusd(), f.ag.address);
}

#[test]
fn the_agusd_pointer_moves_before_the_first_stake_and_never_after() {
    let f = setup();
    assert_eq!(f.vault.stakes(), 0);

    // The live failure: this contract was initialized against the agUSD the
    // protocol used to issue, and the Vault now mints a different one. A
    // holder of the new token cannot stake, and the refusal reads as an
    // insufficient balance rather than as a wiring mistake.
    let replacement_id = f.e.register(MockUsdc, ());
    let replacement = MockUsdcClient::new(&f.e, &replacement_id);
    replacement.initialize(
        &f.admin,
        &7u32,
        &String::from_str(&f.e, "Agama USD"),
        &String::from_str(&f.e, "agUSD"),
    );
    let stranger = Address::generate(&f.e);
    assert_eq!(
        f.vault.try_set_agusd(&stranger, &replacement_id),
        Err(Ok(StakingError::NotAdmin))
    );

    f.vault.set_agusd(&f.admin, &replacement_id);
    assert_eq!(f.vault.agusd(), replacement_id);

    // And the contract now takes the token it was repointed at.
    let alice = Address::generate(&f.e);
    replacement.faucet(&alice, &(100 * ONE));
    assert_eq!(f.vault.stake(&alice, &(100 * ONE)), 100 * ONE);
    assert_eq!(replacement.balance(&f.vault.address), 100 * ONE);
    assert_eq!(f.vault.stakes(), 1);

    // The door closes at the first stake: 100 agUSD are in custody here and
    // the share price is a claim on that balance.
    assert_eq!(
        f.vault.try_set_agusd(&f.admin, &f.ag.address),
        Err(Ok(StakingError::CustodyTaken))
    );
    assert_eq!(f.vault.agusd(), replacement_id);

    // Unwinding to zero does not reopen it. The counter records that custody
    // happened, not what is being held right now, and a pending unstake can
    // outlive the shares that created it.
    let assets = f.vault.request_unstake(&alice, &(100 * ONE));
    assert_eq!(assets, 100 * ONE);
    assert_eq!(f.vault.total_shares(), 0);
    assert_eq!(
        f.vault.try_set_agusd(&f.admin, &f.ag.address),
        Err(Ok(StakingError::CustodyTaken))
    );
}

#[test]
fn delivered_yield_closes_the_agusd_pointer_even_with_no_stakers() {
    // distribute_yield takes custody without touching the stake counter. A
    // contract holding yield and no shares would otherwise still look
    // untouched, and the first staker after a repoint would be issued shares
    // against a NAV denominated in a token the contract does not hold.
    let f = setup();
    fund_agusd(&f, &f.admin, 1_000 * ONE);
    f.vault.distribute_yield(&(1_000 * ONE));
    assert_eq!(f.vault.stakes(), 0);
    assert_eq!(f.vault.total_shares(), 0);
    assert_eq!(f.vault.nav(), 1_000 * ONE);

    let replacement = f.e.register(MockUsdc, ());
    MockUsdcClient::new(&f.e, &replacement).initialize(
        &f.admin,
        &7u32,
        &String::from_str(&f.e, "Agama USD"),
        &String::from_str(&f.e, "agUSD"),
    );
    assert_eq!(
        f.vault.try_set_agusd(&f.admin, &replacement),
        Err(Ok(StakingError::CustodyTaken))
    );
    assert_eq!(f.vault.agusd(), f.ag.address);
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

/// The attack the removed `report_nav` made possible, replayed with every entry
/// point the contract still has.
///
/// `report_nav` overwrote the NAV outright, and the NAV is the denominator of
/// both `stake` (`amount * supply / nav`) and `request_unstake` (`shares * nav
/// / supply`). Against Alice's 1000 agUSD the sequence was: `report_nav(1)`,
/// stake 99 stroops and receive 99% of the share supply for it, `report_nav`
/// back to 1000, unstake, leave with 990 agUSD of Alice's deposit.
///
/// With the setter gone the admin's only way to move the NAV is to move agUSD,
/// and moving agUSD in cannot dilute anybody. 99 stroops buys 99 stroops.
#[test]
fn the_admin_cannot_reprice_shares_without_moving_the_agusd_behind_them() {
    let f = setup();
    let alice = Address::generate(&f.e);
    fund_agusd(&f, &alice, 1_000 * ONE);
    let alice_shares = f.vault.stake(&alice, &(1_000 * ONE));

    // The invariant report_nav existed to break: the reported NAV is the agUSD
    // the contract is actually holding, at every point.
    assert_eq!(f.vault.nav(), f.ag.balance(&f.vault.address));

    // The admin's remaining lever moves real money in and cannot overstate the
    // book. It raises the NAV by exactly what arrived and by nothing else.
    fund_agusd(&f, &f.admin, 100 * ONE);
    f.vault.distribute_yield(&(100 * ONE));
    assert_eq!(f.vault.nav(), 1_100 * ONE);
    assert_eq!(f.vault.nav(), f.ag.balance(&f.vault.address));

    // The dust stake that used to buy the pool. It buys dust.
    let mallory = Address::generate(&f.e);
    fund_agusd(&f, &mallory, 99);
    let mallory_shares = f.vault.stake(&mallory, &99);
    assert!(mallory_shares < 100);
    assert!(mallory_shares * 1_000 < alice_shares);

    // And unstaking returns what was put in, not a share of Alice's position.
    let owed = f.vault.request_unstake(&mallory, &mallory_shares);
    assert!(owed <= 99);
    // Alice is untouched, and better off by the delivered yield.
    let alice_owed = f.vault.request_unstake(&alice, &alice_shares);
    assert!(alice_owed >= 1_099 * ONE);
}

/// The DeFindex-facing name and the name this contract shipped with have to be
/// the same number, at every point where that number can differ: the empty
/// vault, a fresh stake, and after delivered yield has moved the rate off 1.0.
/// They are one computation with two names, and this is what keeps it that way.
#[test]
fn share_price_is_an_alias_of_exchange_rate() {
    let f = setup();
    assert_eq!(f.vault.share_price(), f.vault.exchange_rate());
    assert_eq!(f.vault.share_price(), ONE);

    let alice = Address::generate(&f.e);
    fund_agusd(&f, &alice, 400 * ONE);
    f.vault.stake(&alice, &(400 * ONE));
    assert_eq!(f.vault.share_price(), f.vault.exchange_rate());
    assert_eq!(f.vault.share_price(), ONE);

    fund_agusd(&f, &f.admin, 100 * ONE);
    f.vault.distribute_yield(&(100 * ONE));
    assert_eq!(f.vault.share_price(), f.vault.exchange_rate());
    assert_eq!(f.vault.exchange_rate(), 12_500_000); // 1.25
}

/// `distribute_yield` is the DeFindex name for the path that raises
/// assets-per-share, and it has to do exactly what the name promises: move
/// real agUSD in, raise the rate for every existing holder, and mint nobody a
/// share to do it. A distribution that issued shares would leave the rate
/// where it was and the yield would go nowhere.
#[test]
fn distribute_yield_raises_the_rate_without_issuing_shares() {
    let f = setup();
    let alice = Address::generate(&f.e);
    fund_agusd(&f, &alice, 200 * ONE);
    f.vault.stake(&alice, &(200 * ONE));

    let shares_before = f.vault.total_shares();
    let alice_before = f.vault.balance(&alice);
    let rate_before = f.vault.exchange_rate();

    fund_agusd(&f, &f.admin, 20 * ONE);
    f.vault.distribute_yield(&(20 * ONE));

    assert_eq!(f.vault.total_shares(), shares_before);
    assert_eq!(f.vault.balance(&alice), alice_before);
    assert_eq!(f.vault.exchange_rate(), 11_000_000); // 1.1
    assert!(f.vault.exchange_rate() > rate_before);
    // The agUSD is really in the contract, not just booked in the NAV.
    assert_eq!(f.ag.balance(&f.vault.address), 220 * ONE);
    assert_eq!(f.vault.nav(), 220 * ONE);
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
    assert_eq!(f.vault.pending_admin(), None);

    // A stranger cannot propose.
    assert_eq!(
        f.vault.try_propose_admin(&mallory, &mallory),
        Err(Ok(StakingError::NotAdmin))
    );

    // The admin proposes and nothing moves yet.
    f.vault.propose_admin(&f.admin, &successor);
    assert_eq!(f.vault.pending_admin(), Some(successor.clone()));
    assert_eq!(f.vault.admin(), f.admin);

    // Only the proposed address can accept, and it has to sign for itself.
    assert_eq!(
        f.vault.try_accept_admin(&mallory),
        Err(Ok(StakingError::NotPendingAdmin))
    );
    f.e.mock_auths(&[MockAuth {
        address: &mallory,
        invoke: &MockAuthInvoke {
            contract: &f.vault.address,
            fn_name: "accept_admin",
            args: (successor.clone(),).into_val(&f.e),
            sub_invokes: &[],
        },
    }]);
    assert!(f.vault.try_accept_admin(&successor).is_err());
    assert_eq!(f.vault.admin(), f.admin);

    f.e.mock_all_auths();
    f.vault.accept_admin(&successor);
    assert_eq!(f.vault.admin(), successor);
    assert_eq!(f.vault.pending_admin(), None);
    assert_eq!(
        f.vault.try_accept_admin(&successor),
        Err(Ok(StakingError::NoPendingAdmin))
    );
}
