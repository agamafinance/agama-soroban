#!/usr/bin/env bash
# Replace the Allocation Engine alone, and rewire the stack around it through
# the setters rather than redeploying any of it.
#
# Why only the Engine
#
# `write_down` checked the amount and the pool before it checked that this
# Engine's admin and the Vault's are still the same address, so an operator
# whose rotation was half finished was told the amount was wrong. That sends
# them to look at the position, which is the wrong place. The check is a
# condition on the wiring rather than on the call, so it now runs first. It is
# a legibility change and not a security one, and the security property it
# reports on is unchanged.
#
# The Engine is not upgradeable, so it is a new deployment. Nothing else is,
# and that is the point of this script rather than an accident of it. The Vault
# takes the replacement through `set_engine`, which refuses any Engine that
# does not answer that it governs this Vault and refuses to move at all while
# this Vault has capital out at a pool; the adapters follow through
# `set_counterparties`, which refuses while they hold booked exposure or a
# stroop of USDC. Those two setters are the repair paths whose absence cost
# this protocol a generation of contracts, and this is what they were for: the
# contract with the change moves, and everything that names it is repointed.
#
# The preconditions are checked before anything is deployed, because a rewiring
# that gets half way is worse than one that does not start.
#
# Usage: bash scripts/rewire-engine.sh
#
# Requires the `agama-poc` identity, the admin recorded in testnet.json.
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

tx() { stellar contract invoke --id "$1" --source "$SRC" --network "$NET" -- "${@:2}" 2>&1 \
         | grep -oE '[0-9a-f]{64}' | head -1; }
q()  { stellar contract invoke --id "$1" --source "$SRC" --network "$NET" --send=no -- "${@:2}" 2>/dev/null; }
q0() { q "$@" | tr -d '"'; }

echo "vault (kept)        = $VAULT"
echo "outgoing engine     = $OLD_ENGINE"
echo "private-credit      = $PC"
echo "etherfuse           = $EF"

