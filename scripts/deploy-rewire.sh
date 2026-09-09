#!/usr/bin/env bash
# Redeploy and rewire the generation 2 stack into one that is coherent end to
# end: Vault, agUSD, Allocation Engine, both pool adapters and sagUSD, every one
# of them pointing at the others.
#
# Why all six and not just the Engine
#
# The Engine was the visible problem: it stores its Vault at initialize() with
# no setter, so it stayed pointed at a Vault that had already been superseded.
# Redeploying it alone does not fix anything, because the Vault has the mirror
# image of the same bug. Vault.settle_allocation authorizes the Engine address
# written by its own initialize(), and the live Vault wrote the old Engine, so a
# replacement Engine is simply not an address that Vault will accept a release
# from. It has taken deposits and paid its queue and it can never deploy a
# dollar, whatever is deployed around it.
#
# Fixing that needs a Vault carrying set_engine, which means a new Vault. The
# live agUSD names its Vault as the only minter and freezes that pointer, so a
# new Vault needs a new agUSD too. The adapters store both the Engine and the
# Vault with no setters, so they follow. sagUSD stores its agUSD with no setter,
# so it follows as well. One missing setter, six contracts.
#
# What this script does NOT touch: the real Circle USDC SAC, the six credit
# vaults, the generation 1 agUSD, and the Oracle Adapter, which binds no Vault
# and no Engine and is reused exactly as it is.
#
# The deliberate detour
#
# Every contract here is initialized against the superseded counterpart it would
# have been stuck to, and then corrected with the new setter before it holds any
# state. That is on purpose, and it follows scripts/deploy-agusd-core.sh: the
# recovery path is exercised on-chain against the real addresses that caused the
# incident, rather than described in a comment. Each correction is a transaction
# hash anybody can check.
#
# Superseded by scripts/deploy-hardening.sh, which redeploys the same stack plus
# the Oracle Adapter with the fixes from the adversarial security review. This
# is kept because the addresses and transactions it produced are still on the
# ledger and still recorded.
#
# Usage: bash scripts/deploy-rewire.sh
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
# is minted against, and the same name and symbol as every generation before it.
DECIMALS=7
AGUSD_NAME="Agama USD"
AGUSD_SYMBOL=agUSD
SAGUSD_NAME="Staked agUSD"
SAGUSD_SYMBOL=sagUSD
FEED=PC_NAV

# Allocation Engine limits, in bps of total assets.
#
# The previous configuration was two pools capped at 30% each against a 20%
# reserve floor. Those numbers cannot both matter: two pools at 30% can deploy
# at most 60% of the book, so 40% stays idle whatever the operator does and the
# floor is never the reason anything is refused. The pool cap fires first, every
# time, and the floor is a guard that passes its own unit test and does nothing.
#
# A floor binds only when the registered pool caps sum to more than it is
# willing to release. Two pools at 40% can absorb 80%; the floor releases 75%;
# the last 5% belongs to the floor alone. Filling private credit to 40% and
# Etherfuse to 35% lands idle reserves exactly on the floor, and 5% more into
# Etherfuse is inside every concentration cap and still refused.
#
# The caps stay nested, pool under originator under jurisdiction, so the
# per-pool limit is the tightest concentration constraint and the aggregate ones
# bind when an originator or a jurisdiction fronts more than one pool.
POOL_CAP=4000          # 40% in any single pool
ORIGINATOR_CAP=4500    # 45% behind any single originator
JURISDICTION_CAP=5000  # 50% under any single legal regime
RESERVE_FLOOR=2500     # 25% of total assets stays as idle USDC in the Vault

# Why this run is retiring what it retires. It goes into deployments/testnet.json
# against every address this script replaces, so it is the sentence a reviewer
# reads next to a dead contract. "%s" is filled in with the contract's name.
# Change it: a deployment that inherits the previous one's reason is a
# deployment whose record is fiction.
RETIREMENT_REASON="Replaced by scripts/deploy-rewire.sh. This %s carried the counterparty setters but the guards on them were too loose: Vault.set_engine accepted any address, including an ordinary account, which made the pointer that releases the Vault's reserves a one call instruction to hand them over, and the adapters could be repointed at a Vault their own Engine did not govern, which would have misdirected repayments one allocation later. Deployed and replaced the same day, before it held anything but the deploying admin's own working capital."

