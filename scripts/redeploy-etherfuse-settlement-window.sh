#!/usr/bin/env bash
# Replace the Etherfuse adapter with one that answers settlement_window.
#
# Both pool adapters publish how long their book takes to turn into cash, and
# they published it under different names with different return types:
# settlement_window() -> (u32, u32) on private credit, settlement_days() -> u32
# here. Nothing on-chain reads either, so nothing broke, which is precisely why
# it survived: a caller sizing the withdrawal queue against the book has to know
# which adapter it is holding and call a different name for each, and the next
# adapter added is a third case.
#
# Contained on purpose. The Vault and the Engine are untouched, because an
# adapter stores its own counterparties and the Engine's registry has an
# unregister. The old adapter's exposure is asserted at zero first: a registry
# entry removed while it still holds capital is capital the Engine stops
# counting and the Vault still believes is out.
set -euo pipefail
cd "$(dirname "$0")/.."
NET=${NET:-testnet}
SRC=${SRC:-agama-poc}
DEP=deployments/testnet.json
j() { python3 -c "import json;print(json.load(open('$DEP'))$1)"; }
ADMIN=$(j "['admin']")
ENGINE=$(j "['contracts']['allocationEngine']")
VAULT=$(j "['contracts']['vault']")
USDC=$(j "['contracts']['usdc']")
OLD=$(j "['poolAdapters']['etherfuse']")

inv() { stellar contract invoke --id "$1" --source "$SRC" --network "$NET" -- "${@:2}"; }
rd()  { stellar contract invoke --id "$1" --source "$SRC" --network "$NET" --send=no -- "${@:2}" 2>/dev/null | tr -d '"'; }

echo "==> the adapter being replaced must be empty"
EXP=$(rd "$ENGINE" get_exposure --pool_id "$OLD")
[ "$EXP" = "0" ] || { echo "    refusing: the Engine books $EXP against $OLD"; exit 1; }
echo "    exposure 0, and the Engine agrees"

echo "==> building"
stellar contract build >/dev/null 2>&1
WASM=target/wasm32v1-none/release
[ -f "$WASM/etherfuse.wasm" ] || WASM=target/wasm32-unknown-unknown/release

echo "==> deploying"
# stderr is kept rather than discarded. A deploy that fails under `set -e` with
# its reason sent to /dev/null exits the script with nothing printed after the
# last echo, which is exactly what happened the first time this was run and is
# indistinguishable from the script hanging.
NEW=$(stellar contract deploy --wasm "$WASM/etherfuse.wasm" --source "$SRC" --network "$NET" \
  -- --admin "$ADMIN" --engine "$ENGINE" --vault "$VAULT" --usdc "$USDC" 2>/tmp/ef-deploy.err | tail -1) \
  || { echo "    deploy failed:"; sed -n '1,5p' /tmp/ef-deploy.err; exit 1; }
[ -n "$NEW" ] || { echo "    deploy returned nothing, stopping before anything is unregistered"; exit 1; }
echo "    $NEW"

echo "==> reading it back before touching the registry"
# The deploy that returned an empty address and was not checked is how an asset
# got bricked here once. Nothing is unregistered until the new adapter answers.
[ "$(rd "$NEW" engine)" = "$ENGINE" ] || { echo "    it does not name this Engine"; exit 1; }
[ "$(rd "$NEW" vault)" = "$VAULT" ]   || { echo "    it does not name this Vault"; exit 1; }
[ "$(rd "$NEW" settlement_window)" = "(0, 0)" ] || \
  echo "    note: settlement_window reads $(rd "$NEW" settlement_window)"
echo "    engine and vault check out"

echo "==> swapping the registry entry"
POOL=$(rd "$ENGINE" get_pool --pool_id "$OLD")
CAP=$(python3 -c "import json,sys;print(json.loads('''$POOL''')['cap_bps'])")
ORIG=$(python3 -c "import json;print(json.loads('''$POOL''')['originator'])")
JUR=$(python3 -c "import json;print(json.loads('''$POOL''')['jurisdiction'])")
echo "    carrying over cap $CAP bps, originator $ORIG, jurisdiction $JUR"
inv "$ENGINE" register_pool --admin "$ADMIN" --pool_id "$NEW" --originator "$ORIG" \
  --jurisdiction "$JUR" --cap_bps "$CAP" >/dev/null
inv "$ENGINE" unregister_pool --admin "$ADMIN" --pool_id "$OLD" >/dev/null
echo "    registered the new one, then removed the old one"

echo "==> recording"
python3 - "$OLD" "$NEW" <<'PY'
import json, sys
old, new = sys.argv[1], sys.argv[2]
p = 'deployments/testnet.json'
d = json.load(open(p))
d['poolAdapters']['etherfuse'] = new
gens = [e.get('generation', 0) for e in d['superseded'] if e.get('contract') == 'poolAdapters.etherfuse']
d['superseded'].append({
    'label': 'Etherfuse adapter, %s deployment' % ('next',),
    'contract': 'poolAdapters.etherfuse',
    'address': old,
    'generation': (max(gens) + 1) if gens else 1,
    'supersededBy': 'poolAdapters.etherfuse',
    'reason': ("Replaced to make the two pool adapters answer the same question under the same name. "
               "Both publish how long their book takes to turn into cash, and they published it as "
               "settlement_days() -> u32 here and settlement_window() -> (u32, u32) on private credit. "
               "Nothing on-chain reads either, which is why it survived: a caller sizing the withdrawal "
               "queue has to know which adapter it holds and call a different name with a different "
               "return type for each, and the next adapter added is a third case. The replacement adds "
               "settlement_window returning (0, 0), redemption here being on-chain and immediate, and "
               "keeps settlement_days for anything already reading it. Neither is reachable through a "
               "setter, so shipping it took a new contract. Its exposure was asserted at zero before the "
               "registry entry moved, and the cap, originator and jurisdiction were carried over unchanged."),
})
json.dump(d, open(p, 'w'), indent=2)
print('    record updated')
PY
echo "==> done"
