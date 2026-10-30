#!/usr/bin/env bash
# Deliver the yield the oracle says the credit book earned, rather than a number
# somebody picked, and compute it pool by pool against the feed each pool is
# actually priced from.
#
# The Tranche 2 criterion is that yield distribution to sagUSD is driven by
# oracle data. The demo loop (distribute-yield-loop.sh) delivers a constant and
# says so in its own header, which proves the plumbing and not the criterion.
#
# This computes the amount instead, and the way it computes it is the part that
# was wrong. It used to be
#
#   yield = deployed capital x (PC_NAV now / PC_NAV at the last distribution - 1)
#
# which applies the private credit NAV move to every dollar the Vault has
# deployed, including the dollars sitting in a Stablebond whose price PC_NAV
# says nothing about. The run of 26 October 2026 paid 36,357,814 stroops on
# 1,210 USDC deployed at a PC_NAV move of 0.30047%, and only the pools priced
# from PC_NAV were entitled to it. It is now
#
#   yield = sum over feeds of ( exposure priced from that feed
#                               x (feed now / feed at the last distribution - 1) )
#
# where each pool names its own feed: the adapters answer `oracle_feed()`, so
# the mapping is read off the deployed contracts rather than assumed here. A
# pool whose feed has not moved contributes nothing, and a pool whose feed has
# fallen contributes nothing either: a loss is a `write_down`, not a negative
# distribution, and the two go through different entry points on purpose. The
# fall is printed so it is not silently dropped.
#
# Every feed is read through the Oracle Adapter's own `get_nav`, so a stale feed
# stops this keeper exactly where it stops the Vault: OracleStale propagates and
# nothing is distributed, for any pool, not just the stale one. Partial
# distribution on a partially readable book would move the share price on a
# number nobody can reconcile afterwards.
#
# The per-feed readings are recorded in state/yield-nav.json, so the next run
# measures from the last distribution rather than from deployment.
#
# distribute_yield still requires the agUSD to be transferred, so this cannot
# overstate the book: an oracle that doubles overnight asks the strategist for
# agUSD they must actually hold, and the call fails if they do not.
#
#   bash scripts/keeper-yield.sh            compute and distribute
#   DRY=1 bash scripts/keeper-yield.sh      compute and print, send nothing
set -uo pipefail
cd "$(dirname "$0")/.."
NET=${NET:-testnet}
SRC=${SRC:-agama-poc}
DEP=deployments/testnet.json
STATE=state/yield-nav.json
j() { python3 -c "import json;print(json.load(open('$DEP'))$1)"; }
VAULT=$(j "['contracts']['vault']")
STAKING=$(j "['contracts']['staking']")
AGUSD=$(j "['contracts']['agusd']")
ENGINE=$(j "['contracts']['allocationEngine']")
ORACLE=$(j "['contracts']['oracleAdapter']")
ADMIN=$(j "['admin']")

rd(){ stellar contract invoke --id "$1" --source "$SRC" --network "$NET" --send=no -- "${@:2}" 2>&1 | tail -1; }
num(){ rd "$@" | tr -d '"'; }

mkdir -p state

# The book, pool by pool, as the Engine holds it. Not deployed_capital: that is
# one number for a book made of positions with different prices.
EXPOSURES=$(rd "$ENGINE" get_exposures)
case "$EXPOSURES" in
  *'{'*) : ;;
  *) echo "the Engine would not report its exposure map: $EXPOSURES"; exit 1;;
esac

