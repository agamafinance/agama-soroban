#!/usr/bin/env bash
# Replace the Allocation Engine, carrying all four pools.
#
# The Engine lists the pool adapters as regular dependencies rather than dev
# ones, so editing an adapter changes the Engine's bytecode while every entry
# point it exposes stays identical. That drift has been declared under
# treeAheadOfLedger since 2026-10-31 and this is what clears it: the deployed
# Engine becomes the one in this repository again.
#
# Nothing about the Engine's interface changes here. If you are looking for what
# this migration is for, it is that and only that.
#
# The order is not interchangeable. The Vault takes the replacement through
# set_engine, which refuses an Engine that does not already name this Vault, so
# the Vault is wired into the Engine's own constructor. The adapters follow
# through set_counterparties, which refuses an adapter holding a stroop or
# carrying exposure. And register_pool runs the same check allocate runs, so an
# adapter that still names the outgoing Engine cannot be registered on the
# incoming one: the adapters are repointed before the pools are registered.
#
# Every pool comes out of the record rather than being typed here. The script
# this replaces was written for two and there are four, and a migration that
# silently carries fewer pools than the Engine has is the shape of defect this
# repository has already paid for twice.
#
#   bash scripts/rewire-engine-four-pools.sh
#
# Preconditions, all checked before anything is deployed: nothing allocated,
# nothing written off, and every adapter empty of both exposure and USDC.
set -euo pipefail
cd "$(dirname "$0")/.."
NET=${NET:-testnet}
SRC=${SRC:-agama-poc}
DEP=deployments/testnet.json
WASM=target/wasm32v1-none/release
j() { python3 -c "import json;d=json.load(open('$DEP'));print($1)"; }
ADMIN=$(stellar keys address "$SRC")
VAULT=$(j "d['contracts']['vault']")
OLD_ENGINE=$(j "d['contracts']['allocationEngine']")
POOL_CAP=$(j "d['engineConfig']['poolCapBps']")
ORIG_CAP=$(j "d['engineConfig']['originatorCapBps']")
JUR_CAP=$(j "d['engineConfig']['jurisdictionCapBps']")
RESERVE_FLOOR=$(j "d['engineConfig']['reserveFloorBps']")
USDC=$(j "d['contracts']['usdc']")

# This migration repoints the contract the Vault authorizes for every release,
# so it takes the lock the suites take and the keepers stand aside for.
LOCK=/tmp/agama-smoke-$SRC.lock
if ! mkdir "$LOCK" 2>/dev/null; then
  echo "a suite or another migration holds $SRC ($(cat "$LOCK/owner" 2>/dev/null || echo unknown))." >&2
  exit 1
fi
echo "pid $$ at $(date -u +%H:%M:%S), rewire-engine-four-pools" > "$LOCK/owner"
trap 'rm -rf "$LOCK"' EXIT

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  PASS  $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL  $1"; }
q()  { stellar contract invoke --id "$1" --source "$SRC" --network "$NET" --send=no -- "${@:2}" 2>/dev/null; }
q0() { q "$@" | tr -d '"'; }
num(){ printf '%s' "${1:-}" | tr -d '"'; }
assert_eq() { if [ "$(num "$2")" = "$(num "$3")" ]; then ok "$1 ($(num "$2"))"; else bad "$1: got $(num "$2"), want $(num "$3")"; fi; }
# A call that did not land says so rather than printing an empty hash, which at
# a glance reads exactly like one that worked.
# Errors are looked for first, and that order is the whole point. The previous
# version searched the output for a 64 hex transaction hash and reported success
# on the first match, but --recipient is 64 hex characters, so a call refused
# with #715 printed its own argument back and was read as a hash. It reported
# three refusals as landed transactions.
_tx() {
  local out err h
  out=$("$@" 2>&1) || true
  err=$(printf '%s' "$out" | tr '\n' ' ' | grep -oE 'Error\(Contract, #[0-9]+\)|TxBadSeq|error: [^ ]+' | head -1 || true)
  if [ -n "$err" ]; then printf 'FAILED %s' "$err"; return 1; fi
  h=$(printf '%s' "$out" | grep -oE 'Transaction hash is [0-9a-f]{64}' | grep -oE '[0-9a-f]{64}' | head -1 || true)
  [ -n "$h" ] || h=$(printf '%s' "$out" | grep -oE '[0-9a-f]{64}' | head -1 || true)
  if [ -n "$h" ]; then printf '%s' "$h"; return 0; fi
  printf 'landed, no hash printed'
}
tx() { _tx stellar contract invoke --id "$1" --source "$SRC" --network "$NET" -- "${@:2}"; }

