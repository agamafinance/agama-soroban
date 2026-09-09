#!/usr/bin/env bash
# Redeploy the stack for the Medium findings of the second adversarial review,
# and rewire it.
#
# What changed, and therefore what moves
#
#   - the Allocation Engine measures its three concentration caps on charged
#     exposure, deployed plus written off, so a write-down no longer resets a
#     cap the way it used to reset the reserve floor (M1); it gains `recover`,
#     the way home for capital stranded in an adapter (M2); it refuses
#     `write_down` and `recover` with a named `AdminMismatch` and reports
#     `admin_aligned()` when its admin and the Vault's have diverged (M4).
#   - the Vault gains `record_recovery`, which releases a recognised loss only
#     against cash it can see arriving (M2), and `bump_claim`, the permissionless
#     TTL bump the withdrawal queue needed and no contract exposed (M3).
#   - both pool adapters gain `recover_surplus`, which sends everything above
#     booked exposure to the Vault they already name (M2).
#   - every protocol contract replaces `initialize` with a `__constructor` that
#     runs inside the deploy transaction and interrogates its counterparty (M5).
#
# That last one is why this is a full redeployment rather than a rewiring.
# `initialize` is gone from seven contracts, so every deployed contract in the
# stack differs from the source it is supposed to be, and a deployment whose
# bytecode does not match the repository is not one an auditor can use.
#
# What is reused, and why
#
#   - the real Circle USDC Stellar Asset Contract, never redeployed
#   - the six credit vaults and the generation 1 agUSD, untouched by any of this
#
# Nothing else can be reused, and the reason is the same in every case: the
# constructor replaced the entry point these contracts were wired through, so
# there is no live contract carrying the code this deployment is of. Where a
# setter would have sufficed it is said so below; where it would not, that is a
# finding rather than a preference.
#
# Order is forced by the guards rather than chosen, and the shape of the order is
# itself the M5 fix. Every pointer is now validated by whoever receives it, and
# two contracts cannot each validate the other first, so the wiring runs in the
# one sequence in which each check has something real to check:
#
#   1. Vault, which needs only USDC and checks it answers the token interface
#   2. agUSD, naming the Vault as its minter
#   3. Vault.set_agusd, which checks the token names it back
#   4. Engine, naming the Vault, checking the Vault answers with the same admin
#   5. Vault.set_engine, which checks the Engine governs it with an empty book
#   6. the adapters, each checking its Engine governs the Vault it was given
#   7. register_pool, which checks the adapter names this Engine and this Vault
#
# Usage: bash scripts/deploy-mediums.sh
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

PC_ORIGINATOR=QIRO;      PC_JURISDICTION=LU
EF_ORIGINATOR=ETHERFUS;  EF_JURISDICTION=MX

j() { python3 -c "import json;d=json.load(open('$DEP'));print($1)"; }
ADMIN=$(stellar keys address "$SRC")
USDC=$(j "d['contracts']['usdc']")
COOLDOWN=$(j "d['cooldownSeconds']")
OLD_AGUSD=$(j "d['contracts']['agusdCore']")
OLD_VAULT=$(j "d['contracts']['vault']")
OLD_ENGINE=$(j "d['contracts']['allocationEngine']")
OLD_ORACLE=$(j "d['contracts']['oracleAdapter']")
OLD_STAKING=$(j "d['contracts']['staking']")
OLD_PC=$(j "d['poolAdapters']['private-credit']")
OLD_EF=$(j "d['poolAdapters']['etherfuse']")

f() { j "d['oracleFeeds']['$1']['$2']"; }

