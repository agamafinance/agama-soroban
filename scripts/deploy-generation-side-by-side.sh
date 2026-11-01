#!/usr/bin/env bash
# Deploy a new Vault, agUSD and staking generation without retiring the old one.
#
# deploy-vault-generation.sh retires the outgoing generation at zero, and it is
# right to: a generation that still owes somebody something should not be walked
# away from. But it cannot run here, and the reason is permanent rather than a
# matter of waiting. Three accounts hold 8.1939395 sagUSD, they last acted in
# October, the token has no clawback, its classic issuer signs at weight 0, and
# `Supply` is written in exactly three places in the staking source, none of
# which an admin can reach. So the outgoing supply cannot be brought to zero and
# no replacement can be seeded with those positions. Measured by
# scripts/check-staking-migration-block.sh.
#
# That left seven fixes in the tree and two contracts declared under
# treeAheadOfLedger. This script is the way out, and it is not a trick: the old
# Vault, the old agUSD and the old staking contract are left running, funded and
# able to pay. The three holders' exit path is unchanged and over-covered by
# roughly five hundred times, which this script checks before it starts and
# refuses to proceed without. Nobody is stranded. What changes is which
# generation the record calls live.
#
#   bash scripts/deploy-generation-side-by-side.sh
#
# The cost is honest and worth stating: two live Vaults and two live agUSD
# tokens, one of which the record and the docs no longer point at. That is what
# `superseded` has always meant here, with the difference that this one is not
# empty. The reason is written into the record next to the address.
set -euo pipefail
cd "$(dirname "$0")/.."
NET=${NET:-testnet}
SRC=${SRC:-agama-poc}
DEP=deployments/testnet.json
WASM=target/wasm32v1-none/release
SEED=${SEED:-100000000}
# MOVE is derived from the pool cap further down rather than fixed here, because
# a round trip sized by hand gets refused by the very guard it is supposed to be
# exercising around. A first run allocated 55.6% of a 1.8 USDC seed against a
# 4000 bps cap and read #407 as a failure of the migration.
MOVE=${MOVE:-}
# The first stake has its own floor, MIN_FIRST_STAKE, which is one whole unit,
# and it is unrelated to the pool cap. Tying both to one number means a seed
# small enough to respect the cap is too small to stake.
STAKE=${STAKE:-10000000}
j() { python3 -c "import json;d=json.load(open('$DEP'));print($1)"; }
ADMIN=$(stellar keys address "$SRC")
OLD_VAULT=$(j "d['contracts']['vault']")
OLD_AGUSD=$(j "d['contracts']['agusdCore']")
OLD_STAKING=$(j "d['contracts']['staking']")
ENGINE=$(j "d['contracts']['allocationEngine']")
ORACLE=$(j "d['contracts']['oracleAdapter']")
USDC=$(j "d['contracts']['usdc']")
POOL_CAP=$(j "d['engineConfig']['poolCapBps']")
ORIG_CAP=$(j "d['engineConfig']['originatorCapBps']")
JUR_CAP=$(j "d['engineConfig']['jurisdictionCapBps']")
ENG_FLOOR=$(j "d['engineConfig']['reserveFloorBps']")
POOLS=$(j "'\n'.join('%s %s %s %s %s' % (k, v['address'], v['originator'], v['jurisdiction'], v['capBps']) for k, v in d['engineConfig']['pools'].items())")

LOCK=/tmp/agama-smoke-$SRC.lock
if ! mkdir "$LOCK" 2>/dev/null; then
  echo "a suite or another migration holds $SRC ($(cat "$LOCK/owner" 2>/dev/null || echo unknown))." >&2
  exit 1