# Each pool names the feed it is priced from, so the grouping below is the
# deployed contracts' own answer and not an assumption made in this script.
POOLS=$(python3 -c "
import json,sys
m=json.loads('''$EXPOSURES''')
for k,v in m.items(): print(k, v)
" 2>/dev/null)
if [ -z "$POOLS" ]; then echo "no pool is registered on the Engine, nothing to distribute"; exit 0; fi

declare -a FEEDS=()
BREAKDOWN=""
while read -r pool exposure; do
  [ -z "$pool" ] && continue
  feed=$(num "$pool" oracle_feed)
  case "$feed" in (""|*[!A-Za-z0-9_]*) echo "pool $pool would not name its feed: $feed"; exit 1;; esac
  BREAKDOWN="$BREAKDOWN$pool $feed $exposure"$'\n'
  FEEDS+=("$feed")
done <<< "$POOLS"

# One read per distinct feed, through the Adapter that enforces staleness.
NAVS=""
for feed in $(printf '%s\n' "${FEEDS[@]}" | sort -u); do
  nav=$(num "$ORACLE" get_nav --feed_id "$feed")
  case "$nav" in (*[!0-9]*|"") echo "the Oracle Adapter would not price $feed: $nav"; exit 1;; esac
  NAVS="$NAVS$feed $nav"$'\n'
done

# Last readings, per feed. A state file from before this change holds a single
# `nav` key, which was PC_NAV: it is migrated rather than discarded, so the
# first run after this fix measures from the last distribution that actually
# happened and not from today.
PLAN=$(BREAKDOWN="$BREAKDOWN" NAVS="$NAVS" python3 - "$STATE" <<'PY'
import json, os, sys
state_path = sys.argv[1]
breakdown = [l.split() for l in os.environ['BREAKDOWN'].strip().splitlines() if l.strip()]
navs = {l.split()[0]: int(l.split()[1]) for l in os.environ['NAVS'].strip().splitlines() if l.strip()}
last = {}
if os.path.exists(state_path):
    raw = json.load(open(state_path))
    last = dict(raw.get('feeds') or {})
    if 'nav' in raw and 'PC_NAV' not in last:
        last['PC_NAV'] = raw['nav']
by_feed = {}
for pool, feed, exposure in breakdown:
    by_feed[feed] = by_feed.get(feed, 0) + int(exposure)
total = 0
lines = []
for feed in sorted(by_feed):
    now, exposure = navs[feed], by_feed[feed]
    before = last.get(feed)
    # A feed with no prior reading is not a flat feed. Measuring from the
    # deployment would hand out every basis point the book has ever earned in
    # one distribution, so the first run records the level and pays nothing,
    # and says which of the two happened.
    if not before or before <= 0:
        lines.append(f"  {feed:<10} exposure {exposure:>14}  first reading at {now}, nothing to measure from yet")
        continue
    moved = now - before
    amount = exposure * moved // before
    if amount > 0:
        total += amount
        lines.append(f"  {feed:<10} exposure {exposure:>14}  {before} -> {now}  yield {amount}")
    elif moved < 0:
        lines.append(f"  {feed:<10} exposure {exposure:>14}  {before} -> {now}  FELL by {-amount}, not distributed: a loss is a write_down")
    else:
        lines.append(f"  {feed:<10} exposure {exposure:>14}  flat at {now}")
print(json.dumps({'total': total, 'lines': lines, 'feeds': navs,
                  'pools': [{'pool': p, 'feed': f, 'exposure': int(x)} for p, f, x in breakdown]}))
PY
)
AMOUNT=$(printf '%s' "$PLAN" | python3 -c "import json,sys;print(json.load(sys.stdin)['total'])")
printf '%s' "$PLAN" | python3 -c "
import json,sys
for l in json.load(sys.stdin)['lines']: print(l)
"
echo "  total $AMOUNT"

if [ "${DRY:-0}" = "1" ]; then echo "dry run, nothing sent"; exit 0; fi

save_state() {
  printf '%s' "$PLAN" | python3 -c "
import json,sys
p=json.load(sys.stdin)
json.dump({'feeds': p['feeds'], 'pools': p['pools']}, open('$STATE','w'), indent=1)
"
}

if [ "$AMOUNT" -le 0 ]; then
  echo "no feed has risen since the last distribution, nothing to deliver"
  save_state
  exit 0
fi

BAL=$(num "$AGUSD" balance --id "$ADMIN")
if [ "$BAL" -lt "$AMOUNT" ]; then
  echo "the strategist holds $BAL agUSD and owes $AMOUNT: nothing distributed"
  exit 1
fi

# What the submission says this keeper proves is that the share price moves and
# no share is minted. Read both sides here rather than printing the rate
# afterwards and comparing it to nothing.
RATE_BEFORE=$(num "$STAKING" exchange_rate)
SHARES_BEFORE=$(num "$STAKING" total_shares)

# distribute_yield takes the amount only: the contract reads its own admin and
# pulls the agUSD from them, which is what stops this keeper inventing yield.
OUT=$(stellar contract invoke --id "$STAKING" --source "$SRC" --network "$NET" -- \
        distribute_yield --amount "$AMOUNT" 2>&1)
STATUS=$?
printf '%s\n' "$OUT" | tail -2
# The readings only advance when the distribution landed. Writing them either
# way is how a failed call quietly becomes yield nobody ever delivered: the next
# run would measure from a NAV that was never paid for.
if [ "$STATUS" -ne 0 ] || printf '%s' "$OUT" | grep -q "Error(Contract"; then
  echo "nothing was distributed, the recorded readings stay where they were"
  exit 1
fi
save_state

RATE_AFTER=$(num "$STAKING" exchange_rate)
SHARES_AFTER=$(num "$STAKING" total_shares)
echo "  rate  $RATE_BEFORE -> $RATE_AFTER"
echo "  share $SHARES_BEFORE -> $SHARES_AFTER"
BAD=0
if [ "$RATE_AFTER" -le "$RATE_BEFORE" ]; then
  echo "  FAIL  the share price did not move, which is what a distribution is for"
  BAD=1
else
  echo "  PASS  the share price rose with the distribution"
fi
if [ "$SHARES_AFTER" != "$SHARES_BEFORE" ]; then
  echo "  FAIL  the share count moved: a distribution must mint nothing"
  BAD=1
else
  echo "  PASS  no share was minted"
fi
exit $BAD
