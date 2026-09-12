#!/usr/bin/env bash
# Replace the Allocation Engine with the one that no longer has book_recovery.
#
# Why it is going away
#
# It was added yesterday for M1 of the third adversarial review, and an
# invariant fuzzer found this morning that it could lower floor_base. The cash
# it books is cash already inside the Vault, and idle_reserves reads the real
# balance, so the base counted that dollar the moment it landed; lowering
# recognised_losses against it afterwards spends the same dollar again. recover
# is immune because cash in an adapter is outside the base until the sweep
# brings it in, so its rise and fall happen in one call and cancel.
#
# Fixing it properly means measuring the base on booked_reserves, which drags
# settle_allocation with it and makes cash nobody deposited undeployable. That
# is a redesign of the reserve floor's basis, which is why it is not taken at
# speed on top of the bug it fixes. So the entry point is removed and M1 is open
# again. (The redesign was taken later: floor_base now measures the base on
# accounted cash, and see docs/ARCHITECTURE.md for what it computes.)
#
# Only the Engine changes. The adapters and the Vault are untouched and follow
# through their own setters, and the pool registry is rebuilt on the
# replacement.
#
# Usage: bash scripts/rewire-drop-book-recovery.sh
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
OLD_PC=$(j "d['poolAdapters']['private-credit']")
OLD_EF=$(j "d['poolAdapters']['etherfuse']")
POOL_CAP=$(j "d['engineConfig']['poolCapBps']")
ORIGINATOR_CAP=$(j "d['engineConfig']['originatorCapBps']")
JURISDICTION_CAP=$(j "d['engineConfig']['jurisdictionCapBps']")
RESERVE_FLOOR=$(j "d['engineConfig']['reserveFloorBps']")
PC_ORIGINATOR=$(j "d['engineConfig']['pools']['private-credit']['originator']")
PC_JURISDICTION=$(j "d['engineConfig']['pools']['private-credit']['jurisdiction']")
EF_ORIGINATOR=$(j "d['engineConfig']['pools']['etherfuse']['originator']")
EF_JURISDICTION=$(j "d['engineConfig']['pools']['etherfuse']['jurisdiction']")

MOVE=500000

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
  else bad "$label: it answered"; fi
}
deploy() {
  local out; out=$(stellar contract deploy --wasm "$1" --source "$SRC" --network "$NET" -- "${@:2}" 2>&1)
  echo "$out" | grep -oE 'Transaction hash is [0-9a-f]{64}' | sed 's/Transaction hash is/      deploy tx/' >&2
  echo "$out" | grep -oE 'C[A-Z2-7]{55}' | tail -1
}

echo "vault (kept)      = $VAULT"
echo "outgoing engine   = $OLD_ENGINE"
echo "outgoing adapters = $OLD_PC / $OLD_EF"

