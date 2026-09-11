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

    let v_id = e.register(
        Staking,
        (
            admin.clone(),
            ag_id.clone(),
            COOLDOWN,
            7u32,
            String::from_str(&e, "Staked agUSD"),
            String::from_str(&e, "sagUSD"),
        ),
    );
    let vault = StakingClient::new(&e, &v_id);

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
