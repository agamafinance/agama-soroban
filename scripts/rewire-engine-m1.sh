#!/usr/bin/env bash
# Prove M1 of the third adversarial review on the deployed contracts, replace
# the Allocation Engine alone, and prove the fix the same way.
#
# The finding
#
# A pool adapter's `recover_surplus` may be taken by the Engine or by the
# adapter's own admin. The admin path exists so that an adapter stuck to
# superseded counterparties can be unstuck without a working Engine, and the
# module doc calls it the conservative direction because the cash still reaches
# the Vault and no book moves. That is true of the money and false of what
# happens next. The adapter's surplus is now zero, so `Engine::recover` gets
# `NothingToRecover` on the way in and the whole call reverts, and
# `Vault::record_recovery` has no other caller. The write-down that sweep was
# going to release then sits on `recognised_losses` for the life of the Vault,
# freezing the floor's share of it as reserves that can never be deployed, and
# on the pool's concentration charge for the life of the Engine. Lowering the
# floor or widening the caps works around it; nothing corrects it.
#
# The fix separates the sweep from the booking. `Engine::book_recovery` is
# `recover` with the adapter leg removed, bounded by the same arithmetic: the
# Vault subtracts the balance it can account for from the balance it holds and
# refuses anything larger, so a recovery still cannot be asserted, only
# evidenced. It grants no authority that did not already exist, because an admin
# could send USDC to an adapter and sweep it through `recover` today and get
# back exactly the headroom their own dollars bought.
#
# What is proved here, and how
#
# Every state change below is a submitted transaction whose hash is echoed. A
# refusal cannot be submitted, because the CLI will not send a transaction whose
# simulation fails, so refusals are shown by simulation with the contract error
# code asserted. That is sound for a refusal, which is contract logic either
# way. No authorization claim is made from a simulation.
#
# The deployment ends where it started: 0.2 USDC idle in the Vault, nothing
# deployed, nothing written off, both adapters empty.
#
# Usage: bash scripts/rewire-engine-m1.sh
#
# Requires the `agama-poc` identity, the admin recorded in testnet.json, which
# is also the admin of both pool adapters.
set -euo pipefail
cd "$(dirname "$0")/.."

NET=testnet
SRC=agama-poc
WASM=target/wasm32v1-none/release
DEP=deployments/testnet.json

j() { python3 -c "import json;d=json.load(open('$DEP'));print($1)"; }
ADMIN=$(stellar keys address "$SRC")
USDC=$(j "d['contracts']['usdc']")
VAULT=$(j "d['contracts']['vault']")
OLD_ENGINE=$(j "d['contracts']['allocationEngine']")
PC=$(j "d['poolAdapters']['private-credit']")
EF=$(j "d['poolAdapters']['etherfuse']")
POOL_CAP=$(j "d['engineConfig']['poolCapBps']")
ORIGINATOR_CAP=$(j "d['engineConfig']['originatorCapBps']")
JURISDICTION_CAP=$(j "d['engineConfig']['jurisdictionCapBps']")
RESERVE_FLOOR=$(j "d['engineConfig']['reserveFloorBps']")
PC_ORIGINATOR=$(j "d['engineConfig']['pools']['private-credit']['originator']")
PC_JURISDICTION=$(j "d['engineConfig']['pools']['private-credit']['jurisdiction']")
EF_ORIGINATOR=$(j "d['engineConfig']['pools']['etherfuse']['originator']")
EF_JURISDICTION=$(j "d['engineConfig']['pools']['etherfuse']['jurisdiction']")

# 0.05 USDC. The Vault holds 0.2, the pool cap releases 0.08 and the 25 percent
# floor releases 0.15, so this is inside every limit with room to spare and the
# demonstration is about the loss book rather than about the caps.
MOVE=500000

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  PASS  $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL  $1"; }
num() { echo "$1" | tr -d '"'; }
assert_eq() { if [ "$(num "$2")" = "$(num "$3")" ]; then ok "$1 ($(num "$2"))"; else bad "$1: got $(num "$2"), want $(num "$3")"; fi; }

