#!/usr/bin/env bash
# Deploy and initialize the Tranche 1 / Tranche 2 core contracts on testnet:
# Oracle Adapter, Allocation Engine, Vault, and the two pool adapters
# (Etherfuse, private credit).
#
# This script does NOT touch the contracts that are already live: the real
# Circle USDC SAC, agUSD, sagUSD and the six credit vaults are read out of
# deployments/testnet.json and reused as they are. Only the five new contract
# addresses are written back into that file.
#
# A Vault deployed by this script mints agusd-core, and agusd-core mints only
# for the Vault named at its initialization, so a Vault redeployed here needs a
# new agUSD too. See scripts/deploy-agusd-core.sh, which deploys the pair.
#
# Usage: bash scripts/deploy-core.sh
#
# Requires the `agama-poc` identity, which is the admin already recorded in
# deployments/testnet.json.
set -euo pipefail
cd "$(dirname "$0")/.."

NET=testnet
SRC=agama-poc
WASM=target/wasm32v1-none/release
DEP=deployments/testnet.json

# Oracle feed guards. These mirror the constants compiled into the Oracle
# Adapter (FEED_*, *_STALENESS, *_DEVIATION_BPS), so the on-chain registration
# and the documented configuration cannot drift apart.
FEED_USDC_USD=USDC_USD;  USDC_USD_STALENESS=3600;   USDC_USD_DEVIATION=200
FEED_PC_NAV=PC_NAV;      PC_NAV_STALENESS=604800;   PC_NAV_DEVIATION=500
FEED_EF_BOND=EF_BOND;    EF_BOND_STALENESS=172800;  EF_BOND_DEVIATION=0

# Allocation Engine limits, in bps of total assets. Same values the Engine test
# suite documents: each one is tight enough to bind on its own.
POOL_CAP=3000          # 30% in any single pool
ORIGINATOR_CAP=4000    # 40% behind any single originator
JURISDICTION_CAP=5000  # 50% under any single legal regime
RESERVE_FLOOR=2000     # 20% of total assets stays as idle USDC in the Vault

# Pool registration metadata. `originator` and `jurisdiction` are the buckets
# the concentration caps aggregate over: the private credit facility is fronted
# by Qiro through a Luxembourg SPV, the Etherfuse leg is tokenized Mexican
# government debt.
PC_ORIGINATOR=QIRO;      PC_JURISDICTION=LU
EF_ORIGINATOR=ETHERFUS;  EF_JURISDICTION=MX

ADMIN=$(stellar keys address "$SRC")
USDC=$(python3 -c "import json;print(json.load(open('$DEP'))['contracts']['usdc'])")
# agusdCore, not agusd: the generation 1 token has no mint entry point, so a
# Vault wired to it can never mint against a deposit.
AGUSD=$(python3 -c "import json;print(json.load(open('$DEP'))['contracts']['agusdCore'])")
echo "admin=$ADMIN"
echo "usdc (live, reused)  = $USDC"
echo "agusd-core (live, reused) = $AGUSD"

deploy() { stellar contract deploy --wasm "$1" --source "$SRC" --network "$NET" 2>/dev/null; }
inv() { stellar contract invoke --id "$1" --source "$SRC" --network "$NET" -- "${@:2}"; }

echo "==> building"
stellar contract build >/dev/null

# Deploy first, initialize second. The Vault and the Engine each need the
# other's address at initialization time, so neither can be initialized until
# both exist.
echo "==> deploying"
ORACLE=$(deploy "$WASM/oracle_adapter.wasm")
ENGINE=$(deploy "$WASM/allocation_engine.wasm")
VAULT=$(deploy "$WASM/vault.wasm")
PRIVATE_CREDIT=$(deploy "$WASM/private_credit.wasm")
ETHERFUSE=$(deploy "$WASM/etherfuse.wasm")
echo "    oracle-adapter    = $ORACLE"
echo "    allocation-engine = $ENGINE"
echo "    vault             = $VAULT"
echo "    private-credit    = $PRIVATE_CREDIT"
echo "    etherfuse         = $ETHERFUSE"

