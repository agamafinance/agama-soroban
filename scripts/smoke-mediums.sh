#!/usr/bin/env bash
# On-chain smoke test for the five Medium findings of the second adversarial
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
# transaction signed by the key under test: alice bumps a claim she does not
# own, and alice takes and returns the Engine's admin role with her own
# signature at both ends.
#
# Section M1A does what the previous run did for the Critical findings: it runs
# the exploit against SUPERSEDED contracts, which are still live on the ledger,
# and submits the transaction the fixed contracts refuse. A unit test that fails
# before a change is evidence about the source. This is evidence about the chain.
#
# Every quantity is derived from the state this script finds, not hard coded, so
# it can be re-run against a book that is already carrying deposits, exposure or
# recognised losses.
#
# Identities. `agama-poc` is the admin. `alice` is the unprivileged third party
# and needs a USDC trustline and a little XLM for fees.
#
# Working capital: about 1 USDC on the admin key at its peak, nearly all of
# which comes back. The queue stage borrows a whole agUSD because that is the
# Vault's anti-dust minimum and hands every stroop of it back; the caps stage
# borrows a fifth of one and gets it back through the recovery it is there to
# prove, less whatever is left below the minimum, which the next run absorbs.
# What does not come back is the fifth of a USDC the exploit sinks into the
# superseded stack, and that is the price of running the exploit against the
# contracts that actually have the bug rather than describing it.
#
# Usage: bash scripts/smoke-mediums.sh [all|caps|stranded|ttl|rotation|wiring]
#
#   ttl       M3, the claim record that archives and stops the queue
#   caps      M1, the concentration caps a write-down used to reset
#   stranded  M2, capital with no way out of an adapter
#   rotation  M4, a half finished admin rotation
#   wiring    M5, initialize replaced by a constructor
#   all       all five, which is the default
#
# The stages run M3 first and then M1, M2, M4, M5, which is working capital
# order rather than finding order. M3 needs a whole agUSD in one claim, because
# that is the Vault's anti-dust minimum, and it is the only stage that hands
# every stroop of it back; running it first means the peak requirement is one
# USDC rather than one plus what the other stages are holding. M2 also has to
# run after M1, because what it recovers is what M1 wrote off.
#
# One warning about the rotation stage: it hands the Engine's admin role to
# alice and takes it back, in four submitted transactions. If it is interrupted
# between the second and the fourth, the Engine's admin is alice, and the way
# back is `propose_admin --admin <alice> --new_admin <admin>` signed by alice
# followed by `accept_admin` signed by the admin. Both keys are local.
set -uo pipefail
cd "$(dirname "$0")/.."

STAGE=${1:-all}
stage() { [ "$STAGE" = all ] || [ "$STAGE" = "$1" ]; }

NET=testnet
SRC=agama-poc
OTHER=alice
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
# contains generations from both sides of every fix, and "the last one" is the
# wrong answer as soon as a deploy script has been run twice.
pick_pre_fix() {
  local kind=$1 marker=$2 cand
  for cand in $(j "' '.join(reversed([e['address'] for e in d['superseded'] if e['contract']=='$kind']))"); do
    if ! stellar contract info interface --id "$cand" --network $NET 2>/dev/null | grep -q "fn $marker"; then
      echo "$cand"; return
    fi
  done
}
OLD_ENGINE=$(pick_pre_fix allocationEngine charged_exposure)
OLD_VAULT=$(pick_pre_fix vault record_recovery)

ADMIN=$(stellar keys address $SRC)
OTHER_ADDR=$(stellar keys address $OTHER)

CLAIM=10000000        # 1 agUSD, the Vault's anti-dust minimum

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  PASS  $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL  $1"; }
num() { echo "$1" | tr -d '"'; }
assert_eq() { if [ "$(num "$2")" = "$(num "$3")" ]; then ok "$1 ($(num "$2"))"; else bad "$1: got $(num "$2"), want $(num "$3")"; fi; }
assert_gt() { if [ "$(num "$2")" -gt "$(num "$3")" ]; then ok "$1 ($(num "$2") > $(num "$3"))"; else bad "$1: $(num "$2") is not above $(num "$3")"; fi; }

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
refused_as() {
  local who=$1 want=$2 label=$3 id=$4; shift 4
  local out
  out=$(stellar contract invoke --id "$id" --source "$who" --network $NET --send=no -- "$@" 2>&1)
  if echo "$out" | grep -q "Error(Contract, #$want)"; then
    ok "$label (contract error $want)"
  else
    bad "$label: expected contract error $want, got: $(echo "$out" | head -2 | tr '\n' ' ')"
  fi
}
refused() { refused_as $SRC "$@"; }

