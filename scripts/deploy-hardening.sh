#!/usr/bin/env bash
# Redeploy the stack with the fixes from the adversarial security review.
#
# Why the whole stack again
#
# Seven contracts changed and none of them is upgradeable, so every one of them
# is a new deployment, and the ones that name each other have to move together.
# The Vault now keeps its own reserve floor and its own deployed capital book;
# the Allocation Engine reads free rather than gross reserves and reports
# repayments and write-downs back to the Vault; the adapters gained write_down;
# the Oracle Adapter gained a band, a rate limit and a persistent reference
# point; sagUSD lost report_nav; agUSD gained admin rotation, which every other
# contract gained too. agUSD names its Vault as the only minter and freezes that
# pointer at the first mint, so a new Vault means a new agUSD, and a new agUSD
# means the staking contract follows.
#
# What this does NOT touch: the real Circle USDC SAC, the six credit vaults, and
# the generation 1 agUSD.
#
# The order below is forced by the guards rather than chosen:
#
#   - the Engine has to name the Vault before Vault.set_engine would accept it,
#     so the Vault is deployed first and the Engine is initialized against it
#   - the adapters have to name the Engine and the Vault before
#     Engine.register_pool will accept them, which is new: an adapter that
#     repays a Vault this Engine does not govern used to be registerable
#   - the Vault ships with its reserve floor closed at 100%, the same way the
#     Engine ships with its caps at zero, so nothing can be allocated until
#     set_reserve_floor has been called on both
#
# Usage: bash scripts/deploy-hardening.sh
#
# Requires the `agama-poc` identity, which is the admin recorded in
# deployments/testnet.json.
set -euo pipefail
cd "$(dirname "$0")/.."

NET=testnet
SRC=agama-poc
WASM=target/wasm32v1-none/release
DEP=deployments/testnet.json

DECIMALS=7
AGUSD_NAME="Agama USD"
AGUSD_SYMBOL=agUSD
SAGUSD_NAME="Staked agUSD"
SAGUSD_SYMBOL=sagUSD
FEED=PC_NAV

# Allocation limits, in bps. Unchanged from the previous deployment: the
# registered pool caps sum to 8000 and the floor releases 7500, so the floor is
# reachable by ordinary allocations rather than shadowed by the pool cap.
POOL_CAP=4000          # 40% in any single pool
ORIGINATOR_CAP=4500    # 45% behind any single originator
JURISDICTION_CAP=5000  # 50% under any single legal regime
RESERVE_FLOOR=2500     # 25% of net assets stays as free USDC in the Vault

# Oracle feed guards. The staleness windows and deviation bounds are unchanged;
# the band and the minimum interval are new. The band is what bounds the first
# report for a feed, which a deviation bound cannot reach, and the interval is
# what stops a feed being walked anywhere by repetition inside the bound.
USDC_STALENESS=3600;    USDC_DEVIATION=200;  USDC_MIN=9000000;  USDC_MAX=11000000; USDC_INTERVAL=300
PC_STALENESS=604800;    PC_DEVIATION=500;    PC_MIN=5000000;    PC_MAX=20000000;   PC_INTERVAL=3600
EF_STALENESS=172800;    EF_DEVIATION=0;      EF_MIN=5000000;    EF_MAX=20000000;   EF_INTERVAL=3600

# Why this run is retiring what it retires. It goes into deployments/testnet.json
# against every address this script replaces. "%s" is filled in with the
# contract's name.
RETIREMENT_REASON="Replaced by scripts/deploy-hardening.sh. This %s predates the fixes from the adversarial security review: the Vault delegated the reserve floor entirely to whatever Allocation Engine it pointed at, so a contract that answered vault() correctly could empty it; queued withdrawals were counted as free liquidity by the floor and the caps, so capital could be deployed against money already owed; a stalled head claim froze the withdrawal queue for everyone behind it; a credit loss could not be recognised on-chain at all; sagUSD carried report_nav, a bare setter on the denominator of its own share price; and no contract had admin rotation."

