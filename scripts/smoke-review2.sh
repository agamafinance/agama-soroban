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
tx() { stellar contract invoke --id "$1" --source $SRC --network $NET -- "${@:2}" 2>&1 \
         | grep -oE '[0-9a-f]{64}' | head -1; }
# State changing, signed by somebody other than the admin.
tx_as() { local who=$1 id=$2; shift 2
  stellar contract invoke --id "$id" --source "$who" --network $NET -- "$@" 2>&1 \
    | grep -oE '[0-9a-f]{64}' | head -1; }
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

echo ""
echo "== preconditions =="
assert_eq "the superseded Engine governs the superseded Vault, so the pair matches" \
  "$(q "$OLD_ENGINE" vault)" "$OLD_VAULT"
# bob has to be unable to receive USDC for finding 2 to mean anything. He holds
# none, so the trustline can simply be dropped if a previous run added one.
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
EXPLOIT_POOL=$(stellar contract deploy --wasm target/wasm32v1-none/release/private_credit.wasm \
  --source $SRC --network $NET 2>&1 | grep -oE 'C[A-Z2-7]{55}' | tail -1)
echo "  exploit pool      $EXPLOIT_POOL"
echo "    initialize       tx $(tx "$EXPLOIT_POOL" initialize --admin "$ADMIN" --engine "$OLD_ENGINE" --vault "$OLD_VAULT" --usdc "$USDC")"
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
echo "    deposit          tx $(tx "$VAULT" deposit --from "$ADMIN" --amount "$FLOOR_DEPOSIT")"
N_FREE=$(q0 "$VAULT" free_reserves)
N_DEP=$(q0 "$VAULT" deployed_capital)
N_LOSS=$(q0 "$VAULT" recognised_losses)
N_BASE=$(q0 "$VAULT" floor_base)
N_TOTAL=$((N_FREE + N_DEP))
assert_eq "floor_base is net assets plus everything ever written off" "$N_BASE" "$((N_TOTAL + N_LOSS))"
N_KEEP=$((N_BASE * FLOOR / BPS))
N_ROOM=$((N_FREE - N_KEEP))
N_POOLMAX=$((N_TOTAL * POOL_CAP / BPS))
LEG1=$(( N_ROOM < N_POOLMAX ? N_ROOM : N_POOLMAX ))
LEG2=$((N_ROOM - LEG1))
echo "  book: $N_FREE free, $N_DEP deployed, $N_LOSS already written off, base $N_BASE"
echo "  the floor keeps $N_KEEP, so $N_ROOM is deployable, split $LEG1 / $LEG2 to"
echo "  stay under the $POOL_CAP bps per-pool cap and let the floor be what binds."
PC_HELD0=$(q0 "$USDC" balance --id "$PC")
echo "    allocate pc      tx $(tx "$ENGINE" allocate --admin "$ADMIN" --pool_id "$PC" --amount "$LEG1")"
if [ "$LEG2" -gt 0 ]; then
  echo "    allocate ef      tx $(tx "$ENGINE" allocate --admin "$ADMIN" --pool_id "$EF" --amount "$LEG2")"
fi
assert_eq "free reserves are at the floor, to the stroop" "$(q "$VAULT" free_reserves)" "$N_KEEP"
refused 410 "one more stroop is refused, by the floor and not a cap" \
  "$ENGINE" allocate --admin "$ADMIN" --pool_id "$EF" --amount 1

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
assert_eq "the reserve ratio does not jump upwards on a loss" "$(q "$ENGINE" get_reserve_ratio)" "$FLOOR"
refused 410 "the one stroop the superseded Engine allowed is still refused" \
  "$ENGINE" allocate --admin "$ADMIN" --pool_id "$PC" --amount 1
refused 410 "and so is the headroom a write-down used to invent" \
  "$ENGINE" allocate --admin "$ADMIN" --pool_id "$PC" --amount "$((LEG1 * FLOOR / BPS))"
assert_eq "free reserves have not moved a stroop" "$(q "$VAULT" free_reserves)" "$N_KEEP"

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
fi
echo "    agUSD to bob     tx $(tx "$AGUSD" transfer --from "$ADMIN" --to "$STUCK_ADDR" --amount "$CLAIM")"
echo "    agUSD to alice   tx $(tx "$AGUSD" transfer --from "$ADMIN" --to "$OTHER_ADDR" --amount "$CLAIM")"

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