echo "== deployment under test =="
echo "  vault             $VAULT"
echo "  allocation-engine $ENGINE"
echo "  agusd             $AGUSD"
echo "  private-credit    $PC"
echo "  etherfuse         $EF"
echo "  admin             $ADMIN"
echo "  third party       $OTHER_ADDR ($OTHER)"
echo "  superseded vault  $OLD_VAULT"
echo "  superseded engine $OLD_ENGINE"

# ---------------------------------------------------------------------------
if stage ttl; then
echo ""
echo "== M3: anybody can keep a claim record readable =="
echo "-- Claims are bumped only when they are written, and a claim behind a"
echo "-- stalled queue is a claim nothing writes to. An archived persistent entry"
echo "-- cannot be read at all, so the head archiving stopped the whole queue."
# The live Vault is used whenever the operator key can fund a claim at the
# anti-dust minimum, which is a whole agUSD. When it cannot, the stage stands up
# a Vault and an agUSD of its own from the same WASM and runs the demonstration
# there rather than skipping it. What is under test is a property of the claim
# record and the queue, and it does not depend on which token the Vault
# custodies, so the substitution costs the evidence nothing except the words
# "real Circle USDC". Every transaction below is still submitted.
TVAULT=$VAULT; TAGUSD=$AGUSD; TWHERE="the live Vault"
HELD=$(q0 "$TAGUSD" balance --id "$ADMIN")
SHORTFALL=$(( CLAIM - HELD ))
LIQUID=$(q0 "$USDC" balance --id "$ADMIN")
if [ "$SHORTFALL" -gt 0 ] && [ "$SHORTFALL" -le "${LIQUID:-0}" ]; then
  echo "    deposit          tx $(tx "$TVAULT" deposit --from "$ADMIN" --amount "$SHORTFALL")"
elif [ "$SHORTFALL" -gt 0 ]; then
  echo "  The operator key is $((SHORTFALL - LIQUID)) short of the $CLAIM a claim has to"
  echo "  be worth, and USDC that has gone into a Vault below that minimum cannot"
  echo "  come back out of it, which is the anti-dust rule doing its job. So this"
  echo "  stage runs against a Vault of its own, built from the same WASM as the"
  echo "  live one and holding a token it can mint itself."
  TUSDC=$(stellar contract deploy --wasm target/wasm32v1-none/release/mock_usdc.wasm \
    --source $SRC --network $NET 2>&1 | grep -oE 'C[A-Z2-7]{55}' | tail -1)
  echo "    test token       $TUSDC  tx $(tx "$TUSDC" initialize --admin "$ADMIN" --decimal 7 --name "Test USD" --symbol TUSD)"
  echo "    faucet           tx $(tx "$TUSDC" faucet --to "$ADMIN" --amount 1000000000)"
  TVAULT=$(stellar contract deploy --wasm target/wasm32v1-none/release/vault.wasm \
    --source $SRC --network $NET -- --admin "$ADMIN" --usdc_token "$TUSDC" 2>&1 | grep -oE 'C[A-Z2-7]{55}' | tail -1)
  TAGUSD=$(stellar contract deploy --wasm target/wasm32v1-none/release/agusd_core.wasm \
    --source $SRC --network $NET -- --admin "$ADMIN" --minter "$TVAULT" --decimal 7 \
    --name "Agama USD" --symbol agUSD 2>&1 | grep -oE 'C[A-Z2-7]{55}' | tail -1)
  TWHERE="a Vault of the same WASM, holding a token the operator can mint"
  echo "    vault            $TVAULT"
  echo "    agusd            $TAGUSD"
  echo "    set_agusd        tx $(tx "$TVAULT" set_agusd --admin "$ADMIN" --agusd_token "$TAGUSD")"
  echo "    deposit          tx $(tx "$TVAULT" deposit --from "$ADMIN" --amount "$CLAIM")"
  # The live Vault still has to answer for the entry point itself.
  stellar contract info interface --id "$VAULT" --network $NET 2>/dev/null | grep -q 'fn bump_claim' \
    && ok "the live Vault exposes bump_claim" || bad "the live Vault has no bump_claim"
  refused 306 "and refuses to bump a claim it does not have" \
    "$VAULT" bump_claim --claim_id 999999999
