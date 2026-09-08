#!/usr/bin/env bash
# On-chain smoke test of the generation 2 deposit path: USDC into the Vault,
# agUSD out 1:1, and back again through the withdrawal queue.
#
# Everything here runs against the LIVE testnet deployment recorded in
# deployments/testnet.json, with the real Circle USDC. It is repeatable: the
# deposit is withdrawn again at the end, so the only lasting change is the
# working capital left in the Vault.
#
# Covers, with assertions:
#   wiring  : the Vault mints the token that names the Vault as its minter
#   mint    : a caller that is not the Vault cannot mint, submitted for real
#             because authorization is checked when a transaction is applied
#             and not when it is simulated
#   deposit : USDC in, agUSD out 1:1, balance, supply and reserves all move
#   setter  : set_agusd is refused once the Vault has taken a deposit
#   exit    : request_withdrawal burns the agUSD, claim_withdrawal returns the
#             USDC, and the queue advances
#   guards  : the Allocation Engine still refuses an allocation past the
#             per-pool concentration cap and past the idle reserve floor
#   staking : whether the deployed sagUSD accepts the new token
#
# Needs the admin account (agama-poc) to hold the deposit amount in real USDC.
# Get some at https://faucet.circle.com (USDC / Stellar Testnet).
#
# Written for the generation 2 deployment. The stack has since been redeployed
# and rewired; scripts/smoke-journey.sh covers the whole journey against the
# current one, including everything here. This is kept because the addresses and
# transactions it produced are still on the ledger and still recorded.
#
# Usage: bash scripts/smoke-agusd-core.sh
set -uo pipefail
cd "$(dirname "$0")/.."

NET=testnet
SRC=agama-poc
DEP=deployments/testnet.json

DEPOSIT=30000000  # 3 USDC at 7 decimals
WITHDRAW=10000000 # 1 agUSD, which is also the Vault's anti-dust floor
PROBE=10000000    # size of the mint a non-Vault caller is not allowed to make

j() { python3 -c "import json;d=json.load(open('$DEP'));print($1)"; }
USDC=$(j "d['contracts']['usdc']")
AGUSD_CORE=$(j "d['contracts']['agusdCore']")
AGUSD_V1=$(j "d['contracts']['agusd']")
VAULT=$(j "d['contracts']['vault']")
ENGINE=$(j "d['contracts']['allocationEngine']")
STAKING=$(j "d['contracts']['staking']")
PC=$(j "d['poolAdapters']['private-credit']")
EF=$(j "d['poolAdapters']['etherfuse']")
POOL_CAP=$(j "d['engineConfig']['poolCapBps']")
ORIGINATOR_CAP=$(j "d['engineConfig']['originatorCapBps']")
JURISDICTION_CAP=$(j "d['engineConfig']['jurisdictionCapBps']")
FLOOR=$(j "d['engineConfig']['reserveFloorBps']")
ADMIN=$(stellar keys address $SRC)

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  PASS  $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL  $1"; }
num() { echo "$1" | tr -d '"'; }
assert_eq() { if [ "$(num "$2")" = "$3" ]; then ok "$1 ($2)"; else bad "$1: got $2, want $3"; fi; }

# Read-only: simulated, never submitted, so views cost nothing.
q()  { stellar contract invoke --id "$1" --source $SRC --network $NET --send=no -- "${@:2}" 2>/dev/null; }
# State changing: submitted, and the transaction hash is echoed.
tx() { stellar contract invoke --id "$1" --source $SRC --network $NET -- "${@:2}" 2>&1 \
         | grep -oE '[0-9a-f]{64}' | head -1; }
