#!/usr/bin/env bash
# Replace the staking contract with the one that checks agUSD counts stroops
# the way sagUSD does.
#
# Why
#
# The first staker gets shares one for one, raw stroop for raw stroop, and every
# share price after that is measured from there. set_agusd checked that this
# contract had taken no custody and nothing else, so it would accept an agUSD
# with different decimals, and then the exchange rate reported as 1.0 is not one
# to one in value. Nothing downstream can tell, because the internal arithmetic
# stays perfectly consistent in stroops: an integer ratio is only a price while
# both sides agree what the integers mean.
#
# Both are seven today, so this is a guard against a future mis-wiring rather
# than a live defect. The Vault has the same gap on the token it mints, for the
# same reason, and that fix waits for the next Vault generation.
#
# Usage: bash scripts/redeploy-staking-decimals.sh
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
echo "-- The live contract has no DecimalMismatch to return, so there is no"
echo "-- refusal to assert against: the check does not exist in it."
LIVE_ERR=$(stellar contract info interface --id "$OLD" --network "$NET" 2>/dev/null | grep -ci "DecimalMismatch" || true)
if [ "${LIVE_ERR:-0}" = "0" ]; then ok "the live contract does not check decimal alignment"
else bad "the live contract already checks it"; fi

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
echo "==> the replacement checks it"
NEW_ERR=$(stellar contract info interface --id "$NEW" --network "$NET" 2>/dev/null | grep -ci "DecimalMismatch" || true)
if [ "${NEW_ERR:-0}" -gt 0 ]; then ok "the replacement declares DecimalMismatch"
else bad "the replacement does not declare it"; fi
NEW_EVENTS=$(stellar contract info interface --id "$NEW" --network "$NET" 2>/dev/null | grep -ciE "staked|unstake_requested|unstake_claimed|yield_distributed" || true)
if [ "${NEW_EVENTS:-0}" -gt 0 ]; then ok "and still carries the asset side events ($NEW_EVENTS matches)"
else bad "the replacement lost the events"; fi
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
        'Replaced by scripts/redeploy-staking-decimals.sh. Its set_agusd checked that the contract '
        'had taken no custody and nothing else, so it would accept an agUSD counting stroops '
        'differently from the sagUSD it issues. The first staker gets shares one for one, raw '
        'stroop for raw stroop, and every share price after that is measured from there, so a '
        'misaligned token makes the exchange rate reported as 1.0 not one to one in value, with '
        'nothing downstream able to tell because the internal arithmetic stays consistent in '
        'stroops. Both were seven at the time, so this is a guard against a future mis-wiring '
        'rather than a live defect. It was empty, so it stranded nobody, and nothing on-chain names '
        'this contract.'
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
