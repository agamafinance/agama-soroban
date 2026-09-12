#!/usr/bin/env bash
# Replace the Allocation Engine so that it and the Vault measure the reserve
# floor on one base, and rewire the stack around it through the setters.
#
# What was wrong
#
# The Vault moved its floor onto accounted cash and the Engine did not. The
# Engine built its base from `Vault::free_reserves()`, which reads the real
# token balance, so for any USDC that reached the Vault without its books being
# told the Engine's base ran higher and its free-reserves term ran higher too.
# Asking for a fraction of the base then left the Engine more permissive than
# the Vault by `(1 - floor_bps)` of that cash. The direction was safe, because
# `settle_allocation` re-checks in the same transaction and refuses, but a limit
# enforced in two places against two different numbers is one limit and one
# decoration, and `get_reserve_ratio()` is the number an integrator reads.
#
# Why only the Engine
#
# The change is in this contract and nowhere else. The Vault already exposes
# both quantities; the Engine now asks for them rather than rebuilding them. The
# Vault takes the replacement through `set_engine`, which refuses an Engine that
# does not answer that it governs this Vault and refuses to move while capital
# is out; the adapters follow through `set_counterparties`, which refuses while
# they hold booked exposure or a stroop of USDC.
#
# The order is the one the third review made a precondition rather than a habit:
# the adapters are repointed BEFORE the pools are registered, because
# `register_pool` runs the same check `allocate` runs and an adapter that has
# not been brought across fails it.
#
# Preconditions are checked before anything is deployed, because a rewiring that
# gets half way is worse than one that does not start.
#
# Usage: MIGRATION_REASON="why this Engine replaced the live one" \
#          bash scripts/rewire-engine-one-base.sh
#
# Requires the `agama-poc` identity, the admin recorded in testnet.json.
set -euo pipefail
cd "$(dirname "$0")/.."

if [ -z "${MIGRATION_REASON:-}" ]; then
  echo "MIGRATION_REASON is unset. It is written verbatim into the superseded" >&2
  echo "entry for the retired Engine, and the record is the only place the" >&2
  echo "reason survives, so this script will not guess it." >&2
  exit 2
fi

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
check0() {  # check0 <label> <id> <fn...>
  local label=$1 id=$2; shift 2
  local v; v=$(q0 "$id" "$@")
  if [ "${v:-x}" = "0" ]; then echo "    $label = 0"
  else echo "    $label = ${v:-unreadable}, and it has to be 0"; fail=1; fi
}
check0 "vault deployed_capital"    "$VAULT" deployed_capital
check0 "engine total_allocated"    "$OLD_ENGINE" total_allocated
check0 "engine written_off"        "$OLD_ENGINE" written_off
check0 "private-credit exposure"   "$PC" get_exposure
check0 "etherfuse exposure"        "$EF" get_exposure
# set_counterparties refuses an adapter holding a stroop, so both balances are
# a precondition of the rewiring and not just of a tidy book.
check0 "private-credit usdc"       "$USDC" balance --id "$PC"
check0 "etherfuse usdc"            "$USDC" balance --id "$EF"
[ "$fail" = 0 ] || { echo "refusing to start a rewiring that cannot finish"; exit 1; }

# What the migration is for, read before and asserted after.
BASE_BEFORE=$(q0 "$VAULT" floor_base)
echo "    vault floor_base = $BASE_BEFORE, which the replacement has to agree with"

echo ""
echo "==> building"
stellar contract build >/dev/null

echo ""
echo "==> the replacement Engine, wired to the Vault in its own deploy"
OUT=$(stellar contract deploy --wasm "$WASM/allocation_engine.wasm" --source "$SRC" --network "$NET" \
  -- --admin "$ADMIN" --vault "$VAULT" 2>&1)
echo "$OUT" | grep -oE 'Using wasm hash [0-9a-f]{64}' | sed 's/^/    /'
echo "$OUT" | grep -oE 'Transaction hash is [0-9a-f]{64}' | sed 's/Transaction hash is/    deploy tx/'
ENGINE=$(echo "$OUT" | grep -oE 'C[A-Z2-7]{55}' | tail -1)
echo "    allocation-engine = $ENGINE"

echo ""
echo "==> repointing everything that names it, through the setters"
echo "    vault.set_engine       tx $(tx "$VAULT" set_engine --admin "$ADMIN" --allocation_engine "$ENGINE")"
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
echo "    private-credit.vault()      = $(q "$PC" vault)"
echo "    etherfuse.engine()          = $(q "$EF" engine)"
echo "    etherfuse.vault()           = $(q "$EF" vault)"

echo ""
echo "==> the thing this migration is for, asserted on the ledger"
E_BASE=$(q0 "$ENGINE" floor_base)
V_BASE=$(q0 "$VAULT" floor_base)
E_FREE=$(q0 "$ENGINE" get_reserve_ratio)
V_FREE=$(q0 "$VAULT" accounted_free_reserves)
echo "    engine.floor_base()              = $E_BASE"
echo "    vault.floor_base()               = $V_BASE"
echo "    vault.accounted_free_reserves()  = $V_FREE"
echo "    engine.get_reserve_ratio()       = $E_FREE"
if [ "$E_BASE" != "$V_BASE" ]; then
  echo "    the two bases disagree, which is the whole thing this replaced" >&2
  exit 1
fi
if [ "$E_BASE" != "$BASE_BEFORE" ]; then
  echo "    the base moved during the rewiring, from $BASE_BEFORE to $E_BASE" >&2
  exit 1
fi
echo "    one base, agreed by both, unchanged by the migration"

echo ""
echo "==> writing $DEP"
python3 - "$DEP" "$ENGINE" "$OLD_ENGINE" "$MIGRATION_REASON" <<'PY'
import json, sys
path, engine, old_engine, reason = sys.argv[1:]
dep = json.load(open(path))
history = dep.get('superseded', [])
def ordinal(n):
    # A fixed list ran out at the thirteenth generation and aborted the record
    # write after the migration had already happened on the ledger. It counts
    # now rather than looking up.
    words = ['first', 'second', 'third', 'fourth', 'fifth', 'sixth', 'seventh',
             'eighth', 'ninth', 'tenth', 'eleventh', 'twelfth', 'thirteenth',
             'fourteenth', 'fifteenth', 'sixteenth', 'seventeenth', 'eighteenth',
             'nineteenth', 'twentieth']
    if n <= len(words):
        return words[n - 1]
    suffix = 'th' if 11 <= n % 100 <= 13 else {1: 'st', 2: 'nd', 3: 'rd'}.get(n % 10, 'th')
    return '%d%s' % (n, suffix)

generation = 1 + sum(1 for e in history if e['contract'] == 'allocationEngine')
prev = [e for e in history if e['contract'] == 'allocationEngine']
if prev and prev[-1]['reason'].strip() == reason.strip():
    sys.exit('the reason given is the one already recorded for allocationEngine '
             'generation %d, so one of the two is wrong' % prev[-1]['generation'])
history.append({
    'contract': 'allocationEngine',
    'generation': generation,
    'label': 'Allocation Engine, %s deployment' % ordinal(generation),
    'address': old_engine,
    'supersededBy': 'allocationEngine',
    'reason': reason,
})
dep['contracts']['allocationEngine'] = engine
dep['superseded'] = history
json.dump(dep, open(path, 'w'), indent=2)
open(path, 'a').write('\n')
print(json.dumps(dep['contracts'], indent=2))
PY
echo "==> done"
