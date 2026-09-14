#!/usr/bin/env bash
# Retire the current Vault and agUSD, and stand up the generation that carries
# the two fixes waiting on it.
#
# What has been waiting
#
# The source Vault interrogates its oracle in set_oracle, exposes oracle() and
# oracle_feed(), and requires the agUSD it mints to count stroops the way its
# USDC does. The deployed one does none of the three, and deployments.json has
# carried that as a declared divergence since it was found.
#
# Why it needs two contracts and not one
#
# agusd-core::set_minter refuses once mints > 0, so the live agUSD's minter is
# frozen at the current Vault permanently. A replacement Vault cannot mint the
# live token, so it needs a replacement token, and the outstanding supply has to
# be redeemed first or it is stranded against a Vault nothing points at.
#
# Why it could not be done until now
#
# Redeeming needs the position to clear MIN_WITHDRAWAL, the anti-dust floor of
# 1 agUSD. Supply was 0.2 and the operator held 0.6977610 USDC, so the best
# reachable balance was 0.8977610 and the floor could not be cleared at all. The
# account has since been funded.
#
# The order, and why it is this order
#
#   1. deposit enough to clear the floor, then withdraw everything: the old
#      generation retires at zero supply and zero idle, stranding nothing
#   2. the new Vault, then the new agUSD naming it as minter
#   3. set_agusd, which now checks the minter AND the decimals
#   4. set_oracle, which now checks the pair answers get_feed
#   5. the Engine moves before the Vault points back at it, because
#      Vault::set_engine requires the Engine to already govern this Vault
#   6. the adapters follow, then the registry is rebuilt on them
#   7. staking is redeployed on the new token, because its set_agusd guard
#      freezes at the first stake and cannot be thawed by emptying it
#   8. a full round trip on the result, or none of it is worth anything
#
# The block above is the first run's motivation. Every later run has its own,
# which is why the record's reason is an argument rather than a literal here.
#
# Usage: MIGRATION_REASON="why this generation replaces the live one" \
#          bash scripts/deploy-vault-generation.sh
set -euo pipefail

if [ -z "${MIGRATION_REASON:-}" ]; then
  echo "MIGRATION_REASON is unset. It is written verbatim into the superseded" >&2
  echo "entries for the retired Vault and agUSD, and the record is the only" >&2
  echo "place the reason survives, so this script will not guess it." >&2
  exit 2
fi
cd "$(dirname "$0")/.."

NET=testnet
SRC=agama-poc
WASM=target/wasm32v1-none/release
DEP=deployments/testnet.json

j() { python3 -c "import json;d=json.load(open('$DEP'));print($1)"; }
ADMIN=$(stellar keys address "$SRC")
USDC=$(j "d['contracts']['usdc']")
OLD_VAULT=$(j "d['contracts']['vault']")
OLD_AGUSD=$(j "d['contracts']['agusdCore']")
ENGINE=$(j "d['contracts']['allocationEngine']")
ORACLE=$(j "d['contracts']['oracleAdapter']")
STAKING=$(j "d['contracts']['staking']")
PC=$(j "d['poolAdapters']['private-credit']")
EF=$(j "d['poolAdapters']['etherfuse']")
FEED=$(j "d['vaultOracleFeed']")
FLOOR=$(j "d['engineConfig']['vaultReserveFloorBps']")
POOL_CAP=$(j "d['engineConfig']['poolCapBps']")
ORIG_CAP=$(j "d['engineConfig']['originatorCapBps']")
JUR_CAP=$(j "d['engineConfig']['jurisdictionCapBps']")
ENG_FLOOR=$(j "d['engineConfig']['reserveFloorBps']")
PC_ORIG=$(j "d['engineConfig']['pools']['private-credit']['originator']")
PC_JUR=$(j "d['engineConfig']['pools']['private-credit']['jurisdiction']")
EF_ORIG=$(j "d['engineConfig']['pools']['etherfuse']['originator']")
EF_JUR=$(j "d['engineConfig']['pools']['etherfuse']['jurisdiction']")

MIN_WITHDRAWAL=10000000  # the Vault's anti-dust floor, 1 agUSD at 7 decimals
SEED=20000000      # 2 USDC left in the new Vault, so it is live rather than empty
MOVE=5000000       # 0.5 USDC through a pool, to prove the wiring end to end

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  PASS  $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL  $1"; }
num() { echo "$1" | tr -d '"'; }
assert_eq() { if [ "$(num "$2")" = "$(num "$3")" ]; then ok "$1 ($(num "$2"))"; else bad "$1: got $(num "$2"), want $(num "$3")"; fi; }

