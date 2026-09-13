#!/usr/bin/env bash
# On-chain smoke test of the sagUSD yield path, under the names Agama committed
# to: stake, distribute_yield, and the two step unstake through the cooldown.
#
# Everything here runs against the LIVE testnet deployment recorded in
# deployments/testnet.json. Every state change is submitted, not simulated, so
# each one leaves a transaction hash anybody can look up. Views are simulated
# and cost nothing.
#
# Covers, with assertions:
#   wiring   : sagUSD stakes the agUSD the Vault actually mints
#   names    : distribute_yield and exchange_rate are on the deployed interface,
#              accrue_yield is not, and share_price is the same number as
#              exchange_rate rather than a second source of truth
#   stake    : agUSD in, shares out at the current rate, custody really moves
#   yield    : distribute_yield raises the rate for every existing holder and
#              mints nobody a share to do it
#   exit     : request_unstake burns the shares and queues the appreciated
#              value, the cooldown holds, and claim pays out more agUSD than
#              was staked
#
# It is repeatable: the position is fully unwound at the end, so the only
# lasting change is the yield the admin delivered into the contract and took
# back out again.
#
# Needs the admin account (agama-poc) to hold STAKE + YIELD in agUSD, and will
# mint the shortfall by depositing real Circle USDC into the Vault. Get USDC at
# https://faucet.circle.com (USDC / Stellar Testnet).
#
# Written for the generation before the adversarial security review, which
# removed report_nav from this contract. scripts/smoke-hardening.sh covers the
# yield path against the current deployment. Kept because the transactions it
# produced are still on the ledger.
#
# Usage: bash scripts/smoke-sagusd.sh
set -uo pipefail
cd "$(dirname "$0")/.."

NET=testnet
SRC=agama-poc
DEP=deployments/testnet.json

STAKE=10000000 # 1 agUSD staked
YIELD=1000000  # 0.1 agUSD delivered, a 10% move on the staked balance

j() { python3 -c "import json;d=json.load(open('$DEP'));print($1)"; }
AGUSD=$(j "d['contracts']['agusdCore']")
STAKING=$(j "d['contracts']['staking']")
VAULT=$(j "d['contracts']['vault']")
USDC=$(j "d['contracts']['usdc']")
COOLDOWN=$(j "d['cooldownSeconds']")
ADMIN=$(stellar keys address $SRC)

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  PASS  $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL  $1"; }
num() { echo "$1" | tr -d '"'; }
assert_eq() { if [ "$(num "$2")" = "$3" ]; then ok "$1 ($2)"; else bad "$1: got $2, want $3"; fi; }
assert_gt() {
  if [ "$(num "$2")" -gt "$3" ]; then ok "$1 ($2 > $3)"; else bad "$1: got $2, want > $3"; fi
}

# Read-only: simulated, never submitted, so views cost nothing.
# A read that comes back empty is not a contract answering with nothing. It
# happens when something else is submitting from the same account at the same
# time, which is what running two of these suites at once does: the sequence
# number collides, calls fail with TxBadSeq, and reads come back blank. One
# blank poisons everything after it, because the Vault address is itself read
# from the Engine here, so a single empty answer turns every later assertion
# into a diff against an empty string and reads like a page of contract
# defects. Retried before being believed. Running two suites against one
# account concurrently is still the wrong thing to do; this only stops it
# looking like a protocol failure when it happens.
q() {
  local out i
  for i in 1 2 3 4; do
    out=$(stellar contract invoke --id "$1" --source $SRC --network $NET --send=no -- "${@:2}" 2>/dev/null)
    [ -n "$out" ] && { echo "$out"; return 0; }
    sleep 2
  done
  echo "$out"
}
# State changing: submitted, and the transaction hash is echoed.
tx() { stellar contract invoke --id "$1" --source $SRC --network $NET -- "${@:2}" 2>&1 \
         | grep -oE '[0-9a-f]{64}' | head -1; }

echo "== deployment under test =="
echo "  sagUSD staking     $STAKING"
echo "  agusd-core         $AGUSD"
echo "  vault              $VAULT"

