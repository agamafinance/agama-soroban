#!/usr/bin/env bash
# Quorum on the live Oracle Adapter: one reporter is not enough, two are.
#
# Written because the feeds ran at a threshold of 1 against a reporter set of
# one, which is a quorum in the type system and nowhere else. A single key could
# move the number the Vault prices its book from, and the only thing standing
# between a bad key and a bad NAV was the per-feed band and deviation bound.
# Those limit how wrong one push can be; they do not ask anybody to agree.
#
# What this proves, in order:
#
#   a feed's threshold is 2, read off the ledger
#   one reporter's submission returns Pending and moves nothing
#   that reporter's vote is recorded, so the round is open rather than lost
#   a second, distinct reporter on the same value and the same timestamp commits
#   a reporter cannot vote twice in one round and reach quorum alone
#
# USDC_USD is the feed used, deliberately. Nothing on-chain reads it, so a round
# driven by hand here cannot disturb the Vault's get_nav, which reads PC_NAV.
set -uo pipefail
cd "$(dirname "$0")/.."
NET=${NET:-testnet}
DEP=deployments/testnet.json
j() { python3 -c "import json;print(json.load(open('$DEP'))$1)"; }
ORACLE=$(j "['contracts']['oracleAdapter']")
FEED=USDC_USD

# macOS ships bash 3.2, which has no readarray, so this is word splitting on a
# space separated list rather than anything cleverer.
KEYS=($(python3 -c "
import json
print(' '.join(json.load(open('$DEP'))['oracleReporters']['keys']))
"))
K1=${KEYS[0]}; K2=${KEYS[1]}
A1=$(stellar keys address "$K1"); A2=$(stellar keys address "$K2")

pass=0; fail=0
ok(){ if [ "$2" = "$3" ]; then printf '  PASS  %-46s %s\n' "$1" "$2"; pass=$((pass+1));
      else printf '  FAIL  %-46s expected %s, got %s\n' "$1" "$3" "$2"; fail=$((fail+1)); fi; }

rd(){ stellar contract invoke --id "$ORACLE" --source "$K1" --network "$NET" --send=no -- "$@" 2>/dev/null | tr -d '"'; }
sub(){ # key address value timestamp -> outcome word or error code
  stellar contract invoke --id "$ORACLE" --source "$1" --network "$NET" -- \
    submit_nav --reporter "$2" --feed_id "$FEED" --nav "$3" --timestamp "$4" 2>&1 \
    | grep -oE '"[A-Za-z]+"|Error\(Contract, #[0-9]+\)' | tail -1 | tr -d '"'
}

echo "== the feed and its reporters"
ok "the feed's quorum threshold is two" "$(rd quorum_threshold --feed_id $FEED)" "2"
ok "two distinct reporters are registered" "$(rd reporters | tr -d '[]' | tr ',' '\n' | grep -c .)" "2"
ok "they are not the same address" "$([ "$A1" != "$A2" ] && echo distinct)" "distinct"

BEFORE=$(rd get_nav --feed_id $FEED)
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

# A round cannot commit until the feed's own minimum interval has elapsed since
# the last accepted value, TooSoon, 514. That guard is doing its job and is not
# something to work around, so this waits it out rather than reaching for a feed
# with a shorter one. Back to back runs therefore pause here; a first run after
# any real gap does not.
INTERVAL=$(stellar contract invoke --id "$ORACLE" --source "$K1" --network "$NET" --send=no -- \
  get_feed --feed_id $FEED 2>/dev/null \
  | python3 -c "import sys,json;print(json.load(sys.stdin)['min_interval_secs'])")
# recorded_at, not timestamp. The minimum interval is measured in ledger time
# since the last value was accepted, which is recorded_at; timestamp is what the
# reporter asserted the reading was taken at and can be earlier. Waiting against
# the wrong one of the two leaves the round short by the gap between them, which
# is however long the round took to reach quorum.
LASTTS=$(stellar contract invoke --id "$ORACLE" --source "$K1" --network "$NET" --send=no -- \
  last_update --feed_id $FEED 2>/dev/null \
  | python3 -c "import sys,json;print(json.load(sys.stdin)['recorded_at'])")
WAIT=$(( LASTTS + INTERVAL - $(ledger_now) + 5 ))
if [ "$WAIT" -gt 0 ]; then
  echo "  waiting ${WAIT}s for the feed's ${INTERVAL}s minimum interval to elapse"
  perl -e "select(undef,undef,undef,$WAIT)"
fi

TS=$(ledger_now)
VALUE=$BEFORE   # the value the feed already holds: this tests quorum, not drift
echo "  feed at $BEFORE, opening a round at timestamp $TS"

echo "== one reporter is not a quorum"
ok "the first submission is pending" "$(sub "$K1" "$A1" "$VALUE" "$TS")" "Pending"
ok "nothing committed, the feed is unchanged" "$(rd get_nav --feed_id $FEED)" "$BEFORE"
ok "the vote was recorded, not discarded" "$(rd quorum_votes --feed_id $FEED --timestamp $TS --nav $VALUE)" "1"

echo "== the same reporter cannot carry it alone"
ok "a repeat vote in the same round is refused" "$(sub "$K1" "$A1" "$VALUE" "$TS")" "Error(Contract, #518)"
ok "still one vote after the repeat" "$(rd quorum_votes --feed_id $FEED --timestamp $TS --nav $VALUE)" "1"

echo "== a second distinct reporter commits it"
ok "the second submission is accepted" "$(sub "$K2" "$A2" "$VALUE" "$TS")" "Accepted"
LAST=$(stellar contract invoke --id "$ORACLE" --source "$K1" --network "$NET" --send=no -- \
  last_update --feed_id $FEED 2>/dev/null \
  | python3 -c "import sys,json;print(json.load(sys.stdin)['timestamp'])")
ok "the feed now carries this round's timestamp" "$LAST" "$TS"
ok "and the agreed value" "$(rd get_nav --feed_id $FEED)" "$VALUE"

echo
printf '  TOTAL: %s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
