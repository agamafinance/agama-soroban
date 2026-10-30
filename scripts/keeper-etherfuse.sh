#!/usr/bin/env bash
# Source the EF_BOND feed from Etherfuse, rather than reposting the value
# already stored.
#
# Tranche 2, Deliverable 2 of the SCF #45 award describes this feed as
# "Etherfuse Stablebond pricing uses the Etherfuse feed with a 48-hour staleness
# threshold and no deviation bound, since that NAV is deterministic". The
# Stellar reviewer's finding was that it was not sourced from Etherfuse and that
# nothing on chain read it. The adapter's oracle_value is the read. This is the
# source.
#
# Which bond. USTRY, the US Treasury stablebond, because this protocol's base
# asset is a dollar. CETES is the same instrument denominated in pesos and
# carries an FX leg that would put MXN/USD risk inside a USD NAV, which is a
# different product and not this one.
#
# The deviation bound being zero is the reason this script is careful. Our
# Oracle Adapter is told that this feed is deterministic, so it will accept any
# move the band allows: there is no second line of defence on our side, and the
# quality of the number is entirely the quality of its sourcing. So the checks
# that would normally live in the Adapter live here instead, and they are three:
#
#   1. Etherfuse's own clock, against our tolerance
#   2. each independent source's updated_at, counting only the recent ones
#   3. agreement between those sources, around their median
#
# A single source that has drifted is what a zero deviation bound cannot catch.
#
#   bash scripts/keeper-etherfuse.sh            read, check, submit
#   DRY=1 bash scripts/keeper-etherfuse.sh      read and check, submit nothing
#   BOND=CETES bash scripts/keeper-etherfuse.sh for the peso bond, deliberately
set -uo pipefail
cd "$(dirname "$0")/.."
NET=${NET:-testnet}
SRC=${SRC:-agama-poc}
REPORTER2_KEY=${REPORTER2_KEY:-agama-oracle-2}
BOND=${BOND:-USTRY}
MAX_AGE=${MAX_AGE:-900}          # a source older than this does not count
MIN_SOURCES=${MIN_SOURCES:-3}    # how many recent ones are needed
SPREAD_BPS=${SPREAD_BPS:-50}     # how far from the median each may sit
DEP=deployments/testnet.json

j() { python3 -c "import json;print(json.load(open('$DEP'))$1)"; }
ORACLE=$(j "['contracts']['oracleAdapter']")
ADMIN=$(j "['admin']")
REPORTER2=$(stellar keys address "$REPORTER2_KEY")
rd() { stellar contract invoke --id "$1" --source "$SRC" --network "$NET" --send=no -- "${@:2}" 2>&1 | tail -1; }

echo "== 1. Etherfuse, $BOND"
BODY=$(curl -s --max-time 25 "https://api.etherfuse.com/lookup/bonds/cost/$BOND")
case "$BODY" in (*bond_cost_in_usd*) : ;; (*) echo "   Etherfuse would not quote $BOND: ${BODY:0:200}"; exit 1;; esac