PC_ORIGINATOR=QIRO;      PC_JURISDICTION=LU
EF_ORIGINATOR=ETHERFUS;  EF_JURISDICTION=MX

j() { python3 -c "import json;d=json.load(open('$DEP'));print($1)"; }
ADMIN=$(stellar keys address "$SRC")
USDC=$(j "d['contracts']['usdc']")
COOLDOWN=$(j "d['cooldownSeconds']")
OLD_AGUSD=$(j "d['contracts']['agusdCore']")
OLD_VAULT=$(j "d['contracts']['vault']")
OLD_ENGINE=$(j "d['contracts']['allocationEngine']")
OLD_STAKING=$(j "d['contracts']['staking']")
OLD_ORACLE=$(j "d['contracts']['oracleAdapter']")
OLD_PC=$(j "d['poolAdapters']['private-credit']")
OLD_EF=$(j "d['poolAdapters']['etherfuse']")

echo "admin                      = $ADMIN"
echo "usdc (live, reused)        = $USDC"
echo "superseded agusd-core      = $OLD_AGUSD"
echo "superseded vault           = $OLD_VAULT"
echo "superseded engine          = $OLD_ENGINE"
echo "superseded oracle          = $OLD_ORACLE"
echo "superseded staking         = $OLD_STAKING"
echo "superseded pool adapters   = $OLD_PC, $OLD_EF"

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

# Retire what the superseded generation is holding before anything replaces it.
# The outstanding agUSD can only be redeemed through the Vault that mints it,
# and that Vault is about to stop being the protocol's Vault, so redeeming now
# means the token is superseded with a zero supply and strands nobody. It also
# returns the USDC, which is the working capital the new stack runs on.
echo ""
echo "==> winding down the superseded generation"
OLD_SUPPLY=$(q "$OLD_AGUSD" total_supply | tr -d '"' || echo 0)
if [ "${OLD_SUPPLY:-0}" != "0" ]; then
  CLAIM=$(q "$OLD_VAULT" queue_tail | tr -d '"')
  echo "    redeeming $OLD_SUPPLY of superseded agUSD through its own Vault, claim $CLAIM"
  echo "    request_withdrawal  tx $(tx "$OLD_VAULT" request_withdrawal --from "$ADMIN" --amount "$OLD_SUPPLY")"
  echo "    claim_withdrawal    tx $(tx "$OLD_VAULT" claim_withdrawal --from "$ADMIN" --claim_id "$CLAIM")"
  echo "    supply now          $(q "$OLD_AGUSD" total_supply)"
else
  echo "    superseded agUSD supply is already zero"
fi
OLD_DEPLOYED=$(q "$OLD_ENGINE" total_allocated | tr -d '"' || echo 0)
if [ "${OLD_DEPLOYED:-0}" != "0" ]; then
  OLD_PC_EXPOSURE=$(q "$OLD_PC" get_exposure | tr -d '"')
  echo "    unwinding the superseded Engine's book, $OLD_PC_EXPOSURE in private credit"
  echo "    deallocate          tx $(tx "$OLD_ENGINE" deallocate --pool_id "$OLD_PC" --amount "$OLD_PC_EXPOSURE")"
else
  echo "    the superseded Engine's book is already empty"
fi

echo ""
echo "==> building"
stellar contract build >/dev/null

echo ""
echo "==> deploying"
VAULT=$(deploy "$WASM/vault.wasm")
AGUSD=$(deploy "$WASM/agusd_core.wasm")
ENGINE=$(deploy "$WASM/allocation_engine.wasm")
ORACLE=$(deploy "$WASM/oracle_adapter.wasm")
PC=$(deploy "$WASM/private_credit.wasm")
EF=$(deploy "$WASM/etherfuse.wasm")
STAKING=$(deploy "$WASM/staking.wasm")
echo "    vault             = $VAULT"
echo "    agusd-core        = $AGUSD"
echo "    allocation-engine = $ENGINE"
echo "    oracle-adapter    = $ORACLE"
echo "    private-credit    = $PC"
echo "    etherfuse         = $EF"
echo "    staking (sagUSD)  = $STAKING"