# Deploy with constructor arguments. Everything after the `--` is the
# constructor's, and it runs inside this transaction: there is no window between
# the deploy and the wiring for anyone else's call to land in.
deploy() {
  local wasm=$1; shift
  local out
  out=$(stellar contract deploy --wasm "$wasm" --source "$SRC" --network "$NET" -- "$@" 2>&1)
  # The CLI prints an install transaction, a WASM hash and a deploy transaction,
  # and all three look the same. Only two of them are on the ledger as
  # transactions, so they are labelled rather than left to be guessed at.
  echo "$out" | grep -oE 'Using wasm hash [0-9a-f]{64}' | sed 's/^/    /' >&2
  echo "$out" | grep -oE 'Transaction hash is [0-9a-f]{64}' | sed 's/Transaction hash is/    deploy tx/' >&2
  echo "$out" | grep -oE 'C[A-Z2-7]{55}' | tail -1
}
# State changing: submitted, and the transaction hash is echoed.
tx() { stellar contract invoke --id "$1" --source "$SRC" --network "$NET" -- "${@:2}" 2>&1 \
         | grep -oE '[0-9a-f]{64}' | head -1; }
# Read-only: simulated, never submitted.
q() { stellar contract invoke --id "$1" --source "$SRC" --network "$NET" --send=no -- "${@:2}" 2>/dev/null; }
q0() { q "$@" | tr -d '"'; }

echo "admin                      = $ADMIN"
echo "usdc (live, reused)        = $USDC"
echo "superseded vault           = $OLD_VAULT"
echo "superseded agusd-core      = $OLD_AGUSD"
echo "superseded engine          = $OLD_ENGINE"
echo "superseded oracle          = $OLD_ORACLE"
echo "superseded staking         = $OLD_STAKING"
echo "superseded pc adapter      = $OLD_PC"
echo "superseded ef adapter      = $OLD_EF"

# The unstake carries a cooldown, so it is started here and collected after the
# deployments, which take longer than that. Nothing waits on a sleep.
echo ""
echo "==> winding down the superseded generation, part one"
SHARES=$(q0 "$OLD_STAKING" balance --id "$ADMIN")
if [ "${SHARES:-0}" != "0" ]; then
  echo "    request_unstake     $SHARES sagUSD, tx $(tx "$OLD_STAKING" request_unstake --from "$ADMIN" --shares "$SHARES")"
else
  echo "    nothing staked"
fi

echo ""
echo "==> building"
stellar contract build >/dev/null

# ---------------------------------------------------------------------------
echo ""
echo "==> 1. vault, which takes the one pointer that is not circular"
VAULT=$(deploy "$WASM/vault.wasm" --admin "$ADMIN" --usdc_token "$USDC")
echo "    vault             = $VAULT"

echo ""
echo "==> 2. agusd-core, naming the Vault as its only minter"
AGUSD=$(deploy "$WASM/agusd_core.wasm" --admin "$ADMIN" --minter "$VAULT" \
  --decimal "$DECIMALS" --name "$AGUSD_NAME" --symbol "$AGUSD_SYMBOL")
echo "    agusd-core        = $AGUSD"

echo ""
echo "==> 3. vault.set_agusd, which checks the token names the Vault back"
echo "    set_agusd         tx $(tx "$VAULT" set_agusd --admin "$ADMIN" --agusd_token "$AGUSD")"

echo ""
echo "==> 4. allocation-engine, which checks the Vault answers with this admin"
ENGINE=$(deploy "$WASM/allocation_engine.wasm" --admin "$ADMIN" --vault "$VAULT")
echo "    allocation-engine = $ENGINE"

echo ""
echo "==> 5. vault.set_engine, which checks the Engine governs this Vault"
echo "    set_engine        tx $(tx "$VAULT" set_engine --admin "$ADMIN" --allocation_engine "$ENGINE")"
# The Vault ships with the floor at 10000 bps, so it releases nothing until this
# line runs. It is set to the same number the Engine enforces: if the two ever
# differ, the tighter of them binds, which is the safe direction.
echo "    set_reserve_floor tx $(tx "$VAULT" set_reserve_floor --admin "$ADMIN" --floor_bps "$RESERVE_FLOOR")"

echo ""
echo "==> 6. pool adapters, each checking its Engine governs the Vault given"
PC=$(deploy "$WASM/private_credit.wasm" --admin "$ADMIN" --engine "$ENGINE" --vault "$VAULT" --usdc "$USDC")
EF=$(deploy "$WASM/etherfuse.wasm" --admin "$ADMIN" --engine "$ENGINE" --vault "$VAULT" --usdc "$USDC")
echo "    private-credit    = $PC"
echo "    etherfuse         = $EF"

