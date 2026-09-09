#!/usr/bin/env bash
# Seed each credit vault with demo TVL and a little delivered yield so the
# UI shows live, non-zero numbers (share price slightly above 1.0).
#
# The six credit vaults are deployed instances of an earlier build of the
# staking contract, from before the yield entry point took its DeFindex name,
# and they are not being redeployed. The name is resolved off the interface
# each instance publishes rather than assumed, so this keeps working across
# both generations.
set -euo pipefail
cd "$(dirname "$0")/.."
NET=testnet
SRC=agama-poc
ADMIN=$(stellar keys address agama-poc)
DEP=deployments/testnet.json
USDC=$(python3 -c "import json;print(json.load(open('$DEP'))['contracts']['usdc'])")

inv() { stellar contract invoke --id "$1" --source "$SRC" --network "$NET" -- "${@:2}" >/dev/null 2>&1; }

# Which name this deployed instance gives the yield entry point.
yield_fn() {
  if stellar contract info interface --id "$1" --network "$NET" 2>/dev/null \
     | grep -q 'fn distribute_yield'; then echo distribute_yield; else echo accrue_yield; fi
}

# slug seed yield  (7dp base units: 100k USDC seed, yield tuned per vault)
python3 -c "
import json
for k,v in json.load(open('$DEP'))['creditVaults'].items(): print(k, v)
" | while read -r slug VID; do
  echo "==> seeding $slug"
  inv "$USDC" faucet --to "$ADMIN" --amount 1000000000000          # 100k USDC
  inv "$VID" stake --from "$ADMIN" --amount 1000000000000          # deposit 100k
  inv "$USDC" faucet --to "$ADMIN" --amount 12000000000            # 1.2k USDC
  inv "$VID" "$(yield_fn "$VID")" --amount 12000000000              # ~+1.2% NAV
  sp=$(stellar contract invoke --id "$VID" --source "$SRC" --network "$NET" -- share_price 2>/dev/null)
  nav=$(stellar contract invoke --id "$VID" --source "$SRC" --network "$NET" -- nav 2>/dev/null)
  echo "    share_price=$sp nav=$nav"
done
echo "==> done"
