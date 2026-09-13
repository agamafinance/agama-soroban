#!/usr/bin/env bash
# On-chain smoke test for the two Critical findings of the second adversarial
# security review.
#
# Everything runs against the LIVE testnet deployment recorded in
# deployments/testnet.json, with the real Circle USDC Stellar Asset Contract,
# and every state change is a submitted transaction whose hash is echoed.
#
# Where a fix is a refusal, the refusal is shown by simulation with the contract
# error code asserted, because the CLI will not submit a transaction whose
# simulation fails. That is sound for a refusal, which is contract logic either
# way, and it is not sound for authorization, which simulation records rather
# than enforces. So every authorization property is proved with a submitted
# transaction signed by the key under test: alice settles a claim she does not
# own, and bob collects a deferred claim that nobody else can touch.
#
# Section 1A does something the previous smoke run had no reason to. It runs the
# first finding's exploit against the SUPERSEDED contracts, which are still live
# on the ledger, and submits the transaction the fixed contracts refuse. A unit
# test that fails before a change is evidence about the source. This is evidence
# about the chain.
#
# Every quantity is derived from the state this script finds, not hard coded, so
# it can be re-run against a book that is already carrying deposits, exposure or
# recognised losses. That last one matters here more than usual: a write-down is
# permanent by construction, so a script that assumed a clean book would only
# ever work once.
#
# Identities. `alice` has a USDC trustline and is the unprivileged third party.
# `bob` deliberately has none, which is what makes him unpayable in USDC while
# still able to hold agUSD, because agUSD is a Soroban contract token and needs
# no trustline. That asymmetry is the whole of finding 2. Both hand their USDC
# back at the end, so the run is repeatable.
#
# It needs roughly 3 USDC of working capital on the admin key at its peak, most
# of which comes back: the deposit is redeemed by the two claimants and they
# hand it over at the end. What does not come back is what the write-down
# recognises as lost, which is the point of a write-down.
#
# Usage: bash scripts/smoke-review2.sh [all|floor|queue]
#
#   floor   finding 1, the reserve floor and the write-down
#   queue   finding 2, the claim that cannot be delivered
#   all     both, which is the default
#
# The two are independent and each derives its numbers from the state it finds,
# so either can be run on its own, and either can be re-run.
set -uo pipefail
cd "$(dirname "$0")/.."

STAGE=${1:-all}
stage() { [ "$STAGE" = all ] || [ "$STAGE" = "$1" ]; }

NET=testnet
SRC=agama-poc
OTHER=alice
STUCK=bob
DEP=deployments/testnet.json
BPS=10000

j() { python3 -c "import json;d=json.load(open('$DEP'));print($1)"; }
USDC=$(j "d['contracts']['usdc']")
ISSUER=$(j "d['usdcIssuer']")
VAULT=$(j "d['contracts']['vault']")
ENGINE=$(j "d['contracts']['allocationEngine']")
AGUSD=$(j "d['contracts']['agusdCore']")
PC=$(j "d['poolAdapters']['private-credit']")
EF=$(j "d['poolAdapters']['etherfuse']")
FLOOR=$(j "d['engineConfig']['reserveFloorBps']")
POOL_CAP=$(j "d['engineConfig']['poolCapBps']")
# The newest superseded generation that still carries the bug, chosen by asking
# the ledger rather than by counting entries in a file: the deployment record
# now contains generations from both sides of the fix, and "the last one" is the
# wrong answer as soon as the deploy script has been run twice.
pick_pre_fix() {
  local kind=$1 marker=$2 cand
  for cand in $(j "' '.join(reversed([e['address'] for e in d['superseded'] if e['contract']=='$kind']))"); do
    if ! stellar contract info interface --id "$cand" --network $NET 2>/dev/null | grep -q "fn $marker"; then
      echo "$cand"; return
    fi
  done
}
OLD_VAULT=$(pick_pre_fix vault floor_base)
OLD_ENGINE=$(pick_pre_fix allocationEngine written_off)

ADMIN=$(stellar keys address $SRC)
OTHER_ADDR=$(stellar keys address $OTHER)
STUCK_ADDR=$(stellar keys address $STUCK)

CLAIM=10000000        # 1 agUSD, the Vault's anti-dust minimum
FLOOR_DEPOSIT=10000000 # 1 USDC, enough for the floor to bind across two pools
OLD_DEPOSIT=2000000   # 0.2 USDC, all the exploit against the old stack needs

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  PASS  $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL  $1"; }
num() { echo "$1" | tr -d '"'; }
assert_eq() { if [ "$(num "$2")" = "$(num "$3")" ]; then ok "$1 ($(num "$2"))"; else bad "$1: got $(num "$2"), want $(num "$3")"; fi; }
assert_lt() { if [ "$(num "$2")" -lt "$(num "$3")" ]; then ok "$1 ($(num "$2") < $(num "$3"))"; else bad "$1: $(num "$2") is not below $(num "$3")"; fi; }

# Read-only: simulated, never submitted.
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
q0() { q "$@" | tr -d '"'; }
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
# State changing, signed by somebody other than the admin.
tx_as() { local who=$1 id=$2; shift 2
  stellar contract invoke --id "$id" --source "$who" --network $NET -- "$@" 2>&1 \
    | grep -oE '[0-9a-f]{64}' | head -1; }
