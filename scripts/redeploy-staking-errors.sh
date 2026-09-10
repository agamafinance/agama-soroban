#!/usr/bin/env bash
# Replace the staking contract with the one whose refusals are error codes.
#
# Why
#
# Every other contract here returns a typed error. This one trapped with strings
# from the four entry points a user actually calls: stake, request_unstake,
# claim and distribute_yield. An integrator could see that a stake had failed
# and not why, and could not branch on it. The documentation was honest about
# it, listing the 800 range for the admin calls and "traps: amount must be
# positive" for the rest, which is not the same as it being right.
#
# Why it is cheap
#
# Nothing on-chain names this contract: the Vault does not, the Engine does not,
# neither adapter does. It is a leaf. And it is empty, with no supply, no NAV
# and no stakes recorded, so replacing it strands nobody. Its configuration is
# read off the contract being replaced rather than off a constant, so the
# replacement is the same contract with better refusals.
#
# Usage: bash scripts/redeploy-staking-errors.sh
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
traps() {
  local label=$1 id=$2; shift 2
  local out
  out=$(stellar contract invoke --id "$id" --source "$SRC" --network "$NET" --send=no -- "$@" 2>&1) || true
  if echo "$out" | grep -q "Error(Contract, #8"; then bad "$label: it returned a code"
  else ok "$label"; fi
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
traps "stake with a zero amount traps rather than returning a code" \
  "$OLD" stake --from "$ADMIN" --amount 0
traps "so does an unstake with no supply to price it against" \
  "$OLD" request_unstake --from "$ADMIN" --shares 1
traps "and so does a claim with nothing pending" \
  "$OLD" claim --from "$ADMIN"

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
echo "==> the same four refusals, as codes"
refused 806 "a zero stake is InvalidAmount" "$NEW" stake --from "$ADMIN" --amount 0
refused 808 "an unstake with no supply is NoSupply" "$NEW" request_unstake --from "$ADMIN" --shares 1
refused 809 "a claim with nothing pending is NothingPending" "$NEW" claim --from "$ADMIN"
refused 806 "a zero yield distribution is InvalidAmount" "$NEW" distribute_yield --amount 0

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
        'Replaced by scripts/redeploy-staking-errors.sh. Its four user facing entry points, stake, '
        'request_unstake, claim and distribute_yield, trapped with string panics rather than '
        'returning a typed error, alone among the contracts here. An integrator could see that a '
        'stake had failed and not why, and could not branch on it. The replacement returns codes in '
        'the 800 range for all of them. It was empty at the time, with no supply, no NAV and no '
        'stakes, so it stranded nobody, and nothing on-chain names this contract, so nothing had to '
        'be rewired.'
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
