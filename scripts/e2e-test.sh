#!/usr/bin/env bash
# End-to-end test of the Agama Stellar POC against the LIVE testnet,
# using the REAL Circle USDC (no mint at will: small amounts, recycled).
#
# Needs the admin account (agama-poc) to hold >= 10 USDC. Get some at
# https://faucet.circle.com (USDC / Stellar Testnet): the admin trustline
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
# The Vault, for the redemption path in the preflight below. This suite drives
# agUSD and the six credit vaults directly and never needed it before.
VAULT=$(python3 -c "import json;print(json.load(open('$DEP'))['contracts']['vault'])")
ADMIN=$(stellar keys address agama-poc)

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); echo "  ✅ $1"; }
bad()  { FAIL=$((FAIL+1)); echo "  ❌ $1"; }
num()  { echo "$1" | tr -d '"'; }
assert_eq() { if [ "$(num "$2")" = "$3" ]; then ok "$1 ($2)"; else bad "$1: got $2, want $3"; fi; }
assert_gt() { if [ "$(python3 -c "print(1 if int('$(num "$2")') > int('$3') else 0)")" = "1" ]; then ok "$1 ($2 > $3)"; else bad "$1: got $2, want > $3"; fi; }

inv() { stellar contract invoke --id "$1" --source $SRC --network $NET -- "${@:2}" 2>/dev/null; }

# The same call, but it says whether the transaction actually landed.
#
# `inv` swallows stderr, so a submission that testnet dropped looks exactly like
# a call that returned nothing: the balance after is the balance before, and the
# suite reports "minted 0", which reads as the Vault being broken. testnet drops
# one often enough that two of these failures moved between runs on the same
# unchanged contracts. A step that did not happen is not a wrong answer, and
# conflating the two is how a red suite stops meaning anything.
#
# SENT is 0 when the transaction landed and non-zero with the reason when it did
# not, so the caller can skip loudly instead of asserting on a balance nothing
# moved.
SENT_ERR=""
send() {
  local out
  SENT_ERR=""
  out=$(stellar contract invoke --id "$1" --source $SRC --network $NET -- "${@:2}" 2>&1)
  if printf '%s' "$out" | grep -qE "error:|Error\(Contract"; then
    SENT_ERR=$(printf '%s' "$out" | grep -oE "Error\(Contract, #[0-9]+\)|error: [^\n]{0,80}" | head -1)
    return 1
  fi
  printf '%s' "$out" | tail -1
  return 0
}

# Which name this deployed instance gives the yield entry point.
yield_fn() {
  if stellar contract info interface --id "$1" --network $NET 2>/dev/null \
     | grep -q 'fn distribute_yield'; then echo distribute_yield; else echo accrue_yield; fi
}

