#!/usr/bin/env bash
# Replace the staking contract with the one that gives a pending unstake a
# horizon and lets anybody push it out.
#
# Why
#
# request_unstake burns the shares and takes the assets out of nav, so the
# Pending record is the whole of what says a departed staker is still owed
# anything. It was written with set and nothing else, which gave it 4095
# ledgers, under six hours. The Vault gives a withdrawal claim ninety days and
# exposes bump_claim so anybody can push that out, because the second
# adversarial review found that an archived claim record takes the calls that
# read it with it. This contract holds the same shape of record and had neither
# half of that fix, and a cooldown makes it worse rather than better: a cooldown
# is a period the staker is told to go away for.
#
# Why it is cheap
#
# Nothing on-chain names this contract: the Vault does not, the Engine does not,
# neither adapter does. It is a leaf. And it is empty, with no supply, no NAV
# and no stakes recorded, so replacing it strands nobody. Its configuration is
# read off the contract being replaced rather than off a constant, so the
# replacement is the same contract with better refusals.
#
# Usage: bash scripts/redeploy-staking-ttl.sh
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
missing "there is no way to postpone a pending unstake's archival" \
  "$OLD" bump_pending --addr "$ADMIN"

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
echo "==> the keeper call exists, and refuses to invent a claim"
refused 809 "bumping an address with nothing pending is NothingPending" \
  "$NEW" bump_pending --addr "$ADMIN"
echo "-- It is permissionless, so what stops it being a nuisance is that there"
echo "-- is nothing to gain: it cannot shorten a TTL, cannot alter what is owed"
echo "-- or to whom, and the caller pays the rent."
refused 806 "the typed refusals from the last generation are still there" \
  "$NEW" stake --from "$ADMIN" --amount 0

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
        'Replaced by scripts/redeploy-staking-ttl.sh. request_unstake wrote the Pending record '
        'with set and nothing else, which gave it 4095 ledgers, under six hours. That record is the '
        'whole of what says a departed staker is still owed anything, because the shares are burned '
        'and the assets are out of nav by then, so its archival leaves the money belonging to '
        'nobody until somebody pays for a RestoreFootprint. The Vault gives a withdrawal claim '
        'ninety days and exposes bump_claim so that anybody can push it out, both added by the '
        'second adversarial review for exactly this failure; this contract had neither. The '
        'replacement writes the record through one helper that extends it to the same ninety days '
        'and adds bump_pending, permissionless for the reason bump_claim is. It was empty at the '
        'time, so it stranded nobody, and nothing on-chain names this contract.'
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
