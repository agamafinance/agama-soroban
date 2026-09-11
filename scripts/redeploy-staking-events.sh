#!/usr/bin/env bash
# Replace the staking contract with the one whose asset side is in the event
# stream.
#
# Why
#
# Tranche 1 of the grant funds an indexer exposing NAV and share price history.
# The share price is nav / supply. Supply was already in the stream, through the
# SEP-41 mint and burn events the token layer emits. nav was not in it at all,
# and neither was any of the four calls that move it: stake, request_unstake,
# claim and distribute_yield emitted nothing. The contract's only events were
# administrative.
#
# So the history could not be built from events. It could only be sampled by
# polling exchange_rate(), which has no past, and a number that moves with
# nothing in the log to explain it is what an indexer cannot reconcile.
#
# The four events carry nav and supply as they stand after the call, so every
# price in the history is a fact from the ledger rather than a sample somebody
# happened to take.
#
# Usage: bash scripts/redeploy-staking-events.sh
set -euo pipefail
cd "$(dirname "$0")/.."

NET=testnet
SRC=agama-poc
WASM=target/wasm32v1-none/release
DEP=deployments/testnet.json

j() { python3 -c "import json;d=json.load(open('$DEP'));print($1)"; }
ADMIN=$(stellar keys address "$SRC")
OLD=$(j "d['contracts']['staking']")

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  PASS  $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL  $1"; }
num() { echo "$1" | tr -d '"'; }
assert_eq() { if [ "$(num "$2")" = "$(num "$3")" ]; then ok "$1 ($(num "$2"))"; else bad "$1: got $(num "$2"), want $(num "$3")"; fi; }

q()  { stellar contract invoke --id "$1" --source "$SRC" --network "$NET" --send=no -- "${@:2}" 2>/dev/null; }
q0() { q "$@" | tr -d '"'; }
refused() {
  local want=$1 label=$2 id=$3; shift 3
  local out
  out=$(stellar contract invoke --id "$id" --source "$SRC" --network "$NET" --send=no -- "$@" 2>&1) || true
  if echo "$out" | grep -q "Error(Contract, #$want)"; then ok "$label (contract error $want)"
  else bad "$label: expected contract error $want, got: $(echo "$out" | head -2 | tr '\n' ' ')"; fi
}
missing() {
  local label=$1 id=$2; shift 2
  local out
  out=$(stellar contract invoke --id "$id" --source "$SRC" --network "$NET" --send=no -- "$@" 2>&1) || true
  if echo "$out" | grep -qi "unrecognized subcommand"; then ok "$label"
  else bad "$label: it answered"; fi
}

echo "outgoing staking = $OLD"
AGUSD=$(q0 "$OLD" agusd)
COOLDOWN=$(q0 "$OLD" cooldown)
DECIMALS=$(q0 "$OLD" decimals)
NAME=$(q0 "$OLD" name)
SYMBOL=$(q0 "$OLD" symbol)
echo "  agusd    = $AGUSD"
echo "  cooldown = $COOLDOWN"
echo "  name     = $NAME ($SYMBOL, $DECIMALS dp)"

echo ""
echo "==> preconditions: it has to be empty, or replacing it strands somebody"
fail=0
for fn in total_supply nav stakes; do
  v=$(q0 "$OLD" "$fn")
  if [ "${v:-x}" = "0" ]; then echo "    $fn = 0"; else echo "    $fn = $v, and it has to be 0"; fail=1; fi
done
[ "$fail" = 0 ] || { echo "refusing to start"; exit 1; }

echo ""
echo "==> the gap, on the contract that is live right now"
echo "-- The live contract emits three events and all three are administrative."
echo "-- Nothing says a stake happened, nothing says yield was distributed, and"
echo "-- nothing carries nav at all."
STAKE_EVENTS=$(stellar contract info interface --id "$OLD" --network "$NET" 2>/dev/null | grep -ciE "^event |struct Staked|struct YieldDistributed" || true)
if [ "${STAKE_EVENTS:-0}" = "0" ]; then ok "the live contract has no event for a stake or a yield distribution"
else bad "the live contract already emits them"; fi

