#!/usr/bin/env bash
# The staleness guard, on the live oracle rather than in a unit test.
#
# Several guards in this repository have an on-chain proof: the four allocation
# caps as failed transactions in refusals-on-ledger.sh, the quorum in
# e2e-oracle-quorum.sh. NavOutOfBand and TooSoon are shown by simulation in
# smoke-hardening.sh and not on the ledger, which that script says and this one
# used to get wrong. OracleStale did not have one either, because
# making it fire means letting a feed actually go stale, and the only feed that
# can safely go stale is the one nothing on chain reads.
#
# That feed is USDC_USD: a peg check with a one hour window, read by the app and
# by nobody in the contracts. PC_NAV, which the Vault prices its book from, is
# never the subject here, and this script does not touch it.
#
# There is no way to shorten a registered feed's window and no way to remove a
# feed, so the honest version of this test is to wait. It prints how long. If
# our keeper is running it will refresh the feed under you, so pause it first:
#
#   launchctl unload ~/Library/LaunchAgents/com.agama.oracle-keeper.plist
#   bash scripts/e2e-oracle-staleness.sh
#   launchctl load ~/Library/LaunchAgents/com.agama.oracle-keeper.plist
#
# The last line matters: the point of the guard is that a stale feed refuses to
# answer, and the point of the keeper is that the feed is not stale. Both are
# true, and leaving the keeper down is how the second stops being.
set -uo pipefail
cd "$(dirname "$0")/.."
NET=${NET:-testnet}
SRC=${SRC:-agama-poc}
FEED=${FEED:-USDC_USD}
DEP=deployments/testnet.json
j() { python3 -c "import json;print(json.load(open('$DEP'))$1)"; }
ORACLE=$(j "['contracts']['oracleAdapter']")
WINDOW=$(j "['oracleFeeds']['$FEED']['stalenessSecs']")

pass=0; fail=0
ok(){ if [ "$2" = "$3" ]; then printf '  PASS  %-46s %s\n' "$1" "$2"; pass=$((pass+1));
      else printf '  FAIL  %-46s expected %s, got %s\n' "$1" "$3" "$2"; fail=$((fail+1)); fi; }
call(){ stellar contract invoke --id "$ORACLE" --source "$SRC" --network "$NET" --send=no -- "$@" 2>&1 | tail -1; }
# A refusal is not on the last line: the CLI prints the error, then the event
# log, then a line about --help. Reading the tail of that finds nothing, which
# is how a guard that fired looks exactly like one that did not. This cost a
# run: OracleStale was reported as missing while the oracle was returning it.
sim(){ stellar contract invoke --id "$ORACLE" --source "$SRC" --network "$NET" --send=no -- "$@" 2>&1 \
         | grep -oE "Error\(Contract, #[0-9]+\)" | head -1; }

POINT=$(call last_update --feed_id "$FEED")
LU=$(printf '%s' "$POINT" | python3 -c "import sys,json;print(json.load(sys.stdin)['timestamp'])")
NAV=$(printf '%s' "$POINT" | python3 -c "import sys,json;print(json.load(sys.stdin)['nav'])")
DUE=$(( LU + WINDOW ))
printf '%s: last reported %s at %s, a %s second window, stale from %s\n' "$FEED" "$NAV" "$LU" "$WINDOW" "$DUE"

LEFT=$(( DUE - $(date +%s) + 30 ))
if [ "$LEFT" -gt 0 ]; then
  echo "== while it is inside its window it answers"
  ok "get_nav returns the reported NAV" "$(call get_nav --feed_id "$FEED" | tr -d '"')" "$NAV"
  printf '\n  waiting %s minutes for the window to close. Nothing on chain reads this feed.\n' "$(( LEFT / 60 + 1 ))"
  sleep "$LEFT"
else
  # Already past it, which is the state this leaves behind and the state you
  # find it in if the keeper is down. Asserting that it answers would be a
  # claim about a feed that cannot answer, so the run says so and goes on to
  # the part that is still true.
  printf '  already %s minutes past its window, so the first assertion is not run\n' "$(( -LEFT / 60 ))"
fi

echo "== past the window the read refuses rather than returning a stale number"
ok "get_nav is OracleStale" "$(sim get_nav --feed_id "$FEED")" "Error(Contract, #511)"
echo "== and the report itself is still there: it is the read that refuses, not the data"
STILL=$(call last_update --feed_id "$FEED" | python3 -c "import sys,json;print(json.load(sys.stdin)['nav'])" 2>/dev/null)
ok "last_update still carries the same NAV" "$STILL" "$NAV"
ok "with the same timestamp" "$(call last_update --feed_id "$FEED" | python3 -c "import sys,json;print(json.load(sys.stdin)['timestamp'])" 2>/dev/null)" "$LU"

echo ""
echo "TOTAL: $pass passed, $fail failed"
echo "Start the keeper again: launchctl load ~/Library/LaunchAgents/com.agama.oracle-keeper.plist"
[ "$fail" -eq 0 ]
