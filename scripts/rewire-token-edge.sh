#!/usr/bin/env bash
# Close the third edge of the wiring triangle: the token.
#
# The finding
#
# `register_pool` proves an adapter names this Engine and this Engine's Vault.
# `set_counterparties` proves from the other side that the Engine it is given
# governs the Vault it is given. Both are about which contracts are wired
# together. Neither was about the asset, and an adapter stores one: a
# constructor argument, never validated against the Vault's, and the address
# every transfer in the adapter actually uses.
#
# An adapter with the right pointers and the wrong token is a one way door.
# settle_allocation sends what the Vault holds, so real USDC arrives.
# deallocate sends back the token the adapter stores, of which it holds none,
# and traps. recover_surplus measures its surplus in that same token and reports
# nothing to recover. A write-down clears all three books and the money stays
# exactly where it is. That is the failure that retired three generations of the
# private credit adapter, reachable through a constructor argument nothing
# interrogated.
#
# Both sides now check it. The adapter refuses at construction, which is earlier
# than the registry door and the right place: an adapter that can never repay
# the Vault it names should not reach the ledger. The Engine re-runs it on every
# call that moves capital, for the reason it re-runs the Vault edge, because
# set_vault can point the Engine at a Vault custodying a different asset.
#
# Why the adapters move too
#
# The Engine asks an adapter which token it holds and the deployed adapters have
# no such view, so they cannot answer and the replacement Engine would refuse
# them. Both are empty, so nothing is stranded by replacing them.
#
# Order. The adapters interrogate the Engine in their own constructors, so they
# are built against the Engine that is live now, which does govern the Vault.
# Then the replacement Engine, then the Vault repointed, then the adapters
# brought across, then registered.
#
# Usage: bash scripts/rewire-token-edge.sh
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
echo "PART 1  the gap, on the contracts that are live right now"
echo "=============================================================="
echo "-- The Vault has always published the token it custodies. What no"
echo "-- deployed adapter publishes is the token it transfers with, so there"
echo "-- is nothing for the Engine to compare against and no comparison to"
echo "-- make."
assert_eq "the Vault says which token it holds" "$(q0 "$VAULT" usdc)" "$USDC"
missing "the live private credit adapter cannot be asked which token it holds" "$OLD_PC" usdc
missing "nor can the live etherfuse adapter" "$OLD_EF" usdc

echo ""
echo "==> building"
stellar contract build >/dev/null

echo ""
echo "==> the replacement adapters, built against the Engine that is live"
echo "-- Their constructors interrogate the Engine, so they need one that"
echo "-- already governs this Vault, and that is the outgoing one."
PC=$(deploy "$WASM/private_credit.wasm" --admin "$ADMIN" --engine "$OLD_ENGINE" --vault "$VAULT" --usdc "$USDC")
echo "    private-credit = $PC"
EF=$(deploy "$WASM/etherfuse.wasm" --admin "$ADMIN" --engine "$OLD_ENGINE" --vault "$VAULT" --usdc "$USDC")
echo "    etherfuse      = $EF"
assert_eq "the new private credit adapter publishes its token" "$(q0 "$PC" usdc)" "$USDC"
assert_eq "and the new etherfuse adapter does too" "$(q0 "$EF" usdc)" "$USDC"

echo ""
echo "-- And an adapter pointed at an asset this Vault does not custody"
echo "-- cannot be built at all. 606 is CounterpartyMismatch, returned by the"
echo "-- constructor, so the deploy does not happen."
# Any address that is not this Vault's token will do, and the sagUSD contract
# is one that is certainly live and certainly not it. Deploying a throwaway
# token to make the point would cost XLM to prove something about an argument.
OTHER=$(j "d['contracts']['staking']")
BAD=$(stellar contract deploy --wasm "$WASM/private_credit.wasm" --source "$SRC" --network "$NET" \
  -- --admin "$ADMIN" --engine "$OLD_ENGINE" --vault "$VAULT" --usdc "$OTHER" 2>&1) || true
if echo "$BAD" | grep -q "Error(Contract, #606)"; then ok "a wrong asset adapter is refused by its own constructor (contract error 606)"
else bad "the wrong asset adapter was not refused: $(echo "$BAD" | head -2 | tr '\n' ' ')"; fi

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
echo "-- The outgoing adapters cannot join the replacement Engine's registry,"
echo "-- because they cannot answer which token they hold. 414 is"
echo "-- AdapterMismatch, the same error the Vault edge returns: from the"
echo "-- Engine's side an adapter it cannot interrogate and one that answers"
echo "-- wrongly are the same refusal."
refused 414 "the superseded private credit adapter is refused at the registry" \
  "$ENGINE" register_pool --admin "$ADMIN" --pool_id "$OLD_PC" \
  --originator "$PC_ORIGINATOR" --jurisdiction "$PC_JURISDICTION" --cap_bps "$POOL_CAP"

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
    'Replaced by scripts/rewire-token-edge.sh. register_pool proved an adapter named this Engine '
    "and this Engine's Vault, and set_counterparties proved from the other side that the Engine "
    'governs the Vault, and neither was about the asset. An adapter stores a token, it was a '
    'constructor argument nothing validated against the Vault, and it is the address every transfer '
    'in the adapter uses. An adapter with the right pointers and the wrong token is a one way door: '
    'settle_allocation sends what the Vault holds so real USDC arrives, deallocate sends back the '
    'token the adapter stores and traps, recover_surplus measures its surplus in that token and '
    'reports nothing to recover, and a write-down clears all three books while the money stays. '
    'Both sides check it now, the adapter at construction and the Engine on every call that moves '
    'capital.'
)
def retire(contract, address, label_base):
    gen = 1 + sum(1 for e in history if e['contract'] == contract)
    history.append({
        'contract': contract, 'generation': gen,
        'label': '%s, %s deployment' % (label_base, ORD[gen - 1]),
        'address': address, 'supersededBy': contract, 'reason': REASON,
    })
retire('allocationEngine', old_engine, 'Allocation Engine')
retire('poolAdapters.private-credit', old_pc, 'Private credit adapter')
retire('poolAdapters.etherfuse', old_ef, 'Etherfuse adapter')
dep['contracts']['allocationEngine'] = engine
dep['poolAdapters']['private-credit'] = pc
dep['poolAdapters']['etherfuse'] = ef
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
