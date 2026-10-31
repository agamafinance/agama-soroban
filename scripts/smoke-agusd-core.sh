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
#   wiring  : the Vault mints the token whose mint authority is the Vault
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

# agUSD's supply, from Horizon.
#
# A Stellar Asset Contract has no `total_supply`: its entry points are admin,
# set_admin, authorized, set_authorized, clawback, trust, mint, burn and the
# token interface, and nothing else. Every assertion here that asked
# `total_supply` therefore read empty and failed, reporting a protocol fault
# that was a question the contract cannot answer.
#
# For a classic asset the supply is the sum of everything outstanding, and
# Horizon is where that is reported. All six buckets, because leaving one out
# would understate what the Vault owes: trustlines in three authorization
# states, claimable balances, liquidity pools, and the contract balances, which
# is where most of this one sits.
AGUSD_ISSUER=$(j "d['agusdClassic']['issuer']")
agusd_supply() {
  local horizon
  case "$NET" in (testnet) horizon=https://horizon-testnet.stellar.org;; (*) horizon=https://horizon.stellar.org;; esac
  curl -s --max-time 25 "$horizon/assets?asset_code=agUSD&asset_issuer=$AGUSD_ISSUER" | python3 -c "
import json, sys
try:
    r = json.load(sys.stdin)['_embedded']['records']
except Exception:
    raise SystemExit(1)
if not r:
    raise SystemExit(1)
a = r[0]
b = a.get('balances') or {}
total = sum(float(x or 0) for x in (
    b.get('authorized'),
    b.get('authorized_to_maintain_liabilities'),
    b.get('unauthorized'),
    a.get('claimable_balances_amount'),
    a.get('liquidity_pools_amount'),
    a.get('contracts_amount'),
    a.get('archived_contracts_amount'),
))
print(int(round(total * 10_000_000)))
"
}
assert_eq() { if [ "$(num "$2")" = "$3" ]; then ok "$1 ($2)"; else bad "$1: got $2, want $3"; fi; }

# Read-only: simulated, never submitted, so views cost nothing.
# A read that comes back empty is not a contract answering with nothing. It
# happens when something else is submitting from the same account at the same
# time, which is what running two of these suites at once does: the sequence
# number collides, calls fail with TxBadSeq, and reads come back blank. One
# blank poisons everything after it, because the Vault address is itself read
# from the Engine here, so a single empty answer turns every later assertion
# into a diff against an empty string and reads like a page of contract
# defects. Retried before being believed. Running two suites against one
# account concurrently is still the wrong thing to do; this only stops it
# looking like a protocol failure when it happens.
q() {
  local out i
  for i in 1 2 3 4; do
    out=$(stellar contract invoke --id "$1" --source $SRC --network $NET --send=no -- "${@:2}" 2>/dev/null)
    [ -n "$out" ] && { echo "$out"; return 0; }
    sleep 2
  done
  echo "$out"
}
# State changing: submitted, and the transaction hash is echoed.
# A transaction that failed must not print a transaction hash. This scraped the
# first 64 hex characters out of combined stdout and stderr, and a failure
# prints diagnostic events full of them, so a refused call came back looking
# exactly like a successful one. The script then carried on against a state
# that had not changed, and the failure surfaced three assertions later as a
# number nobody could explain. It says "failed" and the contract error now.
tx() {
  local out
  if out=$(stellar contract invoke --id "$1" --source $SRC --network $NET -- "${@:2}" 2>&1); then
    echo "$out" | grep -oE '[0-9a-f]{64}' | head -1
  else
    echo "FAILED $(echo "$out" | tr '\n' ' ' | grep -oE '#[0-9]+|TxBadSeq|tx_[A-Z_]+' | head -1)"
  fi
}
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


