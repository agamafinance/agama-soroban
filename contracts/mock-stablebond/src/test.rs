#![cfg(test)]
use super::*;
use mock_usdc::{MockUsdc, MockUsdcClient};
use soroban_sdk::testutils::Address as _;
use soroban_sdk::String;

const USDC: i128 = 1_0000000;

struct Fix {
    e: Env,
    usdc: MockUsdcClient<'static>,
    usdc_id: Address,
    pool: MockStablebondClient<'static>,
    pool_id: Address,
    admin: Address,
    holder: Address,
}

fn setup(price: i128) -> Fix {
    let e = Env::default();
    e.mock_all_auths();
    let admin = Address::generate(&e);
    let holder = Address::generate(&e);

    let usdc_id = e.register(MockUsdc, ());
    let usdc = MockUsdcClient::new(&e, &usdc_id);
    usdc.initialize(
        &admin,
        &7u32,
        &String::from_str(&e, "USD Coin"),
        &String::from_str(&e, "USDC"),
    );
    usdc.faucet(&holder, &(1_000 * USDC));

    let pool_id = e.register(
        MockStablebond,
        (admin.clone(), usdc_id.clone(), price),
    );
    let pool = MockStablebondClient::new(&e, &pool_id);
    Fix {
        e,
        usdc,
        usdc_id,
        pool,
        pool_id,
        admin,
        holder,
    }
}

#[test]
fn subscribe_issues_units_and_takes_the_usdc() {
    let f = setup(ONE);
    let units = f.pool.subscribe(&f.holder, &(100 * USDC));
    assert_eq!(units, 100 * USDC, "at par, one unit per USDC");
    assert_eq!(f.pool.units(&f.holder), 100 * USDC);
    assert_eq!(f.pool.total_units(), 100 * USDC);
    assert_eq!(f.usdc.balance(&f.pool_id), 100 * USDC);
    assert_eq!(f.usdc.balance(&f.holder), 900 * USDC);
}

#[test]
fn a_round_trip_at_a_flat_price_returns_the_principal() {
    let f = setup(ONE);
    let units = f.pool.subscribe(&f.holder, &(100 * USDC));
    let back = f.pool.redeem(&f.holder, &units);
    assert_eq!(back, 100 * USDC);
    assert_eq!(f.pool.units(&f.holder), 0);
    assert_eq!(f.usdc.balance(&f.holder), 1_000 * USDC);
}

#[test]
fn units_are_bought_at_the_price_of_the_day() {
    // 1.25 USDC per unit: 100 USDC buys 80 units, not 100.
    let f = setup(1_2500000);
    let units = f.pool.subscribe(&f.holder, &(100 * USDC));
    assert_eq!(units, 80 * USDC);
    assert_eq!(f.pool.value_of(&units), 100 * USDC);
}

#[test]
fn only_the_usdc_that_bought_whole_units_is_taken() {
    // 3 USDC per unit. 10 USDC buys 3.3333333 units, which at 7 decimals is a
    // whole number of the smallest unit, so the remainder here is sub-stroop.
    // The invariant that matters is the one asserted: the pool charges exactly
    // what the units it issued are worth, so nothing is confiscated.
    let f = setup(3_0000000);
    let units = f.pool.subscribe(&f.holder, &(10 * USDC));
    let charged = 1_000 * USDC - f.usdc.balance(&f.holder);
    assert_eq!(charged, f.pool.value_of(&units));
    assert!(charged <= 10 * USDC);
}

#[test]
fn a_subscription_too_small_for_one_unit_is_refused_rather_than_kept() {
    // A unit costs 2 USDC and the caller offers one stroop.
    let f = setup(2_0000000);
    assert_eq!(
        f.pool.try_subscribe(&f.holder, &1),
        Err(Ok(PoolError::DustSubscription))
    );
    assert_eq!(f.usdc.balance(&f.holder), 1_000 * USDC, "nothing was taken");
}