q()  { stellar contract invoke --id "$1" --source "$SRC" --network "$NET" --send=no -- "${@:2}" 2>/dev/null; }
q0() { q "$@" | tr -d '"'; }
tx() { stellar contract invoke --id "$1" --source "$SRC" --network "$NET" -- "${@:2}" 2>&1 \
         | grep -oE '[0-9a-f]{64}' | head -1; }
deploy() {
  local out; out=$(stellar contract deploy --wasm "$1" --source "$SRC" --network "$NET" -- "${@:2}" 2>&1)
  echo "$out" | grep -oE 'Transaction hash is [0-9a-f]{64}' | sed 's/Transaction hash is/      deploy tx/' >&2
  echo "$out" | grep -oE 'C[A-Z2-7]{55}' | tail -1
}

echo "retiring vault  = $OLD_VAULT"
echo "retiring agUSD  = $OLD_AGUSD"
echo "keeping engine  = $ENGINE"
echo "keeping oracle  = $ORACLE"
echo "keeping staking = $STAKING"

echo ""
echo "==> preconditions, all of them, before anything moves"
fail=0
chk() { if [ "$(num "$2")" = "$3" ]; then echo "    $1 = $3"; else echo "    $1 = $(num "$2"), needs $3"; fail=1; fi; }
chk "vault deployed capital" "$(q0 "$OLD_VAULT" deployed_capital)" 0
chk "vault recognised losses" "$(q0 "$OLD_VAULT" recognised_losses)" 0
chk "vault outstanding liabilities" "$(q0 "$OLD_VAULT" outstanding_liabilities)" 0
chk "engine total allocated" "$(q0 "$ENGINE" total_allocated)" 0
chk "private credit exposure" "$(q0 "$PC" get_exposure)" 0
chk "etherfuse exposure" "$(q0 "$EF" get_exposure)" 0
chk "staking supply" "$(q0 "$STAKING" total_supply)" 0
chk "staking nav" "$(q0 "$STAKING" nav)" 0
SUPPLY=$(q0 "$OLD_AGUSD" total_supply)
HELD=$(q0 "$OLD_AGUSD" balance --id "$ADMIN")
chk "the operator holds the whole agUSD supply" "$HELD" "$SUPPLY"
BAL=$(q0 "$USDC" balance --id "$ADMIN")
echo "    operator USDC = $BAL"
# A top-up is only needed when the outstanding supply is below MIN_WITHDRAWAL
# and therefore cannot be redeemed at all. That was the case the first time this
# ran, at 0.2 agUSD against a 1 agUSD floor, and it is not a general condition:
# a position already over the floor comes out on its own. And the seed for the
# new Vault comes out of the redemption proceeds, which land before the seeding
# step, so it does not have to be held up front either.
NEED=0
if [ "$SUPPLY" != "0" ] && [ "$SUPPLY" -lt "$MIN_WITHDRAWAL" ]; then
  NEED=$((MIN_WITHDRAWAL - SUPPLY))
  echo "    supply $SUPPLY is under the $MIN_WITHDRAWAL anti-dust floor, so a top-up of $NEED is needed"
else
  echo "    supply clears the anti-dust floor, so no top-up is needed"
fi
if [ "$BAL" -lt "$NEED" ]; then
  echo "    and the operator is $((NEED - BAL)) short of it"
  fail=1
fi
if [ $((SUPPLY + BAL)) -lt "$SEED" ]; then
  echo "    nothing would be left to seed the new Vault with, which needs $SEED"
  fail=1
fi
[ "$fail" = 0 ] || { echo "refusing to start a migration that cannot finish"; exit 1; }

echo ""
echo "=============================================================="
echo "PART 1  retire the old generation at zero"
echo "=============================================================="
if [ "$(q0 "$OLD_AGUSD" total_supply)" = "0" ] && [ "$(q0 "$OLD_VAULT" idle_reserves)" = "0" ]; then
  echo "-- Already retired at zero by an earlier run. Nothing to redeem and"
  echo "-- nothing left in the Vault, so this part is done."
else
if [ "$NEED" != "0" ]; then
  echo "-- The position is under the anti-dust floor and cannot be redeemed as it"
  echo "-- stands, so a deposit lifts it over and the whole balance comes out in"
  echo "-- one request."
  echo "    deposit             tx $(tx "$OLD_VAULT" deposit --from "$ADMIN" --amount "$((NEED + MIN_WITHDRAWAL)))")"
else
  echo "-- The position already clears the anti-dust floor, so it comes out as it"
  echo "-- stands."
