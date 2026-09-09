#!/usr/bin/env bash
# End-to-end test of the Agama Stellar POC against the LIVE testnet,
# using the REAL Circle USDC (no mint at will — small amounts, recycled).
#
# Needs the admin account (agama-poc) to hold >= 10 USDC. Get some at
# https://faucet.circle.com (USDC / Stellar Testnet) — the admin trustline
# already exists.
#
# Covers, with assertions:
#   core : deposit USDC -> mint agUSD 1:1 -> redeem 1:1 -> stake sagUSD ->
#          distribute_yield (exchange rate rises) -> cooldown blocks ->
#          claim w/ profit
#   per-vault (x6): deposit USDC -> shares -> yield -> share price up ->
#          request_unstake -> claim with profit
#
# Two generations of the staking contract are on-chain at once. sagUSD carries
# the DeFindex names, distribute_yield and exchange_rate. The six credit vaults
# are instances of an earlier build of the same contract, deployed before that
# rename and not redeployed since, so they answer to accrue_yield and only to
# share_price. The yield entry point is therefore resolved per contract off the
# interface each instance actually publishes, rather than assumed.
set -uo pipefail
cd "$(dirname "$0")/.."
NET=testnet
SRC=agama-poc

DEP=deployments/testnet.json
USDC=$(python3 -c "import json;print(json.load(open('$DEP'))['contracts']['usdc'])")
AGUSD=$(python3 -c "import json;print(json.load(open('$DEP'))['contracts']['agusd'])")
SAG=$(python3 -c "import json;print(json.load(open('$DEP'))['contracts']['staking'])")
VAULTS=$(python3 -c "import json;print(' '.join(f'{k}={v}' for k,v in json.load(open('$DEP'))['creditVaults'].items()))")
ADMIN=$(stellar keys address agama-poc)

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); echo "  ✅ $1"; }
bad()  { FAIL=$((FAIL+1)); echo "  ❌ $1"; }
num()  { echo "$1" | tr -d '"'; }
assert_eq() { if [ "$(num "$2")" = "$3" ]; then ok "$1 ($2)"; else bad "$1: got $2, want $3"; fi; }
assert_gt() { if [ "$(python3 -c "print(1 if int('$(num "$2")') > int('$3') else 0)")" = "1" ]; then ok "$1 ($2 > $3)"; else bad "$1: got $2, want > $3"; fi; }

inv() { stellar contract invoke --id "$1" --source $SRC --network $NET -- "${@:2}" 2>/dev/null; }

# Which name this deployed instance gives the yield entry point.
yield_fn() {
  if stellar contract info interface --id "$1" --network $NET 2>/dev/null \
     | grep -q 'fn distribute_yield'; then echo distribute_yield; else echo accrue_yield; fi
}

echo "== preflight: admin USDC balance (real Circle USDC) =="
BAL=$(num "$(inv $USDC balance --id $ADMIN)")
echo "  admin=$ADMIN balance=$BAL (7dp)"
if [ -z "$BAL" ] || [ "$BAL" -lt 80000000 ]; then
  echo ""
  echo "  ⛔ Need >= 8 USDC on the admin to run the E2E."
  echo "     Go to https://faucet.circle.com -> USDC / Stellar Testnet -> send to:"
  echo "     $ADMIN"
  exit 2
fi

echo ""
echo "== CORE FLOW: USDC -> agUSD -> sagUSD (5 USDC working capital) =="
A0=$(num "$(inv $AGUSD balance --id $ADMIN)")
inv $AGUSD deposit --from $ADMIN --amount 50000000 >/dev/null            # 5 USDC
A1=$(num "$(inv $AGUSD balance --id $ADMIN)")
assert_eq "mint 1:1: +5 agUSD" "$((A1-A0))" "50000000"

inv $AGUSD redeem --from $ADMIN --amount 10000000 >/dev/null             # redeem 1
A2=$(num "$(inv $AGUSD balance --id $ADMIN)")
assert_eq "redeem 1:1: -1 agUSD" "$((A1-A2))" "10000000"

SAG_YIELD_FN=$(yield_fn "$SAG")
SP0=$(num "$(inv $SAG exchange_rate)")
S0=$(num "$(inv $SAG balance --id $ADMIN)")
inv $SAG stake --from $ADMIN --amount 30000000 >/dev/null                # stake 3 agUSD
S1=$(num "$(inv $SAG balance --id $ADMIN)")
assert_gt "stake: sagUSD shares minted" "$((S1-S0))" "0"

inv $SAG "$SAG_YIELD_FN" --amount 5000000 >/dev/null                     # +0.5 agUSD yield
SP1=$(num "$(inv $SAG exchange_rate)")
assert_gt "$SAG_YIELD_FN: exchange rate rose" "$SP1" "$SP0"

inv $SAG request_unstake --from $ADMIN --shares $((S1-S0)) >/dev/null
if inv $SAG claim --from $ADMIN >/dev/null 2>&1; then
  bad "cooldown should block early claim"
else
  ok "cooldown blocks early claim"
fi
echo "  …waiting out the sagUSD cooldown (60s)…"
sleep 62
CLAIMED=$(num "$(inv $SAG claim --from $ADMIN)")
assert_gt "claim after cooldown: payout > principal (yield!)" "$CLAIMED" "30000000"

echo ""
echo "== CREDIT VAULTS (3 Qiro + 3 Tenka): 1 USDC each, real USDC =="
for kv in $VAULTS; do
  slug="${kv%%=*}"; VID="${kv#*=}"
  echo "-- $slug --"
  SP0=$(num "$(inv $VID share_price)")
  V0=$(num "$(inv $VID balance --id $ADMIN)")
  inv $VID stake --from $ADMIN --amount 10000000 >/dev/null              # 1 USDC
  V1=$(num "$(inv $VID balance --id $ADMIN)")
  assert_gt "deposit: shares minted" "$((V1-V0))" "0"

  inv $VID "$(yield_fn "$VID")" --amount 1000000 >/dev/null             # +0.1 USDC
  SP1=$(num "$(inv $VID share_price)")
  assert_gt "yield: share price rose" "$SP1" "$SP0"

  inv $VID request_unstake --from $ADMIN --shares $((V1-V0)) >/dev/null
  sleep 11
  OUT=$(num "$(inv $VID claim --from $ADMIN)")
  assert_gt "exit: USDC payout > principal" "$OUT" "10000000"
done

echo ""
echo "================================"
echo " E2E RESULT: $PASS passed, $FAIL failed"
echo "================================"
[ "$FAIL" = "0" ]