# Every suite here assumes a book roughly at rest and none of them establishes
# one, so the first in a run gets what it expects and the rest get whatever the
# previous one left. Established once, here, rather than tolerated assertion by
# assertion. See lib-baseline.sh.
# shellcheck source=lib-baseline.sh
. "$(dirname "$0")/lib-baseline.sh"
normalise_book "$VAULT" "$ENGINE" "$USDC" "$SRC" "$NET" "$ADMIN"
echo ""
echo "== WIRING: the Vault mints the token that names the Vault =="
assert_eq "the Vault's agUSD is agusd-core" "$(q "$VAULT" agusd)" "$AGUSD_CORE"
# The mint authority, asked by the name the deployed contract actually answers
# to. This line asked for `minter()` for as long as agUSD was the custom
# agusd-core contract, and agUSD is a Stellar Asset Contract now: the asset is
# classic, the contract address is its SAC, and a SAC's mint authority is its
# `admin`. There is no `minter` entry point to read, so the call came back empty
# and the suite reported that the Vault was not the minter, which was never true.
# A stale assertion that reads empty is worse than one that is wrong, because
# empty looks like the protocol failing rather than the test asking a question
# the contract cannot answer.
assert_eq "the agUSD SAC's admin is the Vault" "$(q "$AGUSD_CORE" admin)" "$VAULT"
assert_eq "the Vault holds the real USDC" "$(q "$VAULT" usdc)" "$USDC"
assert_eq "agUSD carries USDC's 7 decimals" "$(q "$AGUSD_CORE" decimals)" "7"
assert_eq "the token is agUSD" "$(q "$AGUSD_CORE" symbol)" "agUSD"

echo ""
echo "== MINT AUTHORITY: the Vault, and nothing else =="
# Authorization is enforced when a transaction is applied, not when it is
# simulated, so this one is built, simulated, signed and sent by hand. The CLI
# cannot sign for a contract address, so the transaction goes out with the
# Vault's authorization entry unsatisfied and the network traps it.
SUPPLY0=$(agusd_supply)
traps "the admin, who deployed the token, cannot mint it" \
  "$AGUSD_CORE" mint --to "$ADMIN" --amount "$PROBE"
assert_eq "total supply did not move" "$(agusd_supply)" "$SUPPLY0"

