#!/usr/bin/env bash
# Is the deployed protocol actually able to serve anybody right now?
#
#   bash scripts/check-live-state.sh
#
# Every other check here asks whether the record, the source and the ledger
# agree. They can all agree perfectly about a protocol that refuses every
# deposit. Two states do that quietly:
#
#   The Vault is paused. deposit, request_withdrawal and settle_allocation all
#   refuse; claim_withdrawal still works, so anyone already in the queue can
#   leave, which is the half of that design worth keeping. This session left the
#   Vault paused once and nothing said so, because the smoke helper was reporting
#   failed transactions as successes.
#
#   A feed is past its staleness window. Any read of it fails with OracleStale,
#   which takes down whatever depends on it. A feed with a short window and no
#   keeper pushing it is stale almost all the time by construction, so this
#   prints the window next to the age and lets a human judge which it is.
#
# Reads the chain, changes nothing, needs no key that holds a role.
set -euo pipefail
cd "$(dirname "$0")/.."

NET=testnet
SRC=${SRC:-agama-poc}
DEP=${DEP:-deployments/testnet.json}
PASS=0; FAIL=0; WARN=0
ok()   { PASS=$((PASS+1)); echo "  PASS  $1"; }
bad()  { FAIL=$((FAIL+1)); echo "  FAIL  $1"; }
warn() { WARN=$((WARN+1)); echo "  WARN  $1"; }

q() { stellar contract invoke --id "$1" --source "$SRC" --network "$NET" --send=no -- "${@:2}" 2>/dev/null; }
j() { python3 -c "import json;d=json.load(open('$DEP'));print($1)"; }

VAULT=$(j "d['contracts']['vault']")
ORACLE=$(j "d['contracts']['oracleAdapter']")

echo "==> the Vault is open for business"
PAUSED=$(q "$VAULT" paused | tr -d '"')
case "$PAUSED" in
  false) ok "the Vault is not paused" ;;
  true)  bad "the Vault is PAUSED: deposit, request_withdrawal and settle_allocation all refuse. Anyone already holding a claim can still call claim_withdrawal." ;;
  *)     bad "could not read paused() off the Vault, got '$PAUSED'" ;;
esac

# The Vault reads exactly one feed and it is the one it names. A stale feed
# elsewhere on the oracle is worth knowing about; a stale one here stops deposits.
VFEED=$(q "$VAULT" oracle_feed | tr -d '"')
echo ""
echo "==> every feed on the live oracle is inside its own staleness window"
echo "    the Vault reads $VFEED"
NOW=$(date -u +%s)
while read -r f; do
  [ -n "$f" ] || continue
  LU=$(q "$ORACLE" last_update --feed_id "$f")
  FD=$(q "$ORACLE" get_feed --feed_id "$f")
  RA=$(echo "$LU" | python3 -c "import sys,json;print(json.load(sys.stdin)['recorded_at'])" 2>/dev/null || echo "")
  ST=$(echo "$FD" | python3 -c "import sys,json;print(json.load(sys.stdin)['staleness_secs'])" 2>/dev/null || echo "")
  if [ -z "$RA" ] || [ -z "$ST" ]; then
    bad "$f: could not read its last update or its window off the oracle"
    continue
  fi
  AGE=$((NOW - RA))
  MSG="$f: ${AGE}s old against a ${ST}s window"
  if [ "$AGE" -lt "$ST" ]; then
    ok "$MSG"
  elif [ "$f" = "$VFEED" ]; then
    bad "$MSG, and this is the feed the Vault reads, so get_nav fails and deposits with it"
  else
    warn "$MSG, so any read of it fails with OracleStale. Nothing live reads this feed today, and with no keeper pushing it a short window means it is stale almost always."
  fi
done < <(python3 -c "
import json
d = json.load(open('$DEP'))
f = d.get('oracleFeeds')
for k in (f if isinstance(f, dict) else f or []):
    print(k)
")

echo ""
echo "  $PASS passed, $FAIL failed, $WARN warned"
[ "$FAIL" -eq 0 ]