# A call that has to be refused, and refused for the stated reason. Simulated
# only: a refused call is meant to move nothing, so there is nothing to submit.
# Contract errors surface in simulation, which is what these all are.
refuses() { # refuses <label> <error code> <contract id> <args...>
  local label="$1" code="$2" id="$3"; shift 3
  local out
  if out=$(stellar contract invoke --id "$id" --source $SRC --network $NET --send=no -- "$@" 2>&1); then
    bad "$label: the call was accepted"
  elif echo "$out" | grep -qE "#$code([^0-9]|$)"; then
    ok "$label (contract error #$code)"
  else
    bad "$label: refused, but not with #$code [$(echo "$out" | tr '\n' ' ' | tail -c 160)]"
  fi
}
# A call whose authorization the caller cannot produce, which is a different
# thing from a call the contract refuses. Simulation records authorization
# rather than enforcing it, so these are submitted for real: the transaction
# goes out with a contract address's authorization entry unsatisfied and the
# network traps it when it applies. Building, simulating, signing and sending
# are split apart because the CLI will not sign for a contract address.
traps() { # traps <label> <contract id> <args...>
  local label="$1" id="$2"; shift 2
  local out hash
  out=$(stellar contract invoke --id "$id" --source $SRC --network $NET --build-only -- "$@" 2>/dev/null \
        | stellar tx simulate --source $SRC --network $NET 2>/dev/null \
        | stellar tx sign --sign-with-key $SRC --network $NET 2>/dev/null | tail -1 \
        | stellar tx send --network $NET 2>&1)
  hash=$(echo "$out" | grep -oE '[0-9a-f]{64}' | head -1)
  if echo "$out" | grep -q "TxFailed"; then
    ok "$label (tx $hash failed when it applied)"
  else
    bad "$label: it was not refused (tx $hash)"
  fi
}

echo "== deployment under test =="
echo "  vault (generation 2) $VAULT"
echo "  agusd-core           $AGUSD_CORE"
echo "  agusd generation 1   $AGUSD_V1 (superseded, untouched)"
echo "  usdc                 $USDC"
echo "  allocation-engine    $ENGINE"
echo "  staking (sagUSD)     $STAKING"

echo ""
echo "== WIRING: the Vault mints the token that names the Vault =="
assert_eq "the Vault's agUSD is agusd-core" "$(q "$VAULT" agusd)" "$AGUSD_CORE"
assert_eq "agusd-core's minter is the Vault" "$(q "$AGUSD_CORE" minter)" "$VAULT"
assert_eq "the Vault holds the real USDC" "$(q "$VAULT" usdc)" "$USDC"
assert_eq "agUSD carries USDC's 7 decimals" "$(q "$AGUSD_CORE" decimals)" "7"
assert_eq "the token is agUSD" "$(q "$AGUSD_CORE" symbol)" "agUSD"

echo ""
echo "== MINT AUTHORITY: the Vault, and nothing else =="
# Authorization is enforced when a transaction is applied, not when it is
# simulated, so this one is built, simulated, signed and sent by hand. The CLI
# cannot sign for a contract address, so the transaction goes out with the
# Vault's authorization entry unsatisfied and the network traps it.
SUPPLY0=$(num "$(q "$AGUSD_CORE" total_supply)")
traps "the admin, who deployed the token, cannot mint it" \
  "$AGUSD_CORE" mint --to "$ADMIN" --amount "$PROBE"
assert_eq "total supply did not move" "$(q "$AGUSD_CORE" total_supply)" "$SUPPLY0"

echo ""
echo "== DEPOSIT: USDC in, agUSD out 1:1 =="
U0=$(num "$(q "$USDC" balance --id "$ADMIN")")
if [ "$U0" -lt "$DEPOSIT" ]; then
  echo "  the admin holds $U0 (7dp) of USDC and the deposit is $DEPOSIT"
  echo "  top up at https://faucet.circle.com (USDC / Stellar Testnet) for $ADMIN"
  exit 2
fi
A0=$(num "$(q "$AGUSD_CORE" balance --id "$ADMIN")")
R0=$(num "$(q "$VAULT" idle_reserves)")
D0=$(num "$(q "$VAULT" deposits)")
echo "  deposit $DEPOSIT  tx $(tx "$VAULT" deposit --from "$ADMIN" --amount "$DEPOSIT")"
assert_eq "the depositor was minted 1 agUSD per USDC" \
  "$(q "$AGUSD_CORE" balance --id "$ADMIN")" "$((A0 + DEPOSIT))"