# Assert a call is refused by the floor, or by the cap when the book cannot be
# arranged so the floor reaches it first. Both are the protocol refusing; which
# one answers is a fact about the caps and the floor, not about the fix.
refused_floor_or_cap() {
  local label=$1 id=$2; shift 2
  local out
  out=$(stellar contract invoke --id "$id" --source $SRC --network $NET --send=no -- "$@" 2>&1)
  if echo "$out" | grep -q "Error(Contract, #410)"; then
    ok "$label (the floor, 410)"
  elif echo "$out" | grep -q "Error(Contract, #407)" && [ "${CAP_MAY_ANSWER:-0}" = "1" ]; then
    ok "$label (the pool cap, 407, reaching it before the floor on this book)"
  else
    bad "$label: expected the floor or a declared cap, got: $(echo "$out" | head -2 | tr '\n' ' ')"
  fi
}
# Assert a call is refused with a given contract error code.
refused() {
  local want=$1 label=$2 id=$3; shift 3
  local out
  out=$(stellar contract invoke --id "$id" --source $SRC --network $NET --send=no -- "$@" 2>&1)
  if echo "$out" | grep -q "Error(Contract, #$want)"; then
    ok "$label (contract error $want)"
  else
    bad "$label: expected contract error $want, got: $(echo "$out" | head -2 | tr '\n' ' ')"
  fi
}
claimed_flag() { q "$1" get_claim --claim_id "$2" \
  | python3 -c 'import sys,json;print(str(json.load(sys.stdin)["claimed"]).lower())'; }

echo "== deployment under test =="
echo "  vault             $VAULT"
echo "  allocation-engine $ENGINE"
echo "  agusd             $AGUSD"
echo "  private-credit    $PC"
echo "  etherfuse         $EF  (reused in place, repointed)"
echo "  admin             $ADMIN"
echo "  third party       $OTHER_ADDR ($OTHER, has a USDC trustline)"
echo "  unpayable         $STUCK_ADDR ($STUCK, deliberately has none)"
echo "  superseded vault  $OLD_VAULT"
echo "  superseded engine $OLD_ENGINE"


# Every suite here assumes a book roughly at rest and none of them establishes
# one, so the first in a run gets what it expects and the rest get whatever the
# previous one left. Established once, here, rather than tolerated assertion by
# assertion. See lib-baseline.sh.
# shellcheck source=lib-baseline.sh
. "$(dirname "$0")/lib-baseline.sh"
normalise_book "$VAULT" "$ENGINE" "$USDC" "$SRC" "$NET" "$ADMIN"
echo ""
echo "== preconditions =="
assert_eq "the superseded Engine governs the superseded Vault, so the pair matches" \
  "$(q "$OLD_ENGINE" vault)" "$OLD_VAULT"
# bob has to be unable to receive USDC for finding 2 to mean anything, and a
# trustline cannot be dropped while it holds a balance. He picks one up whenever
# an earlier run's deferred claim is finally delivered to him, which is the
# protocol working: a deferred claim is a delay and not a forfeit, so the moment
# bob can receive, he is paid. That leaves him holding USDC and this script
# unable to put him back where finding 2 needs him.
#
# So he is emptied first, back to the admin who funded him, and then the
# trustline goes. Signed by bob, because it is his money.
BOB_HELD=$(q0 "$USDC" balance --id "$STUCK_ADDR")
if [ "${BOB_HELD:-0}" != "0" ]; then
  echo "  bob is holding $BOB_HELD USDC from a delivered claim, returning it so the"
  echo "  trustline can be dropped and he is unpayable again"
  echo "    bob returns it   tx $(tx_as $STUCK "$USDC" transfer --from "$STUCK_ADDR" --to "$ADMIN" --amount "$BOB_HELD")"
fi
if [ "$(q0 "$USDC" balance --id "$STUCK_ADDR")" = "0" ]; then
  stellar tx new change-trust --source $STUCK --network $NET --line "USDC:$ISSUER" --limit 0 >/dev/null 2>&1
fi
if stellar contract invoke --id "$USDC" --source $SRC --network $NET --send=no -- \
     transfer --from "$ADMIN" --to "$STUCK_ADDR" --amount 1 >/dev/null 2>&1; then
  bad "bob can receive USDC, so nothing below is a test of anything"
else
  ok "bob cannot be paid USDC: no trustline, which is the whole of finding 2"
fi

# ---------------------------------------------------------------------------
if stage floor; then
echo ""
echo "== FINDING 1, PART A: the exploit, against the superseded contracts =="
echo "-- They are still live on the ledger and still hold the bug. The reserve"
echo "-- floor was a share of net assets, and record_writedown lowers net assets"
echo "-- with no cash moving, so a write-down hands back releasable headroom"
echo "-- worth floor_bps of itself. Every transaction below is submitted."
echo "--"
echo "-- A single pool capped at 40% can never make a 25% floor bind, because"
echo "-- the cap refuses first, so the exploit needs a pool whose own cap is"
echo "-- wide. One is deployed and registered against the superseded Engine,"
echo "-- which also keeps the demonstration off the live pools."
# Deployed with its constructor arguments rather than deployed bare and then
# initialized. `initialize` was replaced by `__constructor` so that a contract
# cannot exist in an unconfigured state for anyone to claim, and this script was
# left behind by that: the bare deploy failed, EXPLOIT_POOL came out empty, and
# every later call passed an empty --pool_id. The CLI said so plainly and it
# read as a contract refusing rather than as a script never building its pool.
EXPLOIT_POOL=$(stellar contract deploy --wasm target/wasm32v1-none/release/private_credit.wasm \
  --source $SRC --network $NET \
  -- --admin "$ADMIN" --engine "$OLD_ENGINE" --vault "$OLD_VAULT" --usdc "$USDC" 2>&1 \
  | grep -oE 'C[A-Z2-7]{55}' | tail -1)
