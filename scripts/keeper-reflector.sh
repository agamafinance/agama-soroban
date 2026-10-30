#!/usr/bin/env bash
# Source the USDC/USD peg feed from Reflector, rather than reposting the value
# already stored.
#
# Tranche 2, Deliverable 2 of the SCF #45 award describes this feed as "The
# Reflector USDC/USD feed", and the Stellar reviewer's finding was that it was
# not sourced from Reflector and that nothing on chain read it. The second half
# is answered by the Vault's peg gate. This is the first half.
#
# What it does, in order:
#
#   1. read lastprice(Other("USDC")) off Reflector's SEP-40 oracle on testnet
#   2. check Reflector's own timestamp against its resolution, so a stalled
#      oracle is not laundered into a fresh looking point on our feed
#   3. rescale from Reflector's 14 decimals to the 7 this protocol uses,
#      reading the decimals off the oracle rather than assuming them
#   4. submit it to the Agama Oracle Adapter once per reporter, meeting the
#      two-reporter quorum, and let the Adapter's own guards judge it
#
# Step 2 is the one that matters. A keeper that reads a stale oracle and pushes
# the number with a current timestamp has not sourced anything: it has forged a
# freshness it did not get, which is a worse failure than reposting, because
# reposting at least leaves the staleness visible in the feed's own history.
#
#   bash scripts/keeper-reflector.sh            read, check, submit
#   DRY=1 bash scripts/keeper-reflector.sh      read and check, submit nothing
set -uo pipefail
cd "$(dirname "$0")/.."
NET=${NET:-testnet}
SRC=${SRC:-agama-poc}
REPORTER2_KEY=${REPORTER2_KEY:-agama-oracle-2}
DEP=deployments/testnet.json

