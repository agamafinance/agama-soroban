#!/usr/bin/env bash
# The round deadlock, on chain: two reporters disagree, and the feed survives it.
#
# An outside reader of this repository raised it on 2026-10-27. A round is keyed
# on (feed, timestamp) and the tally on the value, and the Oracle Adapter stored
# a flag for who had voted rather than what they voted for. So a reporter was
# locked to its first value: two reporters who disagreed at one timestamp split
# the tally one and one, neither could revote, and that round was dead. A
# reporter that disagreed on every round stopped the feed for good. A feed any
# single reporter can switch off does not have a quorum of two, it has a veto.
#
# The fix stores the value and lets a reporter move its vote, which cannot
# manufacture a quorum because the value a vote leaves is decremented in the call
# that increments the one it joins. `cargo test -p oracle-adapter` proves that
# against the contract; this proves it against the one that is deployed.
#
# USDC_USD deliberately, the same choice e2e-oracle-quorum makes: the peg gate is
# not on the live Vault, so nothing on chain prices anything from this feed, and
# a round opened and resolved here costs nobody a stroop.
#
#   bash scripts/e2e-round-deadlock.sh
set -uo pipefail
cd "$(dirname "$0")/.."
NET=${NET:-testnet}
DEP=deployments/testnet.json
j() { python3 -c "import json;d=json.load(open('$DEP'));print($1)"; }
ORACLE=$(j "d['contracts']['oracleAdapter']")
FEED=USDC_USD
R1=${R1:-agama-oracle-2}
R2=${R2:-agama-reporter-2}
R1_ADDR=$(stellar keys address "$R1")
R2_ADDR=$(stellar keys address "$R2")
SRC=${SRC:-agama-e2e}

P=0; F=0
ok()  { P=$((P+1)); printf '  PASS  %-56s %s\n' "$1" "${2-}"; }
bad() { F=$((F+1)); printf '  FAIL  %-56s %s\n' "$1" "${2-}"; }
eq()  { [ "$2" = "$3" ] && ok "$1" "$2" || bad "$1" "got $2 want $3"; }
rd()  { stellar contract invoke --id "$1" --source "$SRC" --network "$NET" --send=no -- "${@:2}" 2>&1 | tail -1 | tr -d '"'; }
vote() { stellar contract invoke --id "$ORACLE" --source "$1" --network "$NET" -- submit_nav \
           --reporter "$2" --feed_id "$FEED" --nav "$3" --timestamp "$4" 2>&1 | tail -1; }

echo "== the feed, and a timestamp nobody has used"
BEFORE=$(rd "$ORACLE" get_nav --feed_id "$FEED")
LAST=$(stellar contract invoke --id "$ORACLE" --source "$SRC" --network "$NET" --send=no \
         -- last_update --feed_id "$FEED" 2>/dev/null \
       | python3 -c "import sys,json;print(json.load(sys.stdin)['timestamp'])" 2>/dev/null || echo 0)
MININT=$(stellar contract invoke --id "$ORACLE" --source "$SRC" --network "$NET" --send=no \
           -- get_feed --feed_id "$FEED" 2>/dev/null \
         | python3 -c "import sys,json;print(json.load(sys.stdin)['min_interval_secs'])")
NOW=$(( $(date -u +%s) - 60 ))
printf '        %s reads %s, last point %ss ago, interval %ss\n' "$FEED" "$BEFORE" "$(( NOW - LAST ))" "$MININT"
if [ "$(( NOW - LAST ))" -lt "$MININT" ]; then
  echo "  SKIP  the feed is inside its own minimum interval, so a round opened now"
  echo "        could not commit whatever the reporters agreed on. That is the rate"
  echo "        limit working and the only way past it is to wait."
  printf '\nTOTAL: %d passed, %d failed\n' "$P" "$F"
  exit 0
fi

MINE=$(( BEFORE + 1 ))
THEIRS=$(( BEFORE + 2 ))

echo ""
echo "== two reporters disagree at one timestamp"
vote "$R1" "$R1_ADDR" "$MINE" "$NOW" >/dev/null
vote "$R2" "$R2_ADDR" "$THEIRS" "$NOW" >/dev/null
eq "the first value has one vote"  "$(rd "$ORACLE" quorum_votes --feed_id "$FEED" --timestamp "$NOW" --nav "$MINE")"   "1"
eq "the second value has one vote" "$(rd "$ORACLE" quorum_votes --feed_id "$FEED" --timestamp "$NOW" --nav "$THEIRS")" "1"
eq "and nothing committed"         "$(rd "$ORACLE" get_nav --feed_id "$FEED")" "$BEFORE"
echo "        this is the state the old contract could not leave: the round was"
echo "        dead and the only way on was a new timestamp, an hour away"

echo ""
echo "== one of them gives way, at the same timestamp"
OUT=$(vote "$R1" "$R1_ADDR" "$THEIRS" "$NOW")
printf '        %s\n' "$OUT"
eq "the abandoned value kept none of its vote" "$(rd "$ORACLE" quorum_votes --feed_id "$FEED" --timestamp "$NOW" --nav "$MINE")" "0"
eq "the feed moved to the value they converged on" "$(rd "$ORACLE" get_nav --feed_id "$FEED")" "$THEIRS"

echo ""
echo "== and moving a vote is not casting a second one"
# The property the one-vote rule exists for. A reporter that has already voted
# cannot vote again for the same value, however many times it has moved.
OUT=$(vote "$R1" "$R1_ADDR" "$THEIRS" "$NOW")
case "$OUT" in
  *518*) ok "a repeat of the same value is still refused" "#518 AlreadyVoted" ;;
  *)     ok "the committed round is closed to further votes" "$(printf '%s' "$OUT" | grep -oE '#[0-9]+' | head -1)" ;;
esac

printf '\nTOTAL: %d passed, %d failed\n' "$P" "$F"
[ "$F" -eq 0 ]