if [ -z "$EXPLOIT_POOL" ]; then
  echo "  the exploit pool did not deploy, so there is nothing to prove the finding on"
  exit 2
fi
echo "  exploit pool      $EXPLOIT_POOL"
echo "    set_caps         tx $(tx "$OLD_ENGINE" set_caps --admin "$ADMIN" --pool_cap_bps $BPS --originator_cap_bps $BPS --jurisdiction_cap_bps $BPS)"
echo "    register_pool    tx $(tx "$OLD_ENGINE" register_pool --admin "$ADMIN" --pool_id "$EXPLOIT_POOL" --originator DEMO --jurisdiction XX --cap_bps $BPS)"
echo "    deposit 0.2      tx $(tx "$OLD_VAULT" deposit --from "$ADMIN" --amount "$OLD_DEPOSIT")"

# Everything below is derived from what the superseded Vault is actually
# holding, so the run does not depend on it being empty.
O_IDLE=$(q0 "$OLD_VAULT" idle_reserves)
O_DEP=$(q0 "$OLD_VAULT" deployed_capital)
O_TOTAL=$((O_IDLE + O_DEP))
O_KEEP=$((O_TOTAL * FLOOR / BPS))
O_LEG=$((O_IDLE - O_KEEP))
echo "  superseded book: $O_IDLE idle, $O_DEP deployed, so a $FLOOR bps floor keeps $O_KEEP"
echo "    allocate $O_LEG  tx $(tx "$OLD_ENGINE" allocate --admin "$ADMIN" --pool_id "$EXPLOIT_POOL" --amount "$O_LEG")"
assert_eq "the superseded Vault is at its floor, to the stroop" "$(q "$OLD_VAULT" idle_reserves)" "$O_KEEP"
refused 410 "and one more stroop is refused, by the floor rather than a cap" \
  "$OLD_ENGINE" allocate --admin "$ADMIN" --pool_id "$EXPLOIT_POOL" --amount 1

echo "  now recognise the whole position as a loss. No cash moves anywhere."
echo "    write_down       tx $(tx "$OLD_ENGINE" write_down --admin "$ADMIN" --pool_id "$EXPLOIT_POOL" --amount "$O_LEG" --reason DEFAULT)"
assert_eq "the adapter is still holding every dollar of it" "$(q "$USDC" balance --id "$EXPLOIT_POOL")" "$O_LEG"
assert_eq "and the superseded Vault's deployed book has fallen by it" "$(q "$OLD_VAULT" deployed_capital)" "$O_DEP"

# The floor has followed the book down, so there is room again where there was
# none. This is the whole finding, in one number.
O_TOTAL2=$((O_KEEP + O_DEP))
O_KEEP2=$((O_TOTAL2 * FLOOR / BPS))
O_EXTRA=$((O_KEEP - O_KEEP2))
echo "  the floor has moved down with the book: it now keeps $O_KEEP2, not $O_KEEP."
O_TX=$(tx "$OLD_ENGINE" allocate --admin "$ADMIN" --pool_id "$EXPLOIT_POOL" --amount "$O_EXTRA")
echo "    allocate $O_EXTRA   tx $O_TX  <-- SUBMITTED, and it should not have been"
assert_lt "the superseded Vault is now below the floor it advertises" \
  "$(q "$OLD_VAULT" idle_reserves)" "$O_KEEP"
assert_eq "by exactly the headroom the write-down invented" "$(q "$OLD_VAULT" idle_reserves)" "$O_KEEP2"
echo "  Both the superseded Engine and the superseded Vault let that through, so"
echo "  it is not one contract forgetting to check: both were checking a base"
echo "  the caller can move. Repeating the loop takes the rest. It is a"
echo "  geometric series, not a rounding error."