echo ""
echo "==> oracle-adapter, redeployed because its initialize became a constructor"
ORACLE=$(deploy "$WASM/oracle_adapter.wasm" --admin "$ADMIN")
echo "    oracle-adapter    = $ORACLE"
echo "    add_reporter      tx $(tx "$ORACLE" add_reporter --admin "$ADMIN" --reporter "$ADMIN")"
for feed in USDC_USD PC_NAV EF_BOND; do
  echo "    register $feed tx $(tx "$ORACLE" register_feed --admin "$ADMIN" --feed_id "$feed" \
    --staleness_secs "$(f "$feed" stalenessSecs)" --deviation_bps "$(f "$feed" deviationBps)" \
    --min_nav "$(f "$feed" minNav)" --max_nav "$(f "$feed" maxNav)" \
    --min_interval_secs "$(f "$feed" minIntervalSecs)")"
done
echo "    set_oracle        tx $(tx "$VAULT" set_oracle --admin "$ADMIN" --oracle "$ORACLE" --feed_id "$FEED")"
# A registered feed with no report is a feed get_nav refuses, which is correct
# and is not a state to leave a fresh deployment in.
NOW=$(python3 -c "import time;print(int(time.time()))")
echo "    push_nav PC_NAV   tx $(tx "$ORACLE" push_nav --reporter "$ADMIN" --feed_id PC_NAV \
  --nav 10000000 --timestamp "$NOW")"

echo ""
echo "==> sagUSD: staking the agUSD this Vault mints"
STAKING=$(deploy "$WASM/staking.wasm" --admin "$ADMIN" --agusd "$AGUSD" \
  --cooldown_seconds "$COOLDOWN" --decimal "$DECIMALS" --name "$SAGUSD_NAME" --symbol "$SAGUSD_SYMBOL")
echo "    staking           = $STAKING"

echo ""
echo "==> 7. opening the Engine up to its configured limits"
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
OLD_SUPPLY=$(q0 "$OLD_AGUSD" total_supply || echo 0)
if [ "${OLD_SUPPLY:-0}" != "0" ]; then
  CLAIM=$(q0 "$OLD_VAULT" queue_tail)
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
echo "    engine.admin_aligned()      = $(q "$ENGINE" admin_aligned)"
echo "    engine.caps()               = $(q "$ENGINE" caps)"
echo "    engine.reserve_floor_bps()  = $(q "$ENGINE" reserve_floor_bps)"
echo "    engine.written_off()        = $(q "$ENGINE" written_off)"
echo "    engine.charged_exposure(pc) = $(q "$ENGINE" charged_exposure --pool_id "$PC")"
echo "    private-credit.engine()     = $(q "$PC" engine)"
echo "    private-credit.vault()      = $(q "$PC" vault)"
echo "    etherfuse.engine()          = $(q "$EF" engine)"
echo "    etherfuse.vault()           = $(q "$EF" vault)"
echo "    staking.agusd()             = $(q "$STAKING" agusd)"
echo "    oracle.get_feed(PC_NAV)     = $(q "$ORACLE" get_feed --feed_id PC_NAV)"
echo "    vault.get_nav()             = $(q "$VAULT" get_nav)"

echo ""
echo "==> writing $DEP"
python3 - "$DEP" "$VAULT" "$AGUSD" "$ENGINE" "$ORACLE" "$PC" "$EF" "$STAKING" \
  "$OLD_VAULT" "$OLD_AGUSD" "$OLD_ENGINE" "$OLD_ORACLE" "$OLD_PC" "$OLD_EF" "$OLD_STAKING" <<'PY'
import json, sys
(path, vault, agusd, engine, oracle, pc, ef, staking,
 old_vault, old_agusd, old_engine, old_oracle, old_pc, old_ef, old_staking) = sys.argv[1:]
dep = json.load(open(path))

# Whatever was recorded as superseded before stays recorded, with the reason it
# was replaced. A deployment record that drops its own history is not one.
history = dep.get('superseded', [])
ORDINALS = ['first', 'second', 'third', 'fourth', 'fifth', 'sixth', 'seventh',
            'eighth', 'ninth', 'tenth']


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


