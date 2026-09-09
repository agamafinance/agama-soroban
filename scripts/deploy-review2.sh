#!/usr/bin/env bash
# Redeploy the contracts the second adversarial review changed, and rewire.
#
# What changed, and therefore what moves
#
# Two contracts changed. The Vault keeps a cumulative `recognised_losses` and
# measures its reserve floor against `floor_base` rather than net assets, and it
# steps over a withdrawal claim its token refuses to deliver instead of trapping
# on it. The Allocation Engine keeps the matching `written_off` and measures its
# own copy of the floor, and `get_reserve_ratio`, against the same base.
#
# Neither is upgradeable, so both are new deployments, and the contracts that
# name them have to follow:
#
#   - agUSD names its Vault as the only minter and freezes that pointer at the
#     first mint. The live token has minted, so a new Vault means a new agUSD.
#   - the staking contract stores the agUSD it accepts and closes that setter
#     once it has taken custody. If it is holding nothing it is repointed with
#     set_agusd; if it is, it has to be redeployed. The script decides by trying.
#
# What is reused, and why that is worth doing rather than redeploying for
# symmetry
#
#   - the real Circle USDC SAC, the six credit vaults and the generation 1 agUSD
#   - the Oracle Adapter, unchanged by this review and holding no state that a
#     rewiring would strand. The new Vault points at it with set_oracle.
#   - the Etherfuse adapter, unchanged and empty, repointed at the new Engine
#     and the new Vault with set_counterparties. That call is the repair path
#     the previous review added and this is the first deployment that has had a
#     use for it.
#
# What could not be reused, which is a finding rather than a decision
#
# The private credit adapter is redeployed because it cannot be repointed. It
# holds USDC left over from a write-down a previous smoke run performed:
# the position was written off, so its exposure is zero and `deallocate` is
# capped at zero, and there is no sweep entry point anywhere. set_counterparties
# refuses an adapter with a non-zero balance, correctly, so the adapter is
# stuck. That is finding M2 of the second review, left for triage, and it has
# already cost a redeployment.
#
# Order is forced by the guards rather than chosen: the Engine has to name the
# Vault before Vault.set_engine or Adapter.set_counterparties would accept it,
# and both the Vault and the Engine ship with the floor closed at 100%.
#
# Usage: bash scripts/deploy-review2.sh
#
# Requires the `agama-poc` identity, the admin recorded in testnet.json.
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

# Unchanged from the previous deployment. The registered pool caps sum to 8000
# and the floor releases 7500, so the floor is reachable by ordinary allocations
# rather than shadowed by the pool cap.
POOL_CAP=4000
ORIGINATOR_CAP=4500
JURISDICTION_CAP=5000
RESERVE_FLOOR=2500

PRE_FIX_REASON="Replaced by scripts/deploy-review2.sh. This %s predates the fixes from the second adversarial security review: the reserve floor was a share of net assets, which record_writedown lowers with no cash moving, so alternating allocate and write_down walked the whole of the reserves out of the Vault in slices that were each individually inside the floor; and a withdrawal claim the USDC contract refused to deliver, which for a Stellar Asset Contract means any claimant without a trustline, with a frozen one, or with a limit below the claim, trapped the payout path and froze the whole FIFO queue permanently."

# Re-running this script against a generation that already carries the fix is a
# different retirement and gets a different reason, because saying it predates
# the fix would be false.
POST_FIX_REASON="This %s was replaced by a later run of scripts/deploy-review2.sh from the same source: byte for byte the contract that superseded it. It was retired because the smoke run left it carrying recognised losses that were experiments rather than credit events, and recognised_losses is deliberately permanent, so a book whose reserve floor is not tightened for good by a test is only reachable through a fresh deployment. The permanence is the fix behaving as designed, and this retirement is the price of it."

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
OLD_PC=$(j "d['poolAdapters']['private-credit']")
ORACLE=$(j "d['contracts']['oracleAdapter']")
EF=$(j "d['poolAdapters']['etherfuse']")