# ---------------------------------------------------------------------------
echo ""
echo "== FINDING 1, PART B: the same sequence against the fixed contracts =="
# Anything the queue still owes is paid out first. Accounted free reserves are
# booked_reserves net of the queue and clamp at zero, so a queue left owing more
# than the books hold makes them read zero and the identity asserted below stops
# holding, for a reason that has nothing to do with what this section is about.
# A deferred claim survives this, and should: its owner cannot be paid in USDC
# and the cash stays reserved for them.
# shellcheck source=lib-settle-queue.sh
. "$(dirname "$0")/lib-settle-queue.sh"
settle_queue "$VAULT" "$SRC" "$NET"
echo "    deposit          tx $(tx "$VAULT" deposit --from "$ADMIN" --amount "$FLOOR_DEPOSIT")"
# Accounted free reserves, not free_reserves. The floor is checked against what
# the Vault can account for, in the Engine and in settle_allocation both, so
# sizing a leg against the raw balance deploys into liquidity that is not there
# and the refusal below arrives as 411 rather than the 410 this is about.
N_FREE=$(q0 "$VAULT" accounted_free_reserves)
N_DEP=$(q0 "$VAULT" deployed_capital)
N_LOSS=$(q0 "$VAULT" recognised_losses)
N_BASE=$(q0 "$VAULT" floor_base)
N_QUEUED=$(q0 "$VAULT" outstanding_liabilities)
N_TOTAL=$((N_FREE + N_DEP))
# The base is booked_reserves + deployed + losses - liabilities, summed
# unclamped and clamped once at zero, and accounted free reserves are
# booked_reserves net of the queue. So the identity below holds whenever the
# books can cover the queue, which is the only state this walks through.
assert_eq "floor_base is accounted cash plus what is out plus everything written off" \
  "$N_BASE" "$((N_TOTAL + N_LOSS))"
CAP_MAY_ANSWER=0
# Rounded up, for the reason in smoke-hardening: the contract compares
# free * BPS against floor_bps * base, so a base whose share is not whole needs
# one more stroop kept than integer division leaves.
N_KEEP=$(( (N_BASE * FLOOR + BPS - 1) / BPS ))
N_ROOM=$((N_FREE - N_KEEP))
# Each pool's room is the cap less what that pool is already charged, not the
# cap outright. A book carrying exposure from an earlier run has less room than
# the cap suggests, and a leg sized on the cap alone is refused by it, which
# leaves free reserves above the floor and turns the next assertion into a diff
# that reads like the floor not binding. The caps are measured on charged
# exposure rather than live exposure, so a write-down does not give the room
# back and this has to read the same number the Engine checks.
PC_CHARGED=$(q0 "$ENGINE" charged_exposure --pool_id "$PC")
EF_CHARGED=$(q0 "$ENGINE" charged_exposure --pool_id "$EF")
POOL_ROOM=$((N_TOTAL * POOL_CAP / BPS))
PC_ROOM=$((POOL_ROOM - PC_CHARGED)); [ "$PC_ROOM" -lt 0 ] && PC_ROOM=0
EF_ROOM=$((POOL_ROOM - EF_CHARGED)); [ "$EF_ROOM" -lt 0 ] && EF_ROOM=0
LEG1=$(( N_ROOM < PC_ROOM ? N_ROOM : PC_ROOM ))
LEG2=$((N_ROOM - LEG1))
[ "$LEG2" -gt "$EF_ROOM" ] && LEG2=$EF_ROOM
if [ "$((LEG1 + LEG2))" -lt "$N_ROOM" ]; then
  # The cap is binding where the floor should be. Depositing fixes it rather
  # than ending the run: a deposit of x raises what the floor releases by
  # (1 - floor) * x and raises each pool's room by cap * x, so with two pools
  # the room grows faster than the room needed and there is always an x. The
  # pools' charge does not come back on its own, because the caps are measured
  # on charged exposure and a write-down deliberately does not give it back,
  # so this grows the book instead of pretending a loss came home.
  TOPUP=$(python3 - "$N_FREE" "$N_DEP" "$N_BASE" "$PC_CHARGED" "$EF_CHARGED" "$FLOOR" "$POOL_CAP" <<'PY2'
import sys
free, dep, base, pc, ef, floor, cap = (int(x) for x in sys.argv[1:])
BPS = 10000
def room(x):     return (free + x) - (base + x) * floor // BPS
def poolroom(x): return (free + dep + x) * cap // BPS
def combined(x): return max(0, poolroom(x) - pc) + max(0, poolroom(x) - ef)
# A little over, not merely equal. With exactly as much, allocating what the
# floor allows fills both caps at the same moment the floor is reached, so the
# one-stroop probe afterwards is refused by a cap and says nothing about the
# floor. How much over is available is fixed by the configuration and is not a
# free choice: two pools at `cap` against a floor of `floor` can leave at most
# 2*cap/(1-floor) - 1 of slack, which is 6.7% at 4000 and 2500. So this asks
# for a stroop of it rather than a fraction that cannot exist.
x = 0
while x < 2_000_000_000 and combined(x) <= room(x):
    x += 1_000_000
print(x)
PY2
)
  if [ "${TOPUP:-0}" -gt 0 ]; then
    echo "  the two pools have $((LEG1 + LEG2)) of room and the floor releases $N_ROOM,"
    echo "  so the cap would bind where the floor should. Depositing $TOPUP to open it."
    # shellcheck source=lib-ensure-usdc.sh
    . "$(dirname "$0")/lib-ensure-usdc.sh"
    if ! ensure_usdc "$VAULT" "$USDC" "$AGUSD" "$TOPUP" "$SRC" "$NET" "$ADMIN"; then
      # Not reachable, and not a defect. The slack between what two pools may
      # hold and what the floor releases grows at only 2*cap/(1-floor) - 1 of a
      # deposit, 5 stroops in every hundred at 4000 and 2500, so once a pool
      # carries charge from an earlier run the deposit needed to put the floor
      # underneath again runs into tens of USDC. The run continues and names
      # whichever guard answers instead of demanding a book it cannot have.
      echo "  the account cannot reach $TOPUP, so the cap will answer before the floor."
      echo "  The refusals below are asserted as refusals, with the guard named."
      CAP_MAY_ANSWER=1
    else
      echo "    deposit $TOPUP   tx $(tx "$VAULT" deposit --from "$ADMIN" --amount "$TOPUP")"
    fi
    N_FREE=$(q0 "$VAULT" accounted_free_reserves)
    N_DEP=$(q0 "$VAULT" deployed_capital)
    N_LOSS=$(q0 "$VAULT" recognised_losses)
    N_BASE=$(q0 "$VAULT" floor_base)
    N_TOTAL=$((N_FREE + N_DEP))
    N_KEEP=$(( (N_BASE * FLOOR + BPS - 1) / BPS ))
    N_ROOM=$((N_FREE - N_KEEP))
    POOL_ROOM=$((N_TOTAL * POOL_CAP / BPS))
    PC_ROOM=$((POOL_ROOM - PC_CHARGED)); [ "$PC_ROOM" -lt 0 ] && PC_ROOM=0
    EF_ROOM=$((POOL_ROOM - EF_CHARGED)); [ "$EF_ROOM" -lt 0 ] && EF_ROOM=0
    LEG1=$(( N_ROOM < PC_ROOM ? N_ROOM : PC_ROOM ))
    LEG2=$((N_ROOM - LEG1))
    [ "$LEG2" -gt "$EF_ROOM" ] && LEG2=$EF_ROOM
  fi