COMMON = (
    'Replaced by scripts/deploy-mediums.sh, which closes the Medium findings of '
    'the second adversarial review. Every contract in this generation wires '
    'itself through an initialize() that runs in its own transaction after the '
    'deploy, which is a public window in which the same call naming a different '
    'admin can land first, and which took its counterparties on trust while the '
    'setters that repair those same pointers interrogated them. A '
    '__constructor replaces it in all seven contracts, so the bytecode of every '
    'one of them differs from the source and none of them could be reused. '
)
REASONS = {
    'allocationEngine': COMMON + (
        'This Allocation Engine also measures its three concentration caps on '
        'live exposure alone, which write_down sets to zero while the adapter '
        'goes on holding the capital, so a pool could be filled to its cap, '
        'written off and filled again without limit; it has no recover, so '
        'capital in an adapter with no exposure left cannot be moved by any '
        'entry point; and a divergence between its admin and the Vault\'s '
        'surfaces as the Vault trapping four frames down rather than as a named '
        'refusal.'
    ),
    'vault': COMMON + (
        'This Vault also has no record_recovery, so capital written off and '
        'later recovered has no way back onto its books, and no bump_claim, so '
        'the keeper the architecture document describes has nothing to call and '
        'a head claim that outlives its 90 day TTL stops the whole withdrawal '
        'queue until somebody pays for a RestoreFootprint.'
    ),
    'agusdCore': COMMON + (
        'It names the superseded Vault as its only minter and has minted, so '
        'the pointer is frozen and issuance could not follow the Vault to its '
        'replacement. Superseded with a zero supply: every unit it issued was '
        'redeemed for USDC through its own Vault before the handover, so it '
        'strands no holders.'
    ),
    'oracleAdapter': COMMON + (
        'Nothing else about this Oracle Adapter changed, and it would have been '
        'reused as it was in the previous two deployments, but a contract whose '
        'deployed bytecode no longer matches the repository is not one an audit '
        'can be run against. Its three feeds are registered again on the '
        'replacement with the same guards.'
    ),
    'staking': COMMON + (
        'It stores the agUSD it accepts and closes that pointer once it has '
        'taken custody, so it would have had to follow the new token in any '
        'case. Its stake was unwound and redeemed before the handover, so it '
        'strands nobody.'
    ),
    'poolAdapters.private-credit': COMMON + (
        'This adapter also has no recover_surplus, which is finding M2: '
        'deallocate is capped at booked exposure, so a written-down position '
        'leaves USDC here that no entry point can move, and because '
        'set_counterparties refuses an adapter holding USDC, one stroop of it '
        'closes the only repair path the contract has. Three earlier '
        'generations of this adapter were retired for exactly that, which is '
        'what the fix cost before it was made.'
    ),
    'poolAdapters.etherfuse': COMMON + (
        'This adapter also has no recover_surplus. It was repointed in place '
        'rather than redeployed in the two previous deployments, being empty '
        'both times, and could have been again; what it could not do is carry '
        'code it does not have.'
    ),
}

for contract, address, name in [
    ('vault', old_vault, 'Vault Contract'),
    ('agusdCore', old_agusd, 'agUSD'),
    ('allocationEngine', old_engine, 'Allocation Engine'),
    ('oracleAdapter', old_oracle, 'Oracle Adapter'),
    ('poolAdapters.private-credit', old_pc, 'Private credit adapter'),
    ('poolAdapters.etherfuse', old_ef, 'Etherfuse adapter'),
    ('staking', old_staking, 'sagUSD staking'),
]:
    retire(contract, address, name, REASONS[contract])

dep['contracts'].update({
    'vault': vault,
    'agusdCore': agusd,
    'allocationEngine': engine,
    'oracleAdapter': oracle,
    'staking': staking,
})
dep['poolAdapters']['private-credit'] = pc
dep['poolAdapters']['etherfuse'] = ef