# Reflector's SEP-40 oracle for external CEX and DEX prices on testnet. Recorded
# in the deployment record as an external dependency rather than hardcoded here,
# so there is one place to change it and one place to read it from.
j() { python3 -c "import json;print(json.load(open('$DEP'))$1)"; }
ORACLE=$(j "['contracts']['oracleAdapter']")
ADMIN=$(j "['admin']")
REFLECTOR=$(python3 -c "
import json
d=json.load(open('$DEP'))
print((d.get('externalOracles') or {}).get('reflector',{}).get('address','CCYOZJCOPG34LLQQ7N24YXBM7LL62R7ONMZ3G6WZAAYPB5OYKOMJRN63'))")
REPORTER2=$(stellar keys address "$REPORTER2_KEY")

rd() { stellar contract invoke --id "$1" --source "$SRC" --network "$NET" --send=no -- "${@:2}" 2>&1 | tail -1; }

echo "== 1. Reflector, $REFLECTOR"
BASE=$(rd "$REFLECTOR" base)
DECS=$(rd "$REFLECTOR" decimals | tr -d '"')
RES=$(rd "$REFLECTOR" resolution | tr -d '"')
LAST=$(rd "$REFLECTOR" lastprice --asset '{"Other":"USDC"}')
case "$LAST" in (*price*) : ;; (*) echo "   Reflector would not quote USDC: $LAST"; exit 1;; esac
PRICE=$(printf '%s' "$LAST" | python3 -c "import json,sys;print(json.load(sys.stdin)['price'])")
PTS=$(printf '%s' "$LAST"   | python3 -c "import json,sys;print(json.load(sys.stdin)['timestamp'])")
printf '   base %s, %s decimals, resolution %ss\n' "$BASE" "$DECS" "$RES"
printf '   lastprice USDC  %s at %s\n' "$PRICE" "$PTS"

echo "== 2. is Reflector itself fresh"
NOW=$(date -u +%s)
AGE=$(( NOW - PTS ))
# Two resolution periods. One is too tight: the oracle publishes on a 300s
# grid, so a reading is routinely up to 300s old through no fault of anyone's.
LIMIT=$(( RES * 2 ))
printf '   the reading is %ss old, the limit is %ss (two resolution periods)\n' "$AGE" "$LIMIT"
if [ "$AGE" -gt "$LIMIT" ]; then
  echo "   STOP  Reflector has stalled. Nothing is submitted."
  echo "         Pushing this with a current timestamp would forge a freshness"
  echo "         this keeper did not get, and the Adapter cannot detect that:"
  echo "         it judges the timestamp we hand it. Leaving our feed to go"
  echo "         stale on its own is the honest failure, and the Vault stops"
  echo "         taking deposits when it does, which is the intended behaviour."
  exit 1
fi

echo "== 3. rescale to this protocol's 7 decimals"
NAV=$(python3 -c "
price, decs = $PRICE, $DECS
target = 7
print(price // (10 ** (decs - target)) if decs >= target else price * 10 ** (target - decs))")
printf '   %s at %s decimals  ->  %s at 7\n' "$PRICE" "$DECS" "$NAV"
printf '   which is %s USD per USDC\n' "$(python3 -c "print(f'{$NAV/10**7:.7f}')")"

STORED=$(rd "$ORACLE" get_nav --feed_id USDC_USD | tr -d '"')
printf '   our feed currently reads %s\n' "$STORED"

if [ "${DRY:-0}" = "1" ]; then echo "dry run, nothing submitted"; exit 0; fi

echo "== 4. submit, once per reporter"
# Our own feed takes one point per interval. Checking it here rather than
# letting the Adapter refuse the second vote matters: the first vote lands and
# stays pending, so a keeper that submits blind leaves a half-finished round
# behind every time it runs too soon.
MININT=$(rd "$ORACLE" get_feed --feed_id USDC_USD | python3 -c "import json,sys;print(json.load(sys.stdin)['min_interval_secs'])")
LASTTS=$(rd "$ORACLE" last_update --feed_id USDC_USD | python3 -c "import json,sys;print(json.load(sys.stdin)['timestamp'])")
NOW2=$(date -u +%s)
if [ $(( NOW2 - LASTTS )) -lt "$MININT" ]; then
  printf '   SKIP  the last accepted point is %ss old and this feed takes one per %ss.\n' \
    "$(( NOW2 - LASTTS ))" "$MININT"
  printf '         Nothing submitted. Try again in %ss.\n' "$(( MININT - (NOW2 - LASTTS) ))"
  exit 0
fi

# The Adapter's own guards judge it from here: a 200 bps deviation bound, a 0.9
# to 1.1 band, one point per 300s, and a one hour staleness window on reads.
# Nothing in this script second-guesses them, and nothing in it retries a
# rejection: a value Reflector published and the Adapter refused is a
# disagreement worth leaving in the ledger as nav_rejected.
TS=$NOW
V1=$(stellar contract invoke --id "$ORACLE" --source "$SRC" --network "$NET" -- \
       submit_nav --reporter "$ADMIN" --feed_id USDC_USD --nav "$NAV" --timestamp "$TS" 2>&1)
printf '   reporter 1  %s\n' "$(printf '%s' "$V1" | tail -1)"
V2=$(stellar contract invoke --id "$ORACLE" --source "$REPORTER2_KEY" --network "$NET" -- \
       submit_nav --reporter "$REPORTER2" --feed_id USDC_USD --nav "$NAV" --timestamp "$TS" 2>&1)
printf '   reporter 2  %s\n' "$(printf '%s' "$V2" | tail -1)"
printf '%s' "$V2" | grep -oE "Event: Nav[A-Za-z]+" | head -2 | sed 's/^/   /'

AFTER=$(rd "$ORACLE" get_nav --feed_id USDC_USD | tr -d '"')
printf '   our feed now reads %s\n' "$AFTER"
if [ "$AFTER" = "$NAV" ]; then
  echo "   the peg feed is Reflector's number, not a repost"
  exit 0
fi
echo "   the Adapter did not take it, and the stored value stands at $AFTER"
printf '%s' "$V2" | grep -oE "Error\(Contract, #[0-9]+\)" | head -1 | sed 's/^/   /'
exit 1