fi
echo "  running against $TWHERE"
CID=$(q0 "$TVAULT" queue_tail)
echo "    request_withdrawal tx $(tx "$TVAULT" request_withdrawal --from "$ADMIN" --amount "$CLAIM")  (claim $CID)"
BEFORE=$(q "$TVAULT" get_claim --claim_id "$CID")
echo "  alice, who does not own this claim and holds no role, pays to keep it alive."
BUMP_TX=$(tx_as $OTHER "$TVAULT" bump_claim --claim_id "$CID")
echo "    bump_claim (alice) tx $BUMP_TX"
if [ -n "$BUMP_TX" ]; then ok "an unprivileged key bumped a stranger's claim, submitted and signed by her"; else bad "bump_claim was not submitted"; fi
assert_eq "and the claim is untouched by it" "$(q "$TVAULT" get_claim --claim_id "$CID")" "$BEFORE"
refused 306 "a claim that does not exist cannot be bumped" \
  "$TVAULT" bump_claim --claim_id 999999999
echo "    claim_withdrawal tx $(tx "$TVAULT" claim_withdrawal --from "$ADMIN" --claim_id "$CID")"
assert_eq "the claim was paid normally afterwards" "$(q "$TVAULT" get_claim --claim_id "$CID" | python3 -c 'import sys,json;print(str(json.load(sys.stdin)["claimed"]).lower())')" true
fi

# ---------------------------------------------------------------------------
if stage caps; then
echo ""
echo "== M1, PART A: the exploit, against the superseded contracts =="
echo "-- Still live on the ledger and still holding the bug. A concentration cap"
echo "-- is measured on live exposure, and write_down sets live exposure to zero"
echo "-- while the adapter goes on holding every dollar, so the same pool can be"
echo "-- filled to its cap again and again. Every transaction below is submitted."
assert_eq "the superseded Engine governs the superseded Vault, so the pair matches" \
  "$(q "$OLD_ENGINE" vault)" "$OLD_VAULT"

# Its own pool, deliberately, so the demonstration stays off the live book. The
# cap is set narrow so that it is the cap that refuses and not the floor: a
# 3000 bps pool against a 2500 bps floor leaves the floor 7500 bps of room.
EX_CAP=3000
EXPLOIT_POOL=$(stellar contract deploy --wasm target/wasm32v1-none/release/private_credit.wasm \
  --source $SRC --network $NET -- --admin "$ADMIN" --engine "$OLD_ENGINE" --vault "$OLD_VAULT" \
  --usdc "$USDC" 2>&1 | grep -oE 'C[A-Z2-7]{55}' | tail -1)
echo "  exploit pool      $EXPLOIT_POOL"
echo "    set_caps         tx $(tx "$OLD_ENGINE" set_caps --admin "$ADMIN" --pool_cap_bps $EX_CAP --originator_cap_bps $BPS --jurisdiction_cap_bps $BPS)"
# The superseded pair carries the fix to the first Critical finding, so its
# floor is a share of a base that includes every loss those contracts have ever
# recognised, and they are carrying 1.6 USDC of them from an earlier smoke run
# against a balance of nothing. That floor would refuse every allocation below
# and the demonstration would prove the wrong thing, so it is opened on the two
# retired contracts and the concentration cap is left as the only limit. A
# refusal here is then the cap or it is nothing.
echo "    open the floor   tx $(tx "$OLD_ENGINE" set_reserve_floor --admin "$ADMIN" --floor_bps 0)"
echo "    open it in the Vault too, which enforces its own copy"
echo "                     tx $(tx "$OLD_VAULT" set_reserve_floor --admin "$ADMIN" --floor_bps 0)"
echo "    register_pool    tx $(tx "$OLD_ENGINE" register_pool --admin "$ADMIN" --pool_id "$EXPLOIT_POOL" --originator DEMO --jurisdiction XX --cap_bps $EX_CAP)"
# The superseded Vault may still be carrying deployed capital from an earlier
# run, and a cap of 30% of total assets is only reachable if free reserves
# cover it, so the deposit is sized rather than fixed. Anything less and the
# refusal below would be InsufficientReserves rather than the cap.
O_NEED=$(python3 - "$(q0 "$OLD_VAULT" free_reserves)" "$(q0 "$OLD_VAULT" deployed_capital)" "$EX_CAP" <<'SIZE'
import sys
free, dep, cap = (int(x) for x in sys.argv[1:])
x = 0
while x < 500_000_000 and (free + dep + x) * cap // 10_000 > free + x:
    x += 2_000_000
print(x)
SIZE
)
if [ "${O_NEED:-0}" -gt 0 ]; then
  echo "    deposit $O_NEED  tx $(tx "$OLD_VAULT" deposit --from "$ADMIN" --amount "$O_NEED")"