echo ""
echo "== DEPOSIT: USDC in, agUSD out 1:1 =="
SUPPLY_BEFORE=$(agusd_supply)
IDLE_BEFORE=$(num "$(q "$VAULT" idle_reserves)")
# Spendable, not held. The SAC's `balance` on a classic asset reports what the
# trustline holds, and a trustline that is backing the account's own SDEX offers
# cannot spend all of it: this deployment runs a market maker, so 291.8 USDC of
# balance was 288.4 of selling liabilities and 3.45 actually movable. The suite
# read 291, decided it had plenty, and the deposit came back #10 from the token,
# which is TrustlineMissingError and reads like a missing trustline rather than
# like an offer holding the funds. Five assertions then failed on arithmetic
# derived from a deposit that never happened.
#
# Held is still the fallback: a plain trustline with no offers against it makes
# the two numbers equal, and if Horizon cannot be reached the SAC's answer is
# better than no answer.
spendable_usdc() {
  local out
  out=$(curl -s --max-time 20 "https://horizon-testnet.stellar.org/accounts/$ADMIN" \
    | python3 -c "
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(1)
for b in d.get('balances', []):
    if b.get('asset_code') == 'USDC':
        bal = float(b['balance']); sell = float(b.get('selling_liabilities', 0) or 0)
        print(int(round(max(0.0, bal - sell) * 10_000_000)))
        break
" 2>/dev/null)
  case "$out" in (*[!0-9]*|"") num "$(q "$USDC" balance --id "$ADMIN")";; (*) echo "$out";; esac
}
U0=$(spendable_usdc)
if [ "$U0" -lt "$DEPOSIT" ]; then
  # A short balance here usually is not a short balance. An earlier run queues
  # a withdrawal and does not settle it, so the USDC is in the Vault owed to
  # this very account, which then reads zero and stops. Settling pays whichever
  # claim is at the head to its recorded owner and is permissionless, so it
  # takes nothing from anybody.
  # shellcheck source=lib-ensure-usdc.sh
  . "$(dirname "$0")/lib-ensure-usdc.sh"
  ensure_usdc "$VAULT" "$USDC" "$AGUSD_CORE" "$DEPOSIT" "$SRC" "$NET" "$ADMIN" || true
  U0=$(spendable_usdc)
fi
if [ "$U0" -lt "$DEPOSIT" ]; then
  echo "  the admin can spend $U0 (7dp) of USDC and the deposit is $DEPOSIT"
  echo "  top up at https://faucet.circle.com (USDC / Stellar Testnet) for $ADMIN"
  exit 2
fi
# Read after the top-up above, not before it. Reaching the deposit amount can
# mean redeeming agUSD, which burns supply and moves the Vault's reserves, so a
# snapshot taken earlier is stale by exactly what the top-up cost.
SUPPLY_BEFORE=$(agusd_supply)
IDLE_BEFORE=$(num "$(q "$VAULT" idle_reserves)")
A0=$(num "$(q "$AGUSD_CORE" balance --id "$ADMIN")")
HELD0=$(num "$(q "$USDC" balance --id "$ADMIN")")
R0=$(num "$(q "$VAULT" idle_reserves)")
D0=$(num "$(q "$VAULT" deposits)")
echo "  deposit $DEPOSIT  tx $(tx "$VAULT" deposit --from "$ADMIN" --amount "$DEPOSIT")"
assert_eq "the depositor was minted 1 agUSD per USDC" \
  "$(q "$AGUSD_CORE" balance --id "$ADMIN")" "$((A0 + DEPOSIT))"
# Against the reading taken immediately before the deposit. SUPPLY0 is from
# before the top-up, and reaching the deposit amount can mean redeeming agUSD,
# which burns supply.
assert_eq "total supply rose by the same amount" \
  "$(agusd_supply)" "$((SUPPLY_BEFORE + DEPOSIT))"
assert_eq "the USDC is in the Vault" "$(q "$VAULT" idle_reserves)" "$((R0 + DEPOSIT))"
# Held before against held after, not spendable before against held after. U0 is
# the spendable figure the precondition needs and it is smaller than the
# trustline's balance whenever an offer is backed by it, so subtracting the
# deposit from it describes an account nobody has.
assert_eq "and out of the depositor's account" \
  "$(q "$USDC" balance --id "$ADMIN")" "$((HELD0 - DEPOSIT))"
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
S1=$(agusd_supply)
U1=$(num "$(q "$USDC" balance --id "$ADMIN")")
R1=$(num "$(q "$VAULT" idle_reserves)")
echo "  request_withdrawal $WITHDRAW (claim $CLAIM_ID)  tx $(tx "$VAULT" request_withdrawal --from "$ADMIN" --amount "$WITHDRAW")"
assert_eq "the agUSD is burned at request time" \
  "$(q "$AGUSD_CORE" balance --id "$ADMIN")" "$((A1 - WITHDRAW))"
assert_eq "supply fell with it" "$(agusd_supply)" "$((S1 - WITHDRAW))"
assert_eq "the USDC has not moved yet" "$(q "$VAULT" idle_reserves)" "$R1"
assert_eq "the claim is at the head of the queue and covered" \
  "$(q "$VAULT" claim_status --claim_id "$CLAIM_ID")" "Ready"

echo "  claim_withdrawal $CLAIM_ID  tx $(tx "$VAULT" claim_withdrawal --from "$ADMIN" --claim_id "$CLAIM_ID")"
assert_eq "the USDC came back" "$(q "$USDC" balance --id "$ADMIN")" "$((U1 + WITHDRAW))"
assert_eq "out of the Vault's reserves" "$(q "$VAULT" idle_reserves)" "$((R1 - WITHDRAW))"
assert_eq "the claim is settled" "$(q "$VAULT" claim_status --claim_id "$CLAIM_ID")" "Claimed"
assert_eq "the queue is empty again" "$(q "$VAULT" queue_length)" "0"
# The whole point of the generation 2 token: the Vault is the only thing that
# can create it, one unit per USDC deposited.
#
# Asserted as a delta and an inequality rather than as an equality of totals,
# and the difference matters. Equality of totals also claims the Vault has never
# received a stroop it did not mint against, which is a different property and
# not one this script establishes: USDC can arrive here by a transfer nobody
# booked, an earlier version of smoke-hardening did exactly that, and the Vault
# cannot account for it afterwards. Those stroops leave the Vault holding more
# than agUSD claims, which is the safe direction and still breaks an equality.
#
# So: minting is one for one, measured across the deposit this script just made,
# and the Vault is never short of what it owes. Both hold on a deployment other
# scripts have used, which equality of totals does not.
assert_eq "the deposit minted exactly one agUSD per USDC" \
  "$(( $(agusd_supply) - SUPPLY_BEFORE ))" \
  "$(( $(num "$(q "$VAULT" idle_reserves)") - IDLE_BEFORE ))"
# Idle reserves plus what is out with the pools. Comparing idle alone against
# the whole supply was right only while nothing was deployed, and it reported
# the Vault as insolvent the moment the Engine allocated a dollar: the capital
# had not vanished, it was in an adapter, and the claim against it had not
# changed. Deployed capital is the Vault's own number for exactly that.
IDLE=$(num "$(q "$VAULT" idle_reserves)")
OUT=$(num "$(q "$VAULT" deployed_capital)")
# Plus what has been recognised as lost, which is the third place the Vault's
# capital can be and the one this assertion was missing.
#
# It reported the Vault short by 72000000 while the Engine declared 100000000
# written off, and that is not insolvency being detected, it is a write-down
# being double counted. A write_down is the admission that capital left and is
# not coming back: the USDC is gone, the agUSD minted against it is still
# outstanding, and no honest accounting makes those two meet again. An invariant
# that says a Vault is never short of what its token claims therefore cannot
# hold on any deployment where a loss has ever been recognised, and this one has
# a 10 USDC CCTP burn on it that is deliberately permanent.
#
# What is still worth asserting, and what this does assert, is that the shortfall
# is no larger than the losses that were declared. A Vault short by more than it
# has written off is short for a reason nobody wrote down, and that is the thing
# worth failing on.
LOST=$(num "$(q "$ENGINE" written_off)")
HELD=$(( ${IDLE:-0} + ${OUT:-0} + ${LOST:-0} ))
OWED=$(agusd_supply)
if [ "$HELD" -ge "$OWED" ]; then
  ok "the Vault is short by no more than it has written off" \
     "$IDLE idle plus $OUT deployed plus $LOST recognised as lost, against $OWED"
else
  bad "the Vault holds $IDLE idle plus $OUT deployed, and declares $LOST lost, $HELD against $OWED of agUSD: short by more than anyone wrote down"
fi

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
# Sized from the floor rather than picked. A 9500 bps floor is breached by an
# allocation that leaves free reserves below 95% of the base, which means one
# larger than 5% of it; the old figure here was 1%, which a 95% floor does not
# refuse at all, and it passed only because the deployment it was written
# against had a different shape. Ten percent is safely over the line and still
# well inside the 4000 bps pool cap.
UNDER=$(( $(num "$(q "$VAULT" free_reserves)") / 10 ))
echo "  raise the floor to 9500 bps  tx $(tx "$ENGINE" set_reserve_floor --admin "$ADMIN" --floor_bps 9500)"
# Read the floor back before asserting on it. The raise is a submitted
# transaction and testnet drops one occasionally with a submission timeout; when
# that happened this suite went on to assert that an allocation inside the old
# floor was refused, which it is not, and reported the Engine accepting
# something it should have refused. That reads as the guard being broken when
# the guard was never armed. A step that did not happen is a skip, not a
# failure.
NOW_FLOOR=$(num "$(q "$ENGINE" reserve_floor_bps)")
if [ "$NOW_FLOOR" = "9500" ]; then
  refuses "allocating $UNDER, well inside every cap, is refused by the floor" 410 \
    "$ENGINE" allocate --admin "$ADMIN" --pool_id "$EF" --amount "$UNDER"
else
  echo "  SKIP  the floor did not move, it reads $NOW_FLOOR and not 9500, so the"
  echo "        refusal below was never armed and is not asserted. Rerun."
fi
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