POOLS=$(j "'\n'.join('%s %s %s %s %s' % (k, v['address'], v['originator'], v['jurisdiction'], v['capBps']) for k, v in d['engineConfig']['pools'].items())")

echo "vault (kept)     = $VAULT"
echo "outgoing engine  = $OLD_ENGINE"
echo "pools to carry   = $(printf '%s' "$POOLS" | wc -l | tr -d ' ')"
printf '%s\n' "$POOLS" | sed 's/^/    /'

echo ""
echo "==> preconditions, checked before anything is deployed"
fail=0
chk0() {
  local label=$1; shift
  local v; v=$(q0 "$@")
  if [ "${v:-x}" = "0" ]; then echo "    $label = 0"
  else echo "    $label = ${v:-unreadable}, and it has to be 0"; fail=1; fi
}
chk0 "vault deployed_capital" "$VAULT" deployed_capital
chk0 "engine total_allocated" "$OLD_ENGINE" total_allocated
chk0 "engine written_off"     "$OLD_ENGINE" written_off
while read -r name addr _o _j _c; do
  [ -n "$name" ] || continue
  chk0 "$name exposure" "$OLD_ENGINE" get_exposure --pool_id "$addr"
  chk0 "$name usdc"     "$USDC" balance --id "$addr"
done <<< "$POOLS"
[ "$fail" = 0 ] || { echo "refusing to start a rewiring that cannot finish"; exit 1; }

echo ""
echo "==> building"
stellar contract build >/dev/null

echo ""
echo "==> the replacement Engine, wired to the Vault in its own deploy"
if [ -n "${ENGINE:-}" ]; then
  echo "    adopting the already deployed $ENGINE"
  [ "$(q0 "$ENGINE" vault)" = "$VAULT" ] || { echo "    that Engine does not name this Vault"; exit 1; }
else
  OUT=$(stellar contract deploy --wasm "$WASM/allocation_engine.wasm" --source "$SRC" --network "$NET" \
    -- --admin "$ADMIN" --vault "$VAULT" 2>&1)
  # `|| true` on each: the pipeline is grep then sed, this runs under set -e and
  # pipefail, and a grep that matches nothing exits 1 and takes the script with
  # it. A successful deploy killed the oracle migration that way on 2026-11-01,
  # on the line that was only trying to pretty-print it.
  echo "$OUT" | grep -oE 'Using wasm hash [0-9a-f]{64}' | sed 's/^/    /' || true
  echo "$OUT" | grep -oE 'Transaction hash is [0-9a-f]{64}' | sed 's/Transaction hash is/    deploy tx/' || true
  ENGINE=$(echo "$OUT" | grep -oE 'C[A-Z2-7]{55}' | tail -1 || true)
  if [ -z "$ENGINE" ]; then
    echo "    the deploy produced no contract address. Output follows:" >&2
    printf '%s\n' "$OUT" | tail -20 >&2
    exit 1
  fi
  echo "    allocation-engine = $ENGINE"
fi

echo ""
echo "==> repointing everything that names it, through the setters"
echo "    vault.set_engine        tx $(tx "$VAULT" set_engine --admin "$ADMIN" --allocation_engine "$ENGINE")"
while read -r name addr _o _j _c; do
  [ -n "$name" ] || continue
  echo "    $name.set_counterparties tx $(tx "$addr" set_counterparties --admin "$ADMIN" --engine "$ENGINE" --vault "$VAULT")"
done <<< "$POOLS"

echo ""
echo "==> opening the replacement up to the configured limits"
echo "    set_caps          tx $(tx "$ENGINE" set_caps --admin "$ADMIN" --pool_cap_bps "$POOL_CAP" \
  --originator_cap_bps "$ORIG_CAP" --jurisdiction_cap_bps "$JUR_CAP")"
echo "    set_reserve_floor tx $(tx "$ENGINE" set_reserve_floor --admin "$ADMIN" --floor_bps "$RESERVE_FLOOR")"
while read -r name addr o jur cap; do
  [ -n "$name" ] || continue
  echo "    register $name  tx $(tx "$ENGINE" register_pool --admin "$ADMIN" --pool_id "$addr" \
    --originator "$o" --jurisdiction "$jur" --cap_bps "$cap")"