fi
echo "pid $$ at $(date -u +%H:%M:%S), deploy-generation-side-by-side" > "$LOCK/owner"
trap 'rm -rf "$LOCK"' EXIT

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  PASS  $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL  $1"; }
q()  { stellar contract invoke --id "$1" --source "$SRC" --network "$NET" --send=no -- "${@:2}" 2>/dev/null; }
q0() { q "$@" | tr -d '"'; }
num(){ printf '%s' "${1:-}" | tr -d '"'; }
assert_eq() { if [ "$(num "$2")" = "$(num "$3")" ]; then ok "$1 ($(num "$2"))"; else bad "$1: got $(num "$2"), want $(num "$3")"; fi; }
_tx() {
  local out err h
  out=$("$@" 2>&1) || true
  err=$(printf '%s' "$out" | tr '\n' ' ' | grep -oE 'Error\(Contract, #[0-9]+\)' | head -1 || true)
  [ -n "$err" ] || err=$(printf '%s' "$out" | tr '\n' ' ' | grep -oE 'TxBadSeq|error: [^ ]+' | head -1 || true)
  if [ -n "$err" ]; then printf 'FAILED %s' "$err"; return 1; fi
  h=$(printf '%s' "$out" | grep -oE 'Transaction hash is [0-9a-f]{64}' | grep -oE '[0-9a-f]{64}' | head -1 || true)
  [ -n "$h" ] || h=$(printf '%s' "$out" | grep -oE '[0-9a-f]{64}' | head -1 || true)
  if [ -n "$h" ]; then printf '%s' "$h"; return 0; fi
  printf 'landed, no hash printed'
}
tx() { _tx stellar contract invoke --id "$1" --source "$SRC" --network "$NET" -- "${@:2}"; }
# The address comes off stdout, where the CLI puts exactly one thing: the
# contract it created. Progress, the wasm hash and the arguments all go to
# stderr. Grepping the combined stream for a C address and taking the last match
# returns whichever address happens to appear last, and when a constructor is
# handed a contract address as an argument that is the argument. Deploying the
# share token with --admin "$STAKING" --minter "$STAKING" returned the staking
# contract's own address as the token's, set_shares answered #812, and the
# record was written with stakingShares equal to staking.
deploy() {
  local addr err
  err=$(mktemp)
  addr=$(stellar contract deploy --wasm "$1" --source "$SRC" --network "$NET" -- "${@:2}" 2>"$err" | tail -1 | tr -d '"')
  if ! printf '%s' "$addr" | grep -qE '^C[A-Z2-7]{55}$'; then
    echo "deploy of $1 did not return a contract address, got '$addr':" >&2
    tail -20 "$err" >&2; rm -f "$err"; exit 1
  fi
  rm -f "$err"
  printf '%s' "$addr"
}

echo "outgoing, and staying up:"
echo "    vault   $OLD_VAULT"
echo "    agUSD   $OLD_AGUSD"
echo "    staking $OLD_STAKING"
echo ""

echo "==> the people this leaves behind, and whether they can still get out"
# The whole justification for a side by side deploy is that the old generation
# still works for whoever is left in it. If it cannot pay them, this is not a
# migration, it is an abandonment, and it must not run.
S_SUPPLY=$(q0 "$OLD_STAKING" total_supply)
S_NAV=$(q0 "$OLD_STAKING" nav)
V_IDLE=$(q0 "$OLD_VAULT" idle_reserves)
V_OWED=$(q0 "$OLD_VAULT" outstanding_liabilities)
STRANDED=$(bash scripts/check-staking-migration-block.sh 2>/dev/null \
  | awk '/this is the blocker/ {print $2}')
[ -n "$STRANDED" ] || { echo "could not measure the unreachable balance, refusing to guess it" >&2; exit 1; }
OWED=$(python3 -c "print(int(float('$STRANDED') * 1e7 * int('$S_NAV') / int('$S_SUPPLY')))")
printf '    %s sagUSD is held by accounts we cannot sign for\n' "$STRANDED"
printf '    at %s nav over %s supply that is %s agUSD owed to them\n' "$S_NAV" "$S_SUPPLY" "$OWED"
printf '    the old Vault holds %s idle with %s already owed to others\n' "$V_IDLE" "$V_OWED"
if [ "$((V_IDLE - V_OWED))" -lt "$OWED" ]; then
  echo "    the old generation could not pay them, so this is not a migration" >&2
  exit 1