echo ""
echo "== WIRING =="
assert_eq "sagUSD stakes the agUSD the Vault mints" "$(q "$STAKING" agusd)" "$AGUSD"
assert_eq "the Vault mints that same token" "$(q "$VAULT" agusd)" "$AGUSD"
assert_eq "the cooldown is the configured one" "$(q "$STAKING" cooldown)" "$COOLDOWN"

echo ""
echo "== NAMES: the committed convention, on the deployed interface =="
IFACE=$(stellar contract info interface --id "$STAKING" --network $NET 2>/dev/null)
for fn in distribute_yield exchange_rate; do
  if echo "$IFACE" | grep -q "fn $fn"; then
    ok "$fn is on the deployed interface"
  else
    bad "$fn is missing from the deployed interface"
  fi
done
if echo "$IFACE" | grep -q "fn accrue_yield"; then
  bad "accrue_yield is still on the deployed interface; it was renamed, not aliased"
else
  ok "accrue_yield is gone, renamed rather than aliased"
fi
assert_eq "share_price is the same view under the older name" \
  "$(q "$STAKING" share_price)" "$(num "$(q "$STAKING" exchange_rate)")"

# This measures share issuance and the exchange rate from a standing start, so
# it needs the staking contract empty. Another script leaving shares in it turns
# every rate assertion below into a diff that reads like a pricing bug and is
# not.
#
# It used to stop here and say unwinding was the operator's call. That is right
# when the shares belong to somebody, and it was also the reason these suites
# could not be run one after another: the previous one leaves its own position
# behind. So it unwinds, but only when this account holds every share in
# existence, which is the case where doing it strands nobody. See
# lib-unwind-staking.sh.
echo ""
echo "== PRECONDITION: staking empty =="
# shellcheck source=lib-unwind-staking.sh
. "$(dirname "$0")/lib-unwind-staking.sh"
unwind_staking "$STAKING" "$SRC" "$NET" "$ADMIN" || exit 2

echo ""
echo "== PREFLIGHT: agUSD to stake and to distribute =="
NEED=$((STAKE + YIELD))
HAVE=$(num "$(q "$AGUSD" balance --id "$ADMIN")")
echo "  the admin holds $HAVE agUSD and needs $NEED"
if [ "${HAVE:-0}" -lt "$NEED" ]; then
  SHORT=$((NEED - HAVE))
  U=$(num "$(q "$USDC" balance --id "$ADMIN")")
  if [ "${U:-0}" -lt "$SHORT" ]; then
    # The shortfall is minted from USDC, and the USDC may itself be sitting in
    # the Vault as this account's own agUSD from an earlier suite. Settle and
    # redeem before deciding the faucet is the answer.
    # shellcheck source=lib-ensure-usdc.sh
    . "$(dirname "$0")/lib-ensure-usdc.sh"
    ensure_usdc "$VAULT" "$USDC" "$AGUSD" "$SHORT" "$SRC" "$NET" "$ADMIN" || true
    U=$(num "$(q "$USDC" balance --id "$ADMIN")")
  fi
  if [ "${U:-0}" -lt "$SHORT" ]; then
    echo "  the admin holds $U (7dp) of USDC and needs $SHORT to mint the shortfall"
    echo "  top up at https://faucet.circle.com (USDC / Stellar Testnet) for $ADMIN"
    exit 2
  fi
  echo "  minting the $SHORT shortfall through the Vault"
  echo "  deposit $SHORT  tx $(tx "$VAULT" deposit --from "$ADMIN" --amount "$SHORT")"
  assert_eq "the admin can now cover the stake and the distribution" \
    "$(q "$AGUSD" balance --id "$ADMIN")" "$NEED"
fi