REPORT=$(BODY="$BODY" MAX_AGE="$MAX_AGE" MIN_SOURCES="$MIN_SOURCES" SPREAD_BPS="$SPREAD_BPS" python3 - <<'PY'
import json, os, statistics, time
d = json.loads(os.environ['BODY'])
max_age = int(os.environ['MAX_AGE']); need = int(os.environ['MIN_SOURCES'])
spread = int(os.environ['SPREAD_BPS'])
now = int(time.time())

headline = float(d['bond_cost_in_usd'])
srcs = d.get('sources') or {}
recent = {k: v for k, v in srcs.items()
          if now - int(v['updated_at']) <= max_age and float(v['bond_cost_in_usd']) > 0}
prices = sorted(float(v['bond_cost_in_usd']) for v in recent.values())

out = {
    'symbol': d.get('bond_symbol'), 'currency': d.get('currency'),
    'headline': headline, 'basis_points': d.get('current_basis_points'),
    'sources_total': len(srcs), 'sources_recent': len(recent),
    'ages': sorted(now - int(v['updated_at']) for v in srcs.values()),
    'prices': prices, 'ok': True, 'why': [],
}
if d.get('currency') != 'USD':
    out['ok'] = False
    out['why'].append(f"denominated in {d.get('currency')}, not USD: that is an FX leg, not a bond price")
if len(recent) < need:
    out['ok'] = False
    out['why'].append(f"only {len(recent)} of {len(srcs)} sources are inside {max_age}s, {need} needed")
if prices:
    med = statistics.median(prices)
    out['median'] = med
    worst = max(abs(p - med) / med * 10_000 for p in prices)
    out['worst_bps'] = round(worst, 2)
    if worst > spread:
        out['ok'] = False
        out['why'].append(f"sources disagree by {worst:.1f} bps, the limit is {spread}")
    out['nav'] = int(round(med * 10_000_000))
print(json.dumps(out))
PY
)
printf '%s' "$REPORT" | python3 -c "
import json,sys
r=json.load(sys.stdin)
print(f\"   {r['symbol']} in {r['currency']}, headline {r['headline']}, yield {r['basis_points']} bps\")
print(f\"   sources {r['sources_recent']} recent of {r['sources_total']}, ages {r['ages'][:6]}s\")
if 'median' in r:
    print(f\"   median {r['median']}, worst source is {r['worst_bps']} bps from it\")
for w in r['why']: print(f'   REFUSED {w}')
"
OK=$(printf '%s' "$REPORT" | python3 -c "import json,sys;print(json.load(sys.stdin)['ok'])")
if [ "$OK" != "True" ]; then
  echo "   STOP  the sourcing did not pass its own checks, nothing is submitted."
  echo "         EF_BOND is registered with a zero deviation bound, so the"
  echo "         Adapter would have accepted whatever this handed it."
  exit 1
fi
NAV=$(printf '%s' "$REPORT" | python3 -c "import json,sys;print(json.load(sys.stdin)['nav'])")

echo "== 2. rescale and compare"
printf '   %s USD per unit  ->  %s at 7 decimals\n' "$(printf '%s' "$REPORT" | python3 -c "import json,sys;print(json.load(sys.stdin)['median'])")" "$NAV"
STORED=$(rd "$ORACLE" get_nav --feed_id EF_BOND | tr -d '"')
printf '   our feed currently reads %s\n' "$STORED"
MOVE=$(python3 -c "print(abs($NAV - $STORED) * 10000 // $STORED)")
printf '   a %s bps move\n' "$MOVE"

if [ "${DRY:-0}" = "1" ]; then echo "dry run, nothing submitted"; exit 0; fi

echo "== 3. submit, once per reporter"
# Our own feed takes one point per interval. Checking it here rather than
# letting the Adapter refuse the second vote matters: the first vote lands and
# stays pending, so a keeper that submits blind leaves a half-finished round
# behind every time it runs too soon.
MININT=$(rd "$ORACLE" get_feed --feed_id EF_BOND | python3 -c "import json,sys;print(json.load(sys.stdin)['min_interval_secs'])")
LASTTS=$(rd "$ORACLE" last_update --feed_id EF_BOND | python3 -c "import json,sys;print(json.load(sys.stdin)['timestamp'])")
NOW2=$(date -u +%s)
if [ $(( NOW2 - LASTTS )) -lt "$MININT" ]; then
  printf '   SKIP  the last accepted point is %ss old and this feed takes one per %ss.\n' \
    "$(( NOW2 - LASTTS ))" "$MININT"
  printf '         Nothing submitted. Try again in %ss.\n' "$(( MININT - (NOW2 - LASTTS) ))"
  exit 0
fi

TS=$(date -u +%s)
V1=$(stellar contract invoke --id "$ORACLE" --source "$SRC" --network "$NET" -- \
       submit_nav --reporter "$ADMIN" --feed_id EF_BOND --nav "$NAV" --timestamp "$TS" 2>&1)
printf '   reporter 1  %s\n' "$(printf '%s' "$V1" | tail -1)"
V2=$(stellar contract invoke --id "$ORACLE" --source "$REPORTER2_KEY" --network "$NET" -- \
       submit_nav --reporter "$REPORTER2" --feed_id EF_BOND --nav "$NAV" --timestamp "$TS" 2>&1)
printf '   reporter 2  %s\n' "$(printf '%s' "$V2" | tail -1)"
printf '%s' "$V2" | grep -oE "Event: Nav[A-Za-z]+" | head -2 | sed 's/^/   /'

AFTER=$(rd "$ORACLE" get_nav --feed_id EF_BOND | tr -d '"')
printf '   our feed now reads %s\n' "$AFTER"
[ "$AFTER" = "$NAV" ] && { echo "   EF_BOND is Etherfuse's number, not a repost"; exit 0; }
echo "   the Adapter did not take it, the stored value stands at $AFTER"
printf '%s' "$V2" | grep -oE "Error\(Contract, #[0-9]+\)" | head -1 | sed 's/^/   /'
exit 1
