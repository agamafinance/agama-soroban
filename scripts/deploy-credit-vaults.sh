#!/usr/bin/env bash
# Deploy one on-chain vault per curated credit vault (3 Qiro + 3 Tenka).
# Each is an instance of the `staking` contract taking USDC as the deposit
# asset, with its own share token, NAV and cooldown. Merges the resulting
# contract IDs into deployments/testnet.json under "creditVaults".
set -euo pipefail
cd "$(dirname "$0")/.."

NET=testnet
SRC=agama-poc
WASM=target/wasm32v1-none/release/staking.wasm
DEC=7
COOLDOWN=10 # short for demo fluidity

ADMIN=$(stellar keys address agama-poc)
USDC=$(python3 -c "import json;print(json.load(open('deployments/testnet.json'))['contracts']['usdc'])")
echo "admin=$ADMIN usdc=$USDC"

stellar contract build >/dev/null

# slug|name|symbol  (share token of each vault)
VAULTS=(
  "payment-financing|Payment Financing Vault|qPAY"
  "private-credit|Private Credit Vault|qPCV"
  "institutional-credit|Institutional Credit Vault|qICV"
  "flagship|Flagship Vault|tFLAG"
  "high-yield|High Yield Vault|tHY"
  "dealvaults|DealVaults|tDEAL"
)

declare -a RESULTS=()
for v in "${VAULTS[@]}"; do
  IFS='|' read -r slug name symbol <<<"$v"
  echo "==> deploying vault: $name ($symbol)"
  ID=$(stellar contract deploy --wasm "$WASM" --source "$SRC" --network "$NET" 2>/dev/null)
  stellar contract invoke --id "$ID" --source "$SRC" --network "$NET" -- initialize \
    --admin "$ADMIN" --agusd "$USDC" --cooldown_seconds "$COOLDOWN" \
    --decimal "$DEC" --name "$name" --symbol "$symbol" >/dev/null
  echo "    $slug -> $ID"
  RESULTS+=("$slug=$ID")
done

echo "==> merging into deployments/testnet.json"
python3 - "${RESULTS[@]}" <<'EOF'
import json, sys
dep = json.load(open('deployments/testnet.json'))
dep['creditVaults'] = {kv.split('=')[0]: kv.split('=')[1] for kv in sys.argv[1:]}
json.dump(dep, open('deployments/testnet.json','w'), indent=2)
print(json.dumps(dep['creditVaults'], indent=2))
EOF
echo "==> done"