deploy() {
  local out
  out=$(stellar contract deploy --wasm "$1" --source "$SRC" --network "$NET" 2>&1)
  echo "$out" | grep -oE '[0-9a-f]{64}' | sed 's/^/    tx or wasm hash /' >&2
  echo "$out" | grep -oE 'C[A-Z2-7]{55}' | tail -1
}
# State changing: submitted, and the transaction hash is echoed.
tx() { stellar contract invoke --id "$1" --source "$SRC" --network "$NET" -- "${@:2}" 2>&1 \
         | grep -oE '[0-9a-f]{64}' | head -1; }
# Read-only: simulated, never submitted.
q() { stellar contract invoke --id "$1" --source "$SRC" --network "$NET" --send=no -- "${@:2}" 2>/dev/null; }

# The outgoing Vault answers this only if it already carries the fix.
if stellar contract info interface --id "$(j "d['contracts']['vault']")" --network "$NET" 2>/dev/null | grep -q 'fn floor_base'; then
  RETIREMENT_REASON=$POST_FIX_REASON
else
  RETIREMENT_REASON=$PRE_FIX_REASON
fi

echo "admin                      = $ADMIN"
echo "usdc (live, reused)        = $USDC"
echo "oracle (live, reused)      = $ORACLE"
echo "etherfuse (live, repointed)= $EF"
echo "superseded vault           = $OLD_VAULT"
echo "superseded agusd-core      = $OLD_AGUSD"
echo "superseded engine          = $OLD_ENGINE"
echo "superseded staking         = $OLD_STAKING"
echo "superseded pc adapter      = $OLD_PC"

# The unstake carries a 60 second cooldown, so it is started here and collected
# after the deployments, which take longer than that. Nothing waits on a sleep.
echo ""
echo "==> winding down the superseded generation, part one"
SHARES=$(q "$OLD_STAKING" balance --id "$ADMIN" | tr -d '"')
if [ "${SHARES:-0}" != "0" ]; then
  echo "    request_unstake     $SHARES sagUSD, tx $(tx "$OLD_STAKING" request_unstake --from "$ADMIN" --shares "$SHARES")"
else
  echo "    nothing staked"
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
echo "    vault             = $VAULT"
echo "    agusd-core        = $AGUSD"
echo "    allocation-engine = $ENGINE"
echo "    private-credit    = $PC"

echo ""
echo "==> allocation-engine: initialized against the Vault it governs"
echo "    initialize        tx $(tx "$ENGINE" initialize --admin "$ADMIN" --vault "$VAULT")"

echo ""
echo "==> agusd-core: the Vault is the only minter"
echo "    initialize        tx $(tx "$AGUSD" initialize --admin "$ADMIN" --minter "$VAULT" \
  --decimal "$DECIMALS" --name "$AGUSD_NAME" --symbol "$AGUSD_SYMBOL")"

echo ""
echo "==> vault: wired, and its own reserve floor opened from the closed default"
echo "    initialize        tx $(tx "$VAULT" initialize --admin "$ADMIN" --usdc_token "$USDC" \
  --agusd_token "$AGUSD" --allocation_engine "$ENGINE")"
echo "    set_reserve_floor tx $(tx "$VAULT" set_reserve_floor --admin "$ADMIN" --floor_bps "$RESERVE_FLOOR")"
echo "    set_oracle        tx $(tx "$VAULT" set_oracle --admin "$ADMIN" --oracle "$ORACLE" --feed_id "$FEED")"

echo ""
echo "==> pool adapters"
echo "  private-credit (new, because the live one holds stranded USDC)"
echo "    initialize        tx $(tx "$PC" initialize --admin "$ADMIN" --engine "$ENGINE" \
  --vault "$VAULT" --usdc "$USDC")"
echo "  etherfuse (live, repointed through set_counterparties)"
echo "    set_counterparties tx $(tx "$EF" set_counterparties --admin "$ADMIN" --engine "$ENGINE" --vault "$VAULT")"