# Pool registration metadata, unchanged from the previous deployment for
# continuity: the private credit facility is fronted by Qiro through a
# Luxembourg SPV, the Etherfuse leg is tokenized Mexican government debt.
PC_ORIGINATOR=QIRO;      PC_JURISDICTION=LU
EF_ORIGINATOR=ETHERFUS;  EF_JURISDICTION=MX

j() { python3 -c "import json;d=json.load(open('$DEP'));print($1)"; }
ADMIN=$(stellar keys address "$SRC")
USDC=$(j "d['contracts']['usdc']")
ORACLE=$(j "d['contracts']['oracleAdapter']")
COOLDOWN=$(j "d['cooldownSeconds']")
AGUSD_V1=$(j "d['contracts']['agusd']")
OLD_AGUSD=$(j "d['contracts']['agusdCore']")
OLD_VAULT=$(j "d['contracts']['vault']")
OLD_ENGINE=$(j "d['contracts']['allocationEngine']")
OLD_STAKING=$(j "d['contracts']['staking']")
OLD_PC=$(j "d['poolAdapters']['private-credit']")
OLD_EF=$(j "d['poolAdapters']['etherfuse']")

echo "admin                      = $ADMIN"
echo "usdc (live, reused)        = $USDC"
echo "oracle-adapter (reused)    = $ORACLE"
echo "agusd generation 1         = $AGUSD_V1 (untouched)"
echo "superseded agusd-core      = $OLD_AGUSD"
echo "superseded vault           = $OLD_VAULT"
echo "superseded engine          = $OLD_ENGINE"
echo "superseded staking         = $OLD_STAKING"
echo "superseded pool adapters   = $OLD_PC, $OLD_EF"

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

# Retire what the superseded pair is still holding, before anything replaces it.
#
# The generation 2 agUSD can only be redeemed through the Vault that mints it,
# and that Vault is about to stop being the protocol's Vault. Redeeming now
# means the token is superseded with a zero supply and strands nobody, rather
# than leaving a claim that only a contract nothing points at can honour. It
# also returns the USDC, which is the working capital the new stack runs on.
#
# The superseded Engine's book is unwound for the same reason: an exposure
# record on a stack nobody drives is a number that will still be there in a
# year, reading as capital deployed.
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
  echo "    book now            $(q "$OLD_ENGINE" total_allocated)"
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
PC=$(deploy "$WASM/private_credit.wasm")
EF=$(deploy "$WASM/etherfuse.wasm")
STAKING=$(deploy "$WASM/staking.wasm")
echo "    vault             = $VAULT"
echo "    agusd-core        = $AGUSD"
echo "    allocation-engine = $ENGINE"
echo "    private-credit    = $PC"
echo "    etherfuse         = $EF"
echo "    staking (sagUSD)  = $STAKING"

# Each contract below is wired to the address it would have been stuck to, and
# then walked out of it. The point is not ceremony: it puts every one of the
# five setters on the ledger, applied to the exact superseded addresses that
# caused the incident, at a moment when the guard permits it.
echo ""
echo "==> agusd-core: minter set to the superseded Vault, then corrected"
echo "    initialize        tx $(tx "$AGUSD" initialize --admin "$ADMIN" --minter "$OLD_VAULT" \
  --decimal "$DECIMALS" --name "$AGUSD_NAME" --symbol "$AGUSD_SYMBOL")"
echo "    set_minter        tx $(tx "$AGUSD" set_minter --admin "$ADMIN" --minter "$VAULT")"

# The Engine goes first from here on, and the order is a consequence of the
# guards rather than a preference. Vault.set_engine refuses any address that
# does not answer that it governs this Vault, and the adapters refuse any pair
# whose Engine does not govern the Vault offered with it, so the Engine has to
# be pointed at the new Vault before anything else can be pointed at the Engine.
echo ""
echo "==> allocation-engine: pointed at the superseded Vault, then corrected"
echo "    initialize        tx $(tx "$ENGINE" initialize --admin "$ADMIN" --vault "$OLD_VAULT")"
echo "    set_vault         tx $(tx "$ENGINE" set_vault --admin "$ADMIN" --vault "$VAULT")"

echo ""
echo "==> vault: wired to the superseded token and Engine, then corrected"
echo "    initialize        tx $(tx "$VAULT" initialize --admin "$ADMIN" --usdc_token "$USDC" \
  --agusd_token "$OLD_AGUSD" --allocation_engine "$OLD_ENGINE")"