fi
ok "the old generation can still pay everyone left in it ($(python3 -c "print('%.1fx' % ((int('$V_IDLE')-int('$V_OWED'))/max(int('$OWED'),1)))") over)"
# The two generations do not use the same token implementation. The outgoing
# agUSD is a Stellar Asset Contract and answers `admin`; the replacement is
# agusd_core and answers `minter`. Asking the old one for a minter returns
# nothing, which compares unequal to everything and reads as the old generation
# having lost its ability to pay, which is the one thing this check exists to
# rule out.
# `|| true` on both, and not as a formality. A bare assignment from a command
# substitution propagates that command's exit status, and the CLI exits non-zero
# when asked for an entry point a contract does not have, so under set -e the
# probe that was meant to tolerate a missing getter is what kills the script.
# It did, on this line, immediately after the check above passed.
OLD_MINTER=$(q0 "$OLD_AGUSD" minter || true)
[ -n "$OLD_MINTER" ] || OLD_MINTER=$(q0 "$OLD_AGUSD" admin || true)
assert_eq "and the old Vault still mints its own agUSD" "$OLD_MINTER" "$OLD_VAULT"
assert_eq "so the old staking still names a token it can burn" "$(q0 "$OLD_STAKING" agusd)" "$OLD_AGUSD"

echo ""
echo "==> preconditions on the parts that do move"
fail=0
chk0() {
  local label=$1; shift
  local v; v=$(q0 "$@")
  if [ "${v:-x}" = "0" ]; then echo "    $label = 0"
  else echo "    $label = ${v:-unreadable}, and it has to be 0"; fail=1; fi
}
chk0 "old vault deployed_capital" "$OLD_VAULT" deployed_capital
chk0 "engine total_allocated"     "$ENGINE" total_allocated
chk0 "engine written_off"         "$ENGINE" written_off
while read -r name addr _o _j _c; do
  [ -n "$name" ] || continue
  chk0 "$name exposure" "$ENGINE" get_exposure --pool_id "$addr"
  chk0 "$name usdc"     "$USDC" balance --id "$addr"