assert_eq "total supply rose by the same amount" \
  "$(q "$AGUSD_CORE" total_supply)" "$((SUPPLY0 + DEPOSIT))"
assert_eq "the USDC is in the Vault" "$(q "$VAULT" idle_reserves)" "$((R0 + DEPOSIT))"
assert_eq "and out of the depositor's account" \
  "$(q "$USDC" balance --id "$ADMIN")" "$((U0 - DEPOSIT))"
assert_eq "the Vault counted the deposit" "$(q "$VAULT" deposits)" "$((D0 + 1))"

echo ""
echo "== SETTER: the agUSD pointer is closed once money has arrived =="
refuses "repointing a Vault that has taken deposits is refused" 312 \
  "$VAULT" set_agusd --admin "$ADMIN" --agusd_token "$AGUSD_V1"
assert_eq "the Vault still mints agusd-core" "$(q "$VAULT" agusd)" "$AGUSD_CORE"

echo ""
echo "== EXIT: request burns, claim pays =="
CLAIM_ID=$(num "$(q "$VAULT" queue_tail)")
A1=$(num "$(q "$AGUSD_CORE" balance --id "$ADMIN")")
S1=$(num "$(q "$AGUSD_CORE" total_supply)")
U1=$(num "$(q "$USDC" balance --id "$ADMIN")")
R1=$(num "$(q "$VAULT" idle_reserves)")
echo "  request_withdrawal $WITHDRAW (claim $CLAIM_ID)  tx $(tx "$VAULT" request_withdrawal --from "$ADMIN" --amount "$WITHDRAW")"
assert_eq "the agUSD is burned at request time" \
  "$(q "$AGUSD_CORE" balance --id "$ADMIN")" "$((A1 - WITHDRAW))"
assert_eq "supply fell with it" "$(q "$AGUSD_CORE" total_supply)" "$((S1 - WITHDRAW))"
assert_eq "the USDC has not moved yet" "$(q "$VAULT" idle_reserves)" "$R1"
assert_eq "the claim is at the head of the queue and covered" \
  "$(q "$VAULT" claim_status --claim_id "$CLAIM_ID")" "Ready"

echo "  claim_withdrawal $CLAIM_ID  tx $(tx "$VAULT" claim_withdrawal --from "$ADMIN" --claim_id "$CLAIM_ID")"
assert_eq "the USDC came back" "$(q "$USDC" balance --id "$ADMIN")" "$((U1 + WITHDRAW))"
assert_eq "out of the Vault's reserves" "$(q "$VAULT" idle_reserves)" "$((R1 - WITHDRAW))"
assert_eq "the claim is settled" "$(q "$VAULT" claim_status --claim_id "$CLAIM_ID")" "Claimed"
assert_eq "the queue is empty again" "$(q "$VAULT" queue_length)" "0"
# The whole point of the generation 2 token: supply is exactly what the Vault
# is holding, because the Vault is the only thing that can create it and this
# Vault has not deployed any capital.
assert_eq "one agUSD in circulation, one USDC in the Vault" \
  "$(q "$AGUSD_CORE" total_supply)" "$(num "$(q "$VAULT" idle_reserves)")"

echo ""
echo "== CUSTODY: only the Allocation Engine can pull funds out =="
R2=$(num "$(q "$VAULT" idle_reserves)")
traps "an admin signed settle_allocation cannot release the Vault's USDC" \
  "$VAULT" settle_allocation --pool "$PC" --amount "$WITHDRAW"
assert_eq "the reserves are untouched" "$(q "$VAULT" idle_reserves)" "$R2"

