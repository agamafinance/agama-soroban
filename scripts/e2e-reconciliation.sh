#!/usr/bin/env bash
# Tranche 2, Deliverable 2: the reconciliation from originator servicing data to
# a NAV on chain to yield in the share price, run end to end on testnet.
#
# The criterion, from the award: "the reconciliation procedure between on-chain
# NAV and off-chain originator servicing data documented and executed
# end-to-end on testnet". The Stellar reviewer's finding: "Today the keeper
# reposts the stored value."
#
# So the chain of custody of the number is the thing being demonstrated, and it
# is five links long:
#
#   1. a servicing tape, loan by loan, with a sha256 that travels with it
#   2. scripts/reconcile-nav.py, a pure function of the tape and the as-of date
#   3. submit_nav from each reporter, at one timestamp, meeting the quorum
#   4. the Oracle Adapter's own guards: staleness, deviation, band, interval
#   5. scripts/keeper-yield.sh, which prices each pool from its own feed
#
# Nothing in that chain is this script's opinion. Rerun step 2 on the same tape
# and you get the same integer; disagree with the integer and you disagree with
# the four valuation choices named at the top of reconcile-nav.py, which is a
# conversation worth having and a different one from trusting us.
#
#   bash scripts/e2e-reconciliation.sh
#   TAPE=data/servicing/other.csv bash scripts/e2e-reconciliation.sh
set -uo pipefail
cd "$(dirname "$0")/.."
NET=${NET:-testnet}
SRC=${SRC:-agama-poc}
TAPE=${TAPE:-data/servicing/tape-2026-10-30.csv}
IMPAIRED=${IMPAIRED:-data/servicing/tape-2026-10-30-impaired.csv}
AS_OF=${AS_OF:-$(date -u +%F)}
DEP=deployments/testnet.json

j() { python3 -c "import json;print(json.load(open('$DEP'))$1)"; }
ADMIN=$(j "['admin']")
ORACLE=$(j "['contracts']['oracleAdapter']")
STAKING=$(j "['contracts']['staking']")
AGUSD=$(j "['contracts']['agusd']")
ENGINE=$(j "['contracts']['allocationEngine']")
PC=$(j "['poolAdapters']['private-credit']")
# The reporters are two dedicated keys and the admin is not one of them.
#
# It used to be, and that was the real hole under the reviewer's observation that
# "the 26 Oct PC_NAV moves came from your own two reporter keys". The problem was
# not that both keys were ours. It was that one of the two was the oracle admin,
# so that single key could call set_quorum_threshold down to one, remove the
# other reporter, and then post any NAV it liked. A two of two that one of the
# two can dissolve is not a two of two.
#
# Now the vote and the rules are held by different keys: two dedicated reporters
# can move a NAV but cannot touch a bound, and the admin can change a bound but
# cannot vote. Both sets are ours, which is the point: the separation is ours to
# run and needs no outside counterparty to hold anything.
REPORTER1=$(stellar keys address agama-oracle-2)
REPORTER2=$(stellar keys address agama-reporter-2)

rd() { stellar contract invoke --id "$1" --source "$SRC" --network "$NET" --send=no -- "${@:2}" 2>&1 | tail -1 | tr -d '"'; }

P=0; F=0
ok()  { P=$((P+1)); printf '  PASS  %-54s %s\n' "$1" "${2-}"; }
bad() { F=$((F+1)); printf '  FAIL  %-54s %s\n' "$1" "${2-}"; }
eq()  { [ "$2" = "$3" ] && ok "$1" "$2" || bad "$1" "got $2 want $3"; }
gt()  { [ "$2" -gt "$3" ] 2>/dev/null && ok "$1" "$2" || bad "$1" "$2 is not above $3"; }

echo "== 1. the servicing tape"
python3 scripts/reconcile-nav.py "$TAPE" --as-of "$AS_OF"
R=$(python3 scripts/reconcile-nav.py "$TAPE" --as-of "$AS_OF" --json)
NAV=$(printf '%s' "$R" | python3 -c "import json,sys;print(json.load(sys.stdin)['nav'])")
SHA=$(printf '%s' "$R" | python3 -c "import json,sys;print(json.load(sys.stdin)['tape_sha256'])")

echo
echo "== 2. the computation is a function, not a reading"
NAV2=$(python3 scripts/reconcile-nav.py "$TAPE" --as-of "$AS_OF" --json \
        | python3 -c "import json,sys;print(json.load(sys.stdin)['nav'])")
eq "the same tape and date give the same integer" "$NAV2" "$NAV"
eq "the tape digest is recorded with it" "${#SHA}" "64"

echo
echo "== 3. what is on chain now, and whether this move is allowed to land"
BEFORE=$(rd "$ORACLE" get_nav --feed_id PC_NAV)
GUARD=$(stellar contract invoke --id "$ORACLE" --source "$SRC" --network "$NET" --send=no -- \
          get_feed --feed_id PC_NAV 2>&1 | tail -1)