done <<< "$POOLS"

echo ""
echo "==> checking the wiring, every pointer in both directions"
assert_eq "the Vault names the replacement" "$(q0 "$VAULT" allocation_engine)" "$ENGINE"
assert_eq "the replacement names the Vault" "$(q0 "$ENGINE" vault)" "$VAULT"
assert_eq "its admin is the operator"       "$(q0 "$ENGINE" admin)" "$ADMIN"
assert_eq "and the two admins agree"        "$(q0 "$ENGINE" admin_aligned)" "true"
assert_eq "the reserve floor carried"       "$(q0 "$ENGINE" reserve_floor_bps)" "$RESERVE_FLOOR"
CAPS=$(q "$ENGINE" caps)
read -r P O Ju <<<"$(printf '%s' "$CAPS" | python3 -c "import sys,json;c=json.load(sys.stdin);print(c['pool_bps'],c['originator_bps'],c['jurisdiction_bps'])")"
assert_eq "per pool cap carried"         "$P"  "$POOL_CAP"
assert_eq "per originator cap carried"   "$O"  "$ORIG_CAP"
assert_eq "per jurisdiction cap carried" "$Ju" "$JUR_CAP"
EXPECTED=$(printf '%s' "$POOLS" | grep -c . || true)
assert_eq "every pool was carried" \
  "$(q "$ENGINE" pools | python3 -c "import sys,json;print(len(json.load(sys.stdin)))")" "$EXPECTED"
while read -r name addr o jur cap; do
  [ -n "$name" ] || continue
  META=$(q "$ENGINE" get_pool --pool_id "$addr")
  read -r go gj gc <<<"$(printf '%s' "$META" | python3 -c "import sys,json;m=json.load(sys.stdin);print(m['originator'],m['jurisdiction'],m['cap_bps'])")"
  assert_eq "$name keeps its originator"   "$go" "$o"
  assert_eq "$name keeps its jurisdiction" "$gj" "$jur"
  assert_eq "$name keeps its cap"          "$gc" "$cap"
  assert_eq "$name names the replacement"  "$(q0 "$addr" engine)" "$ENGINE"
done <<< "$POOLS"

echo ""
echo "==> writing $DEP"
python3 - "$DEP" "$ENGINE" "$OLD_ENGINE" <<'ZPY'
import json, sys, collections
path, engine, old = sys.argv[1:]
dep = json.loads(open(path).read(), object_pairs_hook=collections.OrderedDict)
hist = dep.get('superseded', [])
gens = [e for e in hist if e['contract'] == 'allocationEngine']
g = max((e['generation'] for e in gens), default=0) + 1
hist.append(collections.OrderedDict([
    ('contract', 'allocationEngine'),
    ('generation', g),
    ('label', 'Allocation Engine, generation %d' % g),
    ('address', old),
    ('supersededBy', 'allocationEngine'),
    ('reason', (
        'Replaced by scripts/rewire-engine-four-pools.sh so that the deployed Engine is the one in this '
        'repository. No entry point changed and none of this is a feature: the Engine lists the pool '
        'adapters as regular dependencies rather than dev ones, so editing an adapter moves the Engine\'s '
        'bytecode while its interface stays identical, and that drift had been declared under '
        'treeAheadOfLedger since 2026-10-31. It could not be cleared until 2026-11-01, because this '
        'migration refuses to start on a book whose written_off is not zero and the cross chain pool '
        'carried a charge until the operator cleared it; see decisions.crossChainWriteOffCleared, which '
        'says what that clearing actually was. All four pools were carried with their originators, '
        'jurisdictions and caps, read out of this record rather than typed into the script, because the '
        'migration this replaces was written for two.'))
]))
dep['contracts']['allocationEngine'] = engine
dep['superseded'] = hist
ahead = dep.get('treeAheadOfLedger') or []
dropped = [e for e in ahead if e.get('contract') == 'allocationEngine']
dep['treeAheadOfLedger'] = [e for e in ahead if e.get('contract') != 'allocationEngine']
for e in dropped:
    print('    dropped the treeAheadOfLedger entry for %s, which this deploy settles' % e['contract'])
open(path, 'w').write(json.dumps(dep, indent=2, ensure_ascii=False) + '\n')
print('    allocationEngine = %s' % engine)
ZPY

echo ""
echo "  $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
