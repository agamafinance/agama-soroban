#!/usr/bin/env bash
# Keep the oracle feeds answering, from their sources.
#
# This script used to repost the value each feed already held, so that the
# reading stayed inside its staleness window. Its own header said so, and the
# Stellar reviewer's finding on Tranche 2 Deliverable 2 was exactly that: "Today
# the keeper reposts the stored value." Reposting keeps a feed fresh and sources
# nothing, which is the difference between a feed that answers and a feed that
# means something.
#
# It is now a dispatcher over the three real sources, one per feed:
#
#   USDC_USD   Reflector's SEP-40 oracle        scripts/keeper-reflector.sh
#   EF_BOND    the Etherfuse bond cost API      scripts/keeper-etherfuse.sh
#   PC_NAV     an originator servicing tape     scripts/reconcile-nav.py
#
# PC_NAV is deliberately not refreshed here, and that is the one decision in
# this file worth arguing with. Its source is a tape that arrives on the
# originator's cadence rather than on a cron's, and its staleness window is
# seven days to match. There is no honest way to keep it fresh without a new
# tape: reposting the stored value was the dishonest way, and inventing a drift
# would be worse. So what this does for PC_NAV is report how much of its window
# is left and say loudly when it is running out, because a feed about to go
# stale is an operational fact and not an error to be papered over. The Vault
# stopping is the correct outcome of nobody sending a tape.
#
#   bash scripts/keeper-oracle.sh            source every feed that has a source
#   DRY=1 bash scripts/keeper-oracle.sh      read and check, submit nothing
set -uo pipefail
cd "$(dirname "$0")/.."
NET=${NET:-testnet}
SRC=${SRC:-agama-poc}
DEP=deployments/testnet.json
j() { python3 -c "import json;print(json.load(open('$DEP'))$1)"; }
ORACLE=$(j "['contracts']['oracleAdapter']")
rd() { stellar contract invoke --id "$1" --source "$SRC" --network "$NET" --send=no -- "${@:2}" 2>&1 | tail -1; }

RC=0

echo "== USDC_USD, from Reflector"
bash scripts/keeper-reflector.sh 2>&1 | sed 's/^/  /' || RC=1

echo
echo "== EF_BOND, from Etherfuse"
bash scripts/keeper-etherfuse.sh 2>&1 | sed 's/^/  /' || RC=1

echo
echo "== PC_NAV, from a servicing tape"
FEED=$(rd "$ORACLE" get_feed --feed_id PC_NAV)
POINT=$(rd "$ORACLE" last_update --feed_id PC_NAV)
WINDOW=$(printf '%s' "$FEED"  | python3 -c "import json,sys;print(json.load(sys.stdin)['staleness_secs'])")
TS=$(printf '%s' "$POINT"     | python3 -c "import json,sys;print(json.load(sys.stdin)['timestamp'])")
NAV=$(printf '%s' "$POINT"    | python3 -c "import json,sys;print(json.load(sys.stdin)['nav'])")
NOW=$(date -u +%s)
AGE=$(( NOW - TS ))
LEFT=$(( WINDOW - AGE ))
printf '  the stored NAV is %s, pushed %sh ago, %sh of its %sh window left\n' \
  "$NAV" "$(( AGE / 3600 ))" "$(( LEFT / 3600 ))" "$(( WINDOW / 3600 ))"
if [ "$LEFT" -le 0 ]; then
  echo "  STALE  get_nav answers OracleStale and the Vault has stopped pricing its book."
  echo "         The fix is a tape, not a push:"
  echo "           bash scripts/e2e-reconciliation.sh"
  RC=1
elif [ "$LEFT" -lt 86400 ]; then
  echo "  WARN   less than a day left. A new tape is due."
  echo "           python3 scripts/reconcile-nav.py data/servicing/<tape>.csv"
  echo "           bash scripts/e2e-reconciliation.sh"
else
  echo "  the window is comfortable. Nothing is reposted: a feed is refreshed by"
  echo "  a new tape and by nothing else."
fi

echo
[ "$RC" -eq 0 ] && echo "every feed with a source was sourced" || echo "at least one feed could not be sourced, see above"
exit $RC