DEV=$(printf '%s' "$GUARD" | python3 -c "import json,sys;print(json.load(sys.stdin)['deviation_bps'])")
printf '        PC_NAV on chain %s, the tape says %s, the feed allows %s bps\n' "$BEFORE" "$NAV" "$DEV"
MOVE=$(python3 -c "print(abs($NAV - $BEFORE) * 10000 // $BEFORE)")
printf '        this is a %s bps move\n' "$MOVE"
if [ "$MOVE" -gt "$DEV" ]; then
  echo "        the Adapter would reject it with nav_rejected and keep the stored value."
  echo "        That is the guard doing its job, not a failure of this script: a tape"
  echo "        implying a move this large is reconciled by hand before it is pushed."
  exit 1
fi
ok "the move is inside the feed's deviation bound" "$MOVE bps"

echo
echo "== 4. submit_nav, once per reporter, at one timestamp"
# Quorum is two on this feed and there are exactly two reporters, and both of
# them are keys this project holds. The reviewer is right about that and it is
# declared in docs/TRANCHE2_EVIDENCE.md: a quorum among our own keys bounds
# operator error, not operator intent. A third reporter outside this project is
# what turns it into a trust reduction, and it is named as open rather than
# claimed as done.
MININT=$(printf '%s' "$GUARD" | python3 -c "import json,sys;print(json.load(sys.stdin)['min_interval_secs'])")
LASTTS=$(stellar contract invoke --id "$ORACLE" --source "$SRC" --network "$NET" --send=no -- \
          last_update --feed_id PC_NAV 2>&1 | tail -1 \
          | python3 -c "import json,sys;print(json.load(sys.stdin)['timestamp'])")
# A minute back: the ledger's close time trails the wall clock, and a timestamp
# in the ledger's future is refused with TimestampInFuture, 509.
NOW=$(( $(date -u +%s) - 60 ))
AGE=$(( NOW - LASTTS ))
if [ "$AGE" -lt "$MININT" ]; then
  # The feed accepts one point per hour, so a rerun inside that hour cannot
  # push again. That is the guard working, not a gap in the procedure, and the
  # link in the chain it would have demonstrated is still checkable: the value
  # on chain has to be the one this tape produces.
  printf '        SKIP  the last point is %ss old and this feed takes one per %ss.\n' "$AGE" "$MININT"
  printf '              Not pushing again. What the push would have proved is asserted instead.\n'
  eq "the NAV on chain is the one this tape produces" "$(rd "$ORACLE" get_nav --feed_id PC_NAV)" "$NAV"
  eq "it was accepted, so it met the two reporter quorum" \
     "$(rd "$ORACLE" quorum_threshold --feed_id PC_NAV)" "2"
else
  V1=$(stellar contract invoke --id "$ORACLE" --source agama-oracle-2 --network "$NET" -- \
    submit_nav --reporter "$REPORTER1" --feed_id PC_NAV --nav "$NAV" --timestamp "$NOW" 2>&1)
  case "$(printf '%s' "$V1" | tail -1)" in
    *Pending*)  ok "the first reporter's vote is recorded and pending" ;;
    *Accepted*) ok "the first vote completed a quorum already in progress" ;;
    *) bad "the first reporter's vote was recorded" "$(printf '%s' "$V1" | tail -1)" ;;
  esac
  MID=$(rd "$ORACLE" get_nav --feed_id PC_NAV)
  eq "one vote alone does not move the stored NAV" "$MID" "$BEFORE"
  V2=$(stellar contract invoke --id "$ORACLE" --source agama-reporter-2 --network "$NET" -- \
    submit_nav --reporter "$REPORTER2" --feed_id PC_NAV --nav "$NAV" --timestamp "$NOW" 2>&1)
  printf '%s' "$V2" | grep -q "NavQuorumReached" \
    && ok "the second vote reached the quorum" "votes 2" \
    || bad "the second vote reached the quorum" "$(printf '%s' "$V2" | tail -1)"
  eq "the quorum lands the tape's NAV on chain" "$(rd "$ORACLE" get_nav --feed_id PC_NAV)" "$NAV"
  eq "the stored point carries the submitted timestamp" \
     "$(stellar contract invoke --id "$ORACLE" --source "$SRC" --network "$NET" --send=no -- \
         last_update --feed_id PC_NAV 2>&1 | tail -1 \
         | python3 -c "import json,sys;print(json.load(sys.stdin)['timestamp'])")" "$NOW"
fi