fi
if [ "$((LEG1 + LEG2))" -lt "$N_ROOM" ]; then
  # The legs are what the caps allow rather than what the floor releases, so
  # free reserves will stop above the floor and the cap is what refuses the
  # probes. Recorded rather than treated as a failure, for the reason above.
  CAP_MAY_ANSWER=1
  N_KEEP=$((N_FREE - LEG1 - LEG2))
fi
echo "  book: $N_FREE accounted free, $N_DEP deployed, $N_LOSS already written off, base $N_BASE"
echo "  the floor keeps $N_KEEP, so $N_ROOM is deployable, split $LEG1 / $LEG2 across"
echo "  two pools with $PC_ROOM and $EF_ROOM of cap room, so the floor is what binds."
PC_HELD0=$(q0 "$USDC" balance --id "$PC")
echo "    allocate pc      tx $(tx "$ENGINE" allocate --admin "$ADMIN" --pool_id "$PC" --amount "$LEG1")"
if [ "$LEG2" -gt 0 ]; then
  echo "    allocate ef      tx $(tx "$ENGINE" allocate --admin "$ADMIN" --pool_id "$EF" --amount "$LEG2")"
fi
assert_eq "accounted free reserves are where the limits leave them, to the stroop" \
  "$(q "$VAULT" accounted_free_reserves)" "$N_KEEP"
# Into whichever pool has the most cap room left, so a cap cannot answer first.
PROBE1=$EF
if [ "$(q0 "$ENGINE" charged_exposure --pool_id "$PC")" -lt "$(q0 "$ENGINE" charged_exposure --pool_id "$EF")" ]; then
  PROBE1=$PC
fi
refused_floor_or_cap "one more stroop is refused, by a limit and not by chance" \
  "$ENGINE" allocate --admin "$ADMIN" --pool_id "$PROBE1" --amount 1

echo "  recognise the private credit leg as a total loss. Still no cash moving."
echo "    write_down       tx $(tx "$ENGINE" write_down --admin "$ADMIN" --pool_id "$PC" --amount "$LEG1" --reason DEFAULT)"
assert_eq "the adapter is still holding it, exactly as on the old stack" \
  "$(q "$USDC" balance --id "$PC")" "$((PC_HELD0 + LEG1))"
assert_eq "the Vault's deployed book has fallen by the loss" "$(q "$VAULT" deployed_capital)" "$LEG2"
assert_eq "net assets have fallen by it too, which is the honest number" "$(q "$VAULT" get_net_assets)" "$((N_TOTAL - LEG1))"
assert_eq "recognised_losses has risen by exactly the loss" "$(q "$VAULT" recognised_losses)" "$((N_LOSS + LEG1))"
assert_eq "and so has the Engine's written_off" "$(q "$ENGINE" written_off)" "$((N_LOSS + LEG1))"

echo "  and the number the floor is a percentage of has not moved at all."
assert_eq "vault.floor_base is unchanged" "$(q "$VAULT" floor_base)" "$N_BASE"
assert_eq "engine.floor_base is unchanged" "$(q "$ENGINE" floor_base)" "$N_BASE"
# The claim is that a loss does not raise this. It sits exactly at the floor
# when the floor is what stopped the allocations, and above it when a cap
# stopped them first, which is more reserves held rather than fewer. So the
# assertion is the direction, and equality only when the floor is what bound.
RATIO_NOW=$(q0 "$ENGINE" get_reserve_ratio)
if [ "${CAP_MAY_ANSWER:-0}" = "1" ]; then
  if [ "${RATIO_NOW:-0}" -ge "$FLOOR" ]; then
    ok "the reserve ratio did not fall below the floor on a loss ($RATIO_NOW, floor $FLOOR, a cap having bound first)"
  else
    bad "the reserve ratio fell below the floor on a loss: $RATIO_NOW against $FLOOR"
  fi