fi
HELD=$(q0 "$OLD_AGUSD" balance --id "$ADMIN")
echo "    the operator now holds $HELD agUSD, against a floor of 10000000"
CLAIM=$(stellar contract invoke --id "$OLD_VAULT" --source "$SRC" --network "$NET" -- \
  request_withdrawal --from "$ADMIN" --amount "$HELD" 2>&1 | grep -oE '^[0-9]+$' | tail -1)
echo "    request_withdrawal  claim $CLAIM"
echo "    claim_withdrawal    tx $(tx "$OLD_VAULT" claim_withdrawal --from "$ADMIN" --claim_id "$CLAIM")"
fi
assert_eq "the old agUSD retires at zero supply" "$(q0 "$OLD_AGUSD" total_supply)" "0"
# Not zero. The first run of this could assert zero because every stroop in that
# Vault had agUSD behind it. This one holds USDC that does not: recovered
# capital, booked but never minted against. USDC leaves a Vault through
# settle_allocation, which reaches an adapter that only ever sends back to the
# Vault it stores, and through a payout bounded by the agUSD burned to create
# the claim. There is no third path, deliberately, because a Vault that can pay
# equity out to an admin is a Vault an admin can empty. So that surplus stays
# where it is, permanently, and the honest thing is to measure it and write it
# down rather than assert a zero that is not true.
STRANDED=$(q0 "$OLD_VAULT" idle_reserves)
echo "    the old Vault keeps $STRANDED it has no agUSD to release against"
# What is left has to be exactly what the Vault thinks is left. If the balance
# and the books disagree at the moment of retirement, the number written into
# the record as stranded is the wrong number, and nobody would ever find out.
assert_eq "and its books agree with its balance on what is left" \
  "$(q0 "$OLD_VAULT" booked_reserves)" "$STRANDED"
assert_eq "with nothing owed to anybody" "$(q0 "$OLD_VAULT" outstanding_liabilities)" "0"

echo ""
echo "==> building"
stellar contract build >/dev/null

echo ""
echo "=============================================================="
echo "PART 2  the new Vault and the new agUSD"
echo "=============================================================="
VAULT=$(deploy "$WASM/vault.wasm" --admin "$ADMIN" --usdc_token "$USDC")
echo "    vault = $VAULT"
AGUSD=$(deploy "$WASM/agusd_core.wasm" --admin "$ADMIN" --minter "$VAULT" --decimal 7 \
  --name "Agama USD" --symbol agUSD)
echo "    agUSD = $AGUSD"

echo ""
echo "-- set_agusd now checks two things, not one: that the token names this"
echo "-- Vault as its minter, and that it counts stroops the way the USDC does."
echo "    set_agusd           tx $(tx "$VAULT" set_agusd --admin "$ADMIN" --agusd_token "$AGUSD")"
assert_eq "the Vault mints this token" "$(q0 "$VAULT" agusd)" "$AGUSD"
assert_eq "and the decimals line up" "$(q0 "$AGUSD" decimals)" "$(q0 "$USDC" decimals)"

echo ""
echo "-- set_oracle now interrogates the pair. Both halves are readable too,"
echo "-- which they were not on the Vault being retired."
echo "    set_oracle          tx $(tx "$VAULT" set_oracle --admin "$ADMIN" --oracle "$ORACLE" --feed_id "$FEED")"
assert_eq "the oracle pointer reads back" "$(q0 "$VAULT" oracle)" "$ORACLE"
assert_eq "and so does the feed" "$(q0 "$VAULT" oracle_feed)" "$FEED"
echo "    set_reserve_floor   tx $(tx "$VAULT" set_reserve_floor --admin "$ADMIN" --floor_bps "$FLOOR")"

echo ""
echo "=============================================================="
echo "PART 3  move the rest of the stack across, through its setters"
echo "=============================================================="
echo "-- The registry is cleared first, because every entry names the Vault"
echo "-- that is being retired and set_vault cannot repair them."
echo "    unregister pc       tx $(tx "$ENGINE" unregister_pool --admin "$ADMIN" --pool_id "$PC")"
echo "    unregister ef       tx $(tx "$ENGINE" unregister_pool --admin "$ADMIN" --pool_id "$EF")"
echo "    engine.set_vault    tx $(tx "$ENGINE" set_vault --admin "$ADMIN" --vault "$VAULT")"
echo "    vault.set_engine    tx $(tx "$VAULT" set_engine --admin "$ADMIN" --allocation_engine "$ENGINE")"
echo "    pc.set_counterparties tx $(tx "$PC" set_counterparties --admin "$ADMIN" --engine "$ENGINE" --vault "$VAULT")"
echo "    ef.set_counterparties tx $(tx "$EF" set_counterparties --admin "$ADMIN" --engine "$ENGINE" --vault "$VAULT")"
echo "    set_caps            tx $(tx "$ENGINE" set_caps --admin "$ADMIN" --pool_cap_bps "$POOL_CAP" \
  --originator_cap_bps "$ORIG_CAP" --jurisdiction_cap_bps "$JUR_CAP")"