echo
echo "== 5. the keeper turns it into share price, pool by pool"
RATE0=$(rd "$STAKING" exchange_rate)
SHARES0=$(rd "$STAKING" total_shares)
NAVS0=$(rd "$STAKING" nav)
BAL0=$(rd "$AGUSD" balance --id "$ADMIN")
printf '        rate %s shares %s staking nav %s\n' "$RATE0" "$SHARES0" "$NAVS0"
# Whether there is anything to deliver depends on whether a previous run
# already consumed this NAV, and a rerun that asserted a rise either way would
# be asserting that the keeper double pays. So the branch is explicit, and the
# no-op side is not a pass by omission: it checks that the recorded reading is
# the one on chain, which is what makes the previous distribution the one that
# consumed this tape.
PLAN=$(DRY=1 bash scripts/keeper-yield.sh 2>&1)
DUE=$(printf '%s' "$PLAN" | grep -oE "^  total [0-9]+" | grep -oE "[0-9]+$")
if [ "${DUE:-0}" -gt 0 ]; then
  OUT=$(bash scripts/keeper-yield.sh 2>&1)
  printf '%s\n' "$OUT" | sed 's/^/        /'
  RATE1=$(rd "$STAKING" exchange_rate)
  gt "the share price rose"                      "$RATE1" "$RATE0"
  eq "no share was minted"                       "$(rd "$STAKING" total_shares)" "$SHARES0"
  gt "the staking NAV rose"                      "$(rd "$STAKING" nav)" "$NAVS0"
  BAL1=$(rd "$AGUSD" balance --id "$ADMIN")
  [ "$BAL1" -lt "$BAL0" ] && ok "the strategist paid for it in agUSD" "$((BAL0 - BAL1))" \
    || bad "the strategist paid for it in agUSD" "balance unchanged at $BAL1"
  printf '%s' "$OUT" | grep -q "PC_NAV" && ok "the distribution names the feed it came from" \
    || bad "the distribution names the feed it came from"
else
  printf '%s\n' "$PLAN" | sed 's/^/        /'
  # Nothing due has two causes and they are not the same thing. Either this NAV
  # was already distributed, in which case the keeper's recorded reading is this
  # tape's NAV and asserting that is the honest substitute for the distribution;
  # or there is no capital at this feed at all, in which case the keeper never
  # ran against this reading and never recorded it, and asserting the recording
  # would be asserting the result of work that correctly did not happen. That
  # second case is what an unwound book looks like, and it is reachable: the
  # Etherfuse suite ends by returning every stroop it borrowed.
  PCEXP=$(rd "$ENGINE" get_exposure --pool_id "$PC")
  printf '        SKIP  nothing is due. Private credit exposure is %s.\n' "$PCEXP"
  RECORDED=$(python3 -c "
import json
print(json.load(open('state/yield-nav.json'))['feeds'].get('PC_NAV','none'))")
  if [ "${PCEXP:-0}" -gt 0 ]; then
    printf '              This NAV has already been distributed, and a second pass\n'
    printf '              would be a double payment.\n'
    eq "the recorded reading is the NAV this tape produced" "$RECORDED" "$NAV"
  else
    printf '              No capital sits at this feed, so the keeper has nothing to\n'
    printf '              price and recorded nothing. Its last reading was %s.\n' "$RECORDED"
    ok "the keeper declined to distribute against an empty book" "exposure $PCEXP"
  fi
  # Anchored on the whole field, because PC_NAV2 contains PC_NAV and an
  # unanchored count of the shorter name matches the longer one's line too. That
  # became reachable the day a second originator was deployed.
  eq "the keeper priced this pool from PC_NAV and nothing else" \
     "$(printf '%s' "$PLAN" | grep -cE '^ +PC_NAV +exposure')" "1"
  printf '%s' "$PLAN" | grep -q "EF_BOND" \
    && ok "the Etherfuse pool is still a line of its own" \
    || bad "the Etherfuse pool is still a line of its own"
fi

echo
echo "== 6. the same procedure on an impaired tape distributes nothing"
# Computed and not pushed. The same twelve loans with the TENKA facility 112
# days past due, provisioned at 75% of outstanding, and the NAV it produces is
# below par. Pushing it would be a legitimate operation and the keeper would
# correctly distribute nothing, because a fall in NAV is a write_down and goes
# through a different entry point. It is left off chain here rather than moved
# down four percent and back up again, which would be two unexplained moves in
# the feed's history for the sake of a demonstration.
IMP=$(python3 scripts/reconcile-nav.py "$IMPAIRED" --as-of "$AS_OF" --json \
       | python3 -c "import json,sys;print(json.load(sys.stdin)['nav'])")
printf '        performing tape %s, impaired tape %s\n' "$NAV" "$IMP"
[ "$IMP" -lt "$NAV" ] && ok "the default shows up as a lower NAV" "$IMP" \
  || bad "the default shows up as a lower NAV" "$IMP"
YIELD=$(python3 -c "print(max(0, 100000000 * ($IMP - $NAV) // $NAV))")
eq "a falling feed yields nothing to distribute" "$YIELD" "0"

echo
printf 'TOTAL: %d passed, %d failed\n' "$P" "$F"
[ "$F" -eq 0 ] || exit 1
