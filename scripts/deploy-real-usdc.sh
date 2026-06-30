#!/usr/bin/env bash
# Redeploy the full Agama Stellar POC against the REAL Circle USDC on testnet
# (Stellar Asset Contract of USDC:GBBD47IF…FLA5, the official Circle issuer).
# Keeps the admin key as operator; treasury (strategy address) is passed in.
#
# Usage: TREASURY=G... bash scripts/deploy-real-usdc.sh
set -euo pipefail
cd "$(dirname "$0")/.."

NET=testnet
SRC=agama-poc
WASM=target/wasm32v1-none/release
DEC=7
USDC_ISSUER=GBBD47IF6LWK7P7MDEVSCWR7DPUWV3NY3DTQEVFL4NAT4AQH3ZLLFLA5
USDC_ASSET="USDC:$USDC_ISSUER"

ADMIN=$(stellar keys address agama-poc)
TREASURY=${TREASURY:-$(stellar keys address agama-treasury)}
USDC=$(stellar contract asset id --asset "$USDC_ASSET" --network $NET)
echo "admin=$ADMIN treasury=$TREASURY usdc(SAC)=$USDC"

stellar contract build >/dev/null
inv() { stellar contract invoke --id "$1" --source "$SRC" --network "$NET" -- "${@:2}" >/dev/null; }
deploy() { stellar contract deploy --wasm "$1" --source "$SRC" --network "$NET" 2>/dev/null; }

echo "==> agUSD (deposit asset = real USDC)"
AGUSD=$(deploy "$WASM/agusd.wasm")
inv "$AGUSD" initialize --admin "$ADMIN" --usdc "$USDC" --treasury "$TREASURY" \
  --buffer_bps 2000 --decimal $DEC --name "Agama USD" --symbol "agUSD"
echo "    $AGUSD"

echo "==> sagUSD staking vault"
STAKING=$(deploy "$WASM/staking.wasm")
inv "$STAKING" initialize --admin "$ADMIN" --agusd "$AGUSD" --cooldown_seconds 60 \
  --decimal $DEC --name "Staked agUSD" --symbol "sagUSD"
echo "    $STAKING"

echo "==> allocations"
inv "$STAKING" set_allocations --allocations \
  '[{"name":"Payment Financing Vault","target_bps":2500,"apy_bps":1400},{"name":"Private Credit Vault","target_bps":1000,"apy_bps":1300},{"name":"Institutional Credit Vault","target_bps":1500,"apy_bps":1200},{"name":"Flagship Vault","target_bps":2500,"apy_bps":850},{"name":"High Yield Vault","target_bps":1000,"apy_bps":1750},{"name":"DealVaults","target_bps":1500,"apy_bps":1100}]'

echo "==> credit vaults (deposit asset = real USDC)"
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
  ID=$(deploy "$WASM/staking.wasm")
  inv "$ID" initialize --admin "$ADMIN" --agusd "$USDC" --cooldown_seconds 10 \
    --decimal $DEC --name "$name" --symbol "$symbol"
  echo "    $slug -> $ID"
  RESULTS+=("$slug=$ID")
done

echo "==> Allocation Engine targets on agUSD (auto-deploy above 20% buffer)"
TARGETS=$(python3 - "${RESULTS[@]}" <<'PY'
import json, sys
W = {"payment-financing":2500,"private-credit":1000,"institutional-credit":1500,
     "flagship":2500,"high-yield":1000,"dealvaults":1500}
out=[{"vault":kv.split("=")[1],"weight_bps":W[kv.split("=")[0]]} for kv in sys.argv[1:]]
print(json.dumps(out))
PY
)
inv "$AGUSD" set_targets --targets "$TARGETS"

echo "==> writing deployments/testnet.json"
python3 - "$USDC" "$AGUSD" "$STAKING" "$TREASURY" "$USDC_ISSUER" "${RESULTS[@]}" <<'EOF'
import json, sys
usdc, agusd, staking, treasury, issuer, *vaults = sys.argv[1:]
dep = json.load(open('deployments/testnet.json'))
dep['contracts'] = {'usdc': usdc, 'agusd': agusd, 'staking': staking}
dep['creditVaults'] = {kv.split('=')[0]: kv.split('=')[1] for kv in vaults}
dep['treasury'] = treasury
dep['usdcIssuer'] = issuer
dep['usdcReal'] = True
json.dump(dep, open('deployments/testnet.json','w'), indent=2)
print(json.dumps(dep, indent=2))
EOF
echo "==> done"