else
  echo "    the superseded Vault is already holding enough to deploy from"
fi

O_FREE=$(q0 "$OLD_VAULT" free_reserves)
O_DEP=$(q0 "$OLD_VAULT" deployed_capital)
O_TOTAL=$((O_FREE + O_DEP))
O_BOOK=$O_TOTAL
O_CAP=$((O_TOTAL * EX_CAP / BPS))
echo "  superseded book: $O_TOTAL total assets, so a $EX_CAP bps pool cap is $O_CAP"
echo "    allocate $O_CAP  tx $(tx "$OLD_ENGINE" allocate --admin "$ADMIN" --pool_id "$EXPLOIT_POOL" --amount "$O_CAP")"
refused 407 "the pool is full: one more stroop is refused by the cap" \
  "$OLD_ENGINE" allocate --admin "$ADMIN" --pool_id "$EXPLOIT_POOL" --amount 1

echo "  now write the whole position off. No cash moves anywhere."
echo "    write_down       tx $(tx "$OLD_ENGINE" write_down --admin "$ADMIN" --pool_id "$EXPLOIT_POOL" --amount "$O_CAP" --reason DEFAULT)"
assert_eq "the adapter is still holding every dollar of it" "$(q "$USDC" balance --id "$EXPLOIT_POOL")" "$O_CAP"
assert_eq "and the Engine reads its exposure as nothing at all" "$(q "$OLD_ENGINE" get_exposure --pool_id "$EXPLOIT_POOL")" 0

O_TOTAL2=$((O_TOTAL - O_CAP))
O_CAP2=$((O_TOTAL2 * EX_CAP / BPS))
echo "  the cap reads as satisfied, so the same pool can be filled again."
O_TX=$(tx "$OLD_ENGINE" allocate --admin "$ADMIN" --pool_id "$EXPLOIT_POOL" --amount "$O_CAP2")
echo "    allocate $O_CAP2   tx $O_TX  <-- SUBMITTED, and it should not have been"
assert_gt "the pool now holds more than its cap of the book it was capped against" \
  "$(q "$USDC" balance --id "$EXPLOIT_POOL")" "$((O_BOOK * EX_CAP / BPS))"
echo "  Repeating the loop takes the rest. Every call individually inside the cap,"
echo "  and the real concentration behind one originator bounded by nothing."

# ---------------------------------------------------------------------------
echo ""
echo "== M1, PART B: the same sequence against the fixed contracts =="
# Size the deposit so that the pool cap is what binds rather than the floor,
# whatever the book is already carrying. Depositing X raises free reserves and
# the floor's base by X, so it raises the floor's headroom by 0.75X and the
# cap's by 0.4X, and there is always an X that puts the cap underneath.
N_CHARGED0=$(q0 "$ENGINE" charged_exposure --pool_id "$PC")
NEED=$(python3 - "$(q0 "$VAULT" free_reserves)" "$(q0 "$VAULT" deployed_capital)" \
  "$(q0 "$VAULT" floor_base)" "$N_CHARGED0" "$FLOOR" "$POOL_CAP" <<'PY'
import sys
free, dep, base, charged, floor, cap = (int(x) for x in sys.argv[1:])
BPS = 10000
# The pool cap has to bind before the floor does, or the refusal after the
# write-down is the floor wearing the cap's name. On a book carrying no losses
# that is automatic, because 40% of the assets is less than the 75% the floor
# releases; on a book that has already recognised losses the floor's base is
# larger than its free reserves and its headroom can be anything, including
# nothing, so the deposit is sized until the cap is underneath again.
def room(x):    return (free + x) - (base + x) * floor // BPS
def poolmax(x): return (free + dep + x) * cap // BPS - charged
x = 0
while x < 500_000_000 and (poolmax(x) >= room(x) or poolmax(x) < 500_000):
    x += 1_000_000
print(x)
PY
)
if [ "${NEED:-0}" -gt 0 ]; then
  echo "    deposit $NEED   tx $(tx "$VAULT" deposit --from "$ADMIN" --amount "$NEED")"
