#!/usr/bin/env bash
# Replace the Allocation Engine with the one that has the two pool registry
# levers, and prove both against the Engine it replaces.
#
# What M2 was
#
# A pool's effective limit is the tighter of its own cap_bps and the global
# caps().pool_bps, and only the second could ever move: there was no
# update_pool. There was no unregister_pool either, so the registry was a map
# with no way to remove an entry, and the aggregate caps are built by walking
# it. A defaulted pool consumed its originator's and its jurisdiction's limits
# with no lever over either.
#
# The rule itself is not the finding. Charging a write-off against the pool's
# cap is a deliberate decision from the second review, and it is what stops a
# defaulted originator getting its limit back by defaulting. What was missing
# was any way to act on it, so this adds levers and keeps the rule:
#
#   set_pool_cap(pool, 0)   freezes a pool without releasing a stroop of its
#                           charge, which is the delisting that works in default
#   unregister_pool(pool)   removes an entry, and refuses one that still has
#                           exposure on either book or a write-off charged
#
# The deployment ends where it started.
#
# Usage: bash scripts/rewire-engine-m2.sh
set -euo pipefail
cd "$(dirname "$0")/.."

NET=testnet
SRC=agama-poc
WASM=target/wasm32v1-none/release
DEP=deployments/testnet.json

j() { python3 -c "import json;d=json.load(open('$DEP'));print($1)"; }
ADMIN=$(stellar keys address "$SRC")
USDC=$(j "d['contracts']['usdc']")
VAULT=$(j "d['contracts']['vault']")
OLD_ENGINE=$(j "d['contracts']['allocationEngine']")
PC=$(j "d['poolAdapters']['private-credit']")
EF=$(j "d['poolAdapters']['etherfuse']")
POOL_CAP=$(j "d['engineConfig']['poolCapBps']")
ORIGINATOR_CAP=$(j "d['engineConfig']['originatorCapBps']")
JURISDICTION_CAP=$(j "d['engineConfig']['jurisdictionCapBps']")
RESERVE_FLOOR=$(j "d['engineConfig']['reserveFloorBps']")
PC_ORIGINATOR=$(j "d['engineConfig']['pools']['private-credit']['originator']")
PC_JURISDICTION=$(j "d['engineConfig']['pools']['private-credit']['jurisdiction']")
EF_ORIGINATOR=$(j "d['engineConfig']['pools']['etherfuse']['originator']")
EF_JURISDICTION=$(j "d['engineConfig']['pools']['etherfuse']['jurisdiction']")

MOVE=500000   # 0.05 USDC, inside every cap and the floor with room to spare

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  PASS  $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL  $1"; }
num() { echo "$1" | tr -d '"'; }
assert_eq() { if [ "$(num "$2")" = "$(num "$3")" ]; then ok "$1 ($(num "$2"))"; else bad "$1: got $(num "$2"), want $(num "$3")"; fi; }

q()  { stellar contract invoke --id "$1" --source "$SRC" --network "$NET" --send=no -- "${@:2}" 2>/dev/null; }
q0() { q "$@" | tr -d '"'; }
tx() { stellar contract invoke --id "$1" --source "$SRC" --network "$NET" -- "${@:2}" 2>&1 \
         | grep -oE '[0-9a-f]{64}' | head -1; }
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
  else bad "$label: the outgoing Engine answered it"; fi
}

echo "vault (kept)        = $VAULT"
echo "outgoing engine     = $OLD_ENGINE"