echo ""
echo "==> allocation-engine: initialized against the Vault it governs"
echo "    initialize        tx $(tx "$ENGINE" initialize --admin "$ADMIN" --vault "$VAULT")"

echo ""
echo "==> agusd-core: the Vault is the only minter"
echo "    initialize        tx $(tx "$AGUSD" initialize --admin "$ADMIN" --minter "$VAULT" \
  --decimal "$DECIMALS" --name "$AGUSD_NAME" --symbol "$AGUSD_SYMBOL")"

echo ""
echo "==> oracle-adapter: feeds carry a band and a minimum interval now"
echo "    initialize        tx $(tx "$ORACLE" initialize --admin "$ADMIN")"
echo "    add_reporter      tx $(tx "$ORACLE" add_reporter --admin "$ADMIN" --reporter "$ADMIN")"
echo "    register USDC_USD tx $(tx "$ORACLE" register_feed --admin "$ADMIN" --feed_id USDC_USD \
  --staleness_secs "$USDC_STALENESS" --deviation_bps "$USDC_DEVIATION" \
  --min_nav "$USDC_MIN" --max_nav "$USDC_MAX" --min_interval_secs "$USDC_INTERVAL")"
echo "    register PC_NAV   tx $(tx "$ORACLE" register_feed --admin "$ADMIN" --feed_id PC_NAV \
  --staleness_secs "$PC_STALENESS" --deviation_bps "$PC_DEVIATION" \
  --min_nav "$PC_MIN" --max_nav "$PC_MAX" --min_interval_secs "$PC_INTERVAL")"
echo "    register EF_BOND  tx $(tx "$ORACLE" register_feed --admin "$ADMIN" --feed_id EF_BOND \
  --staleness_secs "$EF_STALENESS" --deviation_bps "$EF_DEVIATION" \
  --min_nav "$EF_MIN" --max_nav "$EF_MAX" --min_interval_secs "$EF_INTERVAL")"

echo ""
echo "==> vault: wired, and its own reserve floor opened from the closed default"
echo "    initialize        tx $(tx "$VAULT" initialize --admin "$ADMIN" --usdc_token "$USDC" \
  --agusd_token "$AGUSD" --allocation_engine "$ENGINE")"
# The Vault ships with the floor at 10000 bps, so it releases nothing until
# this line runs. It is set to the same number the Engine enforces: if the two
# ever differ, the tighter of them binds, which is the safe direction.
echo "    set_reserve_floor tx $(tx "$VAULT" set_reserve_floor --admin "$ADMIN" --floor_bps "$RESERVE_FLOOR")"
echo "    set_oracle        tx $(tx "$VAULT" set_oracle --admin "$ADMIN" --oracle "$ORACLE" --feed_id "$FEED")"

