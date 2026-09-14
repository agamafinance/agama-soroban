#!/usr/bin/env bash
# Replace the Oracle Adapter so the deviation bound on the ledger is the exact
# one, and rewire the Vault at it.
#
# Why only the oracle
#
# The bound decided by dividing, so it enforced up to one basis point more than
# it advertised. The fix is in this contract and nowhere else. Nothing else
# points at the oracle: the Vault holds the address and the feed symbol, the
# adapters carry their feed as a constant Symbol rather than an address, and the
# Engine does not touch it at all.
#
# The order, and why it is this order
#
#   1. deploy, then register the three feeds with the parameters the live one
#      has. register_feed is write once per feed, so they have to be right the
#      first time; they are read off the outgoing contract rather than typed.
#   2. the reporter set, or nothing can push
#   3. a first value on every feed, because set_oracle interrogates the
#      candidate with get_feed and the Vault's own get_nav has to answer
#      afterwards
#   4. vault.set_oracle last, so the Vault never points at an oracle that
#      cannot answer
#
# Usage: MIGRATION_REASON="why" bash scripts/redeploy-oracle-exact-bound.sh
set -euo pipefail
cd "$(dirname "$0")/.."

if [ -z "${MIGRATION_REASON:-}" ]; then
  echo "MIGRATION_REASON is unset; the record is the only place the reason survives." >&2
  exit 2
fi

NET=testnet
SRC=agama-poc
DEP=deployments/testnet.json
WASM=target/wasm32v1-none/release

j() { python3 -c "import json;d=json.load(open('$DEP'));print($1)"; }
ADMIN=$(stellar keys address "$SRC")
VAULT=$(j "d['contracts']['vault']")
OLD=$(j "d['contracts']['oracleAdapter']")
FEED=$(stellar contract invoke --id "$VAULT" --source "$SRC" --network "$NET" --send=no -- oracle_feed 2>/dev/null | tr -d '"')

tx() { stellar contract invoke --id "$1" --source "$SRC" --network "$NET" -- "${@:2}" 2>&1 | grep -oE '[0-9a-f]{64}' | head -1; }
q()  { stellar contract invoke --id "$1" --source "$SRC" --network "$NET" --send=no -- "${@:2}" 2>/dev/null; }

echo "outgoing oracle = $OLD"
echo "vault           = $VAULT, reading feed $FEED"

echo ""
echo "==> reading the live configuration, so nothing is retyped"
FEEDS=$(q "$OLD" reporters >/dev/null; for f in USDC_USD PC_NAV EF_BOND; do
  cfg=$(q "$OLD" get_feed --feed_id "$f")
  nav=$(q "$OLD" get_nav --feed_id "$f" 2>/dev/null | tr -d '"')
  echo "$f|$cfg|${nav:-0}"
done)
echo "$FEEDS" | sed 's/^/    /'

echo ""
echo "==> building and deploying"
stellar contract build >/dev/null
OUT=$(stellar contract deploy --wasm "$WASM/oracle_adapter.wasm" --source "$SRC" --network "$NET" \
  -- --admin "$ADMIN" 2>&1)
ORACLE=$(echo "$OUT" | grep -oE 'C[A-Z2-7]{55}' | tail -1)
[ -n "$ORACLE" ] || { echo "the deploy produced no address" >&2; exit 1; }
echo "    oracle-adapter = $ORACLE"

echo ""
echo "==> the feeds, with the parameters the outgoing contract carries"
while IFS='|' read -r f cfg nav; do
  [ -n "$f" ] || continue
  read -r dev maxn mini minn stale <<< "$(echo "$cfg" | python3 -c "
import sys, json
d = json.load(sys.stdin)
print(d['deviation_bps'], d['max_nav'], d['min_interval_secs'], d['min_nav'], d['staleness_secs'])
")"
  echo "    register $f  dev=$dev band=[$minn,$maxn] interval=${mini}s staleness=${stale}s"
  echo "      tx $(tx "$ORACLE" register_feed --admin "$ADMIN" --feed_id "$f" \
        --staleness_secs "$stale" --deviation_bps "$dev" --min_nav "$minn" \
        --max_nav "$maxn" --min_interval_secs "$mini")"
