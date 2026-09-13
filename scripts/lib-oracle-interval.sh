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
#   feed_is_rate_limited <oracle_id> <feed_id> <source> <network> [interval]
#     0  yes, inside the interval; the elapsed seconds are printed
#     1  no, a push will be considered
feed_is_rate_limited() {
  local ORACLE=$1 FEED=$2 SRC=$3 NET=$4 INTERVAL=${5:-3600}
  local last now
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