echo "    set_reserve_floor   tx $(tx "$ENGINE" set_reserve_floor --admin "$ADMIN" --floor_bps "$ENG_FLOOR")"
echo "    register pc         tx $(tx "$ENGINE" register_pool --admin "$ADMIN" --pool_id "$PC" \
  --originator "$PC_ORIG" --jurisdiction "$PC_JUR" --cap_bps "$POOL_CAP")"
echo "    register ef         tx $(tx "$ENGINE" register_pool --admin "$ADMIN" --pool_id "$EF" \
  --originator "$EF_ORIG" --jurisdiction "$EF_JUR" --cap_bps "$POOL_CAP")"
# Not set_agusd. That setter cannot succeed here and never could: its guard
# reads a cumulative stake counter, not the current balance, and its own
# documentation says why. Unwinding to zero is not the same thing as never
# having taken custody, and the pending queue can be non-empty while the share
# supply is nil. So the token pointer freezes at the first stake and never
# thaws. That is the right property for stakers, and it means a new agUSD
# generation costs a staking generation, every time. The ten generations before
# this one were all replaced rather than repointed; only this script believed
# otherwise, asserted it, and failed.
OLD_STAKING=$STAKING
OLD_STAKING_HASH=$(stellar contract fetch --id "$OLD_STAKING" --network "$NET" 2>/dev/null | shasum -a 256 | cut -d' ' -f1)
STAKING=$(stellar contract deploy --wasm "$WASM/staking.wasm" --source "$SRC" --network "$NET" -- \
  --admin "$ADMIN" --agusd "$AGUSD" \
  --cooldown_seconds "$(q0 "$OLD_STAKING" cooldown)" \
  --decimal "$(q0 "$OLD_STAKING" decimals)" \
  --name "$(q "$OLD_STAKING" name | tr -d '"')" \
  --symbol "$(q "$OLD_STAKING" symbol | tr -d '"')" 2>&1 | tail -1)
echo "    staking redeployed  $STAKING"
assert_eq "the replacement names the new token" "$(q0 "$STAKING" agusd)" "$AGUSD"
assert_eq "and it has taken no custody" "$(q0 "$STAKING" stakes)" "0"

echo ""
echo "=============================================================="
echo "PART 4  a full round trip, or none of the above is worth anything"
echo "=============================================================="
echo "    deposit             tx $(tx "$VAULT" deposit --from "$ADMIN" --amount "$SEED")"
assert_eq "agUSD minted one for one" "$(q0 "$AGUSD" total_supply)" "$SEED"
echo "    allocate            tx $(tx "$ENGINE" allocate --admin "$ADMIN" --pool_id "$PC" --amount "$MOVE")"
assert_eq "the adapter holds it" "$(q0 "$USDC" balance --id "$PC")" "$MOVE"
echo "    deallocate          tx $(tx "$ENGINE" deallocate --pool_id "$PC" --amount "$MOVE")"
assert_eq "and it comes home" "$(q0 "$USDC" balance --id "$PC")" "0"
assert_eq "the Vault's book is flat" "$(q0 "$VAULT" deployed_capital)" "0"
echo "    vault.get_nav       = $(q "$VAULT" get_nav)"