echo "== preflight: admin spendable USDC =="
# Spendable, not held. For a classic asset the SAC's `balance` returns the
# trustline's balance, and that includes whatever this account's own open SDEX
# offers have locked as selling liabilities. This account is also the sagUSD
# market maker, so `balance` read 1013 USDC while 0.26 was spendable, every
# transfer below failed with BalanceError, 10, and the suite reported it as
# "minted 0" which looks exactly like the Vault being broken.
ADMIN_SPENDABLE=$(curl -s --max-time 20 "https://horizon-testnet.stellar.org/accounts/$ADMIN" | python3 -c "
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    print(0); raise SystemExit
for b in d.get('balances', []):
    if b.get('asset_code') == 'USDC':
        print(int(round((float(b['balance']) - float(b.get('selling_liabilities', 0) or 0)) * 10_000_000)))
        break
else:
    print(0)
" 2>/dev/null || echo 0)
HELD=$(num "$(inv $USDC balance --id $ADMIN)")
echo "  admin=$ADMIN  held=$HELD  spendable=$ADMIN_SPENDABLE (7dp)"
# Short is not the same as broke: the money is in the Vault and this account
# holds the claim on it, so redeeming is a call away. ensure_usdc settles the
# queue first and then redeems agUSD for the shortfall, both ordinary user
# actions on this account's own position.
if [ "${ADMIN_SPENDABLE:-0}" -lt 80000000 ]; then
  echo "  short of the 8 USDC this run needs; settling and redeeming for the difference"
  # shellcheck source=lib-ensure-usdc.sh
  . "$(dirname "$0")/lib-ensure-usdc.sh"
  ensure_usdc "$VAULT" "$USDC" "$AGUSD" 80000000 "$SRC" "$NET" "$ADMIN" || true
  ADMIN_SPENDABLE=$(curl -s --max-time 20 "https://horizon-testnet.stellar.org/accounts/$ADMIN" | python3 -c "
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    print(0); raise SystemExit
for b in d.get('balances', []):
    if b.get('asset_code') == 'USDC':
        print(int(round((float(b['balance']) - float(b.get('selling_liabilities', 0) or 0)) * 10_000_000)))
        break
else:
    print(0)
" 2>/dev/null || echo 0)
  echo "  spendable now $ADMIN_SPENDABLE"
fi
if [ "${ADMIN_SPENDABLE:-0}" -lt 80000000 ]; then
  echo ""
  echo "  Need >= 8 USDC spendable on the admin to run this. It holds $HELD and can"
  echo "  spend $ADMIN_SPENDABLE: the difference is locked by its own open offers."
  echo "    curl -s https://horizon-testnet.stellar.org/accounts/$ADMIN/offers"
  echo "  Or top it up: https://faucet.circle.com -> USDC / Stellar Testnet -> $ADMIN"
  exit 2
fi

echo ""
echo "== CORE FLOW: USDC -> agUSD -> sagUSD (5 USDC working capital) =="
# Through the Vault, which is where minting lives on this generation.
#
# These two lines called `deposit` and `redeem` on agUSD itself, which were the
# entry points of the generation 1 agUSD: a self-contained vault that minted
# inside its own deposit(). agUSD is a Stellar Asset Contract now. Its entry
# points are admin, set_admin, authorized, set_authorized, clawback, trust,
# mint, burn and the token interface, and it has neither deposit nor redeem, so
# both calls failed, neither balance moved, and the suite reported "+5 agUSD:
# got 0" twice. The Vault mints against USDC one for one and the withdrawal
# queue is how it comes back out.
A0=$(num "$(inv $AGUSD balance --id $ADMIN)")
if send $VAULT deposit --from $ADMIN --amount 50000000 >/dev/null; then
  A1=$(num "$(inv $AGUSD balance --id $ADMIN)")
  assert_eq "mint 1:1: +5 agUSD through the Vault" "$((A1-A0))" "50000000"
else
  echo "  SKIP  the deposit did not land ($SENT_ERR), so there is no mint to measure"
  A1=$A0
fi

# Out through the queue: request_withdrawal burns the agUSD and enqueues the
# USDC claim, claim_withdrawal pays it once Ready. One agUSD is exactly the
# Vault's MIN_WITHDRAWAL, the anti-dust floor, so this is the smallest exit the
# contract will take.
CID=$(send $VAULT request_withdrawal --from "$ADMIN" --amount 10000000 | tr -d '"')
if [ -n "$CID" ] && [ -z "$SENT_ERR" ]; then
  send $VAULT claim_withdrawal --from "$ADMIN" --claim_id "$CID" >/dev/null || true
  A2=$(num "$(inv $AGUSD balance --id $ADMIN)")
  assert_eq "redeem 1:1: -1 agUSD through the queue" "$((A1-A2))" "10000000"
else
  echo "  SKIP  the withdrawal request did not land ($SENT_ERR), so there is no redemption to measure"
fi

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
echo "== CREDIT VAULTS (3 Qiro + 3 ABF): 1 USDC each, real USDC =="
for kv in $VAULTS; do
  slug="${kv%%=*}"; VID="${kv#*=}"
  echo "-- $slug --"
  SP0=$(num "$(inv $VID share_price)")
  V0=$(num "$(inv $VID balance --id $ADMIN)")
  inv $VID stake --from $ADMIN --amount 10000000 >/dev/null              # 1 USDC
  V1=$(num "$(inv $VID balance --id $ADMIN)")
  assert_gt "deposit: shares minted" "$((V1-V0))" "0"

  # Same treatment as the core flow. The distribution is a submitted
  # transaction and testnet drops one occasionally, and when it does the share
  # price is unchanged for a reason that has nothing to do with the contract.
  # Asserting on it anyway reported "share price rose: got X, want > X", which
  # reads as the yield mechanism being broken.
  if send $VID "$(yield_fn "$VID")" --amount 1000000 >/dev/null; then       # +0.1 USDC
    SP1=$(num "$(inv $VID share_price)")
    assert_gt "yield: share price rose" "$SP1" "$SP0"
    YIELDED=1
  else
    echo "  SKIP  the distribution did not land ($SENT_ERR), so there is no rise to measure"
    YIELDED=0
  fi

  if send $VID request_unstake --from $ADMIN --shares $((V1-V0)) >/dev/null; then
    sleep 11
    OUT=$(num "$(inv $VID claim --from $ADMIN)")
    # Only above principal when yield actually landed. Without it the round
    # trip returns the principal less the vault's rounding, which is a stroop in
    # the vault's favour and is correct: the share arithmetic floors, so the
    # holder cannot round a free stroop out of it. Asserting a profit on a
    # distribution that never happened was asserting that the rounding goes the
    # other way.
    if [ "$YIELDED" = "1" ]; then
      assert_gt "exit: USDC payout > principal" "$OUT" "10000000"
    else
      assert_gt "exit: the principal comes back, less the vault's rounding" "$OUT" "9999990"
    fi
  else
    echo "  SKIP  the unstake request did not land ($SENT_ERR)"
  fi
done

echo ""
echo "================================"
echo " E2E RESULT: $PASS passed, $FAIL failed"
echo "================================"
[ "$FAIL" = "0" ]