echo ""
echo "==> pool adapters: each one names the Engine and the Vault it serves"
for pair in "private-credit:$PC" "etherfuse:$EF"; do
  name=${pair%%:*}; id=${pair#*:}
  echo "  $name"
  echo "    initialize        tx $(tx "$id" initialize --admin "$ADMIN" --engine "$ENGINE" \
    --vault "$VAULT" --usdc "$USDC")"
done

echo ""
echo "==> sagUSD: staking the agUSD this Vault mints"
echo "    initialize        tx $(tx "$STAKING" initialize --admin "$ADMIN" --agusd "$AGUSD" \
  --cooldown_seconds "$COOLDOWN" --decimal "$DECIMALS" --name "$SAGUSD_NAME" --symbol "$SAGUSD_SYMBOL")"

echo ""
echo "==> opening the Engine up to its configured limits"
echo "    set_caps           tx $(tx "$ENGINE" set_caps --admin "$ADMIN" --pool_cap_bps "$POOL_CAP" \
  --originator_cap_bps "$ORIGINATOR_CAP" --jurisdiction_cap_bps "$JURISDICTION_CAP")"
echo "    set_reserve_floor  tx $(tx "$ENGINE" set_reserve_floor --admin "$ADMIN" --floor_bps "$RESERVE_FLOOR")"
# register_pool now reads engine() and vault() off the adapter and refuses
# anything that does not name this Engine and this Engine's Vault.
echo "    register pc        tx $(tx "$ENGINE" register_pool --admin "$ADMIN" --pool_id "$PC" \
  --originator "$PC_ORIGINATOR" --jurisdiction "$PC_JURISDICTION" --cap_bps "$POOL_CAP")"
echo "    register ef        tx $(tx "$ENGINE" register_pool --admin "$ADMIN" --pool_id "$EF" \
  --originator "$EF_ORIGINATOR" --jurisdiction "$EF_JURISDICTION" --cap_bps "$POOL_CAP")"

echo ""
echo "==> checking the wiring, every pointer in both directions"
echo "    vault.agusd()               = $(q "$VAULT" agusd)"
echo "    vault.allocation_engine()   = $(q "$VAULT" allocation_engine)"
echo "    vault.usdc()                = $(q "$VAULT" usdc)"
echo "    vault.reserve_floor_bps()   = $(q "$VAULT" reserve_floor_bps)"
echo "    vault.deployed_capital()    = $(q "$VAULT" deployed_capital)"
echo "    vault.outstanding_liab()    = $(q "$VAULT" outstanding_liabilities)"
echo "    agusd.minter()              = $(q "$AGUSD" minter)"
echo "    engine.vault()              = $(q "$ENGINE" vault)"
echo "    engine.caps()               = $(q "$ENGINE" caps)"
echo "    engine.reserve_floor_bps()  = $(q "$ENGINE" reserve_floor_bps)"
echo "    private-credit.engine()     = $(q "$PC" engine)"
echo "    private-credit.vault()      = $(q "$PC" vault)"
echo "    etherfuse.engine()          = $(q "$EF" engine)"
echo "    etherfuse.vault()           = $(q "$EF" vault)"
echo "    staking.agusd()             = $(q "$STAKING" agusd)"
echo "    oracle.get_feed(PC_NAV)     = $(q "$ORACLE" get_feed --feed_id PC_NAV)"

echo ""
echo "==> writing $DEP"
python3 - "$DEP" "$VAULT" "$AGUSD" "$ENGINE" "$ORACLE" "$PC" "$EF" "$STAKING" \
  "$OLD_VAULT" "$OLD_AGUSD" "$OLD_ENGINE" "$OLD_ORACLE" "$OLD_PC" "$OLD_EF" "$OLD_STAKING" \
  "$POOL_CAP" "$ORIGINATOR_CAP" "$JURISDICTION_CAP" "$RESERVE_FLOOR" \
  "$RETIREMENT_REASON" <<'PY'
import json, sys
(path, vault, agusd, engine, oracle, pc, ef, staking,
 old_vault, old_agusd, old_engine, old_oracle, old_pc, old_ef, old_staking,
 pool_cap, originator_cap, jurisdiction_cap, reserve_floor,
 retirement_reason) = sys.argv[1:]
dep = json.load(open(path))

# Whatever was recorded as superseded before stays recorded, with the reason it
# was replaced. A deployment record that drops its own history is not one.
history = dep.get('superseded', [])
ORDINALS = ['first', 'second', 'third', 'fourth', 'fifth', 'sixth', 'seventh']


def retire(contract, address, name, reason):
    generation = 1 + sum(1 for e in history if e['contract'] == contract)
    history.append({
        'contract': contract,
        'generation': generation,
        'label': '%s, %s deployment' % (name, ORDINALS[generation - 1]),
        'address': address,
        'supersededBy': contract,
        'reason': reason,
    })


retirements = [
    ('vault', old_vault, 'Vault Contract', 'Vault Contract'),
    ('agusdCore', old_agusd, 'agUSD', 'agUSD'),
    ('allocationEngine', old_engine, 'Allocation Engine', 'Allocation Engine'),
    ('oracleAdapter', old_oracle, 'Oracle Adapter', 'Oracle Adapter'),
    ('poolAdapters.private-credit', old_pc, 'Private credit adapter', 'private credit adapter'),
    ('poolAdapters.etherfuse', old_ef, 'Etherfuse adapter', 'Etherfuse adapter'),
    ('staking', old_staking, 'sagUSD staking', 'sagUSD staking'),
]
for contract, address, name, subject in retirements:
    retire(contract, address, name, retirement_reason % subject)

dep['contracts'].update({
    'vault': vault,
    'agusdCore': agusd,
    'allocationEngine': engine,
    'oracleAdapter': oracle,
    'staking': staking,
})
dep['poolAdapters'] = {'private-credit': pc, 'etherfuse': ef}
dep['engineConfig'] = {
    'poolCapBps': int(pool_cap),
    'originatorCapBps': int(originator_cap),
    'jurisdictionCapBps': int(jurisdiction_cap),
    'reserveFloorBps': int(reserve_floor),
    'vaultReserveFloorBps': int(reserve_floor),
    'floorBinds': (
        'The registered pool caps sum to %d bps and the floor releases %d bps, so there are '
        'states reachable by ordinary allocations in which every concentration cap is '
        'satisfied and the reserve floor is the only limit refusing the call.'
        % (2 * int(pool_cap), 10000 - int(reserve_floor))
    ),
    'floorEnforcedTwice': (
        'The Vault keeps its own copy of the floor and applies it in settle_allocation, '
        'against its own deployed capital book rather than anything the Engine reports. '
        'The Engine is an address the Vault authorizes, so a floor enforced only in the '
        'Engine is a floor any contract holding that authorization can skip.'
    ),
    'measuredOn': (
        'Free reserves and net assets, not the gross balance. USDC owed to a queued '
        'withdrawal is on the Vault balance and is not deployable, because the agUSD that '
        'entitled anyone else to it has already been burned.'
    ),
    'pools': {
        'private-credit': {'originator': 'QIRO', 'jurisdiction': 'LU', 'capBps': int(pool_cap)},
        'etherfuse': {'originator': 'ETHERFUS', 'jurisdiction': 'MX', 'capBps': int(pool_cap)},
    },
}
dep['oracleFeeds'] = {
    'USDC_USD': {'stalenessSecs': 3600, 'deviationBps': 200,
                 'minNav': 9000000, 'maxNav': 11000000, 'minIntervalSecs': 300},
    'PC_NAV': {'stalenessSecs': 604800, 'deviationBps': 500,
               'minNav': 5000000, 'maxNav': 20000000, 'minIntervalSecs': 3600},
    'EF_BOND': {'stalenessSecs': 172800, 'deviationBps': 0,
                'minNav': 5000000, 'maxNav': 20000000, 'minIntervalSecs': 3600},
}
dep['oracleFeedGuards'] = (
    'The band bounds every report including the first, which a deviation bound cannot '
    'reach because a bound on a move needs something to move from. The minimum interval '
    'is measured in ledger time between accepted values, not in the timestamps the '
    'reporter supplies, because the reporter chooses those. The reference point is '
    'persistent, so it cannot expire out from under the checks that read it.'
)
dep['adminRotation'] = (
    'Every contract carries propose_admin and accept_admin. The handover is two steps '
    'and the successor has to authorize the second one itself, so the role cannot be '
    'handed to an address nobody controls.'
)
dep['superseded'] = history
json.dump(dep, open(path, 'w'), indent=2)
open(path, 'a').write('\n')
print(json.dumps(dep['contracts'], indent=2))
PY
echo "==> done"