echo ""
echo "==> the wiring, every pointer in both directions"
for pair in "vault.agusd:$VAULT:agusd" "vault.oracle:$VAULT:oracle" "vault.oracle_feed:$VAULT:oracle_feed" \
            "vault.allocation_engine:$VAULT:allocation_engine" "vault.usdc:$VAULT:usdc" \
            "agusd.minter:$AGUSD:minter" "engine.vault:$ENGINE:vault" \
            "pc.vault:$PC:vault" "pc.usdc:$PC:usdc" "ef.vault:$EF:vault" "staking.agusd:$STAKING:agusd"; do
  n=${pair%%:*}; rest=${pair#*:}; id=${rest%%:*}; fn=${rest#*:}
  printf "    %-24s = %s\n" "$n" "$(q "$id" "$fn")"
done

echo ""
echo "==> writing $DEP"
OLD_VAULT_HASH=$(stellar contract fetch --id "$OLD_VAULT" --network "$NET" 2>/dev/null | shasum -a 256 | cut -d' ' -f1)
OLD_AGUSD_HASH=$(stellar contract fetch --id "$OLD_AGUSD" --network "$NET" 2>/dev/null | shasum -a 256 | cut -d' ' -f1)
python3 - "$DEP" "$VAULT" "$OLD_VAULT" "$AGUSD" "$OLD_AGUSD" "$MIGRATION_REASON" \
  "${STRANDED:-0}" "$OLD_VAULT_HASH" "$OLD_AGUSD_HASH" \
  "${STAKING:-}" "${OLD_STAKING:-}" "${OLD_STAKING_HASH:-}" <<'PY'
import json, sys
(path, vault, old_vault, agusd, old_agusd, REASON, stranded, vhash, ahash,
 staking, old_staking, staking_hash) = sys.argv[1:]
dep = json.load(open(path))
history = dep.get('superseded', [])
ORD = ['first','second','third','fourth','fifth','sixth','seventh','eighth','ninth','tenth',
       'eleventh','twelfth','thirteenth','fourteenth','fifteenth']
for contract, address, label in (('vault', old_vault, 'Vault Contract'),
                                 ('agusdCore', old_agusd, 'agUSD (`contracts/agusd-core`)')):
    gen = 1 + sum(1 for e in history if e['contract'] == contract)
    entry = {'contract': contract, 'generation': gen,
             'label': '%s, %s deployment' % (label, ORD[gen - 1]),
             'address': address, 'supersededBy': contract, 'reason': REASON}
    # Read off the ledger before the pointers move, so the record's own
    # repeated-reason check has something to discriminate on besides prose.
    h = vhash if contract == 'vault' else ahash
    if h:
        entry['wasmHash'] = h
    history.append(entry)
    # Refusing a reason copied from the generation before, because that is the
    # mistake this argument exists to prevent, and it is silent otherwise.
    prev = [e for e in history[:-1] if e['contract'] == contract]
    if prev and prev[-1]['reason'].strip() == REASON.strip():
        sys.exit('the reason given is the one already recorded for %s generation %d, so one of '
                 'the two is wrong' % (contract, prev[-1]['generation']))
dep['contracts']['vault'] = vault
dep['contracts']['agusdCore'] = agusd
if staking and old_staking and staking != old_staking:
    gen = 1 + sum(1 for e in history if e['contract'] == 'staking')
    entry = {'contract': 'staking', 'generation': gen,
             'label': 'sagUSD staking, %s deployment' % ORD[gen - 1],
             'address': old_staking, 'supersededBy': 'staking',
             'reason': 'Replaced because agUSD moved and set_agusd cannot follow it: the '
                       'guard reads a cumulative stake counter rather than the current '
                       'balance, deliberately, so the token pointer freezes at the first '
                       'stake and never thaws. Emptied first, so nothing was stranded in '
                       'it. ' + REASON}
    if staking_hash:
        entry['wasmHash'] = staking_hash
    history.append(entry)
    dep['contracts']['staking'] = staking
dep['superseded'] = history
dep.pop('pendingRedeployment', None)
# The gap this migration closes was declared. Leaving the declaration behind
# would be a false statement in the other direction, and check-deployment-record
# fails on exactly that, so it goes with the gap.
ahead = [e for e in dep.get('sourceAheadOfLedger', []) if e['contract'] != 'vault']
if ahead:
    dep['sourceAheadOfLedger'] = ahead
else:
    dep.pop('sourceAheadOfLedger', None)
if int(stranded) > 0:
    dep['strandedInRetiredVaults'] = dep.get('strandedInRetiredVaults', [])
    dep['strandedInRetiredVaults'].append({
        'vault': old_vault,
        'amount': int(stranded),
        'note': 'USDC left in this Vault after every holder redeemed, with no agUSD '
                'outstanding to release it against. Recovered capital, booked but never '
                'minted against. It cannot be withdrawn: USDC leaves a Vault only through '
                'settle_allocation, which reaches an adapter that sends only back to the '
                'Vault it stores, and through a payout bounded by the agUSD burned to '
                'create the claim. There is no path to an admin, deliberately, so this is '
                'the price of a Vault generation rather than an oversight.'})
json.dump(dep, open(path, 'w'), indent=2); open(path, 'a').write('\n')
print(json.dumps({'vault': vault, 'agusdCore': agusd}, indent=2))
PY

echo ""
echo "  $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