fi
N_FREE=$(q0 "$VAULT" free_reserves)
N_DEP=$(q0 "$VAULT" deployed_capital)
N_BASE=$(q0 "$VAULT" floor_base)
N_TOTAL=$((N_FREE + N_DEP))
N_CHARGED=$(q0 "$ENGINE" charged_exposure --pool_id "$PC")
LEG=$((N_TOTAL * POOL_CAP / BPS - N_CHARGED))
echo "  book: $N_TOTAL total assets, base $N_BASE, pc charged $N_CHARGED, so the pool cap allows $LEG more"
PC_HELD0=$(q0 "$USDC" balance --id "$PC")
N_WOP0=$(q0 "$ENGINE" written_off_pool --pool_id "$PC")
echo "    allocate $LEG    tx $(tx "$ENGINE" allocate --admin "$ADMIN" --pool_id "$PC" --amount "$LEG")"
refused 407 "the pool is full: one more stroop is refused by the cap" \
  "$ENGINE" allocate --admin "$ADMIN" --pool_id "$PC" --amount 1
assert_eq "charged exposure equals live exposure while nothing is written off" \
  "$(q "$ENGINE" charged_exposure --pool_id "$PC")" "$(q "$ENGINE" get_exposure --pool_id "$PC")"

echo "  write the position off. Same call, same absence of cash movement."
echo "    write_down       tx $(tx "$ENGINE" write_down --admin "$ADMIN" --pool_id "$PC" --amount "$LEG" --reason DEFAULT)"
assert_eq "the adapter is still holding it, exactly as on the old stack" \
  "$(q "$USDC" balance --id "$PC")" "$((PC_HELD0 + LEG))"
assert_eq "live exposure has gone to nothing, exactly as on the old stack" \
  "$(q "$ENGINE" get_exposure --pool_id "$PC")" 0
assert_eq "but the charge against the cap has not moved" \
  "$(q "$ENGINE" charged_exposure --pool_id "$PC")" "$((N_CHARGED + LEG))"
assert_eq "written_off_pool carries it" "$(q "$ENGINE" written_off_pool --pool_id "$PC")" "$((N_WOP0 + LEG))"

refused 407 "and the allocation the superseded Engine just submitted is refused" \
  "$ENGINE" allocate --admin "$ADMIN" --pool_id "$PC" --amount "$(( (N_TOTAL - LEG) * POOL_CAP / BPS ))"
refused 407 "so is a single stroop into the same pool" \
  "$ENGINE" allocate --admin "$ADMIN" --pool_id "$PC" --amount 1
echo "  The originator and the jurisdiction sums are built from the same per-pool"
echo "  numbers, so they carry the charge too."
fi

# ---------------------------------------------------------------------------
if stage stranded; then
echo ""
echo "== M2: capital written off has a way out of the adapter =="
echo "-- deallocate is capped at booked exposure and a written-off position has"
echo "-- none, so this cash used to be unreachable, and because an adapter"
echo "-- holding USDC cannot be repointed it also bricked the repair path."
STUCK=$(q0 "$USDC" balance --id "$PC")
if [ "${STUCK:-0}" = "0" ]; then
  echo "  nothing stranded in the private credit adapter, so this stage needs the caps stage first"
else
assert_eq "the adapter's booked exposure is nothing" "$(q "$PC" get_exposure)" 0
assert_gt "and it is holding USDC anyway" "$STUCK" 0
refused 412 "deallocate cannot reach it: it is capped at an exposure of zero" \
  "$ENGINE" deallocate --pool_id "$PC" --amount "$STUCK"