echo ""
echo "== 1. STAKE: agUSD into sagUSD =="
A0=$(num "$(q "$AGUSD" balance --id "$ADMIN")")
SHARES0=$(num "$(q "$STAKING" total_shares)")
CUSTODY0=$(num "$(q "$AGUSD" balance --id "$STAKING")")
RATE0=$(num "$(q "$STAKING" exchange_rate)")
echo "  stake $STAKE  tx $(tx "$STAKING" stake --from "$ADMIN" --amount "$STAKE")"
MINTED=$((STAKE * 10000000 / RATE0))
assert_eq "shares were issued at the rate that was showing" \
  "$(q "$STAKING" balance --id "$ADMIN")" "$MINTED"
assert_eq "the staking contract custodies the agUSD" \
  "$(q "$AGUSD" balance --id "$STAKING")" "$((CUSTODY0 + STAKE))"
assert_eq "and it left the staker's account" \
  "$(q "$AGUSD" balance --id "$ADMIN")" "$((A0 - STAKE))"
assert_eq "staking does not move the rate" "$(q "$STAKING" exchange_rate)" "$RATE0"

echo ""
echo "== 2. DISTRIBUTE_YIELD: the exchange rate rises =="
NAV0=$(num "$(q "$STAKING" nav)")
SHARES1=$(num "$(q "$STAKING" total_shares)")
HELD=$(num "$(q "$STAKING" balance --id "$ADMIN")")
echo "  distribute_yield $YIELD  tx $(tx "$STAKING" distribute_yield --amount "$YIELD")"
assert_eq "the NAV rose by exactly the yield delivered" \
  "$(q "$STAKING" nav)" "$((NAV0 + YIELD))"
assert_eq "and the agUSD is really in the contract, not just booked" \
  "$(q "$AGUSD" balance --id "$STAKING")" "$((CUSTODY0 + STAKE + YIELD))"
assert_gt "the exchange rate rose" "$(q "$STAKING" exchange_rate)" "$RATE0"
assert_eq "to the NAV per share" "$(q "$STAKING" exchange_rate)" \
  "$(( (NAV0 + YIELD) * 10000000 / SHARES1 ))"
assert_eq "nobody minted a share to do it" "$(q "$STAKING" total_shares)" "$SHARES1"
assert_eq "and no holder's balance changed" "$(q "$STAKING" balance --id "$ADMIN")" "$HELD"
assert_eq "share_price agrees, under the older name" \
  "$(q "$STAKING" share_price)" "$(num "$(q "$STAKING" exchange_rate)")"

echo ""
echo "== 3. UNSTAKE: two steps, through the cooldown =="
A1=$(num "$(q "$AGUSD" balance --id "$ADMIN")")
echo "  request_unstake $MINTED  tx $(tx "$STAKING" request_unstake --from "$ADMIN" --shares "$MINTED")"
OWED=$(num "$(q "$STAKING" pending --addr "$ADMIN" \
  | python3 -c "import sys,json;print(json.load(sys.stdin)['assets'])")")
assert_eq "the shares are burned at request time" "$(q "$STAKING" balance --id "$ADMIN")" "0"
assert_gt "and the position is worth more than was staked" "$OWED" "$STAKE"
if [ -z "$(tx "$STAKING" claim --from "$ADMIN")" ]; then
  ok "the cooldown holds: claim is refused before it elapses"
else
  bad "claim paid out before the cooldown elapsed"
fi
echo "  waiting out the ${COOLDOWN}s cooldown"
python3 -c "import time;time.sleep($COOLDOWN + 10)"
echo "  claim  tx $(tx "$STAKING" claim --from "$ADMIN")"
assert_eq "the staker got back the appreciated value" \
  "$(q "$AGUSD" balance --id "$ADMIN")" "$((A1 + OWED))"
assert_gt "which is more agUSD than was staked" "$((OWED))" "$STAKE"
assert_eq "the contract is back to holding what it started with" \
  "$(q "$AGUSD" balance --id "$STAKING")" "$CUSTODY0"
assert_eq "and the rate is back to par with no shares outstanding" \
  "$(q "$STAKING" exchange_rate)" "10000000"

echo ""
echo "================================"
echo " sagUSD SMOKE RESULT: $PASS passed, $FAIL failed"
echo "================================"
[ "$FAIL" = "0" ]
