#!/usr/bin/env bash
# Is a feed inside its minimum interval, so a push now is refused?
#
# Each feed carries a minimum interval between accepted values, an hour on the
# two NAV feeds here. A suite that pushes within the hour of another suite's
# push has its value refused, the stored value does not move, and the assertions
# that read it back compare against the previous value. That is the rate limit
# working, and it used to read as three assertion failures saying the oracle did
# not store what it was given.
#
# Suites use this to say which it is instead of failing. It is the single
# largest reason these scripts could not be run one after another, and it is not
# something a script can work around: waiting is the only way past a guard whose
# whole purpose is to make callers wait.
#
# The interval is read off the feed, not assumed. It used to default to 3600 for
# every feed, and USDC_USD runs at 300, so a feed that was five minutes past its
# own limit and ready to take a value was reported as rate limited and skipped.
# A guard that reports itself as firing when it is not is worse than no guard:
# the push path under it went unexercised, and that is where a stale $ADMIN
# signature sat unnoticed after the admin stopped being a reporter.
#
#   feed_is_rate_limited <oracle_id> <feed_id> <source> <network> [interval]
#     0  yes, inside the interval; the elapsed seconds are printed
#     1  no, a push will be considered
#
# The fifth argument overrides the feed's own number, for a caller that wants a
# margin over it. It is not a substitute for it.
feed_is_rate_limited() {
  local ORACLE=$1 FEED=$2 SRC=$3 NET=$4 INTERVAL=${5:-}
  local last now
  if [ -z "$INTERVAL" ]; then
    INTERVAL=$(stellar contract invoke --id "$ORACLE" --source "$SRC" --network "$NET" --send=no \
                 -- get_feed --feed_id "$FEED" 2>/dev/null \
               | python3 -c "import sys,json;print(json.load(sys.stdin)['min_interval_secs'])" 2>/dev/null \
               || echo "")
    case "${INTERVAL:-}" in (""|*[!0-9]*) INTERVAL=3600;; esac
  fi
  # Published so a caller can name the real number in its own message. Two
  # suites printed "its minimum interval is 3600s" for every feed, which was
  # wrong for USDC_USD on each of them.
  FEED_INTERVAL=$INTERVAL
  last=$(stellar contract invoke --id "$ORACLE" --source "$SRC" --network "$NET" --send=no \
           -- last_update --feed_id "$FEED" 2>/dev/null \
         | python3 -c "import sys,json;print(json.load(sys.stdin).get('recorded_at',0))" 2>/dev/null || echo 0)
  now=$(date -u +%s)
  if [ "${last:-0}" != "0" ] && [ $((now - last)) -lt "$INTERVAL" ]; then
    echo "$((now - last))"
    return 0
  fi
  return 1
}
