#![cfg(test)]
use super::*;
use agusd::{AgUsd, AgUsdClient};
use mock_usdc::{MockUsdc, MockUsdcClient};
use soroban_sdk::testutils::storage::Persistent as _;
use soroban_sdk::testutils::Events as _;
use soroban_sdk::{
    symbol_short,
    testutils::{Address as _, Ledger as _, MockAuth, MockAuthInvoke},
    vec, Address, Env, IntoVal, String, Symbol, TryFromVal,
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

    let v_id = e.register(Staking, (admin.clone(), ag_id.clone(), COOLDOWN));
    let vault = StakingClient::new(&e, &v_id);

    // sagUSD is its own token contract now, and this contract is its admin
    // rather than its ledger. A MockUsdc stands in for the Stellar Asset
    // Contract: what the staking contract asks of it is `admin`, `mint`,
    // `burn`, `balance` and `decimals`, and those are the same on both.
    let sh_id = e.register(MockUsdc, ());
    MockUsdcClient::new(&e, &sh_id).initialize(
        &v_id,
        &7u32,
        &String::from_str(&e, "Staked agUSD"),
        &String::from_str(&e, "sagUSD"),
    );
    vault.set_shares(&admin, &sh_id);

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

/// Where yield delivered with no shares outstanding ends up.
///
/// The test above establishes that a distribution with no stakers is deliberate
/// and that it closes the agUSD pointer. It stops there, and the interesting
/// half is what happens to the value afterwards, because that nav has no share
/// to belong to and `request_unstake` refuses with `NoSupply` so nobody can
/// take it directly.
///
/// The next stake takes all of it. `stake` mints at par whenever supply is
/// zero, so a staker of one stroop becomes the whole supply of a pool worth the
/// orphaned nav plus their stroop, and unstaking pays them the lot. That is not
/// a theft, and it is worth being precise about why: the nav had no claimant
/// before they arrived, `request_unstake` had already refused everyone, and
/// whoever stakes next owns the pool by definition. Nobody with a claim loses
/// anything.
///
/// It is an asymmetry rather than a leak: a one stroop staker and a thousand
/// agUSD staker collect the same orphaned amount, and the one who collects is
/// whoever notices first. Pinned rather than fixed, because every fix is worse.
/// Refusing the distribution would undo the pointer freeze the test above
/// exists for. Zeroing the nav would destroy agUSD the contract actually holds.
/// This is here so a change that turned it into something with a victim, an
/// orphaned nav reachable without becoming the whole supply, fails a test.
#[test]
fn the_defindex_reading_is_what_unstaking_actually_pays() {
    let f = setup();
    let alice = Address::generate(&f.e);
    // A share count and a NAV that do not divide, so a rounded scalar rate and
    // the real quotient disagree. 3 shares against 10 agUSD is the shape: the
    // rate truncates and multiplying it back out loses stroops.
    fund_agusd(&f, &alice, 3);
    f.vault.stake(&alice, &3);
    fund_agusd(&f, &f.admin, 7);
    f.vault.distribute_yield(&7);
    assert_eq!(f.vault.total_shares(), 3);
    assert_eq!(f.vault.nav(), 10);

    let read = f.vault.get_asset_amounts_per_shares(&3);
    assert_eq!(read.len(), 1);
    let quoted = read.get(0).unwrap();
    // Taken before the unstake: it empties the vault, and the rate of an empty
    // vault is 1.0 by definition, which would make this comparison vacuous.
    let via_rate = 3 * f.vault.exchange_rate() / ONE;

    // What the contract pays for exactly those shares.
    f.vault.request_unstake(&alice, &3);
    assert_eq!(f.vault.pending(&alice).assets, quoted);

    // And the scalar route would have been short here, which is why this entry
    // point does not take it: 10 * ONE / 3 truncates, and 3 of those is 9.
    assert_eq!(quoted, 10);
    assert_eq!(via_rate, 9);
}

#[test]
fn the_defindex_reading_on_an_empty_and_a_fresh_vault() {
    let f = setup();
    // No shares: nothing is owed for any count, including a large one.
    assert_eq!(f.vault.get_asset_amounts_per_shares(&0).get(0).unwrap(), 0);
    assert_eq!(
        f.vault.get_asset_amounts_per_shares(&1_000_000).get(0).unwrap(),
        0
    );
    // A negative count is not a question.
    assert_eq!(
        f.vault.try_get_asset_amounts_per_shares(&-1),
        Err(Ok(StakingError::InvalidAmount))
    );

    // One for one before any yield, and zero shares stay worth zero after.
    let alice = Address::generate(&f.e);
    fund_agusd(&f, &alice, 100 * ONE);
    f.vault.stake(&alice, &(100 * ONE));
    assert_eq!(
        f.vault.get_asset_amounts_per_shares(&(100 * ONE)).get(0).unwrap(),
        100 * ONE
    );
    assert_eq!(f.vault.get_asset_amounts_per_shares(&0).get(0).unwrap(), 0);
}

#[test]
fn the_managed_funds_reading_is_one_asset_and_all_of_it_idle() {
    let f = setup();
    let alice = Address::generate(&f.e);
    fund_agusd(&f, &alice, 100 * ONE);
    f.vault.stake(&alice, &(100 * ONE));
    fund_agusd(&f, &f.admin, 5 * ONE);
    f.vault.distribute_yield(&(5 * ONE));

    let funds = f.vault.fetch_total_managed_funds();
    assert_eq!(funds.len(), 1);
    let a = funds.get(0).unwrap();
    assert_eq!(a.asset, f.ag.address);
    assert_eq!(a.total_amount, 105 * ONE);
    // Nothing is deployed from here. What leaves the protocol leaves through the
    // Vault and the Engine, which are not strategies of this contract.
    assert_eq!(a.idle_amount, 105 * ONE);
    assert_eq!(a.invested_amount, 0);
    assert_eq!(a.strategy_allocations.len(), 0);

    // total_amount is the NAV, not the balance. A pending unstake has left the
    // NAV and not yet left the contract, so the two separate here.
    f.vault.request_unstake(&alice, &(10 * ONE));
    let after = f.vault.fetch_total_managed_funds().get(0).unwrap();
    assert_eq!(after.total_amount, f.vault.nav());
    assert!(f.ag.balance(&f.vault.address) > after.total_amount);
}

#[test]
fn yield_with_no_shares_goes_to_whoever_stakes_next() {
    let f = setup();
    let orphaned = 1_000 * ONE;
    fund_agusd(&f, &f.admin, orphaned);
    f.vault.distribute_yield(&orphaned);
    assert_eq!(f.vault.total_shares(), 0);
    assert_eq!(f.vault.nav(), orphaned);

    // Nobody can reach it directly: there is no share to price against.
    let alice = Address::generate(&f.e);
    assert_eq!(
        f.vault.try_request_unstake(&alice, &1),
        Err(Ok(StakingError::NoSupply))
    );

    // And the rate says one, because a rate per share needs a share.
    assert_eq!(f.vault.exchange_rate(), ONE);

    // One stroop in, and the pool is theirs.
    fund_agusd(&f, &alice, 1);
    let shares = f.vault.stake(&alice, &1);
    assert_eq!(shares, 1, "a stake with no supply mints at par");
    assert_eq!(f.vault.total_shares(), 1);
    assert_eq!(f.vault.nav(), orphaned + 1);

    // Which the rate now reports honestly, all of it against one share.
    assert_eq!(f.vault.exchange_rate(), (orphaned + 1) * ONE);

    let owed = f.vault.request_unstake(&alice, &1);
    assert_eq!(
        owed,
        orphaned + 1,
        "the first staker after an orphaned distribution collects it entirely"
    );
    assert_eq!(f.vault.nav(), 0, "and nothing is left stranded behind them");
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

/// Every refusal in this contract used to be a string panic.
///
/// It was the only contract in the repository whose core entry points trapped
/// rather than returning a code, so an integrator could see that a stake had
/// failed and not why, and could not branch on it. The documentation was honest
/// about it, which is not the same as it being right: it listed the 800 range
/// for the admin calls and "traps: amount must be positive" for the ones a user
/// actually calls.
#[test]
fn every_refusal_returns_a_code_rather_than_trapping() {
    let f = setup();
    let alice = Address::generate(&f.e);
    fund_agusd(&f, &alice, 1_000_0000000);

    assert_eq!(
        f.vault.try_stake(&alice, &0),
        Err(Ok(StakingError::InvalidAmount))
    );
    assert_eq!(
        f.vault.try_stake(&alice, &-1),
        Err(Ok(StakingError::InvalidAmount))
    );
    assert_eq!(
        f.vault.try_request_unstake(&alice, &0),
        Err(Ok(StakingError::InvalidAmount))
    );
    // Nothing has been staked, so there are no shares to price an unstake with.
    assert_eq!(
        f.vault.try_request_unstake(&alice, &1),
        Err(Ok(StakingError::NoSupply))
    );
    assert_eq!(
        f.vault.try_claim(&alice),
        Err(Ok(StakingError::NothingPending))
    );
    assert_eq!(
        f.vault.try_distribute_yield(&0),
        Err(Ok(StakingError::InvalidAmount))
    );

    f.vault.stake(&alice, &100_0000000);
    f.vault.request_unstake(&alice, &50_0000000);
    assert_eq!(
        f.vault.try_claim(&alice),
        Err(Ok(StakingError::StillInCooldown))
    );
    f.e.ledger().set_timestamp(1_000 + COOLDOWN + 1);
    f.vault.claim(&alice);
}

/// The custody invariant: everything this contract holds is either priced into
/// the share price or owed to somebody who has already left.
///
/// `nav` is a stored counter rather than a balance read, which is what makes
/// the share price undonatable: sending agUSD to this address directly does not
/// move `exchange_rate` by a stroop, so the first staker cannot be sandwiched
/// by a donation the way a vault that reads its own balance can. The price of
/// that is a second thing to keep in step, and this is what keeps it honest:
/// after every operation the balance has to equal `nav` plus everything sitting
/// in a pending unstake.
///
/// `request_unstake` is the interesting one. It burns the shares and takes the
/// assets out of `nav` immediately, while the agUSD stays here until the
/// cooldown runs out. So during the cooldown the contract is holding money that
/// is no longer part of the share price and belongs to somebody who has already
/// gone, which is exactly the distinction the Vault draws between its balance
/// and its free reserves.
#[test]
fn what_this_contract_holds_is_always_navsized_plus_what_it_owes() {
    let f = setup();
    let alice = Address::generate(&f.e);
    let bob = Address::generate(&f.e);
    fund_agusd(&f, &alice, 1_000_0000000);
    fund_agusd(&f, &bob, 1_000_0000000);
    fund_agusd(&f, &f.admin, 500_0000000);

    let held = |f: &Fix| f.ag.balance(&f.vault.address);
    let owed = |f: &Fix, who: &Address| f.vault.pending(who).assets;
    let check = |f: &Fix, note: &str| {
        assert_eq!(
            held(f),
            f.vault.nav() + owed(f, &alice) + owed(f, &bob),
            "{}",
            note
        );
    };

    check(&f, "empty");
    f.vault.stake(&alice, &400_0000000);
    check(&f, "one staker");
    f.vault.stake(&bob, &600_0000000);
    check(&f, "two stakers");

    f.vault.distribute_yield(&100_0000000);
    check(&f, "after yield");

    // Burned shares, assets out of nav, agUSD still here.
    f.vault.request_unstake(&alice, &200_0000000);
    check(&f, "one unstake pending");
    assert!(owed(&f, &alice) > 0, "the request recorded nothing");

    // Yield distributed while a claim is pending goes to whoever is still
    // staked, and the pending balance does not move.
    let alice_owed = owed(&f, &alice);
    f.vault.distribute_yield(&50_0000000);
    assert_eq!(owed(&f, &alice), alice_owed, "a departed staker took yield");
    check(&f, "yield while a claim is pending");

    f.e.ledger().set_timestamp(1_000 + COOLDOWN + 1);
    f.vault.claim(&alice);
    check(&f, "after the claim is paid");

    // A donation raises the balance and nothing else, which is the invariant
    // failing in the safe direction: it is not priced in, so it cannot move the
    // share price, and it is not owed to anybody, so it strands.
    let rate_before = f.vault.exchange_rate();
    f.ag.transfer(&bob, &f.vault.address, &10_0000000);
    assert_eq!(
        f.vault.exchange_rate(),
        rate_before,
        "a direct transfer moved the share price"
    );
    assert_eq!(
        held(&f),
        f.vault.nav() + owed(&f, &alice) + owed(&f, &bob) + 10_0000000,
        "the donation is the whole of the difference"
    );
}

/// A pending unstake is the only record that says a departed staker is still
/// owed anything, and it was given under six hours to say it in.
///
/// `request_unstake` burns the shares and takes the assets out of `nav`, so the
/// record is the whole of the claim: if it archives the money belongs to nobody
/// and sits in this contract. Written with `set` alone it got 4095 ledgers,
/// about five and three quarter hours at five seconds a ledger, while the Vault
/// gives a withdrawal claim ninety days and lets anybody push that out again.
///
/// The second adversarial review is why the Vault does that: an archived claim
/// record takes the calls that read it with it, and the queue stops until
/// somebody pays for a `RestoreFootprint`. This contract holds the same shape of
/// record and had neither half of that fix. A cooldown makes it worse rather
/// than better, because a cooldown is a period the staker is told to go away
/// for.
///
/// Read straight off the ledger entry, because the property is the remaining
/// TTL and nothing the contract returns reports it.
#[test]
fn a_pending_unstake_is_written_with_a_horizon_and_can_be_pushed_out() {
    let f = setup();
    let alice = Address::generate(&f.e);
    fund_agusd(&f, &alice, 1_000_0000000);
    f.vault.stake(&alice, &500_0000000);
    f.vault.request_unstake(&alice, &200_0000000);
    let v = f.vault.address.clone();
    let ttl = |f: &Fix| {
        f.e.as_contract(&v, || {
            f.e.storage()
                .persistent()
                .get_ttl(&Store::Pending(alice.clone()))
        })
    };

    assert_eq!(
        ttl(&f),
        PENDING_BUMP,
        "the record has to be written with a horizon, not with whatever set gives it"
    );

    // Nobody writes to a pending record between the request and the claim, so
    // nothing extends it and it ages by exactly the ledgers that pass.
    f.e.ledger().with_mut(|l| l.sequence_number += 200_000);
    let waiting = ttl(&f);
    assert_eq!(waiting, PENDING_BUMP - 200_000);

    // And anybody can push it back out. The caller is not the staker, on
    // purpose: requiring the owner's signature would mean the one person who
    // might have lost their key is the only one who can keep their claim alive.
    f.vault.bump_pending(&alice);
    assert_eq!(ttl(&f), PENDING_BUMP);

    // It cannot invent a claim, and it cannot alter one.
    let bob = Address::generate(&f.e);
    assert_eq!(
        f.vault.try_bump_pending(&bob),
        Err(Ok(StakingError::NothingPending))
    );
    assert_eq!(f.vault.pending(&alice).assets, 200_0000000);

    // A second request restarts the cooldown and refreshes the horizon with it,
    // because it goes through the same writer.
    f.e.ledger().with_mut(|l| l.sequence_number += 100_000);
    f.vault.request_unstake(&alice, &100_0000000);
    assert_eq!(ttl(&f), PENDING_BUMP);

    // And once the record is claimed there is nothing left to bump.
    f.e.ledger().set_timestamp(1_000 + COOLDOWN + 1);
    f.vault.claim(&alice);
    assert_eq!(
        f.vault.try_bump_pending(&alice),
        Err(Ok(StakingError::NothingPending))
    );
}

/// A share price history has to be buildable from the event stream alone.
///
/// Tranche 1 of the grant funds an indexer exposing NAV and share price
/// history. The share price is `nav / supply`. Supply was already in the stream,
/// through the SEP-41 mint and burn events the token layer emits. `nav` was not
/// in it at all, and neither was a single one of the four calls that move it, so
/// the history could not be built from events: it could only be sampled by
/// polling `exchange_rate()`, which has no past. A number that moves with
/// nothing in the log to explain it is the thing an indexer cannot reconcile.
///
/// So the events carry `nav` and `supply` as they stand after the call. Not
/// because a reader cannot fetch them, but because it cannot fetch them *as they
/// were*.
#[test]
fn the_share_price_at_every_step_is_reconstructible_from_events() {
    let f = setup();
    let alice = Address::generate(&f.e);
    fund_agusd(&f, &alice, 1_000_0000000);
    fund_agusd(&f, &f.admin, 500_0000000);

    // Replay the stream the way an indexer would: take the last (nav, supply)
    // any event reported and compute the price from it.
    let price_from_events = |f: &Fix| -> Option<i128> {
        let mut latest: Option<(i128, i128)> = None;
        for (_, topics, data) in f.e.events().all().iter() {
            let name: Option<Symbol> = topics.get(0).and_then(|t| Symbol::try_from_val(&f.e, &t).ok());
            let Some(name) = name else { continue };
            if name != Symbol::new(&f.e, "staked")
                && name != Symbol::new(&f.e, "unstake_requested")
                && name != Symbol::new(&f.e, "yield_distributed")
            {
                continue;
            }
            if let Ok(m) = soroban_sdk::Map::<Symbol, i128>::try_from_val(&f.e, &data) {
                if let (Some(nav), Some(supply)) = (
                    m.get(symbol_short!("nav")),
                    m.get(symbol_short!("supply")),
                ) {
                    latest = Some((nav, supply));
                }
            }
        }
        latest.map(|(nav, supply)| if supply == 0 { 10_000_000 } else { nav * 10_000_000 / supply })
    };

    f.vault.stake(&alice, &400_0000000);
    assert_eq!(price_from_events(&f), Some(f.vault.exchange_rate()));

    f.vault.distribute_yield(&100_0000000);
    assert_eq!(
        price_from_events(&f),
        Some(f.vault.exchange_rate()),
        "a yield distribution moved the price and the stream did not say so"
    );

    f.vault.request_unstake(&alice, &100_0000000);
    assert_eq!(price_from_events(&f), Some(f.vault.exchange_rate()));

    // And the payout itself is in the stream too, so the cash leaving is
    // reconcilable even though it moves no price.
    f.e.ledger().set_timestamp(1_000 + COOLDOWN + 1);
    let paid = f.vault.claim(&alice);
    let claimed: Option<i128> = f.e.events().all().iter().rev().find_map(|(_, topics, data)| {
        let name: Symbol = Symbol::try_from_val(&f.e, &topics.get(0)?).ok()?;
        if name != Symbol::new(&f.e, "unstake_claimed") {
            return None;
        }
        soroban_sdk::Map::<Symbol, i128>::try_from_val(&f.e, &data)
            .ok()?
            .get(symbol_short!("assets"))
    });
    assert_eq!(claimed, Some(paid), "the payout is not in the event stream");
}

/// The first staker gets shares one for one, raw stroop for raw stroop, and
/// every share price after that is measured from there.
///
/// Accept an agUSD that counts stroops differently from sagUSD and the exchange
/// rate this contract reports as 1.0 is not one to one in value, and nothing
/// downstream can tell, because the internal arithmetic stays perfectly
/// consistent in stroops. It is the same check the Vault makes on the token it
/// mints, for the same reason: an integer ratio is only a price while both sides
/// agree what the integers mean.
#[test]
fn the_agusd_pointer_refuses_a_token_that_counts_stroops_differently() {
    let f = setup();

    let wrong = f.e.register(MockUsdc, ());
    MockUsdcClient::new(&f.e, &wrong).initialize(
        &f.admin,
        &6u32,
        &String::from_str(&f.e, "Agama USD"),
        &String::from_str(&f.e, "agUSD"),
    );
    assert_eq!(
        f.vault.try_set_agusd(&f.admin, &wrong),
        Err(Ok(StakingError::DecimalMismatch))
    );
    assert_eq!(f.vault.agusd(), f.ag.address);

    // Seven decimals is accepted, so this is a check on alignment rather than a
    // wall across repointing.
    let right = f.e.register(MockUsdc, ());
    MockUsdcClient::new(&f.e, &right).initialize(
        &f.admin,
        &7u32,
        &String::from_str(&f.e, "Agama USD"),
        &String::from_str(&f.e, "agUSD"),
    );
    f.vault.set_agusd(&f.admin, &right);
    assert_eq!(f.vault.agusd(), right);
}

/// `set_shares` refuses a token that does not name this contract as its admin.
///
/// The guard exists for the failure the Vault actually hit: a contract pointed
/// at a token it cannot mint is a contract whose `stake` reverts, and the
/// cheapest moment to find that out is before anyone has staked.
#[test]
fn set_shares_refuses_a_token_it_cannot_mint() {
    let f = setup();
    let stranger = Address::generate(&f.e);

    let theirs = f.e.register(MockUsdc, ());
    MockUsdcClient::new(&f.e, &theirs).initialize(
        &stranger,
        &7u32,
        &String::from_str(&f.e, "Not ours"),
        &String::from_str(&f.e, "NOPE"),
    );
    assert_eq!(
        f.vault.try_set_shares(&f.admin, &theirs),
        Err(Ok(StakingError::SharesMismatch))
    );
}

/// And it refuses one that counts stroops differently from agUSD, because the
/// first staker is priced one for one and a mismatch makes a rate of 1.0 not
/// one to one in value.
#[test]
fn set_shares_refuses_a_token_with_the_wrong_decimals() {
    let e = Env::default();
    e.mock_all_auths();
    e.ledger().set_timestamp(1_000);
    let admin = Address::generate(&e);
    let treasury = Address::generate(&e);

    let usdc_id = e.register(MockUsdc, ());
    MockUsdcClient::new(&e, &usdc_id).initialize(
        &admin,
        &7u32,
        &String::from_str(&e, "USD Coin"),
        &String::from_str(&e, "USDC"),
    );
    let ag_id = e.register(AgUsd, ());
    AgUsdClient::new(&e, &ag_id).initialize(
        &admin,
        &usdc_id,
        &treasury,
        &2000u32,
        &7u32,
        &String::from_str(&e, "Agama USD"),
        &String::from_str(&e, "agUSD"),
    );
    let v_id = e.register(Staking, (admin.clone(), ag_id.clone(), COOLDOWN));
    let vault = StakingClient::new(&e, &v_id);

    let six = e.register(MockUsdc, ());
    MockUsdcClient::new(&e, &six).initialize(
        &v_id,
        &6u32,
        &String::from_str(&e, "Staked agUSD"),
        &String::from_str(&e, "sagUSD"),
    );
    assert_eq!(
        vault.try_set_shares(&admin, &six),
        Err(Ok(StakingError::DecimalMismatch))
    );
}

/// Once a stake has been taken the share token is fixed, because shares
/// outstanding are denominated in it.
#[test]
fn set_shares_shuts_once_somebody_has_staked() {
    let f = setup();
    let alice = Address::generate(&f.e);
    fund_agusd(&f, &alice, 100 * ONE);
    f.vault.stake(&alice, &(100 * ONE));

    let other = f.e.register(MockUsdc, ());
    MockUsdcClient::new(&f.e, &other).initialize(
        &f.vault.address,
        &7u32,
        &String::from_str(&f.e, "Staked agUSD"),
        &String::from_str(&f.e, "sagUSD"),
    );
    assert_eq!(
        f.vault.try_set_shares(&f.admin, &other),
        Err(Ok(StakingError::CustodyTaken))
    );
}

/// The share supply is counted here, and it has to track the token's own ledger
/// through a full round trip.
///
/// A Stellar Asset Contract publishes no total supply, so this contract keeps
/// the count itself. That is a second number for the same quantity, which is
/// exactly the shape of thing that drifts, so the test reads both and compares.
#[test]
fn tracked_supply_matches_the_share_token_through_a_round_trip() {
    let f = setup();
    let shares = MockUsdcClient::new(&f.e, &f.vault.shares());
    let alice = Address::generate(&f.e);
    let bob = Address::generate(&f.e);

    fund_agusd(&f, &alice, 100 * ONE);
    fund_agusd(&f, &bob, 60 * ONE);

    f.vault.stake(&alice, &(100 * ONE));
    assert_eq!(f.vault.total_supply(), shares.total_supply());
    assert_eq!(f.vault.balance(&alice), shares.balance(&alice));

    // Yield moves the rate but not the share count.
    fund_agusd(&f, &f.admin, 50 * ONE);
    f.vault.distribute_yield(&(50 * ONE));
    assert_eq!(f.vault.total_supply(), shares.total_supply());
    assert_eq!(f.vault.exchange_rate(), 15 * ONE / 10);

    // A second staker at the higher price gets fewer shares than assets.
    f.vault.stake(&bob, &(60 * ONE));
    assert_eq!(f.vault.total_supply(), shares.total_supply());
    assert_eq!(f.vault.balance(&bob), 40 * ONE);

    // And unstaking burns through the token, so both counts fall together.
    f.vault.request_unstake(&alice, &(100 * ONE));
    assert_eq!(f.vault.total_supply(), shares.total_supply());
    assert_eq!(f.vault.balance(&alice), 0);
}
