#!/usr/bin/env bash
# Deliver yield into the staking contract on a loop, for a demo.
#
# Every INTERVAL seconds the strategist delivers `YIELD` agUSD through
# distribute_yield, which raises the NAV and with it the exchange rate. The admin
# must hold enough agUSD to do it; deploy.sh seeds that buffer.
#
# It was called report-nav.sh, which named the wrong thing on the wrong contract.
# report_nav was the Oracle Adapter's old NAV setter, removed because it let its
# caller reprice every share in the contract; this script has never touched the
# oracle and calls the one entry point that moves NAV and cannot overstate the
# book. A script whose name says it pushes an oracle reading is a script somebody
# eventually runs expecting that.
#
# Usage: bash scripts/distribute-yield-loop.sh [yield_human] [interval_seconds] [rounds]
#   yield_human    agUSD delivered per round (default 25)
#   interval_secs  seconds between rounds (default 30)
#   rounds         number of rounds, 0 = infinite (default 0)
set -euo pipefail
cd "$(dirname "$0")/.."

YIELD_HUMAN=${1:-25}
INTERVAL=${2:-30}
ROUNDS=${3:-0}
NET=testnet
SRC=agama-poc

STAKING=$(python3 -c "import json;print(json.load(open('deployments/testnet.json'))['contracts']['staking'])")
AMOUNT=$(python3 -c "print(int(${YIELD_HUMAN}*10_000_000))")

i=0
while :; do
  i=$((i+1))
  echo "[round $i] distribute_yield ${YIELD_HUMAN} agUSD"
  stellar contract invoke --id "$STAKING" --source "$SRC" --network "$NET" -- \
    distribute_yield --amount "$AMOUNT" >/dev/null 2>&1 && echo "  ok" || echo "  failed"
  stellar contract invoke --id "$STAKING" --source "$SRC" --network "$NET" -- \
    exchange_rate 2>/dev/null | xargs -I{} echo "  exchange_rate={}"
  if [ "$ROUNDS" != "0" ] && [ "$i" -ge "$ROUNDS" ]; then break; fi
  sleep "$INTERVAL"
done