q()  { stellar contract invoke --id "$1" --source "$SRC" --network "$NET" --send=no -- "${@:2}" 2>/dev/null; }
q0() { q "$@" | tr -d '"'; }
tx() { stellar contract invoke --id "$1" --source "$SRC" --network "$NET" -- "${@:2}" 2>&1 \
         | grep -oE '[0-9a-f]{64}' | head -1; }
refused() {
  local want=$1 label=$2 id=$3; shift 3
  local out
  out=$(stellar contract invoke --id "$id" --source "$SRC" --network "$NET" --send=no -- "$@" 2>&1) || true
  if echo "$out" | grep -q "Error(Contract, #$want)"; then
    ok "$label (contract error $want)"
  else
    bad "$label: expected contract error $want, got: $(echo "$out" | head -2 | tr '\n' ' ')"
  fi
}

echo "vault (kept)        = $VAULT"
echo "outgoing engine     = $OLD_ENGINE"
echo "private-credit      = $PC"
echo "etherfuse           = $EF"
echo "admin              = $ADMIN"

echo ""
echo "==> preconditions"
fail=0
for pair in "vault:$VAULT:deployed_capital" "private-credit:$PC:get_exposure" "etherfuse:$EF:get_exposure"; do
  name=${pair%%:*}; rest=${pair#*:}; id=${rest%%:*}; fn=${rest#*:}
  v=$(q0 "$id" "$fn")
  if [ "${v:-x}" = "0" ]; then echo "    $name $fn = 0"; else echo "    $name $fn = $v, and it has to be 0"; fail=1; fi
done
for pair in "private-credit:$PC" "etherfuse:$EF"; do
  name=${pair%%:*}; id=${pair#*:}
  v=$(q0 "$USDC" balance --id "$id")
  if [ "${v:-x}" = "0" ]; then echo "    $name usdc balance = 0"; else echo "    $name usdc balance = $v"; fail=1; fi
done
START_IDLE=$(q0 "$VAULT" idle_reserves)
echo "    vault idle reserves = $START_IDLE"
[ "$fail" = 0 ] || { echo "refusing to start"; exit 1; }

echo ""
echo "=============================================================="
echo "PART 1  the finding, on the Engine that is live right now"
echo "=============================================================="
if [ "$(q0 "$VAULT" recognised_losses)" = "$MOVE" ]; then
  echo "-- Already on the ledger from an earlier run, and still there, which is"
  echo "-- the finding rather than a wrinkle in it: this Engine has no call that"
  echo "-- can clear it. Skipping to the part that can."
else
echo "    allocate            tx $(tx "$OLD_ENGINE" allocate --admin "$ADMIN" --pool_id "$PC" --amount "$MOVE")"
echo "    write_down          tx $(tx "$OLD_ENGINE" write_down --admin "$ADMIN" --pool_id "$PC" --amount "$MOVE" --reason DEFAULT)"
assert_eq "the loss is on the Vault's book" "$(q0 "$VAULT" recognised_losses)" "$MOVE"
assert_eq "and charged against the pool's cap" "$(q0 "$OLD_ENGINE" written_off_pool --pool_id "$PC")" "$MOVE"
assert_eq "the adapter is still holding every dollar of it" "$(q0 "$USDC" balance --id "$PC")" "$MOVE"

echo ""
echo "-- The adapter admin takes the fallback sweep. This is the legitimate"
echo "-- operator action the adapter offers, not an attack."
echo "    recover_surplus     tx $(tx "$PC" recover_surplus --caller "$ADMIN")"
fi
assert_eq "the cash is home in the Vault" "$(q0 "$USDC" balance --id "$PC")" "0"
assert_eq "and the Vault can see it as unaccounted" \
  "$(( $(q0 "$VAULT" idle_reserves) - $(q0 "$VAULT" booked_reserves) ))" "$MOVE"

echo ""
echo "-- And now the only path to record_recovery is shut. 611 is the"
echo "-- adapter's own NothingToRecover, arriving as a sub-call error because"
echo "-- recover calls the adapter without try_: there is no amount to pass on."
refused 611 "recover is refused, and there is no second way in" \
  "$OLD_ENGINE" recover --admin "$ADMIN" --pool_id "$PC"
assert_eq "the loss stays on the Vault's book" "$(q0 "$VAULT" recognised_losses)" "$MOVE"
assert_eq "and the pool's cap stays charged" "$(q0 "$OLD_ENGINE" written_off_pool --pool_id "$PC")" "$MOVE"
echo "-- That is the finding. On this Engine it is the end of the sequence."

echo ""
echo "==> building the replacement"
stellar contract build >/dev/null

echo ""
echo "==> deploying it, wired to the Vault in its own constructor"
OUT=$(stellar contract deploy --wasm "$WASM/allocation_engine.wasm" --source "$SRC" --network "$NET" \
  -- --admin "$ADMIN" --vault "$VAULT" 2>&1)
echo "$OUT" | grep -oE 'Using wasm hash [0-9a-f]{64}' | sed 's/^/    /'
echo "$OUT" | grep -oE 'Transaction hash is [0-9a-f]{64}' | sed 's/Transaction hash is/    deploy tx/'
ENGINE=$(echo "$OUT" | grep -oE 'C[A-Z2-7]{55}' | tail -1)
echo "    allocation-engine = $ENGINE"

echo ""
echo "==> repointing everything that names it, adapters before the registry"
echo "-- register_pool runs the same counterparty check allocate runs, so an"
echo "-- adapter that has not been brought across yet fails it. The order is a"
echo "-- precondition rather than a habit, which the third review made true."
echo "    vault.set_engine       tx $(tx "$VAULT" set_engine --admin "$ADMIN" --allocation_engine "$ENGINE")"
echo "    pc.set_counterparties  tx $(tx "$PC" set_counterparties --admin "$ADMIN" --engine "$ENGINE" --vault "$VAULT")"
echo "    ef.set_counterparties  tx $(tx "$EF" set_counterparties --admin "$ADMIN" --engine "$ENGINE" --vault "$VAULT")"
echo "    set_caps               tx $(tx "$ENGINE" set_caps --admin "$ADMIN" --pool_cap_bps "$POOL_CAP" \
  --originator_cap_bps "$ORIGINATOR_CAP" --jurisdiction_cap_bps "$JURISDICTION_CAP")"
echo "    set_reserve_floor      tx $(tx "$ENGINE" set_reserve_floor --admin "$ADMIN" --floor_bps "$RESERVE_FLOOR")"
echo "    register pc            tx $(tx "$ENGINE" register_pool --admin "$ADMIN" --pool_id "$PC" \
  --originator "$PC_ORIGINATOR" --jurisdiction "$PC_JURISDICTION" --cap_bps "$POOL_CAP")"
echo "    register ef            tx $(tx "$ENGINE" register_pool --admin "$ADMIN" --pool_id "$EF" \
  --originator "$EF_ORIGINATOR" --jurisdiction "$EF_JURISDICTION" --cap_bps "$POOL_CAP")"

echo ""
echo "=============================================================="
echo "PART 2  the loss the old Engine stranded, cleared"
echo "=============================================================="
echo "-- The replacement starts with an empty loss book while the Vault is"
echo "-- still carrying the write-down, which is the right way round: the Vault"
echo "-- is the contract whose floor is measured against it, and the Engine's"
echo "-- copy is a convenience. The cash has been sitting in the Vault since"
echo "-- the adapter admin swept it, and it is what bounds this call."
assert_eq "the Vault is still carrying the stranded loss" "$(q0 "$VAULT" recognised_losses)" "$MOVE"
assert_eq "the replacement Engine starts with none of it" "$(q0 "$ENGINE" written_off)" "0"
echo "    book_recovery       tx $(tx "$ENGINE" book_recovery --admin "$ADMIN" --pool_id "$PC" --amount "$MOVE")"
assert_eq "the loss is released" "$(q0 "$VAULT" recognised_losses)" "0"
assert_eq "the Vault can account for every stroop it holds again" \
  "$(( $(q0 "$VAULT" idle_reserves) - $(q0 "$VAULT" booked_reserves) ))" "0"
assert_eq "and the Vault is back to where it started" "$(q0 "$VAULT" idle_reserves)" "$START_IDLE"

echo ""
echo "=============================================================="
echo "PART 3  the same sequence again, on the fixed Engine"
echo "=============================================================="
echo "-- Part 2 cleared a loss the replacement had never recorded, so it says"
echo "-- nothing about the pool's concentration charge. This runs the whole"
echo "-- finding from the start against the fixed contract, where the Engine"
echo "-- has its own charge to release."
echo "    allocate            tx $(tx "$ENGINE" allocate --admin "$ADMIN" --pool_id "$PC" --amount "$MOVE")"
echo "    write_down          tx $(tx "$ENGINE" write_down --admin "$ADMIN" --pool_id "$PC" --amount "$MOVE" --reason DEFAULT)"
echo "    recover_surplus     tx $(tx "$PC" recover_surplus --caller "$ADMIN")"
assert_eq "the charge is on the pool" "$(q0 "$ENGINE" written_off_pool --pool_id "$PC")" "$MOVE"
refused 611 "recover is refused here too, because the fix is not to that call" \
  "$ENGINE" recover --admin "$ADMIN" --pool_id "$PC"

echo ""
echo "-- The booking on its own, which is the whole of the fix."
echo "    book_recovery       tx $(tx "$ENGINE" book_recovery --admin "$ADMIN" --pool_id "$PC" --amount "$MOVE")"
assert_eq "the pool's charge is released" "$(q0 "$ENGINE" written_off_pool --pool_id "$PC")" "0"
assert_eq "the Engine's loss book is clear" "$(q0 "$ENGINE" written_off)" "0"
assert_eq "the Vault's is too, and the two agree" "$(q0 "$VAULT" recognised_losses)" "0"

echo ""
echo "-- It asserts nothing. With the cash already booked there is no"
echo "-- unaccounted balance left, and the Vault refuses a second helping with"
echo "-- 323, its own RecoveryNotReceived."
refused 323 "a recovery the Vault cannot see is refused" \
  "$ENGINE" book_recovery --admin "$ADMIN" --pool_id "$PC" --amount "$MOVE"

echo ""
echo "==> the wiring, every pointer in both directions"
echo "    vault.allocation_engine()   = $(q "$VAULT" allocation_engine)"
echo "    engine.vault()              = $(q "$ENGINE" vault)"
echo "    engine.admin_aligned()      = $(q "$ENGINE" admin_aligned)"
echo "    engine.caps()               = $(q "$ENGINE" caps)"
echo "    engine.reserve_floor_bps()  = $(q "$ENGINE" reserve_floor_bps)"
echo "    private-credit.engine()     = $(q "$PC" engine)"
echo "    private-credit.vault()      = $(q "$PC" vault)"
echo "    etherfuse.engine()          = $(q "$EF" engine)"
echo "    etherfuse.vault()           = $(q "$EF" vault)"

echo ""
echo "==> the deployment is back where it started"
assert_eq "vault idle reserves" "$(q0 "$VAULT" idle_reserves)" "$START_IDLE"
assert_eq "vault deployed capital" "$(q0 "$VAULT" deployed_capital)" "0"
assert_eq "vault recognised losses" "$(q0 "$VAULT" recognised_losses)" "0"
assert_eq "engine total allocated" "$(q0 "$ENGINE" total_allocated)" "0"
assert_eq "private credit balance" "$(q0 "$USDC" balance --id "$PC")" "0"
assert_eq "etherfuse balance" "$(q0 "$USDC" balance --id "$EF")" "0"

echo ""
echo "==> writing $DEP"
python3 - "$DEP" "$ENGINE" "$OLD_ENGINE" <<'PY'
import json, sys
path, engine, old_engine = sys.argv[1:]
dep = json.load(open(path))
history = dep.get('superseded', [])
ORDINALS = ['first', 'second', 'third', 'fourth', 'fifth', 'sixth', 'seventh',
            'eighth', 'ninth', 'tenth', 'eleventh', 'twelfth']
generation = 1 + sum(1 for e in history if e['contract'] == 'allocationEngine')
history.append({
    'contract': 'allocationEngine',
    'generation': generation,
    'label': 'Allocation Engine, %s deployment' % ORDINALS[generation - 1],
    'address': old_engine,
    'supersededBy': 'allocationEngine',
    'reason': (
        'Replaced by scripts/rewire-engine-m1.sh, for M1 of the third '
        'adversarial review. A pool adapter\'s recover_surplus may be taken by '
        'the adapter\'s own admin as well as by the Engine, which is how an '
        'adapter stuck to superseded counterparties is unstuck without a '
        'working Engine. Taken that way the cash reaches the Vault and no book '
        'moves, and in this Engine that is terminal: the surplus is gone, so '
        'recover gets NothingToRecover from the adapter and reverts, and '
        'Vault::record_recovery has no other caller. The write-down stays on '
        'recognised_losses for the life of the Vault, freezing the floor\'s '
        'share of it as undeployable reserves, and on the pool\'s '
        'concentration charge for the life of the Engine. book_recovery is '
        'recover with the adapter leg removed, bounded by the same unaccounted '
        'balance the Vault already checks. Nothing else was redeployed: the '
        'Vault took the replacement through set_engine and both adapters '
        'followed through set_counterparties.'
    ),
})
dep['contracts']['allocationEngine'] = engine
dep['superseded'] = history
dep['reusedInPlace'] = {
    'vault': 'Repointed at the replacement Engine with set_engine, which refuses an Engine that does not govern this Vault and refuses to move while capital is deployed.',
    'agusdCore': 'Unchanged. It names the Vault as its minter and the Vault did not move.',
    'staking': 'Unchanged.',
    'oracleAdapter': 'Unchanged.',
    'poolAdapters.private-credit': 'Repointed at the replacement Engine with set_counterparties, empty at the time as that setter requires, and before register_pool rather than after.',
    'poolAdapters.etherfuse': 'Repointed at the replacement Engine with set_counterparties, empty at the time as that setter requires, and before register_pool rather than after.',
    'usdc': 'The real Circle USDC Stellar Asset Contract on testnet, never redeployed.',
    'creditVaults': 'The six generation 1 credit vaults, untouched by this review.',
    'agusd': 'Generation 1 agUSD, left exactly as it is with its holders.',
}
dep['strandedRecoveries'] = (
    'A recovery reaches the Vault through the Engine, which sweeps the adapter '
    'and books what it swept in one call. The adapter also lets its own admin '
    'take that sweep, so that an adapter stuck to superseded counterparties can '
    'be unstuck without a working Engine, and taken that way the cash arrives '
    'with no book moving. Engine::book_recovery is the booking on its own, for '
    'exactly that case. It is bounded by the balance the Vault holds and cannot '
    'account for, the same test record_repayment and record_recovery already '
    'apply, so a recovery is still evidenced rather than asserted, and it '
    'grants no authority an admin did not have: sending USDC to an adapter and '
    'sweeping it through recover buys back the same headroom and no more. There '
    'is no matching book_repayment, because a repayment that reaches the Vault '
    'by another route cannot strand a position the way a recovery can: USDC '
    'leaves an adapter only through deallocate, which lowers the exposure by '
    'what it sends, and recover_surplus, which sends only what is above the '
    'exposure, so an adapter never holds less than it has booked and deallocate '
    'is never short. contracts/allocation-engine/src/test.rs pins that '
    'invariant so that adding a disbursement path breaks a test rather than a '
    'settlement.'
)
json.dump(dep, open(path, 'w'), indent=2)
open(path, 'a').write('\n')
print(json.dumps(dep['contracts'], indent=2))
PY

echo ""
echo "=============================================================="
echo "  $PASS passed, $FAIL failed"
echo "=============================================================="
[ "$FAIL" = 0 ]