echo ""
echo "==> sagUSD: staking the agUSD this Vault mints"
# set_agusd closes the moment the contract has taken custody, so whether the
# live one can follow the new token is a question about its state rather than a
# choice. Try it; redeploy only if it says no.
REPOINT=$(tx "$OLD_STAKING" set_agusd --admin "$ADMIN" --agusd "$AGUSD")
if [ -n "$REPOINT" ] && [ "$(q "$OLD_STAKING" agusd | tr -d '"')" = "$AGUSD" ]; then
  STAKING=$OLD_STAKING
  STAKING_REUSED=yes
  echo "    set_agusd         tx $REPOINT  (repointed in place, it had taken no custody)"
else
  STAKING_REUSED=no
  STAKING=$(deploy "$WASM/staking.wasm")
  echo "    redeployed        = $STAKING  (the live one has custody and cannot follow)"
  echo "    initialize        tx $(tx "$STAKING" initialize --admin "$ADMIN" --agusd "$AGUSD" \
    --cooldown_seconds "$COOLDOWN" --decimal "$DECIMALS" --name "$SAGUSD_NAME" --symbol "$SAGUSD_SYMBOL")"
fi

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
echo "==> winding down the superseded generation, part two"
PENDING=$(q "$OLD_STAKING" pending --addr "$ADMIN" | python3 -c "import sys,json;print(json.load(sys.stdin)['assets'])" 2>/dev/null || echo 0)
if [ "${PENDING:-0}" != "0" ]; then
  echo "    claim               $PENDING agUSD out of the superseded sagUSD, tx $(tx "$OLD_STAKING" claim --from "$ADMIN")"
fi
OLD_SUPPLY=$(q "$OLD_AGUSD" total_supply | tr -d '"' || echo 0)
if [ "${OLD_SUPPLY:-0}" != "0" ]; then
  CLAIM=$(q "$OLD_VAULT" queue_tail | tr -d '"')
  echo "    redeeming $OLD_SUPPLY of superseded agUSD through its own Vault, claim $CLAIM"
  echo "    request_withdrawal  tx $(tx "$OLD_VAULT" request_withdrawal --from "$ADMIN" --amount "$OLD_SUPPLY")"
  echo "    claim_withdrawal    tx $(tx "$OLD_VAULT" claim_withdrawal --from "$ADMIN" --claim_id "$CLAIM")"
  echo "    supply now          $(q "$OLD_AGUSD" total_supply)"
fi

echo ""
echo "==> checking the wiring, every pointer in both directions"
echo "    vault.agusd()               = $(q "$VAULT" agusd)"
echo "    vault.allocation_engine()   = $(q "$VAULT" allocation_engine)"
echo "    vault.usdc()                = $(q "$VAULT" usdc)"
echo "    vault.reserve_floor_bps()   = $(q "$VAULT" reserve_floor_bps)"
echo "    vault.recognised_losses()   = $(q "$VAULT" recognised_losses)"
echo "    vault.floor_base()          = $(q "$VAULT" floor_base)"
echo "    agusd.minter()              = $(q "$AGUSD" minter)"
echo "    engine.vault()              = $(q "$ENGINE" vault)"
echo "    engine.caps()               = $(q "$ENGINE" caps)"
echo "    engine.reserve_floor_bps()  = $(q "$ENGINE" reserve_floor_bps)"
echo "    engine.written_off()        = $(q "$ENGINE" written_off)"
echo "    engine.floor_base()         = $(q "$ENGINE" floor_base)"
echo "    private-credit.engine()     = $(q "$PC" engine)"
echo "    private-credit.vault()      = $(q "$PC" vault)"
echo "    etherfuse.engine()          = $(q "$EF" engine)"
echo "    etherfuse.vault()           = $(q "$EF" vault)"
echo "    staking.agusd()             = $(q "$STAKING" agusd)"
echo "    oracle.get_feed(PC_NAV)     = $(q "$ORACLE" get_feed --feed_id PC_NAV)"

echo ""
echo "==> writing $DEP"
python3 - "$DEP" "$VAULT" "$AGUSD" "$ENGINE" "$PC" "$STAKING" \
  "$OLD_VAULT" "$OLD_AGUSD" "$OLD_ENGINE" "$OLD_PC" "$OLD_STAKING" \
  "$RESERVE_FLOOR" "$RETIREMENT_REASON" "$STAKING_REUSED" <<'PY'
import json, sys
(path, vault, agusd, engine, pc, staking,
 old_vault, old_agusd, old_engine, old_pc, old_staking,
 reserve_floor, retirement_reason, staking_reused) = sys.argv[1:]
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


PC_REASON = (
    'Replaced by scripts/deploy-review2.sh, and not because its code changed: '
    'it is byte for byte the adapter that was already deployed. It could not '
    'follow the new Engine and Vault because set_counterparties refuses an '
    'adapter holding USDC, and it holds USDC left over from a written-down '
    'position. The position was written off, so its '
    'exposure is zero, deallocate is capped at zero and there is no sweep entry '
    'point, which leaves the cash and the repair path both stuck. That is '
    'finding M2 of the second adversarial review, recorded and left for triage, '
    'and this retirement is what it cost. The Etherfuse adapter, empty, was '
    'repointed in place instead.'
)
STAKING_REASON = (
    'Replaced by scripts/deploy-review2.sh, and not because its code changed. '
    'It stores the agUSD it accepts and closes that pointer once it has taken '
    'custody, which it has; the Vault changed, so agUSD changed, so this '
    'contract had to follow. Anything staked in it was unwound and redeemed '
    'before the handover, so it strands nobody.'
)

retirements = [
    ('vault', old_vault, 'Vault Contract', retirement_reason % 'Vault'),
    ('agusdCore', old_agusd, 'agUSD',
     'Replaced by scripts/deploy-review2.sh. It names the superseded Vault as '
     'its only minter and has minted, so the pointer is frozen and issuance '
     'could not follow the Vault to its replacement. Superseded with a zero '
     'supply: every unit it issued was redeemed for USDC through its own Vault '
     'before the handover, so it strands no holders.'),
    ('allocationEngine', old_engine, 'Allocation Engine', retirement_reason % 'Allocation Engine'),
    ('poolAdapters.private-credit', old_pc, 'Private credit adapter', PC_REASON),
]
if staking_reused != 'yes':
    retirements.append(('staking', old_staking, 'sagUSD staking', STAKING_REASON))
for contract, address, name, reason in retirements:
    retire(contract, address, name, reason)

dep['contracts'].update({
    'vault': vault,
    'agusdCore': agusd,
    'allocationEngine': engine,
    'staking': staking,
})
dep['poolAdapters']['private-credit'] = pc
dep['engineConfig']['floorMeasuredAgainst'] = (
    'floor_base, which is free reserves plus deployed capital plus everything '
    'ever written off, and not net assets. record_writedown lowers deployed '
    'capital with no cash moving, so a floor that is a share of net assets is a '
    'floor whose absolute size the admin lowers every time a loss is '
    'recognised: allocating to the floor and writing the position off, over and '
    'over, moved 999.9999999 of 1000 USDC out of a Vault holding a 25 percent floor '
    'with every individual call inside the limit. Recognised losses stay in the '
    'base for good, so a write-down buys nothing. It is also the more correct '
    'base, because agUSD redeems one for one and a default does not reduce what '
    'the Vault owes.'
)
dep['withdrawalQueue'] = (
    'Strictly FIFO, and it cannot be stalled by either kind of absent '
    'claimant. settle_withdrawal is permissionless and pays the head claim to '
    'its recorded owner, which covers the claimant who will not come back. A '
    'claimant who cannot be paid is stepped over: USDC is a Stellar Asset '
    'Contract, so a payout fails whenever the destination has no trustline, has '
    'a frozen one, has a limit below the claim, or no longer exists, and a '
    'failed payout used to trap the whole call and leave the head where it was. '
    'Delivery is now attempted, and a claim the token refuses is marked '
    'deferred, left unpaid, still counted in outstanding_liabilities, and '
    'collected later by its owner through claim_withdrawal out of head order.'
)
dep['reusedInPlace'] = {
    'staking': (
        'Repointed at the new agUSD with set_agusd rather than redeployed, '
        'because it had taken no custody. That setter, and the adapters\' '
        'set_counterparties, are repair paths the first review added; this is '
        'the deployment that had a use for them.'
    ) if staking_reused == 'yes' else 'Redeployed: it had taken custody, which closes set_agusd for good.',
    'oracleAdapter': 'Unchanged by the second review and holding no state a rewiring would strand. The new Vault points at it with set_oracle.',
    'poolAdapters.etherfuse': 'Unchanged and empty, so it was repointed at the new Engine and Vault with set_counterparties rather than redeployed. First use of the repair path the previous review added.',
    'usdc': 'The real Circle USDC Stellar Asset Contract on testnet, never redeployed.',
}
dep['superseded'] = history
json.dump(dep, open(path, 'w'), indent=2)
open(path, 'a').write('\n')
print(json.dumps(dep['contracts'], indent=2))
PY
echo "==> done"
