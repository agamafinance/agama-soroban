#!/usr/bin/env bash
# Redeploy staking so it accepts the current agUSD, because its setter cannot.
#
# Why the setter cannot
#
# set_agusd refuses once `stakes > 0`, and `stakes` is a cumulative count of
# every stake this contract has ever taken. It never decrements. So the pointer
# freezes permanently at the first stake, even on a contract that is now
# completely empty: supply zero, NAV zero, not a stroop of agUSD held.
#
# That looks over-strict and it is not. A pending unstake survives with supply
# and NAV both at zero, because request_unstake burns the shares and takes the
# assets out of NAV at request time and the agUSD only leaves at the claim. The
# record is denominated in assets, so repointing the token underneath it would
# pay a claim in a token it was never priced against. The contract cannot
# enumerate its own pending records to check for that, so a cumulative counter
# is the conservative proxy, and being conservative about somebody else's claim
# is the right direction.
#
# The cost is what this script is: every change to agUSD forces a staking
# redeployment for the life of the protocol. Worth knowing before an agUSD
# generation is planned rather than discovered halfway through one, which is how
# it was found.
#
# It is cheap here. Nothing on-chain names this contract, so nothing is rewired,
# and it is empty, so it strands nobody. The configuration is read off the
# contract being replaced, except the agUSD, which is read off the deployment
# record.
#
# Usage: bash scripts/redeploy-staking-follow-agusd.sh
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
AGUSD=$(j "d['contracts']['agusdCore']")
OLD_AGUSD=$(q0 "$OLD" agusd)
COOLDOWN=$(q0 "$OLD" cooldown)
DECIMALS=$(q0 "$OLD" decimals)
NAME=$(q0 "$OLD" name)
SYMBOL=$(q0 "$OLD" symbol)
echo "  agusd    = $AGUSD (the contract being replaced accepts $OLD_AGUSD)"
echo "  cooldown = $COOLDOWN"
echo "  name     = $NAME ($SYMBOL, $DECIMALS dp)"

echo ""
echo "==> preconditions: it has to be empty, or replacing it strands somebody"
fail=0
# Not `stakes`. A non-zero cumulative stake count is the reason this script is
# needed, not a reason to refuse it, and the inherited check had it as a
# precondition, which made it self-defeating.
#
# What actually decides whether replacing this contract strands anybody is
# whether anything is still owed. Supply zero means every share has been
# redeemed. NAV zero means nothing is priced into a share. And the agUSD balance
# being zero is the one that covers pending unstakes, which survive with the
# other two at zero and hold real agUSD against a claim until it is collected.
for fn in total_supply nav; do
  v=$(q0 "$OLD" "$fn")
  if [ "${v:-x}" = "0" ]; then echo "    $fn = 0"; else echo "    $fn = $v, and it has to be 0"; fail=1; fi
done
HELD_OLD=$(q0 "$OLD_AGUSD" balance --id "$OLD")
if [ "${HELD_OLD:-x}" = "0" ]; then echo "    agUSD held = 0, so no pending unstake is waiting on it"
else echo "    agUSD held = $HELD_OLD, which is somebody's pending unstake"; fail=1; fi
echo "    cumulative stakes taken = $(q0 "$OLD" stakes), which is why the setter is frozen"
[ "$fail" = 0 ] || { echo "refusing to start"; exit 1; }

echo ""
echo "==> the gap, on the contract that is live right now"
echo "-- The live contract is empty and its pointer is still frozen, which is"
echo "-- the whole reason this script exists."
assert_eq "it holds nothing" "$(q0 "$OLD" total_supply)" "0"
assert_eq "and its NAV is zero" "$(q0 "$OLD" nav)" "0"
echo "    cumulative stakes taken: $(q0 "$OLD" stakes)"
refused 803 "and set_agusd is refused anyway, with CustodyTaken" \
  "$OLD" set_agusd --admin "$ADMIN" --agusd "$AGUSD"

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
echo "==> the replacement accepts the current agUSD"
assert_eq "it accepts the current agUSD" "$(q0 "$NEW" agusd)" "$AGUSD"
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
        'Replaced by scripts/redeploy-staking-follow-agusd.sh, so that staking accepts the agUSD '
        'generation deployed alongside the reserve floor change. Its own set_agusd could not do it: '
        'the setter refuses once stakes > 0, and stakes is a cumulative count of every stake ever '
        'taken which never decrements, so the pointer freezes permanently at the first one even on a '
        'contract that is completely empty. That is conservative rather than over-strict, because a '
        'pending unstake survives with supply and NAV both at zero and is denominated in assets, so '
        'repointing the token underneath it would pay a claim in a token it was never priced '
        'against, and the contract cannot enumerate its own pending records to check. The cost is '
        'that every agUSD generation forces a staking redeployment for the life of the protocol. It '
        'was empty here, so it stranded nobody, and nothing on-chain names this contract.'
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
