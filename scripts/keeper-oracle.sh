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
# Every key the reporter set is made of, not just this script's own source.
# A feed whose quorum is above 1 commits nothing until that many distinct
# reporters have submitted the same value for the same timestamp, so a keeper
# that signs with one key keeps no feed fresh at all: it votes, the round stays
# open, and the feed goes stale on schedule while every run reports success.
KEYS=$(python3 -c "
import json
r = json.load(open('$DEP')).get('oracleReporters') or {}
print(' '.join(r.get('keys') or ['$SRC']))
")
# Ledger time, not this machine's clock.
#
# The Adapter refuses a timestamp ahead of ledger close time with
# TimestampInFuture, 509, and a testnet ledger closes every five seconds or so,
# so `date +%s` is ahead of the chain for most of every five second window. A
# keeper reading the local clock therefore fails intermittently, for a reason
# that looks like nothing and depends on when in the window it happened to run.
ledger_now() {
  curl -s -X POST "${RPC:-https://soroban-testnet.stellar.org}" \
    -H 'Content-Type: application/json' \
    -d '{"jsonrpc":"2.0","id":1,"method":"getLatestLedger"}' \
    | python3 -c "import sys,json;print(json.load(sys.stdin)['result']['closeTime'])"
}
NOW=$(ledger_now)
[ -n "$NOW" ] || { echo "  the RPC did not answer with a ledger, nothing submitted"; exit 1; }
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
  # FORCE=1 pushes regardless of how much window is left, which is how the
  # multi-reporter path gets exercised on demand: at a quorum above 1 a run that
  # skips every feed proves nothing, and waiting half a seven day window to find
  # out whether the keeper can still commit is not a test.
  if [ "${FORCE:-0}" != "1" ] && [ "$left" -gt $(( window / 2 )) ]; then
    if [ "$left" -ge 3600 ]; then
      printf '  %-10s fresh, %sh left of a %sh window\n' "$feed" "$(( left / 3600 ))" "$(( window / 3600 ))"
    else
      printf '  %-10s fresh, %smin left of a %smin window\n' "$feed" "$(( left / 60 ))" "$(( window / 60 ))"
    fi
    fresh=$((fresh+1)); continue
  fi

  # One value, one timestamp, every key. The timestamp is computed once for the
  # whole run precisely so the submissions land in the same round: a keeper that
  # read the clock per key would open a new round with each signature and never
  # reach quorum however many reporters it had.
  votes=0; refused=""
  for key in $KEYS; do
    who=$(stellar keys address "$key" 2>/dev/null) || { refused="no such key $key"; break; }
    out=$(stellar contract invoke --id "$ORACLE" --source "$key" --network "$NET" -- \
            submit_nav --reporter "$who" --feed_id "$feed" --nav "$nav" --timestamp "$NOW" 2>&1)
    code=$(printf '%s' "$out" | grep -oE 'Error\(Contract, #[0-9]+\)' | head -1)
    if [ "$code" = "Error(Contract, #514)" ]; then
      refused="toosoon"; break
    elif [ -n "$code" ]; then
      refused="$code"; break
    fi
    votes=$((votes+1))
  done

  if [ "$refused" = "toosoon" ]; then
    printf '  %-10s too soon since the last submission, left alone\n' "$feed"; fresh=$((fresh+1))
  elif [ -n "$refused" ]; then
    printf '  %-10s REFUSED %s after %s vote(s)\n' "$feed" "$refused" "$votes"; failed=$((failed+1))
  else
    printf '  %-10s resubmitted at %s by %s reporter(s), was %sh stale of a %sh window\n' \
      "$feed" "$nav" "$votes" "$(( age / 3600 ))" "$(( window / 3600 ))"
    pushed=$((pushed+1))
  fi
done
echo "  pushed $pushed, already fresh $fresh, failed $failed"
[ "$failed" -eq 0 ]