echo ""
echo "==> preconditions, checked before anything is deployed"
fail=0
for pair in "vault:$VAULT:deployed_capital" "private-credit:$PC:get_exposure" "etherfuse:$EF:get_exposure"; do
  name=${pair%%:*}; rest=${pair#*:}; id=${rest%%:*}; fn=${rest#*:}
  v=$(q0 "$id" "$fn")
  if [ "${v:-x}" = "0" ]; then echo "    $name $fn = 0"; else echo "    $name $fn = $v, and it has to be 0"; fail=1; fi
done
for pair in "private-credit:$PC" "etherfuse:$EF"; do
  name=${pair%%:*}; id=${pair#*:}
  v=$(q0 "$USDC" balance --id "$id")
  if [ "${v:-x}" = "0" ]; then echo "    $name usdc balance = 0"; else echo "    $name usdc balance = $v, and set_counterparties will refuse it"; fail=1; fi
done
[ "$fail" = 0 ] || { echo "refusing to start a rewiring that cannot finish"; exit 1; }

echo ""
echo "==> building"
stellar contract build >/dev/null

echo ""
echo "==> the replacement Engine, wired to the Vault in its own deploy"
OUT=$(stellar contract deploy --wasm "$WASM/allocation_engine.wasm" --source "$SRC" --network "$NET" \
  -- --admin "$ADMIN" --vault "$VAULT" 2>&1)
# The CLI prints an install transaction, a WASM hash and a deploy transaction,
# and all three look the same. Only two of them are on the ledger as
# transactions, so they are labelled rather than left to be guessed at.
echo "$OUT" | grep -oE 'Using wasm hash [0-9a-f]{64}' | sed 's/^/    /'
echo "$OUT" | grep -oE 'Transaction hash is [0-9a-f]{64}' | sed 's/Transaction hash is/    deploy tx/'
ENGINE=$(echo "$OUT" | grep -oE 'C[A-Z2-7]{55}' | tail -1)
echo "    allocation-engine = $ENGINE"

echo ""
echo "==> repointing everything that names it, through the setters"
echo "    vault.set_engine   tx $(tx "$VAULT" set_engine --admin "$ADMIN" --allocation_engine "$ENGINE")"
echo "    pc.set_counterparties  tx $(tx "$PC" set_counterparties --admin "$ADMIN" --engine "$ENGINE" --vault "$VAULT")"
echo "    ef.set_counterparties  tx $(tx "$EF" set_counterparties --admin "$ADMIN" --engine "$ENGINE" --vault "$VAULT")"

echo ""
echo "==> opening the replacement up to the configured limits"
echo "    set_caps           tx $(tx "$ENGINE" set_caps --admin "$ADMIN" --pool_cap_bps "$POOL_CAP" \
  --originator_cap_bps "$ORIGINATOR_CAP" --jurisdiction_cap_bps "$JURISDICTION_CAP")"
echo "    set_reserve_floor  tx $(tx "$ENGINE" set_reserve_floor --admin "$ADMIN" --floor_bps "$RESERVE_FLOOR")"
echo "    register pc        tx $(tx "$ENGINE" register_pool --admin "$ADMIN" --pool_id "$PC" \
  --originator "$PC_ORIGINATOR" --jurisdiction "$PC_JURISDICTION" --cap_bps "$POOL_CAP")"
echo "    register ef        tx $(tx "$ENGINE" register_pool --admin "$ADMIN" --pool_id "$EF" \
  --originator "$EF_ORIGINATOR" --jurisdiction "$EF_JURISDICTION" --cap_bps "$POOL_CAP")"

echo ""
echo "==> checking the wiring, every pointer in both directions"
echo "    vault.allocation_engine()   = $(q "$VAULT" allocation_engine)"
echo "    engine.vault()              = $(q "$ENGINE" vault)"
echo "    engine.admin_aligned()      = $(q "$ENGINE" admin_aligned)"
echo "    engine.caps()               = $(q "$ENGINE" caps)"
echo "    engine.reserve_floor_bps()  = $(q "$ENGINE" reserve_floor_bps)"
echo "    engine.pools()              = $(q "$ENGINE" pools)"
echo "    private-credit.engine()     = $(q "$PC" engine)"
echo "    etherfuse.engine()          = $(q "$EF" engine)"

echo ""
echo "==> writing $DEP"
python3 - "$DEP" "$ENGINE" "$OLD_ENGINE" <<'PY'
import json, sys
path, engine, old_engine = sys.argv[1:]
dep = json.load(open(path))
history = dep.get('superseded', [])
ORDINALS = ['first', 'second', 'third', 'fourth', 'fifth', 'sixth', 'seventh',
            'eighth', 'ninth', 'tenth', 'eleventh']
generation = 1 + sum(1 for e in history if e['contract'] == 'allocationEngine')
history.append({
    'contract': 'allocationEngine',
    'generation': generation,
    'label': 'Allocation Engine, %s deployment' % ORDINALS[generation - 1],
    'address': old_engine,
    'supersededBy': 'allocationEngine',
    'reason': (
        'Replaced by scripts/rewire-engine.sh. In this Engine write_down checks '
        'the amount and the pool before it checks that its own admin and the '
        "Vault's are still the same address, so an operator whose rotation is "
        'half finished is told the amount is wrong, which sends them to look at '
        'the position rather than at the rotation. The alignment is a condition '
        'on the wiring rather than on the call and now runs first. It is a '
        'legibility change and not a security one: the same call is refused '
        'either way. Nothing else was redeployed alongside it. The Vault took '
        'the replacement through set_engine and both adapters followed through '
        'set_counterparties, which is what those setters exist for and the '
        'first time a change to one contract has been absorbed by the rest '
        'without a redeployment.'
    ),
})
dep['contracts']['allocationEngine'] = engine
dep['superseded'] = history
dep['reusedInPlace'] = {
    'vault': 'Repointed at the replacement Engine with set_engine, which refuses an Engine that does not govern this Vault and refuses to move while capital is deployed.',
    'agusdCore': 'Unchanged. It names the Vault as its minter and the Vault did not move.',
    'staking': 'Unchanged.',
    'oracleAdapter': 'Unchanged.',
    'poolAdapters.private-credit': 'Repointed at the replacement Engine with set_counterparties, empty at the time as that setter requires.',
    'poolAdapters.etherfuse': 'Repointed at the replacement Engine with set_counterparties, empty at the time as that setter requires.',
    'usdc': 'The real Circle USDC Stellar Asset Contract on testnet, never redeployed.',
    'creditVaults': 'The six generation 1 credit vaults, untouched by this review.',
    'agusd': 'Generation 1 agUSD, left exactly as it is with its holders.',
}
json.dump(dep, open(path, 'w'), indent=2)
open(path, 'a').write('\n')
print(json.dumps(dep['contracts'], indent=2))
PY
echo "==> done"