dep['engineConfig']['capsMeasuredOn'] = (
    'charged_exposure, which is what a pool holds plus what has been written '
    'off against it and not recovered, and not live exposure alone. write_down '
    'sets live exposure to zero while the adapter goes on holding the capital, '
    'so caps measured on it let the same pool be filled to its cap, written off '
    'and filled again without limit, with the originator and jurisdiction sums '
    'following because they are built from the same per-pool numbers. The '
    'denominator stays real total assets: losses belong in the floor base, '
    'where a larger base is a tighter constraint, and not in a cap denominator, '
    'where a larger base is a looser one. A defaulted originator does not get '
    'its limit back by defaulting.'
)
dep['strandedCapital'] = (
    'Engine.recover(admin, pool_id) sweeps whatever an adapter holds above its '
    'booked exposure to the Vault the adapter already names, and the Vault '
    'releases the recognised loss against it only after verifying the cash '
    'arrived in its own balance. Neither the destination nor the amount is a '
    'parameter, so there is nothing for an admin to aim. floor_base does not '
    'move: the loss the recovery removes from the base is exactly the cash it '
    'adds to free reserves, so what a write-down cannot buy, a recovery cannot '
    'buy back. Adapter.recover_surplus is also callable by the adapter admin '
    'directly, which is the path that still works when the Engine an adapter is '
    'stuck to has itself been superseded, and which is the state that retired '
    'three private credit adapters.'
)
dep['claimTtl'] = (
    'Vault.bump_claim(claim_id) is permissionless and extends a claim record\'s '
    'TTL. Claims are persistent with a 90 day bump written only when the claim '
    'is written, the queue is allowed to stall by design, and the book behind it '
    'settles at D+15 to D+90, so a head claim outliving its TTL is ordinary. An '
    'archived persistent entry cannot be read, so read_claim used to fail and '
    'stop the queue for everyone until an out-of-band RestoreFootprint. The '
    'caller chooses nothing, cannot shorten a TTL and pays the rent.'
)
dep['adminRotation'] = (
    'Every contract carries propose_admin and accept_admin. The handover is two '
    'steps and the successor has to authorize the second one itself, so the role '
    'cannot be handed to an address nobody controls. The Engine and the Vault '
    'rotate independently and write_down and recover need one signature that '
    'satisfies both, so a half finished rotation disables loss recognition: the '
    'Engine now refuses with a named AdminMismatch rather than trapping on the '
    'Vault\'s NotAdmin, and admin_aligned() reports the divergence at any time '
    'rather than leaving it to be discovered during a default.'
)
dep['wiring'] = (
    'Every protocol contract wires itself in a __constructor that runs inside '
    'the transaction that deploys it, so there is no uninitialized contract for '
    'a competing initialize to reach, and each constructor runs the check the '
    'setter that repairs the same pointer runs. Two contracts cannot each '
    'validate the other first, so the deployment order is the one sequence in '
    'which every check has something real to check: Vault with USDC only, agUSD '
    'naming the Vault, Vault.set_agusd checking the token names it back, Engine '
    'naming the Vault and checking it answers with the same admin, '
    'Vault.set_engine checking the Engine governs it with an empty book, the '
    'adapters each checking their Engine governs their Vault, and register_pool '
    'checking the adapter names both.'
)
dep['reusedInPlace'] = {
    'usdc': 'The real Circle USDC Stellar Asset Contract on testnet, never redeployed.',
    'creditVaults': 'The six generation 1 credit vaults, untouched by this review.',
    'agusd': 'Generation 1 agUSD, left exactly as it is with its holders.',
    'note': (
        'Nothing else could be reused. initialize was replaced by a '
        '__constructor in all seven protocol contracts, so every deployed '
        'contract in the stack differs from the source it is supposed to be, and '
        'the setters that would otherwise have carried a rewiring cannot install '
        'code. The Oracle Adapter and the Etherfuse adapter are the two that were '
        'reused in place in previous deployments and could not be this time.'
    ),
}
dep['superseded'] = history
json.dump(dep, open(path, 'w'), indent=2)
open(path, 'a').write('\n')
print(json.dumps(dep['contracts'], indent=2))
print(json.dumps(dep['poolAdapters'], indent=2))
PY
echo "==> done"