echo "==> initializing Oracle Adapter"
inv "$ORACLE" initialize --admin "$ADMIN" >/dev/null
inv "$ORACLE" add_reporter --admin "$ADMIN" --reporter "$ADMIN" >/dev/null
inv "$ORACLE" register_feed --admin "$ADMIN" --feed_id "$FEED_USDC_USD" \
  --staleness_secs "$USDC_USD_STALENESS" --deviation_bps "$USDC_USD_DEVIATION" >/dev/null
inv "$ORACLE" register_feed --admin "$ADMIN" --feed_id "$FEED_PC_NAV" \
  --staleness_secs "$PC_NAV_STALENESS" --deviation_bps "$PC_NAV_DEVIATION" >/dev/null
inv "$ORACLE" register_feed --admin "$ADMIN" --feed_id "$FEED_EF_BOND" \
  --staleness_secs "$EF_BOND_STALENESS" --deviation_bps "$EF_BOND_DEVIATION" >/dev/null

echo "==> initializing Allocation Engine"
inv "$ENGINE" initialize --admin "$ADMIN" --vault "$VAULT" >/dev/null

echo "==> initializing Vault"
inv "$VAULT" initialize --admin "$ADMIN" --usdc_token "$USDC" \
  --agusd_token "$AGUSD" --allocation_engine "$ENGINE" >/dev/null
inv "$VAULT" set_oracle --admin "$ADMIN" --oracle "$ORACLE" --feed_id "$FEED_PC_NAV" >/dev/null

echo "==> initializing pool adapters"
inv "$PRIVATE_CREDIT" initialize --admin "$ADMIN" --engine "$ENGINE" \
  --vault "$VAULT" --usdc "$USDC" >/dev/null
inv "$ETHERFUSE" initialize --admin "$ADMIN" --engine "$ENGINE" \
  --vault "$VAULT" --usdc "$USDC" >/dev/null

# The Engine ships fail closed: every cap at zero and the reserve floor at 100%,
# so it refuses to deploy capital until this block runs.
echo "==> opening the Engine up to its configured limits"
inv "$ENGINE" set_caps --admin "$ADMIN" --pool_cap_bps "$POOL_CAP" \
  --originator_cap_bps "$ORIGINATOR_CAP" --jurisdiction_cap_bps "$JURISDICTION_CAP" >/dev/null
inv "$ENGINE" set_reserve_floor --admin "$ADMIN" --floor_bps "$RESERVE_FLOOR" >/dev/null
inv "$ENGINE" register_pool --admin "$ADMIN" --pool_id "$PRIVATE_CREDIT" \
  --originator "$PC_ORIGINATOR" --jurisdiction "$PC_JURISDICTION" --cap_bps "$POOL_CAP" >/dev/null
inv "$ENGINE" register_pool --admin "$ADMIN" --pool_id "$ETHERFUSE" \
  --originator "$EF_ORIGINATOR" --jurisdiction "$EF_JURISDICTION" --cap_bps "$POOL_CAP" >/dev/null

echo "==> writing $DEP"
python3 - "$DEP" "$ORACLE" "$ENGINE" "$VAULT" "$PRIVATE_CREDIT" "$ETHERFUSE" <<'PY'
import json, sys
path, oracle, engine, vault, private_credit, etherfuse = sys.argv[1:]
dep = json.load(open(path))
dep['contracts'].update({
    'vault': vault,
    'allocationEngine': engine,
    'oracleAdapter': oracle,
})
dep['poolAdapters'] = {
    'private-credit': private_credit,
    'etherfuse': etherfuse,
}
dep['engineConfig'] = {
    'poolCapBps': 3000,
    'originatorCapBps': 4000,
    'jurisdictionCapBps': 5000,
    'reserveFloorBps': 2000,
    'pools': {
        'private-credit': {'originator': 'QIRO', 'jurisdiction': 'LU', 'capBps': 3000},
        'etherfuse': {'originator': 'ETHERFUS', 'jurisdiction': 'MX', 'capBps': 3000},
    },
}
dep['oracleFeeds'] = {
    'USDC_USD': {'stalenessSecs': 3600, 'deviationBps': 200},
    'PC_NAV': {'stalenessSecs': 604800, 'deviationBps': 500},
    'EF_BOND': {'stalenessSecs': 172800, 'deviationBps': 0},
}
dep['vaultOracleFeed'] = 'PC_NAV'
json.dump(dep, open(path, 'w'), indent=2)
open(path, 'a').write('\n')
print(json.dumps(dep, indent=2))
PY
echo "==> done"
