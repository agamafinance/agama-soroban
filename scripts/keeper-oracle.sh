#!/usr/bin/env bash
# Keep the oracle feeds answering.
#
# A feed is only as useful as it is recent. Each carries its own staleness
# window, and once a reading is older than that window `get_nav` stops returning
# a number and answers OracleStale. There was no keeper, so all three feeds were
# pushed once on 3 October and left: USDC_USD went stale an hour later, EF_BOND
# after two days, and PC_NAV, the only one anything on chain reads, was four
# days into a seven day window when this was written.
#
# What this pushes, and what it refuses to invent. There is no real private
# credit NAV source on testnet, so the honest value to resubmit is the one the
# feed already holds. That says "no new information", which is true, rather than
# inventing a drift that would read as yield nobody earned. Only the timestamp
# moves. A real reporter replaces this; until then the Adapter's own deviation
# and bound checks are what keep either of us honest.
#
# A run too soon after the last submission is refused with TooSoon, 514. That is
# not a failure: it means the feed is fresher than this keeper needs to be.
set -uo pipefail
cd "$(dirname "$0")/.."
NET=${NET:-testnet}
SRC=${SRC:-agama-poc}
DEP=deployments/testnet.json
j() { python3 -c "import json;print(json.load(open('$DEP'))$1)"; }
ORACLE=$(j "['contracts']['oracleAdapter']")
REPORTER=$(stellar keys address "$SRC")
NOW=$(date +%s)
inv() { stellar contract invoke --id "$ORACLE" --source "$SRC" --network "$NET" "$@" 2>/dev/null; }

feeds=$(python3 -c "
import json
f = json.load(open('$DEP')).get('oracleFeeds')
print(' '.join(f.keys() if isinstance(f, dict) else (f or [])))
")
[ -n "$feeds" ] || { echo "no feeds in the record"; exit 1; }

pushed=0; fresh=0; failed=0
for feed in $feeds; do
  last=$(inv --send=no -- last_update --feed_id "$feed")
  cfg=$(inv --send=no -- get_feed --feed_id "$feed")
  read -r nav ts window interval <<EOF
$(printf '%s\n%s' "$last" "$cfg" | python3 -c "
import sys, json
lines = sys.stdin.read().strip().split('\n')
try:
    l = json.loads(lines[0]); c = json.loads(lines[1])
except Exception:
    print('', '', '', ''); raise SystemExit
print(l.get('nav', ''), l.get('timestamp', 0), c.get('staleness_secs', 0), c.get('min_interval_secs', 0))
")
EOF
  if [ -z "${nav:-}" ]; then
    printf '  %-10s no readable last value, skipped\n' "$feed"; failed=$((failed+1)); continue
  fi

  age=$(( NOW - ts ))
  left=$(( window - age ))
  # Resubmit once half the window is gone, not at the deadline, so a missed run
  # is not an outage. Half rather than a quarter because of USDC_USD: its window
  # is an hour, and a quarter of it is fifteen minutes, which a keeper running
  # every ten would still have skipped right up to the edge. Each feed's minimum
  # interval is well under half its window, so none of these can refuse for
  # being too soon.
  if [ "$left" -gt $(( window / 2 )) ]; then
    if [ "$left" -ge 3600 ]; then
      printf '  %-10s fresh, %sh left of a %sh window\n' "$feed" "$(( left / 3600 ))" "$(( window / 3600 ))"
    else
      printf '  %-10s fresh, %smin left of a %smin window\n' "$feed" "$(( left / 60 ))" "$(( window / 60 ))"
    fi
    fresh=$((fresh+1)); continue
  fi

  out=$(stellar contract invoke --id "$ORACLE" --source "$SRC" --network "$NET" -- \
          submit_nav --reporter "$REPORTER" --feed_id "$feed" --nav "$nav" --timestamp "$NOW" 2>&1)
  code=$(printf '%s' "$out" | grep -oE 'Error\(Contract, #[0-9]+\)' | head -1)
  if [ "$code" = "Error(Contract, #514)" ]; then
    printf '  %-10s too soon since the last submission, left alone\n' "$feed"; fresh=$((fresh+1))
  elif [ -n "$code" ]; then
    printf '  %-10s REFUSED %s\n' "$feed" "$code"; failed=$((failed+1))
  else
    printf '  %-10s resubmitted at %s, was %sh stale of a %sh window\n' \
      "$feed" "$nav" "$(( age / 3600 ))" "$(( window / 3600 ))"
    pushed=$((pushed+1))
  fi
done
echo "  pushed $pushed, already fresh $fresh, failed $failed"
[ "$failed" -eq 0 ]