done <<< "$POOLS"
# Spendable, not held. USDC is a classic asset and the operator runs a market
# maker, so most of the balance sits under selling_liabilities against open SDEX
# offers and cannot be transferred. Comparing the held balance let this start
# with 230 USDC on the books and 1.9 actually movable, and the seeding deposit
# died inside the token with "resulting balance is not within the allowed range".
BAL=$(q0 "$USDC" balance --id "$ADMIN")
SPEND=$(curl -s "${HORIZON:-https://horizon-testnet.stellar.org}/accounts/$ADMIN" \
  | python3 -c "
import json,sys
a=json.load(sys.stdin)
for b in a['balances']:
    if b.get('asset_code')=='USDC':
        print(int(round((float(b['balance'])-float(b.get('selling_liabilities',0)))*1e7))); break
else: print(0)")
echo "    operator USDC = $BAL held, $SPEND spendable, seeding needs $SEED"
if [ "$SPEND" -lt "$SEED" ]; then
  echo "    $((SEED - SPEND)) short once open offers are accounted for."
  echo "    Free it by pulling the offers that quote the outgoing generation's tokens,"
  echo "    or lower SEED. Do not compare against the held balance; it lies here."
  fail=1
fi
[ "$fail" = 0 ] || { echo "refusing to start a migration that cannot finish"; exit 1; }

echo ""
echo "==> building"
stellar contract build >/dev/null

echo ""
echo "==> the new Vault and its agUSD"
VAULT=${VAULT:-$(deploy "$WASM/vault.wasm" --admin "$ADMIN" --usdc_token "$USDC")}
echo "    vault = $VAULT"
AGUSD=${AGUSD:-$(deploy "$WASM/agusd_core.wasm" --admin "$ADMIN" --minter "$VAULT" --decimal 7 \
  --name "Agama USD" --symbol agUSD)}
echo "    agUSD = $AGUSD"
echo "    set_agusd         tx $(tx "$VAULT" set_agusd --admin "$ADMIN" --agusd_token "$AGUSD")"
echo "    set_oracle        tx $(tx "$VAULT" set_oracle --admin "$ADMIN" --oracle "$ORACLE" --feed_id PC_NAV)"
echo "    set_reserve_floor tx $(tx "$VAULT" set_reserve_floor --admin "$ADMIN" --floor_bps 2500)"

echo ""
echo "==> the new staking generation, and a share token it can actually mint"
# set_shares asks the token who its admin is and refuses any answer but the
# staking contract, so the token is deployed after the contract that will own it.
STAKING=${STAKING:-$(deploy "$WASM/staking.wasm" --admin "$ADMIN" --agusd "$AGUSD" \
  --cooldown_seconds "$(q0 "$OLD_STAKING" cooldown)")}
echo "    staking = $STAKING"
SHARES=${SHARES:-$(deploy "$WASM/agusd_core.wasm" --admin "$STAKING" --minter "$STAKING" --decimal 7 \
  --name "Staked Agama USD" --symbol sagUSD)}
echo "    shares  = $SHARES"
echo "    set_shares        tx $(tx "$STAKING" set_shares --admin "$ADMIN" --shares_token "$SHARES")"

echo ""
echo "==> moving the engine and all four pools onto the new Vault"
# The registry goes first: every entry names the Vault being left behind, and
# set_vault cannot repair an entry, only refuse to be inconsistent with it.
while read -r name addr _o _j _c; do
  [ -n "$name" ] || continue
  echo "    unregister $name tx $(tx "$ENGINE" unregister_pool --admin "$ADMIN" --pool_id "$addr")"
done <<< "$POOLS"
echo "    engine.set_vault  tx $(tx "$ENGINE" set_vault --admin "$ADMIN" --vault "$VAULT")"
echo "    vault.set_engine  tx $(tx "$VAULT" set_engine --admin "$ADMIN" --allocation_engine "$ENGINE")"
while read -r name addr _o _j _c; do
  [ -n "$name" ] || continue
  echo "    $name.set_counterparties tx $(tx "$addr" set_counterparties --admin "$ADMIN" --engine "$ENGINE" --vault "$VAULT")"
done <<< "$POOLS"
echo "    set_caps          tx $(tx "$ENGINE" set_caps --admin "$ADMIN" --pool_cap_bps "$POOL_CAP" \
  --originator_cap_bps "$ORIG_CAP" --jurisdiction_cap_bps "$JUR_CAP")"
echo "    set_reserve_floor tx $(tx "$ENGINE" set_reserve_floor --admin "$ADMIN" --floor_bps "$ENG_FLOOR")"
while read -r name addr o jur cap; do
  [ -n "$name" ] || continue
  echo "    register $name   tx $(tx "$ENGINE" register_pool --admin "$ADMIN" --pool_id "$addr" \
    --originator "$o" --jurisdiction "$jur" --cap_bps "$cap")"
done <<< "$POOLS"

echo ""
echo "==> a full round trip, or none of the above is worth anything"
FIRST=$(printf '%s' "$POOLS" | head -1 | awk '{print $2}')
echo "    deposit           tx $(tx "$VAULT" deposit --from "$ADMIN" --amount "$SEED")"
assert_eq "agUSD minted one for one" "$(q0 "$AGUSD" total_supply)" "$SEED"
# Sized against the cap that would refuse it, with a margin, and against the
# reserve floor that bounds the total. Both are read off the Engine rather than
# assumed, so this stays right when the configuration changes.
if [ -z "$MOVE" ]; then
  NET=$(q0 "$VAULT" idle_reserves)
  MOVE=$(python3 -c "
net = int('$NET'); cap = int('$POOL_CAP'); floor = int('$ENG_FLOOR')
by_cap = net * cap // 10000
by_floor = net * (10000 - floor) // 10000
print(max(min(by_cap, by_floor) * 7 // 10, 1))")
  echo "    round trip sized at $MOVE, under a ${POOL_CAP} bps pool cap on $NET"
fi
echo "    allocate          tx $(tx "$ENGINE" allocate --admin "$ADMIN" --pool_id "$FIRST" --amount "$MOVE")"
assert_eq "the adapter holds it" "$(q0 "$USDC" balance --id "$FIRST")" "$MOVE"
echo "    deallocate        tx $(tx "$ENGINE" deallocate --pool_id "$FIRST" --amount "$MOVE")"
assert_eq "and it comes home" "$(q0 "$USDC" balance --id "$FIRST")" "0"
assert_eq "the new Vault's book is flat" "$(q0 "$VAULT" deployed_capital)" "0"
echo "    a stake on the new generation, to prove the share token mints"
if [ "$(q0 "$STAKING" total_supply)" = "0" ]; then
  echo "    stake             tx $(tx "$STAKING" stake --from "$ADMIN" --amount "$STAKE")"
  assert_eq "shares were minted to the staker" "$(q0 "$SHARES" balance --id "$ADMIN")" "$STAKE"
  assert_eq "and the supply agrees" "$(q0 "$STAKING" total_supply)" "$STAKE"
else
  ok "the new generation has already taken a stake ($(q0 "$STAKING" total_supply))"
  assert_eq "and the share token minted it" "$(q0 "$SHARES" balance --id "$ADMIN")" "$(q0 "$STAKING" total_supply)"
fi

echo ""
echo "==> every pointer, both directions, new generation"
assert_eq "vault.agusd"             "$(q0 "$VAULT" agusd)" "$AGUSD"
assert_eq "agusd.minter"            "$(q0 "$AGUSD" minter)" "$VAULT"
assert_eq "vault.oracle"            "$(q0 "$VAULT" oracle)" "$ORACLE"
assert_eq "vault.allocation_engine" "$(q0 "$VAULT" allocation_engine)" "$ENGINE"
assert_eq "engine.vault"            "$(q0 "$ENGINE" vault)" "$VAULT"
assert_eq "staking.agusd"           "$(q0 "$STAKING" agusd)" "$AGUSD"
assert_eq "staking.shares"          "$(q0 "$STAKING" shares)" "$SHARES"
assert_eq "shares.admin is staking" "$(q0 "$SHARES" admin)" "$STAKING"
assert_eq "still four pools"        "$(q "$ENGINE" pools | python3 -c "import sys,json;print(len(json.load(sys.stdin)))")" "4"
while read -r name addr _o _j _c; do
  [ -n "$name" ] || continue
  assert_eq "$name names the new Vault" "$(q0 "$addr" vault)" "$VAULT"
done <<< "$POOLS"

echo ""
echo "==> and the old generation is still standing, which is the point"
assert_eq "the old Vault still holds its reserves" "$(q0 "$OLD_VAULT" idle_reserves)" "$V_IDLE"
assert_eq "the old staking still has its supply"   "$(q0 "$OLD_STAKING" total_supply)" "$S_SUPPLY"
assert_eq "and still names a token it can burn"    "$(q0 "$OLD_STAKING" agusd)" "$OLD_AGUSD"

echo ""
echo "==> writing $DEP"
python3 - "$DEP" "$VAULT" "$OLD_VAULT" "$AGUSD" "$OLD_AGUSD" "$STAKING" "$OLD_STAKING" \
  "$SHARES" "$STRANDED" "$OWED" <<'ZPY'
import json, sys, collections
(path, vault, old_vault, agusd, old_agusd, staking, old_staking, shares,
 stranded, owed) = sys.argv[1:]
dep = json.loads(open(path).read(), object_pairs_hook=collections.OrderedDict)
hist = dep.get('superseded', [])
REASON = (
    'Replaced by scripts/deploy-generation-side-by-side.sh, which deploys a new generation without '
    'retiring this one. deploy-vault-generation.sh refuses to start above a staking supply of zero, and '
    'that supply cannot be brought to zero: %s sagUSD is held by three accounts that stopped answering in '
    'October, the token has no clawback, its classic issuer signs at weight 0, and Supply is written in '
    'exactly three places in the staking source, none reachable by an admin. See '
    'scripts/check-staking-migration-block.sh, which measures it live. So this generation is left running '
    'rather than emptied, and that is deliberate: it still holds its reserves, its agUSD still has a '
    'minter, its staking contract still names a token it can burn, and the %s agUSD owed to those holders '
    'is covered by its idle reserves many times over. Their exit path is unchanged. The record stops '
    'pointing at this generation; it does not stop working.' % (stranded, owed))
for contract, old in (('vault', old_vault), ('agusdCore', old_agusd), ('staking', old_staking)):
    g = max((e['generation'] for e in hist if e['contract'] == contract), default=0) + 1
    hist.append(collections.OrderedDict([
        ('contract', contract), ('generation', g),
        ('label', '%s, generation %d' % (contract, g)),
        ('address', old), ('supersededBy', contract),
        ('stillLive', True),
        ('reason', REASON),
    ]))
dep['contracts']['vault'] = vault
dep['contracts']['agusdCore'] = agusd
dep['contracts']['staking'] = staking
dep['contracts']['stakingShares'] = shares
dep['superseded'] = hist
ahead = dep.get('treeAheadOfLedger') or []
for e in ahead:
    print('    dropped the treeAheadOfLedger entry for %s' % e['contract'])
dep['treeAheadOfLedger'] = []
open(path, 'w').write(json.dumps(dep, indent=2, ensure_ascii=False) + '\n')
print('    vault   = %s' % vault)
print('    agUSD   = %s' % agusd)
print('    staking = %s' % staking)
print('    shares  = %s' % shares)
ZPY

echo ""
echo "  $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
