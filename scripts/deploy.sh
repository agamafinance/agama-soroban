#!/usr/bin/env bash
# Deploy + initialize the Agama Stellar POC contracts on testnet.
# Reproducible: re-running redeploys fresh contract instances and rewrites
# deployments/testnet.json. Requires `agama-poc` (admin) and `agama-treasury`
# identities (create with `stellar keys generate <name> --network testnet --fund`).
set -euo pipefail

cd "$(dirname "$0")/.."
NET=testnet
SRC=agama-poc
WASM=target/wasm32v1-none/release
DEC=7
COOLDOWN=60 # seconds — short for the demo

ADMIN=$(stellar keys address agama-poc)
TREASURY=$(stellar keys address agama-treasury)
echo "admin=$ADMIN treasury=$TREASURY"

echo "==> building"
stellar contract build >/dev/null

deploy() { stellar contract deploy --wasm "$1" --source "$SRC" --network "$NET" 2>/dev/null; }
inv() { stellar contract invoke --id "$1" --source "$SRC" --network "$NET" -- "${@:2}"; }

echo "==> deploying"
USDC=$(deploy "$WASM/mock_usdc.wasm")
AGUSD=$(deploy "$WASM/agusd.wasm")
STAKING=$(deploy "$WASM/staking.wasm")
echo "USDC=$USDC"
echo "AGUSD=$AGUSD"
echo "STAKING=$STAKING"

echo "==> initializing"
inv "$USDC" initialize --admin "$ADMIN" --decimal "$DEC" --name "USD Coin" --symbol "USDC"
inv "$AGUSD" initialize --admin "$ADMIN" --usdc "$USDC" --treasury "$TREASURY" \
  --decimal "$DEC" --name "Agama USD" --symbol "agUSD"
inv "$STAKING" initialize --admin "$ADMIN" --agusd "$AGUSD" --cooldown_seconds "$COOLDOWN" \
  --decimal "$DEC" --name "Staked agUSD" --symbol "sagUSD"

echo "==> curated credit-vault allocations (UI display) — Qiro + Tenka"
inv "$STAKING" set_allocations --allocations \
  '[{"name":"Payment Financing Vault","target_bps":2500,"apy_bps":1400},{"name":"Private Credit Vault","target_bps":1000,"apy_bps":1300},{"name":"Institutional Credit Vault","target_bps":1500,"apy_bps":1200},{"name":"Flagship Vault","target_bps":2500,"apy_bps":850},{"name":"High Yield Vault","target_bps":1000,"apy_bps":1750},{"name":"DealVaults","target_bps":1500,"apy_bps":1100}]'

echo "==> seeding admin yield buffer (50k USDC -> agUSD)"
inv "$USDC" faucet --to "$ADMIN" --amount 500000000000   # 50,000 USDC (7dp)
inv "$AGUSD" deposit --from "$ADMIN" --amount 500000000000

echo "==> writing deployments/testnet.json"
mkdir -p deployments
cat > deployments/testnet.json <<JSON
{
  "network": "testnet",
  "networkPassphrase": "Test SDF Network ; September 2015",
  "rpcUrl": "https://soroban-testnet.stellar.org",
  "admin": "$ADMIN",
  "treasury": "$TREASURY",
  "decimals": $DEC,
  "cooldownSeconds": $COOLDOWN,
  "contracts": {
    "usdc": "$USDC",
    "agusd": "$AGUSD",
    "staking": "$STAKING"
  }
}
JSON
echo "==> done"
cat deployments/testnet.json