echo ""
echo "==> preconditions"
fail=0
for pair in "vault:$VAULT:deployed_capital" "private-credit:$PC:get_exposure" "etherfuse:$EF:get_exposure"; do
  name=${pair%%:*}; rest=${pair#*:}; id=${rest%%:*}; fn=${rest#*:}
  v=$(q0 "$id" "$fn")
  if [ "${v:-x}" = "0" ]; then echo "    $name $fn = 0"; else echo "    $name $fn = $v, and it has to be 0"; fail=1; fi
done
START_IDLE=$(q0 "$VAULT" idle_reserves)
echo "    vault idle reserves = $START_IDLE"
[ "$fail" = 0 ] || { echo "refusing to start"; exit 1; }

echo ""
echo "=============================================================="
echo "PART 1  the finding, on the Engine that is live right now"
echo "=============================================================="
echo "-- Neither lever exists. The CLI builds its subcommands from the"
echo "-- contract spec, so a call that is not in the deployed interface is"
echo "-- not a refusal to assert an error code against: it is a name the"
echo "-- contract does not have."
missing "set_pool_cap is not in the deployed interface" \
  "$OLD_ENGINE" set_pool_cap --admin "$ADMIN" --pool_id "$PC" --cap_bps 0
missing "unregister_pool is not in the deployed interface" \
  "$OLD_ENGINE" unregister_pool --admin "$ADMIN" --pool_id "$PC"
assert_eq "so a registered pool's cap is whatever it was registered at" \
  "$(q "$OLD_ENGINE" get_pool --pool_id "$PC" | python3 -c 'import json,sys;print(json.load(sys.stdin)["cap_bps"])')" "$POOL_CAP"

echo ""
echo "==> building the replacement"
stellar contract build >/dev/null

echo ""
echo "==> deploying it, wired to the Vault in its own constructor"
OUT=$(stellar contract deploy --wasm "$WASM/allocation_engine.wasm" --source "$SRC" --network "$NET" \
  -- --admin "$ADMIN" --vault "$VAULT" 2>&1)
echo "$OUT" | grep -oE 'Using wasm hash [0-9a-f]{64}' | sed 's/^/    /'
echo "$OUT" | grep -oE 'Transaction hash is [0-9a-f]{64}' | sed 's/Transaction hash is/    deploy tx/'
ENGINE=$(echo "$OUT" | grep -oE 'C[A-Z2-7]{55}' | tail -1)
echo "    allocation-engine = $ENGINE"

echo ""
echo "==> repointing, adapters before the registry"
echo "    vault.set_engine       tx $(tx "$VAULT" set_engine --admin "$ADMIN" --allocation_engine "$ENGINE")"
echo "    pc.set_counterparties  tx $(tx "$PC" set_counterparties --admin "$ADMIN" --engine "$ENGINE" --vault "$VAULT")"
echo "    ef.set_counterparties  tx $(tx "$EF" set_counterparties --admin "$ADMIN" --engine "$ENGINE" --vault "$VAULT")"
echo "    set_caps               tx $(tx "$ENGINE" set_caps --admin "$ADMIN" --pool_cap_bps "$POOL_CAP" \
  --originator_cap_bps "$ORIGINATOR_CAP" --jurisdiction_cap_bps "$JURISDICTION_CAP")"
echo "    set_reserve_floor      tx $(tx "$ENGINE" set_reserve_floor --admin "$ADMIN" --floor_bps "$RESERVE_FLOOR")"
echo "    register pc            tx $(tx "$ENGINE" register_pool --admin "$ADMIN" --pool_id "$PC" \
  --originator "$PC_ORIGINATOR" --jurisdiction "$PC_JURISDICTION" --cap_bps "$POOL_CAP")"
echo "    register ef            tx $(tx "$ENGINE" register_pool --admin "$ADMIN" --pool_id "$EF" \
  --originator "$EF_ORIGINATOR" --jurisdiction "$EF_JURISDICTION" --cap_bps "$POOL_CAP")"

echo ""
echo "=============================================================="
echo "PART 2  the freeze, which is the lever a defaulted pool gets"
echo "=============================================================="
echo "    allocate            tx $(tx "$ENGINE" allocate --admin "$ADMIN" --pool_id "$PC" --amount "$MOVE")"
echo "    set_pool_cap to 0   tx $(tx "$ENGINE" set_pool_cap --admin "$ADMIN" --pool_id "$PC" --cap_bps 0)"
refused 407 "no further capital reaches a pool capped at zero" \
  "$ENGINE" allocate --admin "$ADMIN" --pool_id "$PC" --amount 1
assert_eq "and what it already holds is untouched" "$(q0 "$ENGINE" get_exposure --pool_id "$PC")" "$MOVE"
echo "-- Frozen, not stranded: the capital still comes home."
echo "    deallocate          tx $(tx "$ENGINE" deallocate --pool_id "$PC" --amount "$MOVE")"
assert_eq "the position is unwound" "$(q0 "$ENGINE" get_exposure --pool_id "$PC")" "0"
echo "    set_pool_cap back   tx $(tx "$ENGINE" set_pool_cap --admin "$ADMIN" --pool_id "$PC" --cap_bps "$POOL_CAP")"

echo ""
echo "=============================================================="
echo "PART 3  delisting, and the one thing it will not do"
echo "=============================================================="
echo "    allocate            tx $(tx "$ENGINE" allocate --admin "$ADMIN" --pool_id "$PC" --amount "$MOVE")"
refused 420 "a pool holding capital does not leave the registry" \
  "$ENGINE" unregister_pool --admin "$ADMIN" --pool_id "$PC"

echo "    write_down          tx $(tx "$ENGINE" write_down --admin "$ADMIN" --pool_id "$PC" --amount "$MOVE" --reason DEFAULT)"
assert_eq "live exposure is now zero on the Engine" "$(q0 "$ENGINE" get_exposure --pool_id "$PC")" "0"
assert_eq "and on the adapter" "$(q0 "$PC" get_exposure)" "0"
echo "-- Everything the first condition asks for is satisfied, and it still"
echo "-- refuses, because the aggregate caps are built by walking this"
echo "-- registry: an entry leaving takes its write-off charge with it, and a"
echo "-- defaulted originator would get its limit back by defaulting."
refused 421 "a defaulted pool cannot delist its way out of the charge" \
  "$ENGINE" unregister_pool --admin "$ADMIN" --pool_id "$PC"
assert_eq "the charge stands" "$(q0 "$ENGINE" written_off_pool --pool_id "$PC")" "$MOVE"

echo ""
echo "-- It becomes delistable when the loss is recovered rather than when it"
echo "-- is forgotten."
echo "    recover             tx $(tx "$ENGINE" recover --admin "$ADMIN" --pool_id "$PC")"
assert_eq "the charge is released" "$(q0 "$ENGINE" written_off_pool --pool_id "$PC")" "0"
echo "    unregister_pool     tx $(tx "$ENGINE" unregister_pool --admin "$ADMIN" --pool_id "$PC")"
refused 404 "the entry is gone" \
  "$ENGINE" allocate --admin "$ADMIN" --pool_id "$PC" --amount 1

echo ""
echo "-- And a pool registered again starts from nothing rather than from what"
echo "-- its old entries happened to hold."
echo "    register pc again   tx $(tx "$ENGINE" register_pool --admin "$ADMIN" --pool_id "$PC" \
  --originator "$PC_ORIGINATOR" --jurisdiction "$PC_JURISDICTION" --cap_bps "$POOL_CAP")"
assert_eq "exposure starts at zero" "$(q0 "$ENGINE" get_exposure --pool_id "$PC")" "0"
assert_eq "and so does the charge" "$(q0 "$ENGINE" written_off_pool --pool_id "$PC")" "0"

echo ""
echo "==> the wiring"
echo "    vault.allocation_engine()   = $(q "$VAULT" allocation_engine)"
echo "    engine.vault()              = $(q "$ENGINE" vault)"
echo "    engine.admin_aligned()      = $(q "$ENGINE" admin_aligned)"
echo "    engine.pools()              = $(q "$ENGINE" pools)"

echo ""
echo "==> the deployment is back where it started"
assert_eq "vault idle reserves" "$(q0 "$VAULT" idle_reserves)" "$START_IDLE"
assert_eq "vault deployed capital" "$(q0 "$VAULT" deployed_capital)" "0"
assert_eq "vault recognised losses" "$(q0 "$VAULT" recognised_losses)" "0"
assert_eq "engine total allocated" "$(q0 "$ENGINE" total_allocated)" "0"
assert_eq "private credit balance" "$(q0 "$USDC" balance --id "$PC")" "0"
assert_eq "etherfuse balance" "$(q0 "$USDC" balance --id "$EF")" "0"

echo ""
echo "==> writing $DEP"
python3 - "$DEP" "$ENGINE" "$OLD_ENGINE" <<'PY'
import json, sys
path, engine, old_engine = sys.argv[1:]
dep = json.load(open(path))
history = dep.get('superseded', [])
ORDINALS = ['first', 'second', 'third', 'fourth', 'fifth', 'sixth', 'seventh', 'eighth',
            'ninth', 'tenth', 'eleventh', 'twelfth', 'thirteenth', 'fourteenth']
generation = 1 + sum(1 for e in history if e['contract'] == 'allocationEngine')
history.append({
    'contract': 'allocationEngine',
    'generation': generation,
    'label': 'Allocation Engine, %s deployment' % ORDINALS[generation - 1],
    'address': old_engine,
    'supersededBy': 'allocationEngine',
    'reason': (
        'Replaced by scripts/rewire-engine-m2.sh, for M2 of the third '
        'adversarial review. It has no set_pool_cap and no unregister_pool, so '
        "a registered pool's own cap could never move and the registry was a "
        'map with no way to remove an entry. A pool whose own figure was the '
        'binding one was capped at it for the life of the contract, and because '
        'the aggregate caps are built by walking the registry, a defaulted pool '
        "consumed its originator's and its jurisdiction's limits with no lever "
        'over either. The charging rule is not the finding and did not change: '
        'the replacement adds set_pool_cap, whose useful direction is down, '
        'since a cap of zero freezes a pool without releasing a stroop of its '
        'charge, and unregister_pool, which refuses any pool that still has '
        'exposure on either book or a write-off charged against it, so a pool '
        'in default is freezable but not delistable and becomes delistable when '
        'the loss is recovered rather than when it is forgotten. Nothing else '
        'was redeployed.'
    ),
})
dep['contracts']['allocationEngine'] = engine
dep['superseded'] = history
dep['poolRegistryLevers'] = (
    "set_pool_cap moves a registered pool's own cap, which is the tighter half "
    'of its effective limit wherever it binds. Lowering it below what the pool '
    'already holds is allowed: caps are checked when capital is deployed, so an '
    'over-cap pool simply receives nothing more, and a cap of zero is a freeze '
    'that touches neither the position nor the charge. unregister_pool removes '
    "an entry, and refuses one whose Engine exposure or adapter exposure is "
    'non-zero, or which still carries a write-off charge. That last condition '
    'is what makes delisting safe rather than convenient: the originator and '
    'jurisdiction sums are built by walking the registry, so an entry leaving '
    'takes its charge out of them, and a defaulted pool could otherwise be '
    'delisted and replaced under the same originator with its whole limit back. '
    'It runs no counterparty check, deliberately, because the entry most worth '
    'removing is the one whose adapter no longer names this Vault. What it '
    'cannot see is USDC sitting in an adapter that no book knows about, so the '
    'order is sweep with recover, which attributes the recovery to the pool the '
    'cash came from, and delist after.'
)
json.dump(dep, open(path, 'w'), indent=2)
open(path, 'a').write('\n')
print(json.dumps(dep['contracts'], indent=2))
PY

echo ""
echo "  $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