echo ""
echo "==> building"
stellar contract build >/dev/null

echo ""
echo "==> deploying the replacement with the configuration read off the old one"
OUT=$(stellar contract deploy --wasm "$WASM/staking.wasm" --source "$SRC" --network "$NET" \
  -- --admin "$ADMIN" --agusd "$AGUSD" --cooldown_seconds "$COOLDOWN" --decimal "$DECIMALS" \
     --name "$NAME" --symbol "$SYMBOL" 2>&1)
echo "$OUT" | grep -oE 'Using wasm hash [0-9a-f]{64}' | sed 's/^/    /'
echo "$OUT" | grep -oE 'Transaction hash is [0-9a-f]{64}' | sed 's/Transaction hash is/    deploy tx/'
NEW=$(echo "$OUT" | grep -oE 'C[A-Z2-7]{55}' | tail -1)
echo "    staking = $NEW"

echo ""
echo "==> the replacement carries the four"
NEW_EVENTS=$(stellar contract info interface --id "$NEW" --network "$NET" 2>/dev/null | grep -ciE "staked|unstake_requested|unstake_claimed|yield_distributed" || true)
if [ "${NEW_EVENTS:-0}" -gt 0 ]; then ok "the replacement declares the asset side events ($NEW_EVENTS matches)"
else bad "the replacement does not declare them"; fi
refused 806 "and the typed refusals from the last generations are still there" \
  "$NEW" stake --from "$ADMIN" --amount 0
refused 809 "including the keeper call's" "$NEW" bump_pending --addr "$ADMIN"

echo ""
echo "==> and it is the same contract otherwise"
assert_eq "agusd"    "$(q0 "$NEW" agusd)"    "$AGUSD"
assert_eq "cooldown" "$(q0 "$NEW" cooldown)" "$COOLDOWN"
assert_eq "symbol"   "$(q0 "$NEW" symbol)"   "$SYMBOL"
assert_eq "supply"   "$(q0 "$NEW" total_supply)" "0"
assert_eq "exchange rate starts at one" "$(q0 "$NEW" exchange_rate)" "10000000"

echo ""
echo "==> writing $DEP"
python3 - "$DEP" "$NEW" "$OLD" <<'PY'
import json, sys
path, new, old = sys.argv[1:]
dep = json.load(open(path))
history = dep.get('superseded', [])
ORD = ['first','second','third','fourth','fifth','sixth','seventh','eighth','ninth','tenth',
       'eleventh','twelfth','thirteenth','fourteenth','fifteenth']
gen = 1 + sum(1 for e in history if e['contract'] == 'staking')
history.append({
    'contract': 'staking', 'generation': gen,
    'label': 'sagUSD staking, %s deployment' % ORD[gen - 1],
    'address': old, 'supersededBy': 'staking',
    'reason': (
        'Replaced by scripts/redeploy-staking-events.sh. Its four asset moving entry points, '
        'stake, request_unstake, claim and distribute_yield, emitted nothing, so the only events '
        'this contract produced were administrative. Share supply was visible through the SEP-41 '
        'mint and burn events the token layer emits, and nav was not visible at all, which means '
        'the share price history the grant funds an indexer to expose could not be built from the '
        'event stream: it could only be sampled by polling exchange_rate(), which has no past. The '
        'replacement emits all four, carrying nav and supply as they stand after the call so that '
        'every price in the history is a fact from the ledger. It was empty at the time, so it '
        'stranded nobody, and nothing on-chain names this contract.'
    ),
})
dep['contracts']['staking'] = new
dep['superseded'] = history
json.dump(dep, open(path, 'w'), indent=2); open(path, 'a').write('\n')
print(json.dumps({'staking': new}, indent=2))
PY

echo ""
echo "  $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