echo ""
echo "== GUARDS: the Engine's caps and reserve floor still bind =="
# The Engine stores the Vault address at initialize() and has no setter, so it
# still guards the superseded Vault. The limits below are therefore measured
# against that Vault's book, not against the one that just took the deposit.
ENGINE_VAULT=$(num "$(q "$ENGINE" vault)")
echo "  the Engine guards $ENGINE_VAULT"
if [ "$ENGINE_VAULT" = "$VAULT" ]; then
  ok "the Engine points at the Vault under test"
else
  echo "  NOTE  the Engine points at the superseded Vault, so the limits below are"
  echo "        measured on that book. Repointing it needs an Engine redeployment."
fi
DEPLOYED=$(num "$(q "$ENGINE" total_allocated)")
IDLE=$(num "$(q "$ENGINE_VAULT" idle_reserves)")
TOTAL=$((IDLE + DEPLOYED))
echo "  idle=$IDLE total=$TOTAL floor=${FLOOR}bps pool cap=${POOL_CAP}bps"

OVER=$(( TOTAL * (POOL_CAP + 1000) / 10000 ))
refuses "allocating $OVER, past the ${POOL_CAP} bps pool cap, is refused" 407 \
  "$ENGINE" allocate --admin "$ADMIN" --pool_id "$EF" --amount "$OVER"

# This raises the floor above the current reserve ratio to show it refusing a
# release that every cap allows, then puts it straight back. It dates from a
# configuration where two pools capped at 30% could deploy at most 60% of the
# book, so a 20% floor could never bind on its own. The deployed limits no
# longer have that problem, and scripts/smoke-journey.sh reaches the state where
# the floor is the only limit refusing an allocation without touching it.
UNDER=$(( TOTAL / 100 ))
echo "  raise the floor to 9500 bps  tx $(tx "$ENGINE" set_reserve_floor --admin "$ADMIN" --floor_bps 9500)"
refuses "allocating $UNDER, well inside every cap, is refused by the floor" 410 \
  "$ENGINE" allocate --admin "$ADMIN" --pool_id "$EF" --amount "$UNDER"
echo "  restore the floor to $FLOOR bps  tx $(tx "$ENGINE" set_reserve_floor --admin "$ADMIN" --floor_bps "$FLOOR")"
assert_eq "the reserve floor is back where it was" "$(q "$ENGINE" reserve_floor_bps)" "$FLOOR"
assert_eq "the caps are untouched" "$(q "$ENGINE" caps)" \
  "{jurisdiction_bps:$JURISDICTION_CAP,originator_bps:$ORIGINATOR_CAP,pool_bps:$POOL_CAP}"

echo ""
echo "== STAKING: does the deployed sagUSD accept the new token =="
STAKING_ASSET=$(num "$(q "$STAKING" agusd)")
echo "  the staking contract stakes $STAKING_ASSET"
if [ "$STAKING_ASSET" = "$AGUSD_CORE" ]; then
  ok "sagUSD accepts agusd-core"
else
  echo "  NOTE  that is the generation 1 agUSD, not agusd-core. The staking"
  echo "        contract stores the token address at initialize() and has no"
  echo "        setter, so it cannot be pointed at the new token."
  V1_BAL=$(num "$(q "$AGUSD_V1" balance --id "$ADMIN")")
  CORE_BAL=$(num "$(q "$AGUSD_CORE" balance --id "$ADMIN")")
  STAKE=$((V1_BAL + 1000000))
  if [ "$CORE_BAL" -ge "$STAKE" ]; then
    # Staking more than the generation 1 balance while holding plenty of
    # agusd-core: if the contract read the new token this would go through.
    refuses "staking $STAKE fails on the generation 1 balance of $V1_BAL, while the caller holds $CORE_BAL of agusd-core" \
      1 "$STAKING" stake --from "$ADMIN" --amount "$STAKE"
  else
    echo "  SKIP  not enough agusd-core on the admin to make the point"
  fi
fi

echo ""
echo "================================"
echo " SMOKE RESULT: $PASS passed, $FAIL failed"
echo "================================"
[ "$FAIL" = "0" ]
