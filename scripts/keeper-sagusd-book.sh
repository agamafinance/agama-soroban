#!/usr/bin/env bash
# Re-quote the sagUSD orderbook off the share price.
#
# A pool re-prices itself: the formula moves as the reserves move, so nobody has
# to do anything. An orderbook does not. An offer is a fixed price somebody
# wrote down, and it stays written down after the price it was right about has
# moved. For sagUSD that is not a risk, it is a certainty: the share price only
# ever rises, so an ask left alone is an ask that gets cheaper every time yield
# is distributed, until somebody takes it and the difference comes out of us.
#
# This is what a market maker does, which is the thing an AMM charges 30 bps to
# do automatically. Running it is the cost of the orderbook's zero fee.
#
# What makes it cheap here is that there is nothing to discover. The fair price
# of a share is a contract read, exchange_rate, so this does not have to form a
# view about anything. It reads, applies a spread, and replaces its own offers
# by id so they are updated rather than stacked.
#
#   bash scripts/keeper-sagusd-book.sh [--once]
set -euo pipefail
cd "$(dirname "$0")/.."
NET=${NET:-testnet}
SRC=${SRC:-agama-poc}
SPREAD_BPS=${SPREAD_BPS:-10}
SIZE=${SIZE:-1000000000}          # 100 sagUSD a side
STATE=${STATE:-/tmp/agama-sagusd-book.json}
DEP=deployments/testnet.json
j() { python3 -c "import json;print(json.load(open('$DEP'))$1)"; }

STAKING=$(j "['contracts']['staking']")
SISSUER=$(j "['sagusdClassic']['issuer']")
UISSUER=$(j "['usdcIssuer']")
ME=$(stellar keys address "$SRC")

rate=$(stellar contract invoke --id "$STAKING" --source "$SRC" --network "$NET" --send=no \
        -- exchange_rate 2>/dev/null | tr -d '"')
[ -n "$rate" ] || { echo "no rate from the staking contract, leaving the book alone"; exit 1; }

# A rate of zero would quote a share at nothing and hand the inventory away.
[ "$rate" -gt 0 ] || { echo "rate is $rate, refusing to quote"; exit 1; }

ask=$(( rate * (10000 + SPREAD_BPS) / 10000 ))
bid=$(( rate * (10000 - SPREAD_BPS) / 10000 ))
printf 'rate %s  ask %s  bid %s  (%s bps each side)\n' "$rate" "$ask" "$bid" "$SPREAD_BPS"

# Our own offers, so this replaces rather than stacks. Read from the ledger
# rather than from the state file: the file is a hint, the ledger is the fact.
offers=$(curl -s "https://horizon-testnet.stellar.org/accounts/$ME/offers?limit=200")
ask_id=$(printf '%s' "$offers" | python3 -c "
import sys,json
r=json.load(sys.stdin).get('_embedded',{}).get('records',[])
for o in r:
    if o['selling'].get('asset_code')=='sagUSD' and o['buying'].get('asset_code')=='USDC':
        print(o['id']); break
else: print(0)")
bid_id=$(printf '%s' "$offers" | python3 -c "
import sys,json
r=json.load(sys.stdin).get('_embedded',{}).get('records',[])
for o in r:
    if o['selling'].get('asset_code')=='USDC' and o['buying'].get('asset_code')=='sagUSD':
        print(o['id']); break
else: print(0)")

echo "  ask offer $ask_id, bid offer $bid_id"
stellar tx new manage-sell-offer --source-account "$SRC" \
  --selling "sagUSD:$SISSUER" --buying "USDC:$UISSUER" \
  --amount "$SIZE" --price "$ask:10000000" --offer-id "$ask_id" --network "$NET" >/dev/null 2>&1 \
  && echo "  ask requoted" || echo "  ask unchanged (not enough free sagUSD?)"
stellar tx new manage-buy-offer --source-account "$SRC" \
  --selling "USDC:$UISSUER" --buying "sagUSD:$SISSUER" \
  --amount "$SIZE" --price "$bid:10000000" --offer-id "$bid_id" --network "$NET" >/dev/null 2>&1 \
  && echo "  bid requoted" || echo "  bid unchanged (not enough free USDC?)"

python3 - "$STATE" "$rate" "$ask" "$bid" <<'PY'
import json, sys, time
state, rate, ask, bid = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
json.dump({'at': int(time.time()), 'rate': rate, 'ask': ask, 'bid': bid}, open(state, 'w'))
PY
echo "  state written to $STATE"
