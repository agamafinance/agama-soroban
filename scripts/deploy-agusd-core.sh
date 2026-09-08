#!/usr/bin/env bash
# Deploy the generation 2 agUSD (contracts/agusd-core) and the Vault that mints
# it, on testnet.
#
# Why the Vault is redeployed here. The Vault mints agUSD inside deposit() and
# burns it inside request_withdrawal(), through the token address written by
# initialize(). The Vault that was live before this script pointed at the
# generation 1 agUSD, which is a self contained vault with no mint entry point,
# so its deposit() failed in simulation with MissingValue on `mint`. A Soroban
# contract with no upgrade entry point cannot be repointed, so proving the
# deposit path meant deploying a Vault that carries the new set_agusd.
#
# This script deliberately reproduces that dead end and then walks out of it:
# the Vault is initialized against the generation 1 agUSD, exactly the state the
# previous deployment was stuck in, and then repointed at agusd-core with
# set_agusd before it has taken a single deposit. The recovery path is exercised
# on-chain rather than described.
#
# What it does NOT touch: the real Circle USDC SAC, the generation 1 agUSD, the
# sagUSD staking contract, the six credit vaults, the Allocation Engine, the
# Oracle Adapter and the two pool adapters are all read out of
# deployments/testnet.json and reused as they are.
#
# Known consequence, recorded here because it outlives this script. The
# Allocation Engine stores the Vault address at initialize() and has no setter
# either, so the live Engine still points at the superseded Vault. The new Vault
# is initialized with the live Engine as its only allocation counterparty, so
# custody is already wired the right way round, but until the Engine is
# redeployed it will not call the new Vault: the new Vault takes deposits, pays
# the withdrawal queue and holds 100% of its assets as idle reserves.
#
# Usage: bash scripts/deploy-agusd-core.sh
#
# Requires the `agama-poc` identity, which is the admin recorded in
# deployments/testnet.json.
set -euo pipefail
cd "$(dirname "$0")/.."

NET=testnet
SRC=agama-poc
WASM=target/wasm32v1-none/release
DEP=deployments/testnet.json

# agUSD is a synthetic dollar, so it carries the same 7 decimals as the USDC it
# is minted against and the same name the generation 1 token uses.
DECIMALS=7
NAME="Agama USD"
SYMBOL=agUSD
FEED=PC_NAV

j() { python3 -c "import json;d=json.load(open('$DEP'));print($1)"; }
ADMIN=$(stellar keys address "$SRC")
USDC=$(j "d['contracts']['usdc']")
AGUSD_V1=$(j "d['contracts']['agusd']")
ENGINE=$(j "d['contracts']['allocationEngine']")
ORACLE=$(j "d['contracts']['oracleAdapter']")
OLD_VAULT=$(j "d['contracts']['vault']")

echo "admin                    = $ADMIN"
echo "usdc (live, reused)      = $USDC"
echo "agusd gen 1 (untouched)  = $AGUSD_V1"
echo "engine (live, reused)    = $ENGINE"
echo "oracle (live, reused)    = $ORACLE"
echo "vault being superseded   = $OLD_VAULT"

# Deploy, echoing the install and create transaction hashes so a run leaves a
# record that can be checked against the ledger, and returning the contract id.
deploy() {
  local out
  out=$(stellar contract deploy --wasm "$1" --source "$SRC" --network "$NET" 2>&1)
  echo "$out" | grep -oE '[0-9a-f]{64}' | sed 's/^/    tx or wasm hash /' >&2
  echo "$out" | grep -oE 'C[A-Z2-7]{55}' | tail -1
}
# State changing: submitted, and the transaction hash is echoed.
tx() { stellar contract invoke --id "$1" --source "$SRC" --network "$NET" -- "${@:2}" 2>&1 \
         | grep -oE '[0-9a-f]{64}' | head -1; }
# Read-only: simulated, never submitted, so the wiring checks cost nothing.
q() { stellar contract invoke --id "$1" --source "$SRC" --network "$NET" --send=no -- "${@:2}" 2>/dev/null; }

echo "==> building"
stellar contract build >/dev/null

# The token names the Vault as its minter and the Vault names the token as its
# agUSD, so neither can be initialized until both addresses exist.
echo "==> deploying"
VAULT=$(deploy "$WASM/vault.wasm")
AGUSD_CORE=$(deploy "$WASM/agusd_core.wasm")
echo "    vault       = $VAULT"
echo "    agusd-core  = $AGUSD_CORE"

echo "==> initializing agusd-core with the Vault as its only minter"
echo "    tx $(tx "$AGUSD_CORE" initialize --admin "$ADMIN" --minter "$VAULT" \
  --decimal "$DECIMALS" --name "$NAME" --symbol "$SYMBOL")"

echo "==> initializing the Vault against the generation 1 agUSD"
echo "    tx $(tx "$VAULT" initialize --admin "$ADMIN" --usdc_token "$USDC" \
  --agusd_token "$AGUSD_V1" --allocation_engine "$ENGINE")"
echo "    tx $(tx "$VAULT" set_oracle --admin "$ADMIN" --oracle "$ORACLE" --feed_id "$FEED")"

echo "==> repointing the Vault at agusd-core, before its first deposit"
echo "    tx $(tx "$VAULT" set_agusd --admin "$ADMIN" --agusd_token "$AGUSD_CORE")"

echo "==> checking the wiring"
echo "    vault.agusd()       = $(q "$VAULT" agusd)"
echo "    vault.deposits()    = $(q "$VAULT" deposits)"
echo "    agusd-core.minter() = $(q "$AGUSD_CORE" minter)"

echo "==> writing $DEP"
python3 - "$DEP" "$AGUSD_CORE" "$VAULT" "$OLD_VAULT" "$AGUSD_V1" <<'PY'
import json, sys
path, agusd_core, vault, old_vault, agusd_v1 = sys.argv[1:]
dep = json.load(open(path))
dep['contracts']['agusdCore'] = agusd_core
dep['contracts']['vault'] = vault
dep['superseded'] = {
    'agusd': {
        'address': agusd_v1,
        'supersededBy': 'agusdCore',
        'reason': (
            'Generation 1 agUSD is a self contained vault, not a plain token: it mints '
            'only inside its own deposit() and exposes no mint entry point, so the Vault '
            'cannot mint against a deposit. It stays deployed, it keeps its holders, and '
            'it is still the token the deployed sagUSD staking contract accepts.'
        ),
    },
    'vault': {
        'address': old_vault,
        'supersededBy': 'vault',
        'reason': (
            'Initialized against generation 1 agUSD with no setter for the token address '
            'and no upgrade entry point, so its deposit() could never mint. The Allocation '
            'Engine still points at it, because the Engine stores the Vault address at '
            'initialize() and cannot be repointed either.'
        ),
    },
}
json.dump(dep, open(path, 'w'), indent=2)
open(path, 'a').write('\n')
print(json.dumps(dep, indent=2))
PY
echo "==> done"