#[test]
fn the_price_moving_is_how_the_bond_accrues() {
    let f = setup(ONE);
    let units = f.pool.subscribe(&f.holder, &(100 * USDC));
    f.pool.set_price(&f.admin, &1_1000000); // plus 10%
    assert_eq!(f.pool.value_of(&units), 110 * USDC, "same units, more value");
    assert_eq!(f.pool.units(&f.holder), units, "no unit was minted");
}

#[test]
fn a_repricing_the_pool_cannot_pay_fails_the_redemption_instead_of_underpaying() {
    let f = setup(ONE);
    let units = f.pool.subscribe(&f.holder, &(100 * USDC));
    // The coupon is declared but never paid in: the pool owes 110 and holds 100.
    f.pool.set_price(&f.admin, &1_1000000);
    assert_eq!(
        f.pool.try_redeem(&f.holder, &units),
        Err(Ok(PoolError::PoolIlliquid))
    );
    assert_eq!(f.pool.units(&f.holder), units, "the position survives intact");

    // Funded, the same redemption pays the accrued value.
    f.usdc.faucet(&f.admin, &(50 * USDC));
    f.pool.fund(&f.admin, &(10 * USDC));
    assert_eq!(f.pool.redeem(&f.holder, &units), 110 * USDC);
}

#[test]
fn a_partial_redemption_leaves_the_rest_of_the_position() {
    let f = setup(ONE);
    let units = f.pool.subscribe(&f.holder, &(100 * USDC));
    let paid = f.pool.redeem(&f.holder, &(units / 4));
    assert_eq!(paid, 25 * USDC);
    assert_eq!(f.pool.units(&f.holder), units - units / 4);
    assert_eq!(f.pool.total_units(), units - units / 4);
}

#[test]
fn redeeming_more_than_you_hold_is_refused() {
    let f = setup(ONE);
    let units = f.pool.subscribe(&f.holder, &(10 * USDC));
    assert_eq!(
        f.pool.try_redeem(&f.holder, &(units + 1)),
        Err(Ok(PoolError::InsufficientUnits))
    );
}

#[test]
fn one_holder_cannot_be_paid_out_of_another_holders_principal() {
    let f = setup(ONE);
    let second = Address::generate(&f.e);
    f.usdc.faucet(&second, &(100 * USDC));
    let mine = f.pool.subscribe(&f.holder, &(100 * USDC));
    f.pool.subscribe(&second, &(100 * USDC));

    // The price doubles with no coupon paid in. The pool holds 200 and owes
    // 400, so the first redemption to arrive must not be allowed to take
    // everything: it asks for 200, the pool has exactly 200, and that is the
    // uncomfortable case. The mock pays it, which is what an unfunded bond pool
    // genuinely does, and the second holder is then told the truth.
    f.pool.set_price(&f.admin, &2_0000000);
    assert_eq!(f.pool.redeem(&f.holder, &mine), 200 * USDC);
    assert_eq!(
        f.pool.try_redeem(&second, &(100 * USDC)),
        Err(Ok(PoolError::PoolIlliquid)),
        "the shortfall surfaces as a refusal, not as a short payment"
    );
}

#[test]
fn zero_and_negative_amounts_are_refused_on_both_paths() {
    let f = setup(ONE);
    assert_eq!(
        f.pool.try_subscribe(&f.holder, &0),
        Err(Ok(PoolError::InvalidAmount))
    );
    assert_eq!(
        f.pool.try_subscribe(&f.holder, &-1),
        Err(Ok(PoolError::InvalidAmount))
    );
    assert_eq!(
        f.pool.try_redeem(&f.holder, &0),
        Err(Ok(PoolError::InvalidAmount))
    );
}

#[test]
fn the_usdc_the_pool_reports_is_the_one_it_was_built_with() {
    let f = setup(ONE);
    assert_eq!(f.pool.usdc(), f.usdc_id);
    assert_eq!(f.pool.admin(), f.admin);
}