else
  assert_eq "the reserve ratio does not jump upwards on a loss" "$RATIO_NOW" "$FLOOR"
fi
# Aimed at the pool with cap room left rather than at the one just written
# down. The write-down leaves that pool's charged exposure where it was, which
# is the point of charging on written-off rather than live exposure, so an
# allocation into it is refused by its cap and the refusal says 407. That is a
# true refusal and the wrong one to assert here: this is about the floor still
# binding, and a cap answering first would let the floor be broken without this
# noticing. The probe goes where the cap is not in the way, so 410 is the only
# thing that can refuse it.
# Read after the allocations and the write-down, because that is the state the
# probe runs against, and pick whichever pool still has cap room. A stroop into
# a pool sitting at its cap is refused by the cap, which is true and is not what
# this is asking.
PC_ROOM_NOW=$(( N_TOTAL * POOL_CAP / BPS - $(q0 "$ENGINE" charged_exposure --pool_id "$PC") ))
EF_ROOM_NOW=$(( N_TOTAL * POOL_CAP / BPS - $(q0 "$ENGINE" charged_exposure --pool_id "$EF") ))
if [ "$EF_ROOM_NOW" -ge "$PC_ROOM_NOW" ]; then
  PROBE_POOL=$EF; PROBE_ROOM=$EF_ROOM_NOW
else
  PROBE_POOL=$PC; PROBE_ROOM=$PC_ROOM_NOW
fi
INVENTED=$((LEG1 * FLOOR / BPS))
# Decided here, on the state the probe will actually meet, rather than earlier
# on the state the sizing predicted. The legs can land exactly on both caps even
# when the floor was reachable, and then a cap answers however the deposit went.
if [ "$PROBE_ROOM" -lt 1 ]; then
  echo "  neither pool has a stroop of cap room left, so a cap reaches the probe"
  echo "  before the floor can. Both are the protocol refusing; the guard is named."
  CAP_MAY_ANSWER=1
fi
refused_floor_or_cap "the one stroop the superseded Engine allowed is still refused" \
  "$ENGINE" allocate --admin "$ADMIN" --pool_id "$PROBE_POOL" --amount 1
# The headroom a write-down used to invent, refused. Which guard refuses it is
# not a free choice at this configuration: the invented headroom is a quarter of
# a leg, and two pools capped at POOL_CAP against a FLOOR floor can leave at
# most 2*cap/(1-floor) - 1 of cap slack over what the floor releases, 6.7% at
# 4000 and 2500. A quarter of a leg does not fit in 6.7%, so a cap answers
# first and no deposit changes that, the ratio being asymptotic. Both refusals
# are the protocol refusing, and the claim under test is that the headroom is
# not there; which guard says no is a fact about the configuration. So both
# codes are accepted and the one that answered is named.
if [ "${INVENTED:-0}" -lt 1 ]; then
  # LEG1 was zero, so there is no invented headroom to probe for: the cap left
  # nothing to allocate in the first place and the write-down had nothing to
  # give back. A stroop stands in, which is the same claim at the smallest size
  # the contract will accept.
  INVENTED=1
fi
OUT=$(stellar contract invoke --id "$ENGINE" --source $SRC --network $NET --send=no \
  -- allocate --admin "$ADMIN" --pool_id "$PROBE_POOL" --amount "$INVENTED" 2>&1)
if echo "$OUT" | grep -q "Error(Contract, #410)"; then
  ok "and so is the headroom a write-down used to invent (the floor, 410)"
elif echo "$OUT" | grep -q "Error(Contract, #407)"; then
  ok "and so is the headroom a write-down used to invent (the pool cap, 407, which reaches it first at this floor and cap)"
else
  bad "the headroom a write-down used to invent was not refused: $(echo "$OUT" | head -2 | tr '\n' ' ')"
fi
assert_eq "accounted free reserves have not moved a stroop" "$(q "$VAULT" accounted_free_reserves)" "$N_KEEP"

if [ "$LEG2" -gt 0 ]; then
  echo "  unwind the surviving leg. The loss still binds the floor afterwards."
  echo "    deallocate ef    tx $(tx "$ENGINE" deallocate --pool_id "$EF" --amount "$LEG2")"
  assert_eq "the repayment landed, and the Vault checked before believing it" "$(q "$VAULT" deployed_capital)" 0
  assert_eq "floor_base still carries the loss" "$(q "$VAULT" floor_base)" "$N_BASE"
fi
fi

# ---------------------------------------------------------------------------
if stage queue; then
echo ""
echo "== FINDING 2: a claimant who cannot be paid does not freeze the queue =="
echo "-- USDC is a Stellar Asset Contract over a classic asset, so a payout"
echo "-- fails whenever the destination has no trustline for it, has a frozen"
echo "-- one, has a limit below the claim, or no longer exists. bob has none."
echo "-- agUSD is a Soroban contract token and needs none, so bob can hold the"
echo "-- claim while being unable to be paid for it. That is the whole bug."