refused 605 "and set_counterparties will not repoint an adapter holding cash" \
  "$PC" set_counterparties --admin "$ADMIN" --engine "$ENGINE" --vault "$VAULT"
refused_as $OTHER 610 "an unprivileged caller cannot sweep it either" \
  "$PC" recover_surplus --caller "$OTHER_ADDR"

V_IDLE0=$(q0 "$VAULT" idle_reserves)
V_LOSS0=$(q0 "$VAULT" recognised_losses)
V_BASE0=$(q0 "$VAULT" floor_base)
A_USDC0=$(q0 "$USDC" balance --id "$ADMIN")
E_OFF0=$(q0 "$ENGINE" written_off)
echo "    recover          tx $(tx "$ENGINE" recover --admin "$ADMIN" --pool_id "$PC")"
assert_eq "the adapter is empty" "$(q "$USDC" balance --id "$PC")" 0
assert_eq "the Vault has the cash, and it went there because it is not a parameter" \
  "$(q "$VAULT" idle_reserves)" "$((V_IDLE0 + STUCK))"
assert_eq "the admin's own balance did not move: there is no path out to a caller" \
  "$(q "$USDC" balance --id "$ADMIN")" "$A_USDC0"
# A recovery larger than the loss on the books is surplus over principal,
# which was never written off; it books as reserves and lifts the base. The
# assertions carry that case so the run does not depend on the two matching.
APPLIED=$(( V_LOSS0 < STUCK ? V_LOSS0 : STUCK ))
assert_eq "the recognised loss is released by the cash that arrived" \
  "$(q "$VAULT" recognised_losses)" "$((V_LOSS0 - APPLIED))"
assert_eq "and so is the Engine's" "$(q "$ENGINE" written_off)" "$((E_OFF0 - APPLIED))"
assert_eq "floor_base moves only by surplus over the loss, never down" \
  "$(q "$VAULT" floor_base)" "$((V_BASE0 + STUCK - APPLIED))"
assert_eq "the pool's cap charge is released with it" \
  "$(q "$ENGINE" charged_exposure --pool_id "$PC")" "$(q "$ENGINE" get_exposure --pool_id "$PC")"
echo "  and the repair path the stranded cash was blocking works again."
echo "    set_counterparties tx $(tx "$PC" set_counterparties --admin "$ADMIN" --engine "$ENGINE" --vault "$VAULT")  (repointed at the same pair, which is a no-op that could not be performed a moment ago)"
assert_eq "the adapter still names this Engine" "$(q "$PC" engine)" "$ENGINE"
assert_eq "and this Vault" "$(q "$PC" vault)" "$VAULT"
refused 611 "with nothing left above the exposure, recover_surplus refuses" \
  "$PC" recover_surplus --caller "$ADMIN"
fi
fi

# ---------------------------------------------------------------------------
if stage rotation; then
echo ""
echo "== M4: a half finished admin rotation is loud, not silent =="
echo "-- write_down needs one signature that satisfies the Engine and the Vault,"
echo "-- and the two roles rotate independently. Every rotation below is a"
echo "-- submitted transaction signed by the key taking or giving up the role."
assert_eq "the two admins agree to start with" "$(q "$ENGINE" admin_aligned)" true
assert_eq "and the Engine reports the Vault's admin" "$(q "$ENGINE" vault_admin)" "$ADMIN"

echo "  hand the Engine's admin to alice, and leave the Vault's where it is."
echo "    propose_admin    tx $(tx "$ENGINE" propose_admin --admin "$ADMIN" --new_admin "$OTHER_ADDR")"
echo "    accept_admin     tx $(tx_as $OTHER "$ENGINE" accept_admin --new_admin "$OTHER_ADDR")  (signed by alice, which is the whole point of the second step)"
assert_eq "the Engine's admin is alice now" "$(q "$ENGINE" admin)" "$OTHER_ADDR"
assert_eq "and the divergence is readable in one call, before any incident" \
  "$(q "$ENGINE" admin_aligned)" false
refused_as $OTHER 418 "write_down refuses with a named AdminMismatch" \
  "$ENGINE" write_down --admin "$OTHER_ADDR" --pool_id "$PC" --amount 1 --reason DEFAULT
