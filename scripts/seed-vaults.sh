#!/usr/bin/env bash
# Seed each credit vault with demo TVL and a little accrued yield so the
# UI shows live, non-zero numbers (share price slightly above 1.0).
set -euo pipefail
cd "$(dirname "$0")/.."
NET=testnet
SRC=agama-poc
ADMIN=$(stellar keys address agama-poc)
DEP=deployments/testnet.json
USDC=$(python3 -c "import json;print(json.load(open('$DEP'))['contracts']['usdc'])")

inv() { stellar contract invoke --id "$1" --source "$SRC" --network "$NET" -- "${@:2}" >/dev/null 2>&1; }

# slug seed yield  (7dp base units: 100k USDC seed, yield tuned per vault)
python3 -c "
import json
for k,v in json.load(open('$DEP'))['creditVaults'].items(): print(k, v)
" | while read -r slug VID; do
  echo "==> seeding $slug"
  inv "$USDC" faucet --to "$ADMIN" --amount 1000000000000          # 100k USDC
  inv "$VID" stake --from "$ADMIN" --amount 1000000000000          # deposit 100k
  inv "$USDC" faucet --to "$ADMIN" --amount 12000000000            # 1.2k USDC
  inv "$VID" accrue_yield --amount 12000000000                     # ~+1.2% NAV
  sp=$(stellar contract invoke --id "$VID" --source "$SRC" --network "$NET" -- share_price 2>/dev/null)
  nav=$(stellar contract invoke --id "$VID" --source "$SRC" --network "$NET" -- nav 2>/dev/null)
  echo "    share_price=$sp nav=$nav"
done
echo "==> done"