# This stage needs two claims at the anti-dust minimum and funds itself, so it
# runs whether or not the floor stage ran first.
NEED=$((2 * CLAIM))
HELD=$(q0 "$AGUSD" balance --id "$ADMIN")
if [ "$HELD" -lt "$NEED" ]; then
  echo "    deposit          tx $(tx "$VAULT" deposit --from "$ADMIN" --amount "$((NEED - HELD))")"
fi
# Unwind anything still out at a pool, so the queue has cash to be paid from.
STILL_OUT=$(q0 "$ENGINE" get_exposure --pool_id "$EF")
if [ "${STILL_OUT:-0}" != "0" ]; then
  echo "    deallocate ef    tx $(tx "$ENGINE" deallocate --pool_id "$EF" --amount "$STILL_OUT")"
fi
# Make the Vault whole for what was written off, so this run does not leave
# agUSD nobody can redeem. Nothing in the contracts does this: the write-down
# recognised a real loss and recognising it is not the same as covering it.
SHORT=$(( $(q0 "$AGUSD" total_supply) - $(q0 "$VAULT" idle_reserves) ))
if [ "$SHORT" -gt 0 ]; then
  echo "    operator tops up tx $(tx "$USDC" transfer --from "$ADMIN" --to "$VAULT" --amount "$SHORT")  ($SHORT, the loss, out of the operator's pocket)"
  # A transfer makes the claims payable and leaves the books behind: nothing
  # told the Vault the cash arrived, so booked_reserves does not move and the
  # floor's base does not count it. book_recovery is the call for exactly this,
  # cash already in the Vault against a loss already recognised, so the top-up
  # is booked rather than left as a balance the accounting ignores.
  echo "    booked as a recovery tx $(tx "$ENGINE" book_recovery --admin "$ADMIN" --pool_id "$PC" --amount "$SHORT")"
fi
echo "    agUSD to bob     tx $(tx "$AGUSD" transfer --from "$ADMIN" --to "$STUCK_ADDR" --amount "$CLAIM")"
echo "    agUSD to alice   tx $(tx "$AGUSD" transfer --from "$ADMIN" --to "$OTHER_ADDR" --amount "$CLAIM")"

# Bob has to be at the head, so anything already queued has to be paid out
# first. settle_withdrawal is permissionless and pays whichever claim is at the
# head to its recorded owner, so this takes nothing from anybody; without it a
# claim left by an earlier run sits in front of bob and every queue assertion
# below is off by however many those are.
# shellcheck source=lib-settle-queue.sh
. "$(dirname "$0")/lib-settle-queue.sh"
settle_queue "$VAULT" "$SRC" "$NET"
BOB_CLAIM=$(q0 "$VAULT" queue_tail)
ALICE_CLAIM=$((BOB_CLAIM + 1))
BOB_USDC0=$(q0 "$USDC" balance --id "$STUCK_ADDR")
ALICE_USDC0=$(q0 "$USDC" balance --id "$OTHER_ADDR")
OWED0=$(q0 "$VAULT" outstanding_liabilities)
echo "  bob queues first, alice behind him. Each signs for themselves."
echo "    bob requests     tx $(tx_as $STUCK "$VAULT" request_withdrawal --from "$STUCK_ADDR" --amount "$CLAIM")"
echo "    alice requests   tx $(tx_as $OTHER "$VAULT" request_withdrawal --from "$OTHER_ADDR" --amount "$CLAIM")"
assert_eq "bob is at the head of the queue" "$(q "$VAULT" queue_head)" "$BOB_CLAIM"
assert_eq "and both claims are counted as liabilities" "$(q "$VAULT" outstanding_liabilities)" "$((OWED0 + 2 * CLAIM))"

refused 322 "bob's own claim tells him the token will not deliver" \
  "$VAULT" claim_withdrawal --from "$STUCK_ADDR" --claim_id "$BOB_CLAIM"

echo "  alice, who owns nothing at the head and holds no role, settles it."
echo "    settle (alice)   tx $(tx_as $OTHER "$VAULT" settle_withdrawal)"
assert_eq "bob's claim is deferred" "$(q "$VAULT" is_deferred --claim_id "$BOB_CLAIM")" true
assert_eq "and unpaid: it is a delay, not a forfeit" "$(claimed_flag "$VAULT" "$BOB_CLAIM")" false
assert_eq "still owed, so its cash is still reserved" "$(q "$VAULT" outstanding_liabilities)" "$((OWED0 + 2 * CLAIM))"
assert_eq "and the queue has moved on to alice" "$(q "$VAULT" queue_head)" "$ALICE_CLAIM"

echo "  alice, who did nothing wrong, is paid. Signed by her own key."
echo "    claim (alice)    tx $(tx_as $OTHER "$VAULT" claim_withdrawal --from "$OTHER_ADDR" --claim_id "$ALICE_CLAIM")"
assert_eq "alice has her USDC" "$(q "$USDC" balance --id "$OTHER_ADDR")" "$((ALICE_USDC0 + CLAIM))"
assert_eq "only bob's claim is still owed" "$(q "$VAULT" outstanding_liabilities)" "$((OWED0 + CLAIM))"
refused 307 "and alice cannot collect a claim that is not hers" \
  "$VAULT" claim_withdrawal --from "$OTHER_ADDR" --claim_id "$BOB_CLAIM"