done <<< "$FEEDS"

echo ""
echo "==> the reporter set"
for r in $(q "$OLD" reporters | tr -d '[]"' | tr ',' ' '); do
  echo "    add_reporter ${r:0:8}  tx $(tx "$ORACLE" add_reporter --admin "$ADMIN" --reporter "$r")"
done

echo ""
echo "==> a first value on every feed, carried across rather than invented"
TS=$(( $(date -u +%s) - 60 ))
while IFS='|' read -r f cfg nav; do
  [ -n "$f" ] || continue
  [ "${nav:-0}" != "0" ] || { echo "    $f had no value to carry"; continue; }
  echo "    push $f = $nav  tx $(tx "$ORACLE" push_nav --reporter "$ADMIN" --feed_id "$f" --nav "$nav" --timestamp "$TS")"
done <<< "$FEEDS"

echo ""
echo "==> the Vault, last, once the replacement can answer"
SET_TX=$(tx "$VAULT" set_oracle --admin "$ADMIN" --oracle "$ORACLE" --feed_id "$FEED")
echo "    set_oracle  tx ${SET_TX:-FAILED}"
# Checked against the chain rather than against the transaction, because a hash
# is not evidence the pointer moved. The first run of this script passed an
# argument named --feed where the contract calls it --feed_id: the call was
# refused, the helper returned nothing, and the record was written anyway,
# claiming a replacement was live while the Vault still named the outgoing one.
POINTS_AT=$(q "$VAULT" oracle | tr -d '"')
if [ "$POINTS_AT" != "$ORACLE" ]; then
  echo "" >&2
  echo "  the Vault still names $POINTS_AT, so the replacement is deployed and" >&2
  echo "  configured but nothing uses it. The record is NOT being written: it" >&2
  echo "  would claim a migration that did not happen." >&2
  exit 1
fi

echo ""
echo "==> checking"
echo "    vault.oracle()       = $(q "$VAULT" oracle)"
echo "    vault.oracle_feed()  = $(q "$VAULT" oracle_feed)"
echo "    vault.get_nav()      = $(q "$VAULT" get_nav)"
for f in USDC_USD PC_NAV EF_BOND; do
  echo "    $f get_nav=$(q "$ORACLE" get_nav --feed_id "$f") bound=$(q "$ORACLE" get_feed --feed_id "$f" | python3 -c "import sys,json;print(json.load(sys.stdin)['deviation_bps'])")"
done

echo ""
echo "==> writing $DEP"
python3 - "$DEP" "$ORACLE" "$OLD" "$MIGRATION_REASON" <<'PY'
import json, sys
path, new, old, reason = sys.argv[1:]
dep = json.load(open(path))
history = dep.get('superseded', [])
def ordinal(n):
    words = ['first','second','third','fourth','fifth','sixth','seventh','eighth','ninth',
             'tenth','eleventh','twelfth','thirteenth','fourteenth','fifteenth']
    if n <= len(words):
        return words[n - 1]
    suffix = 'th' if 11 <= n % 100 <= 13 else {1:'st',2:'nd',3:'rd'}.get(n % 10, 'th')
    return '%d%s' % (n, suffix)
prev = [e for e in history if e['contract'] == 'oracleAdapter']
if prev and prev[-1]['reason'].strip() == reason.strip():
    sys.exit('that reason is already recorded for oracleAdapter generation %d' % prev[-1]['generation'])
history.append({
    'contract': 'oracleAdapter', 'generation': len(prev) + 1,
    'label': 'Oracle Adapter, %s deployment' % ordinal(len(prev) + 1),
    'address': old, 'supersededBy': 'oracleAdapter', 'reason': reason,
})
dep['contracts']['oracleAdapter'] = new
dep['superseded'] = history
json.dump(dep, open(path, 'w'), indent=2)
open(path, 'a').write('\n')
print(json.dumps({'oracleAdapter': new}, indent=2))
PY
echo "==> done"