echo ""
echo "==> preconditions"
fail=0
for pair in "vault:$VAULT:deployed_capital" "private-credit:$OLD_PC:get_exposure" "etherfuse:$OLD_EF:get_exposure"; do
  name=${pair%%:*}; rest=${pair#*:}; id=${rest%%:*}; fn=${rest#*:}
  v=$(q0 "$id" "$fn"); if [ "${v:-x}" = "0" ]; then echo "    $name $fn = 0"; else echo "    $name $fn = $v"; fail=1; fi
done
for pair in "private-credit:$OLD_PC" "etherfuse:$OLD_EF"; do
  name=${pair%%:*}; id=${pair#*:}
  v=$(q0 "$USDC" balance --id "$id"); if [ "${v:-x}" = "0" ]; then echo "    $name balance = 0"; else echo "    $name balance = $v"; fail=1; fi
done
START_IDLE=$(q0 "$VAULT" idle_reserves)
echo "    vault idle reserves = $START_IDLE"
[ "$fail" = 0 ] || { echo "refusing to start"; exit 1; }

echo ""
echo "=============================================================="
echo "PART 1  the call that is going away, on the Engine that has it"
echo "=============================================================="
echo "-- The live Engine answers book_recovery. That is the call an invariant"
echo "-- fuzzer showed can lower floor_base, by booking cash the base counted"
echo "-- the moment it arrived."
BR=$(stellar contract invoke --id "$OLD_ENGINE" --source "$SRC" --network "$NET" --send=no -- book_recovery --admin "$ADMIN" --pool_id "$OLD_PC" --amount 1 2>&1) || true
if echo "$BR" | grep -qi "unrecognized subcommand"; then bad "the live Engine does not have book_recovery"
else ok "the live Engine has book_recovery in its interface"; fi

echo ""
echo "==> building"
stellar contract build >/dev/null

echo ""
echo "==> the adapters and the Vault stay where they are"
echo "-- Nothing about them changed, so they come across through their own"
echo "-- setters rather than being redeployed."
PC="$OLD_PC"
EF="$OLD_EF"
assert_eq "private credit still publishes this Vault's token" "$(q0 "$PC" usdc)" "$USDC"
assert_eq "and so does etherfuse" "$(q0 "$EF" usdc)" "$USDC"

echo ""
echo "==> the replacement Engine"
ENGINE=$(deploy "$WASM/allocation_engine.wasm" --admin "$ADMIN" --vault "$VAULT")
echo "    allocation-engine = $ENGINE"

echo ""
echo "==> repointing, adapters across before the registry"
echo "    vault.set_engine       tx $(tx "$VAULT" set_engine --admin "$ADMIN" --allocation_engine "$ENGINE")"
echo "    pc.set_counterparties  tx $(tx "$PC" set_counterparties --admin "$ADMIN" --engine "$ENGINE" --vault "$VAULT")"
echo "    ef.set_counterparties  tx $(tx "$EF" set_counterparties --admin "$ADMIN" --engine "$ENGINE" --vault "$VAULT")"
echo "    set_caps               tx $(tx "$ENGINE" set_caps --admin "$ADMIN" --pool_cap_bps "$POOL_CAP" \
  --originator_cap_bps "$ORIGINATOR_CAP" --jurisdiction_cap_bps "$JURISDICTION_CAP")"
echo "    set_reserve_floor      tx $(tx "$ENGINE" set_reserve_floor --admin "$ADMIN" --floor_bps "$RESERVE_FLOOR")"

echo ""
echo "-- The registry is rebuilt on the replacement, with the same two pools."
echo "    register pc            tx $(tx "$ENGINE" register_pool --admin "$ADMIN" --pool_id "$PC" \
  --originator "$PC_ORIGINATOR" --jurisdiction "$PC_JURISDICTION" --cap_bps "$POOL_CAP")"
echo "    register ef            tx $(tx "$ENGINE" register_pool --admin "$ADMIN" --pool_id "$EF" \
  --originator "$EF_ORIGINATOR" --jurisdiction "$EF_JURISDICTION" --cap_bps "$POOL_CAP")"

echo ""
echo "=============================================================="
echo "PART 2  the repaired wiring moves capital and brings it home"
echo "=============================================================="
echo "    allocate            tx $(tx "$ENGINE" allocate --admin "$ADMIN" --pool_id "$PC" --amount "$MOVE")"
assert_eq "the adapter holds it" "$(q0 "$USDC" balance --id "$PC")" "$MOVE"
echo "    deallocate          tx $(tx "$ENGINE" deallocate --pool_id "$PC" --amount "$MOVE")"
assert_eq "and it comes home" "$(q0 "$USDC" balance --id "$PC")" "0"
assert_eq "with the book flat" "$(q0 "$ENGINE" total_allocated)" "0"

echo ""
echo "==> the wiring, every edge in both directions"
echo "    vault.allocation_engine()   = $(q "$VAULT" allocation_engine)"
echo "    vault.usdc()                = $(q "$VAULT" usdc)"
echo "    engine.vault()              = $(q "$ENGINE" vault)"
echo "    pc.engine() / vault() / usdc() = $(q "$PC" engine) $(q "$PC" vault) $(q "$PC" usdc)"
echo "    ef.engine() / vault() / usdc() = $(q "$EF" engine) $(q "$EF" vault) $(q "$EF" usdc)"

echo ""
echo "==> the deployment is back where it started"
assert_eq "vault idle reserves" "$(q0 "$VAULT" idle_reserves)" "$START_IDLE"
assert_eq "vault deployed capital" "$(q0 "$VAULT" deployed_capital)" "0"
assert_eq "vault recognised losses" "$(q0 "$VAULT" recognised_losses)" "0"

echo ""
echo "==> writing $DEP"
python3 - "$DEP" "$ENGINE" "$OLD_ENGINE" "$PC" "$OLD_PC" "$EF" "$OLD_EF" <<'PY'
import json, sys
path, engine, old_engine, pc, old_pc, ef, old_ef = sys.argv[1:]
dep = json.load(open(path))
history = dep.get('superseded', [])
ORD = ['first','second','third','fourth','fifth','sixth','seventh','eighth','ninth','tenth',
       'eleventh','twelfth','thirteenth','fourteenth','fifteenth']
REASON = (
    'Replaced by scripts/rewire-drop-book-recovery.sh, which removes book_recovery. That entry '
    'point was added a day earlier for M1 of the third adversarial review, and an invariant fuzzer '
    'found it could lower floor_base. The cash it books is cash already inside the Vault, and '
    'idle_reserves reads the real token balance, so the base counted that dollar the moment it '
    'landed; lowering recognised_losses against it afterwards spends the same dollar again. recover '
    'is immune because cash sitting in an adapter is outside the base until the sweep brings it in, '
    'so its rise and its fall happen in one call and cancel. Fixing it properly means measuring the '
    'base on booked_reserves, which drags settle_allocation with it and makes cash nobody deposited '
    'undeployable, a redesign of the reserve floor basis rather than something to take on top of '
    'the bug it fixes. M1 is open again. The redesign was taken later and floor_base now measures '
    'the base on accounted cash.'
)
def retire(contract, address, label_base):
    gen = 1 + sum(1 for e in history if e['contract'] == contract)
    history.append({
        'contract': contract, 'generation': gen,
        'label': '%s, %s deployment' % (label_base, ORD[gen - 1]),
        'address': address, 'supersededBy': contract, 'reason': REASON,
    })
retire('allocationEngine', old_engine, 'Allocation Engine')
dep['contracts']['allocationEngine'] = engine
dep['superseded'] = history
dep['adapterTokenEdge'] = (
    'An adapter is bound to its asset for life. The token is a constructor argument, it is checked '
    "at construction against the token the Vault it names custodies, and set_counterparties never "
    'takes it as a parameter, so a repointing has to land on a Vault holding the same asset. That '
    'is what makes the asset something the other two checks can rely on rather than another thing '
    'that can drift. The Engine re-runs the comparison on every call that moves capital, for the '
    'reason it re-runs the Vault edge: set_vault can point the Engine at a Vault custodying a '
    'different asset, and every adapter already registered then names a token that Vault does not '
    'hold. The way out of that one is a new adapter rather than a repointing, which is the cost of '
    'the token being immutable and is the right side to err on.'
)
json.dump(dep, open(path, 'w'), indent=2); open(path, 'a').write('\n')
print(json.dumps({'engine': engine, 'private-credit': pc, 'etherfuse': ef}, indent=2))
PY

echo ""
echo "  $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