echo "    set_agusd         tx $(tx "$VAULT" set_agusd --admin "$ADMIN" --agusd_token "$AGUSD")"
# Two guards meet on this line. The Engine being left has a live, non-empty
# exposure book, and every stroop of it was funded by a different Vault, so a
# guard that only asked whether capital was deployed would refuse the one call
# it exists for. And the Engine being adopted has to answer that it governs this
# Vault, which is why it was configured first and which is what stops this
# pointer being aimed at an ordinary account.
echo "    set_engine        tx $(tx "$VAULT" set_engine --admin "$ADMIN" --allocation_engine "$ENGINE")"
echo "    set_oracle        tx $(tx "$VAULT" set_oracle --admin "$ADMIN" --oracle "$ORACLE" --feed_id "$FEED")"

echo ""
echo "==> pool adapters: wired to the superseded pair, then corrected"
for pair in "private-credit:$PC" "etherfuse:$EF"; do
  name=${pair%%:*}; id=${pair#*:}
  echo "  $name"
  echo "    initialize        tx $(tx "$id" initialize --admin "$ADMIN" --engine "$OLD_ENGINE" \
    --vault "$OLD_VAULT" --usdc "$USDC")"
  echo "    set_counterparties tx $(tx "$id" set_counterparties --admin "$ADMIN" \
    --engine "$ENGINE" --vault "$VAULT")"
done

echo ""
echo "==> sagUSD: wired to the generation 1 agUSD, then corrected"
echo "    initialize        tx $(tx "$STAKING" initialize --admin "$ADMIN" --agusd "$AGUSD_V1" \
  --cooldown_seconds "$COOLDOWN" --decimal "$DECIMALS" --name "$SAGUSD_NAME" --symbol "$SAGUSD_SYMBOL")"
echo "    set_agusd         tx $(tx "$STAKING" set_agusd --admin "$ADMIN" --agusd "$AGUSD")"

# The Engine ships fail closed: every cap at zero and the reserve floor at 100%,
# so it refuses to deploy capital until this block runs.
echo ""
echo "==> opening the Engine up to its configured limits"
echo "    set_caps           tx $(tx "$ENGINE" set_caps --admin "$ADMIN" --pool_cap_bps "$POOL_CAP" \
  --originator_cap_bps "$ORIGINATOR_CAP" --jurisdiction_cap_bps "$JURISDICTION_CAP")"
echo "    set_reserve_floor  tx $(tx "$ENGINE" set_reserve_floor --admin "$ADMIN" --floor_bps "$RESERVE_FLOOR")"
echo "    register pc        tx $(tx "$ENGINE" register_pool --admin "$ADMIN" --pool_id "$PC" \
  --originator "$PC_ORIGINATOR" --jurisdiction "$PC_JURISDICTION" --cap_bps "$POOL_CAP")"
echo "    register ef        tx $(tx "$ENGINE" register_pool --admin "$ADMIN" --pool_id "$EF" \
  --originator "$EF_ORIGINATOR" --jurisdiction "$EF_JURISDICTION" --cap_bps "$POOL_CAP")"

echo ""
echo "==> checking the wiring, every pointer in both directions"
echo "    vault.agusd()             = $(q "$VAULT" agusd)"
echo "    vault.allocation_engine() = $(q "$VAULT" allocation_engine)"
echo "    vault.usdc()              = $(q "$VAULT" usdc)"
echo "    agusd.minter()            = $(q "$AGUSD" minter)"
echo "    engine.vault()            = $(q "$ENGINE" vault)"
echo "    engine.caps()             = $(q "$ENGINE" caps)"
echo "    engine.reserve_floor()    = $(q "$ENGINE" reserve_floor_bps)"
echo "    private-credit.engine()   = $(q "$PC" engine)"
echo "    private-credit.vault()    = $(q "$PC" vault)"
echo "    etherfuse.engine()        = $(q "$EF" engine)"
echo "    etherfuse.vault()         = $(q "$EF" vault)"
echo "    staking.agusd()           = $(q "$STAKING" agusd)"

echo ""
echo "==> writing $DEP"
python3 - "$DEP" "$VAULT" "$AGUSD" "$ENGINE" "$PC" "$EF" "$STAKING" \
  "$OLD_VAULT" "$OLD_AGUSD" "$OLD_ENGINE" "$OLD_PC" "$OLD_EF" "$OLD_STAKING" \
  "$POOL_CAP" "$ORIGINATOR_CAP" "$JURISDICTION_CAP" "$RESERVE_FLOOR" \
  "$RETIREMENT_REASON" <<'PY'
import json, sys
(path, vault, agusd, engine, pc, ef, staking,
 old_vault, old_agusd, old_engine, old_pc, old_ef, old_staking,
 pool_cap, originator_cap, jurisdiction_cap, reserve_floor,
 retirement_reason) = sys.argv[1:]
dep = json.load(open(path))

# Whatever was recorded as superseded before stays recorded. The history of this
# deployment is part of what is being submitted, so nothing is dropped and every
# entry carries the reason it was replaced.
history = dep.get('superseded', [])
if isinstance(history, dict):
    history = [
        dict(contract=name, generation=1, label=name, **entry)
        for name, entry in history.items()
    ]


ORDINALS = ['first', 'second', 'third', 'fourth', 'fifth', 'sixth']


def retire(contract, address, name, reason):
    """Append a superseded entry, numbering it after the ones already there."""
    generation = 1 + sum(1 for e in history if e['contract'] == contract)
    history.append({
        'contract': contract,
        'generation': generation,
        'label': '%s, %s deployment' % (name, ORDINALS[generation - 1]),
        'address': address,
        'supersededBy': contract,
        'reason': reason,
    })


# One reason for all six, given once. They are retired together because they are
# a stack: whatever is wrong with one of them, correcting it means redeploying
# the ones that name it. The text comes from the script rather than from here so
# that a run has to say what it is actually retiring and why.
RETIREMENT_REASON = retirement_reason

retirements = [
    {
        'contract': 'vault',
        'address': old_vault,
        'name': 'Vault Contract',
        'reason': RETIREMENT_REASON % 'Vault Contract',
    },
    {
        'contract': 'agusdCore',
        'name': 'agUSD',
        'address': old_agusd,
        'reason': RETIREMENT_REASON % 'agUSD',
    },
    {
        'contract': 'allocationEngine',
        'name': 'Allocation Engine',
        'address': old_engine,
        'reason': RETIREMENT_REASON % 'Allocation Engine',
    },
    {
        'contract': 'poolAdapters.private-credit',
        'name': 'Private credit adapter',
        'address': old_pc,
        'reason': RETIREMENT_REASON % 'private credit adapter',
    },
    {
        'contract': 'poolAdapters.etherfuse',
        'name': 'Etherfuse adapter',
        'address': old_ef,
        'reason': RETIREMENT_REASON % 'Etherfuse adapter',
    },
    {
        'contract': 'staking',
        'name': 'sagUSD staking',
        'address': old_staking,
        'reason': RETIREMENT_REASON % 'sagUSD staking',
    },
]
for entry in retirements:
    retire(entry['contract'], entry['address'], entry['name'], entry['reason'])

dep['contracts'].update({
    'vault': vault,
    'agusdCore': agusd,
    'allocationEngine': engine,
    'staking': staking,
})
dep['poolAdapters'] = {'private-credit': pc, 'etherfuse': ef}
dep['engineConfig'] = {
    'poolCapBps': int(pool_cap),
    'originatorCapBps': int(originator_cap),
    'jurisdictionCapBps': int(jurisdiction_cap),
    'reserveFloorBps': int(reserve_floor),
    'floorBinds': (
        'The registered pool caps sum to %d bps and the floor releases %d bps, so there are '
        'states reachable by ordinary allocations in which every concentration cap is '
        'satisfied and the reserve floor is the only limit refusing the call.'
        % (2 * int(pool_cap), 10000 - int(reserve_floor))
    ),
    'pools': {
        'private-credit': {'originator': 'QIRO', 'jurisdiction': 'LU', 'capBps': int(pool_cap)},
        'etherfuse': {'originator': 'ETHERFUS', 'jurisdiction': 'MX', 'capBps': int(pool_cap)},
    },
}
dep['superseded'] = history
json.dump(dep, open(path, 'w'), indent=2)
open(path, 'a').write('\n')
print(json.dumps(dep, indent=2))
PY
echo "==> done"
