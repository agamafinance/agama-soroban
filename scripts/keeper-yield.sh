#!/usr/bin/env bash
# Deliver the yield the oracle says the credit book earned, rather than a number
# somebody picked.
#
# The Tranche 2 criterion is that yield distribution to sagUSD is driven by
# oracle data. The demo loop (distribute-yield-loop.sh) delivers a constant and
# says so in its own header, which proves the plumbing and not the criterion.
# This computes the amount instead:
#
#   yield = deployed capital x (PC_NAV now / PC_NAV at the last distribution - 1)
#
# The feed is the one the Vault itself prices its book from, read through the
# Vault's get_nav so that a stale feed stops this keeper exactly where it stops
# the Vault: OracleStale propagates and nothing is distributed. The NAV used is
# recorded in state/yield-nav.json, so the next run measures from the last
# distribution rather than from deployment.
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
ADMIN=$(j "['admin']")

rd(){ stellar contract invoke --id "$1" --source "$SRC" --network "$NET" --send=no -- "${@:2}" 2>&1 | tail -1 | tr -d '"'; }

NAV_NOW=$(rd "$VAULT" get_nav)
case "$NAV_NOW" in (*[!0-9]*|"") echo "the Vault could not read the feed: $NAV_NOW"; exit 1;; esac
DEPLOYED=$(rd "$VAULT" deployed_capital)
mkdir -p state
NAV_LAST=$(python3 -c "
import json, os
p='$STATE'
print(json.load(open(p))['nav'] if os.path.exists(p) else '$NAV_NOW')
")

AMOUNT=$(python3 -c "
nav_now, nav_last, dep = $NAV_NOW, $NAV_LAST, $DEPLOYED
print(max(0, dep * (nav_now - nav_last) // nav_last) if nav_last else 0)
")
printf 'PC_NAV %s -> %s, deployed %s, yield %s\n' "$NAV_LAST" "$NAV_NOW" "$DEPLOYED" "$AMOUNT"

if [ "${DRY:-0}" = "1" ]; then echo "dry run, nothing sent"; exit 0; fi
if [ "$AMOUNT" -le 0 ]; then
  echo "the feed has not moved since the last distribution, nothing to deliver"
  python3 -c "import json;json.dump({'nav': $NAV_NOW}, open('$STATE','w'))"
  exit 0
fi

BAL=$(rd "$AGUSD" balance --id "$ADMIN")
if [ "$BAL" -lt "$AMOUNT" ]; then
  echo "the strategist holds $BAL agUSD and owes $AMOUNT: nothing distributed"
  exit 1
fi

# distribute_yield takes the amount only: the contract reads its own admin and
# pulls the agUSD from them, which is what stops this keeper inventing yield.
OUT=$(stellar contract invoke --id "$STAKING" --source "$SRC" --network "$NET" -- \
        distribute_yield --amount "$AMOUNT" 2>&1)
STATUS=$?
printf '%s\n' "$OUT" | tail -2
# The reading only advances when the distribution landed. Writing it either way
# is how a failed call quietly becomes yield nobody ever delivered: the next run
# measures from a NAV that was never paid for.
if [ "$STATUS" -ne 0 ] || printf '%s' "$OUT" | grep -q "Error(Contract"; then
  echo "nothing was distributed, the recorded NAV stays at $NAV_LAST"
  exit 1
fi
python3 -c "import json;json.dump({'nav': $NAV_NOW}, open('$STATE','w'))"
echo "rate now $(rd "$STAKING" exchange_rate)"
