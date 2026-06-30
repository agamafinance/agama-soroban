#!/usr/bin/env bash
# Animate the sagUSD yield during the demo: every INTERVAL seconds, the strategist
# delivers `YIELD` agUSD into the vault via accrue_yield, raising the NAV and the
# share price. Admin must hold enough agUSD buffer (seeded by deploy.sh).
#
# Usage: bash scripts/report-nav.sh [yield_human] [interval_seconds] [rounds]
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
  echo "[round $i] accrue_yield ${YIELD_HUMAN} agUSD"
  stellar contract invoke --id "$STAKING" --source "$SRC" --network "$NET" -- \
    accrue_yield --amount "$AMOUNT" >/dev/null 2>&1 && echo "  ok" || echo "  failed"
  stellar contract invoke --id "$STAKING" --source "$SRC" --network "$NET" -- \
    share_price 2>/dev/null | xargs -I{} echo "  share_price={}"
  if [ "$ROUNDS" != "0" ] && [ "$i" -ge "$ROUNDS" ]; then break; fi
  sleep "$INTERVAL"
done