refused_as $OTHER 418 "and so does recover, for the same reason" \
  "$ENGINE" recover --admin "$OTHER_ADDR" --pool_id "$PC"
refused 402 "the Vault's admin is not the Engine's admin any more either" \
  "$ENGINE" write_down --admin "$ADMIN" --pool_id "$PC" --amount 1 --reason DEFAULT

echo "  give it back, the same way round."
echo "    propose_admin    tx $(tx_as $OTHER "$ENGINE" propose_admin --admin "$OTHER_ADDR" --new_admin "$ADMIN")"
echo "    accept_admin     tx $(tx "$ENGINE" accept_admin --new_admin "$ADMIN")"
assert_eq "the Engine's admin is back" "$(q "$ENGINE" admin)" "$ADMIN"
assert_eq "and the two agree again" "$(q "$ENGINE" admin_aligned)" true
fi

# ---------------------------------------------------------------------------
if stage wiring; then
echo ""
echo "== M5: the wiring runs inside the deploy and checks what it is given =="
for pair in "vault:$VAULT" "engine:$ENGINE" "agusd:$AGUSD" "private-credit:$PC" "etherfuse:$EF"; do
  name=${pair%%:*}; id=${pair#*:}
  IFACE=$(stellar contract info interface --id "$id" --network $NET 2>/dev/null)
  echo "$IFACE" | grep -q 'fn initialize' \
    && bad "$name still exposes initialize" \
    || ok "$name exposes no initialize: there is no window between deploy and wiring"
done
IFACE=$(stellar contract info interface --id "$OLD_ENGINE" --network $NET 2>/dev/null)
echo "$IFACE" | grep -q 'fn initialize' \
  && ok "the superseded Engine does expose one, which is what was closed" \
  || bad "the superseded Engine has no initialize either, so this proves nothing"

echo "  and the constructor runs the check the repair path runs."
# An ordinary account is refused, and it is worth being precise about how. The
# host will not invoke a non-contract address at all, so the call fails with
# InvalidInput before try_admin has a contract error to catch. The guard holds;
# the refusal is simply not the named one, and no amount of try_ makes it so.
OUT=$(stellar contract deploy --wasm target/wasm32v1-none/release/allocation_engine.wasm \
  --source $SRC --network $NET -- --admin "$ADMIN" --vault "$ADMIN" 2>&1)
echo "$OUT" | grep -q "not a contract address" \
  && ok "an Engine cannot be deployed against an ordinary account as its Vault (the host refuses to invoke it)" \
  || bad "deploying against an account gave: $(echo "$OUT" | tail -2 | tr '\n' ' ')"
# A real contract that answers admin() with somebody else is the case the named
# error is for. The USDC Stellar Asset Contract answers with its issuer.
refused 419 "and a contract answering with a different admin is refused by name" \
  "$ENGINE" set_vault --admin "$ADMIN" --vault "$USDC"
refused 312 "the agUSD pointer is shut for good once the Vault has taken a deposit" \
  "$VAULT" set_agusd --admin "$ADMIN" --agusd_token "$USDC"

# The minter check cannot be shown on this Vault, which has deposits and refuses
# earlier and for a stronger reason, so it is shown on a Vault that has none.
# It costs a deploy and no USDC, and it is the check that would have caught the
# very first Vault this protocol lost.
echo "  a throwaway Vault, to show the checks that only a fresh one can reach."
FRESH=$(stellar contract deploy --wasm target/wasm32v1-none/release/vault.wasm \
  --source $SRC --network $NET -- --admin "$ADMIN" --usdc_token "$USDC" 2>&1 | grep -oE 'C[A-Z2-7]{55}' | tail -1)
echo "    fresh vault      $FRESH"
refused 324 "it refuses an agUSD that does not name it as minter" \
  "$FRESH" set_agusd --admin "$ADMIN" --agusd_token "$AGUSD"
refused 301 "and with no Engine it releases nothing, because set_engine is the only door" \
  "$FRESH" settle_allocation --pool "$PC" --amount 1
assert_eq "a Vault ships with no Engine at all" "$(stellar contract invoke --id "$FRESH" --source $SRC --network $NET --send=no -- allocation_engine 2>&1 | grep -oE '#3[0-9]+' | head -1)" "#301"
refused 606 "and an adapter refuses an Engine that does not govern the Vault offered" \
  "$PC" set_counterparties --admin "$ADMIN" --engine "$ENGINE" --vault "$ADMIN"
# The whole justification for redeploying seven contracts rather than rewiring
# them is that their bytecode no longer matched the repository. That claim is
# checkable, so it is checked: the code on the ledger is fetched back and
# compared with what this tree builds.
echo "  the deployed bytecode against the source it is supposed to be."
for pair in "vault:$VAULT:vault.wasm" "agusd:$AGUSD:agusd_core.wasm" \
            "engine:$ENGINE:allocation_engine.wasm" "private-credit:$PC:private_credit.wasm" \
            "etherfuse:$EF:etherfuse.wasm"; do
  name=${pair%%:*}; rest=${pair#*:}; id=${rest%%:*}; wasm=${rest#*:}
  stellar contract fetch --id "$id" --network $NET --out-file /tmp/agama-onchain.wasm >/dev/null 2>&1
  on=$(shasum -a 256 /tmp/agama-onchain.wasm 2>/dev/null | cut -d' ' -f1)
  loc=$(shasum -a 256 "target/wasm32v1-none/release/$wasm" 2>/dev/null | cut -d' ' -f1)
  if [ -n "$on" ] && [ "$on" = "$loc" ]; then
    ok "$name on the ledger is byte for byte what this tree builds"
  else
    bad "$name differs: ledger ${on:0:16} against local ${loc:0:16}"
  fi
done

assert_eq "the deployed Engine names the Vault" "$(q "$ENGINE" vault)" "$VAULT"
assert_eq "the deployed Vault names the Engine" "$(q "$VAULT" allocation_engine)" "$ENGINE"
assert_eq "the deployed agUSD names the Vault as its minter" "$(q "$AGUSD" minter)" "$VAULT"
fi

# ---------------------------------------------------------------------------
echo ""
echo "== housekeeping, so the run is repeatable =="
OUT=$(q0 "$ENGINE" get_exposure --pool_id "$PC")
[ "${OUT:-0}" != "0" ] && echo "    deallocate pc    tx $(tx "$ENGINE" deallocate --pool_id "$PC" --amount "$OUT")"
OUT=$(q0 "$ENGINE" get_exposure --pool_id "$EF")
[ "${OUT:-0}" != "0" ] && echo "    deallocate ef    tx $(tx "$ENGINE" deallocate --pool_id "$EF" --amount "$OUT")"
HELD=$(q0 "$AGUSD" balance --id "$ADMIN")
if [ "${HELD:-0}" -ge "$CLAIM" ]; then
  SHORT=$(( HELD - $(q0 "$VAULT" idle_reserves) ))
  [ "$SHORT" -gt 0 ] && echo "    operator tops up tx $(tx "$USDC" transfer --from "$ADMIN" --to "$VAULT" --amount "$SHORT")  ($SHORT, whatever is still written off)"
  CID=$(q0 "$VAULT" queue_tail)
  echo "    redeem $HELD  tx $(tx "$VAULT" request_withdrawal --from "$ADMIN" --amount "$HELD")"
  echo "    claim            tx $(tx "$VAULT" claim_withdrawal --from "$ADMIN" --claim_id "$CID")"
fi

echo ""
echo "== state left behind =="
echo "  vault idle          $(q "$VAULT" idle_reserves)"
echo "  vault deployed      $(q "$VAULT" deployed_capital)"
echo "  vault liabilities   $(q "$VAULT" outstanding_liabilities)"
echo "  vault losses        $(q "$VAULT" recognised_losses)"
echo "  vault floor_base    $(q "$VAULT" floor_base)"
echo "  agusd supply        $(q "$AGUSD" total_supply)"
echo "  engine allocated    $(q "$ENGINE" total_allocated)"
echo "  engine written_off  $(q "$ENGINE" written_off)"
echo "  engine ratio        $(q "$ENGINE" get_reserve_ratio)"
echo "  pc charged          $(q "$ENGINE" charged_exposure --pool_id "$PC")"
echo "  pc adapter balance  $(q "$USDC" balance --id "$PC")"
echo "  admins aligned      $(q "$ENGINE" admin_aligned)"

echo ""
echo "== $PASS passed, $FAIL failed =="
[ "$FAIL" -eq 0 ]