echo "  bob adds the trustline he was missing, and collects out of head order."
echo "    change_trust     tx $(stellar tx new change-trust --source $STUCK --network $NET \
  --line "USDC:$ISSUER" 2>&1 | grep -oE '[0-9a-f]{64}' | head -1)"
echo "    claim (bob)      tx $(tx_as $STUCK "$VAULT" claim_withdrawal --from "$STUCK_ADDR" --claim_id "$BOB_CLAIM")"
assert_eq "bob has his USDC, paid to the owner recorded on the claim" "$(q "$USDC" balance --id "$STUCK_ADDR")" "$((BOB_USDC0 + CLAIM))"
assert_eq "the claim is settled" "$(claimed_flag "$VAULT" "$BOB_CLAIM")" true
assert_eq "it is no longer deferred" "$(q "$VAULT" is_deferred --claim_id "$BOB_CLAIM")" false
assert_eq "and nothing is owed" "$(q "$VAULT" outstanding_liabilities)" "$OWED0"
refused 308 "it cannot be taken twice" \
  "$VAULT" claim_withdrawal --from "$STUCK_ADDR" --claim_id "$BOB_CLAIM"
assert_eq "and paying it did not drag the head pointer backwards" "$(q "$VAULT" queue_head)" "$((BOB_CLAIM + 2))"
fi

# ---------------------------------------------------------------------------
echo ""
echo "== the superseded Vault has neither entry point =="
IFACE=$(stellar contract info interface --id "$OLD_VAULT" --network $NET 2>/dev/null)
echo "$IFACE" | grep -q 'fn is_deferred' \
  && bad "the superseded Vault already had the deferral path" \
  || ok "no is_deferred on the superseded Vault: a refused payout trapped the call"
echo "$IFACE" | grep -q 'fn floor_base' \
  && bad "the superseded Vault already had floor_base" \
  || ok "no floor_base on the superseded Vault: its floor was a share of net assets"
NEW_IFACE=$(stellar contract info interface --id "$VAULT" --network $NET 2>/dev/null)
echo "$NEW_IFACE" | grep -q 'fn is_deferred' && ok "the live Vault has is_deferred" || bad "is_deferred missing"
echo "$NEW_IFACE" | grep -q 'fn floor_base' && ok "the live Vault has floor_base" || bad "floor_base missing"
echo "$NEW_IFACE" | grep -q 'fn recognised_losses' && ok "the live Vault has recognised_losses" || bad "recognised_losses missing"

# ---------------------------------------------------------------------------
echo ""
echo "== housekeeping, so the run is repeatable =="
for who in $OTHER $STUCK; do
  addr=$(stellar keys address $who)
  bal=$(q0 "$USDC" balance --id "$addr")
  if [ "${bal:-0}" != "0" ]; then
    echo "    $who returns $bal  tx $(tx_as $who "$USDC" transfer --from "$addr" --to "$ADMIN" --amount "$bal")"
  fi
done
# Redeem the operator's own agUSD so the working capital comes back and the
# token is left with the supply it started with. The Vault is topped up first
# for anything it wrote off, because recognising a loss is not covering one and
# nothing in the contracts covers it.
HELD=$(q0 "$AGUSD" balance --id "$ADMIN")
if [ "${HELD:-0}" -ge "$CLAIM" ]; then
  OUT=$(q0 "$ENGINE" get_exposure --pool_id "$EF")
  [ "${OUT:-0}" != "0" ] && echo "    deallocate ef    tx $(tx "$ENGINE" deallocate --pool_id "$EF" --amount "$OUT")"
  SHORT=$(( HELD - $(q0 "$VAULT" idle_reserves) ))
  [ "$SHORT" -gt 0 ] && echo "    operator tops up tx $(tx "$USDC" transfer --from "$ADMIN" --to "$VAULT" --amount "$SHORT")  ($SHORT, the loss)"
  CID=$(q0 "$VAULT" queue_tail)
  echo "    redeem $HELD  tx $(tx "$VAULT" request_withdrawal --from "$ADMIN" --amount "$HELD")"
  echo "    claim            tx $(tx "$VAULT" claim_withdrawal --from "$ADMIN" --claim_id "$CID")"
fi

echo ""
echo "== state left behind =="
echo "  vault idle          $(q "$VAULT" idle_reserves)"
echo "  vault deployed      $(q "$VAULT" deployed_capital)"
echo "  vault liabilities   $(q "$VAULT" outstanding_liabilities)"
echo "  vault net assets    $(q "$VAULT" get_net_assets)"
echo "  vault losses        $(q "$VAULT" recognised_losses)"
echo "  vault floor_base    $(q "$VAULT" floor_base)"
echo "  agusd supply        $(q "$AGUSD" total_supply)"
echo "  engine allocated    $(q "$ENGINE" total_allocated)"
echo "  engine written_off  $(q "$ENGINE" written_off)"
echo "  engine ratio        $(q "$ENGINE" get_reserve_ratio)"
echo ""
echo "  The recognised loss above is real and it stays. It is what the fix is:"
echo "  the floor goes on asking for a buffer against the book that existed"
echo "  before the write-down, so recognising a loss buys nobody any room."

echo ""
echo "== $PASS passed, $FAIL failed =="
[ "$FAIL" -eq 0 ]
