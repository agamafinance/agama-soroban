#!/usr/bin/env bash
# On-chain smoke test for the fixes from the adversarial security review.
#
# Everything here runs against the LIVE testnet deployment recorded in
# deployments/testnet.json, with the real Circle USDC, and every state change is
# a submitted transaction whose hash is echoed.
#
# Where a fix is a refusal, the refusal is shown by simulation and the contract
# error code is asserted, because the CLI will not submit a transaction whose
# simulation fails. That is sound for a refusal, which is contract logic, and it
# is not sound for authorization, which simulation records rather than enforces.
# So every authorization property here is proved with a submitted transaction
# signed by the key under test: `alice` settles a withdrawal she does not own
# and accepts the admin role with her own signature, and neither of those would
# work if the enforcement were not real.
#
# Covers, with assertions:
#   staking  : report_nav is gone from the deployed interface
#   vault    : the Vault enforces the reserve floor itself, against its own
#              deployed capital book, with the Engine's own floor wide open
#   vault    : a queued withdrawal is subtracted from free reserves and from
#              net assets, so it cannot be deployed
#   vault    : a third party settles the head claim and the recorded owner is
#              paid, which is what unfreezes a stalled queue
#   vault    : the circuit breaker blocks deposits and requests, and pays out
#   engine   : a credit loss is written down across three books at once
#   engine   : an adapter that names a different Engine and Vault is refused
#   oracle   : the band and the minimum interval are enforced
#   all      : the admin role moves in two steps, the second one signed by the
#              address it moves to
#
# Usage: bash scripts/smoke-hardening.sh
set -uo pipefail
cd "$(dirname "$0")/.."

NET=testnet
SRC=agama-poc
# A second, unprivileged identity. It owns no claim and holds no role, which is
# the entire point of using it.
OTHER=alice
DEP=deployments/testnet.json

j() { python3 -c "import json;d=json.load(open('$DEP'));print($1)"; }
USDC=$(j "d['contracts']['usdc']")
VAULT=$(j "d['contracts']['vault']")
ENGINE=$(j "d['contracts']['allocationEngine']")
ORACLE=$(j "d['contracts']['oracleAdapter']")
AGUSD=$(j "d['contracts']['agusdCore']")
STAKING=$(j "d['contracts']['staking']")
PC=$(j "d['poolAdapters']['private-credit']")
EF=$(j "d['poolAdapters']['etherfuse']")
POOL_CAP=$(j "d['engineConfig']['poolCapBps']")
ORIG_CAP=$(j "d['engineConfig']['originatorCapBps']")
JUR_CAP=$(j "d['engineConfig']['jurisdictionCapBps']")
FLOOR=$(j "d['engineConfig']['reserveFloorBps']")
# A superseded adapter: it names an Engine and a Vault from an earlier
# generation, which is exactly the wiring register_pool now has to refuse.
STALE_ADAPTER=$(j "[e['address'] for e in d['superseded'] if e['contract']=='poolAdapters.private-credit'][-1]")
ADMIN=$(stellar keys address $SRC)
OTHER_ADDR=$(stellar keys address $OTHER)

CLAIM_AMOUNT=10000000 # 1 agUSD, the Vault's anti-dust minimum
WRITE_OFF=1000000     # 0.1 USDC recognised as a loss

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  PASS  $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL  $1"; }
num() { echo "$1" | tr -d '"'; }
assert_eq() { if [ "$(num "$2")" = "$3" ]; then ok "$1 ($2)"; else bad "$1: got $2, want $3"; fi; }

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
# State changing, signed by the unprivileged identity.
tx_other() { stellar contract invoke --id "$1" --source $OTHER --network $NET -- "${@:2}" 2>&1 \
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

# Every quantity below is a delta against the state this script found, so it can
# be run against a Vault that is already holding something.
q0() { stellar contract invoke --id "$1" --source $SRC --network $NET --send=no -- "${@:2}" 2>/dev/null | tr -d '"'; }

echo "== deployment under test =="
echo "  vault             $VAULT"
echo "  allocation-engine $ENGINE"
echo "  oracle-adapter    $ORACLE"
echo "  agusd             $AGUSD"
echo "  staking (sagUSD)  $STAKING"
echo "  private-credit    $PC"
echo "  etherfuse         $EF"
echo "  admin             $ADMIN"
echo "  unprivileged      $OTHER_ADDR ($OTHER)"


# Every suite here assumes a book roughly at rest and none of them establishes
# one, so the first in a run gets what it expects and the rest get whatever the
# previous one left. Established once, here, rather than tolerated assertion by
# assertion. See lib-baseline.sh.
# shellcheck source=lib-baseline.sh
. "$(dirname "$0")/lib-baseline.sh"
normalise_book "$VAULT" "$ENGINE" "$USDC" "$SRC" "$NET" "$ADMIN"
echo ""
echo "== FINDING 1: report_nav is gone from the staking contract =="
IFACE=$(stellar contract info interface --id "$STAKING" --network $NET 2>/dev/null)
if echo "$IFACE" | grep -q 'fn report_nav'; then
  bad "report_nav is still on the deployed interface"
else
  ok "report_nav is absent from the deployed interface"
fi
echo "$IFACE" | grep -q 'fn distribute_yield' && ok "distribute_yield is there, the path that moves real agUSD" \
  || bad "distribute_yield is missing"
echo "$IFACE" | grep -q 'fn exchange_rate' && ok "exchange_rate is there" || bad "exchange_rate is missing"

# What the Vault holds and cannot explain, before this script touches anything.
# Carried to the end, where the only thing asserted is that it did not grow.
UNACCOUNTED_BEFORE=$(( $(num "$(q "$VAULT" idle_reserves)") - $(num "$(q "$VAULT" booked_reserves)") ))
echo "  vault unaccounted cash at start  $UNACCOUNTED_BEFORE"

echo ""
echo "== VAULT: deposit, and the numbers the limits are measured on =="
WALLET=$(q0 "$USDC" balance --id "$ADMIN")
# Deposit everything the admin has, in whole tenths of a USDC, so the working
# capital is whatever the account actually holds rather than a hardcoded number
# that goes stale the first time a run costs something.
DEPOSIT=$(( WALLET / 1000000 * 1000000 ))
if [ "$DEPOSIT" -lt $((3 * CLAIM_AMOUNT)) ]; then
  # Short here is usually the value sitting in the Vault as this account's own
  # agUSD from an earlier suite, rather than an empty account. Settle what the
  # queue owes and redeem the shortfall before deciding a top-up is needed.
  # shellcheck source=lib-ensure-usdc.sh
  . "$(dirname "$0")/lib-ensure-usdc.sh"
  ensure_usdc "$VAULT" "$USDC" "$AGUSD" "$((3 * CLAIM_AMOUNT))" "$SRC" "$NET" "$ADMIN" || true
  WALLET=$(q0 "$USDC" balance --id "$ADMIN")
  DEPOSIT=$(( WALLET / 1000000 * 1000000 ))
fi
if [ "$DEPOSIT" -lt $((3 * CLAIM_AMOUNT)) ]; then
  echo "  the admin holds $WALLET USDC (7dp), which is not enough to run this."
  echo "  it needs at least $((3 * CLAIM_AMOUNT)); top the account up and re-run."
  exit 1
fi
# Read after the top-up and not before it. Reaching the balance can mean
# redeeming agUSD, which burns supply and moves the Vault's idle reserves, so a
# snapshot taken first is stale by exactly what it took to get here and every
# assertion below is off by that amount.
IDLE0=$(q0 "$VAULT" idle_reserves)
LIAB0=$(q0 "$VAULT" outstanding_liabilities)
AG0=$(q0 "$AGUSD" balance --id "$ADMIN")
# What is already out at a pool, read rather than assumed to be nothing. An
# earlier suite can leave an allocation standing, and a deposit does not change
# it, so asserting zero here fails on a book that is merely in use rather than
# on a book that is wrong.
DEP0=$(q0 "$VAULT" deployed_capital)
echo "  deposit $DEPOSIT  tx $(tx "$VAULT" deposit --from "$ADMIN" --amount "$DEPOSIT")"
assert_eq "agUSD minted one for one" "$(q "$AGUSD" balance --id "$ADMIN")" "$((AG0 + DEPOSIT))"
assert_eq "idle reserves rose by the deposit" "$(q "$VAULT" idle_reserves)" "$((IDLE0 + DEPOSIT))"
assert_eq "free reserves are idle less what is owed" "$(q "$VAULT" free_reserves)" "$((IDLE0 + DEPOSIT - LIAB0))"
assert_eq "a deposit leaves deployed capital where it was" "$(q "$VAULT" deployed_capital)" "$DEP0"

echo ""
echo "== FINDING 3: a queued withdrawal is not free liquidity =="
IDLE=$(q0 "$VAULT" idle_reserves)
CLAIM=$(num "$(q "$VAULT" queue_tail)")
echo "  request_withdrawal $CLAIM_AMOUNT, claim $CLAIM  tx $(tx "$VAULT" request_withdrawal --from "$ADMIN" --amount "$CLAIM_AMOUNT")"
LIAB=$((LIAB0 + CLAIM_AMOUNT))
FREE=$((IDLE - LIAB))
assert_eq "the gross balance has not moved" "$(q "$VAULT" idle_reserves)" "$IDLE"
assert_eq "the liability is on the books" "$(q "$VAULT" outstanding_liabilities)" "$LIAB"
assert_eq "free reserves are net of it" "$(q "$VAULT" free_reserves)" "$FREE"
# Both include whatever is out at a pool, which is not necessarily nothing.
assert_eq "gross assets still count it" "$(q "$VAULT" get_total_assets)" "$((IDLE + DEP0))"
assert_eq "net assets do not" "$(q "$VAULT" get_net_assets)" "$((FREE + DEP0))"
refused 411 "the Engine cannot deploy the money already owed" \
  "$ENGINE" allocate --admin "$ADMIN" --pool_id "$PC" --amount "$IDLE"

echo ""
echo "== FINDING 2: the Vault enforces the floor itself, not the Engine =="
# Open the Engine as wide as it goes: every cap at 100%, the floor at zero.
# Whatever stops an allocation from here on is the Vault, and nothing else.
echo "  engine caps to 100%   tx $(tx "$ENGINE" set_caps --admin "$ADMIN" --pool_cap_bps 10000 --originator_cap_bps 10000 --jurisdiction_cap_bps 10000)"
echo "  engine floor to 0     tx $(tx "$ENGINE" set_reserve_floor --admin "$ADMIN" --floor_bps 0)"
assert_eq "the Engine is now unconstrained" "$(q "$ENGINE" reserve_floor_bps)" "0"
assert_eq "the Vault is not" "$(q "$VAULT" reserve_floor_bps)" "$FLOOR"

# The Vault's floor is a share of net assets, and net assets are invariant under
# an allocation, so the most that can leave is (10000 - floor) / 10000 of them.
# It takes both pools to get there: each adapter was registered with a 40% cap
# of its own, and a pool's own cap is never loosened by the global one.
# Measured on what the Vault can account for and on the base the floor is a
# share of, which is what settle_allocation checks. Against the raw balance the
# legs overshoot by whatever reached the Vault unannounced and the Vault's own
# floor refuses them, which reads as the floor misbehaving and is the script
# asking for more than the books allow. Each pool's leg is also its cap less
# what it already carries, and a written-down pool carries its loss for good.
H_ACC=$(q0 "$VAULT" accounted_free_reserves)
H_BASE2=$(q0 "$VAULT" floor_base)
H_DEP=$(q0 "$VAULT" deployed_capital)
H_ASSETS=$((H_ACC + H_DEP))
# What the floor keeps, rounded up. The contract asks that free reserves times
# 10000 be at least floor_bps times the base, so when the quarter is not whole
# the integer division here keeps one stroop too few and the leg computed from
# it is one stroop too many. The Vault then refuses, correctly, and it reads as
# the floor misbehaving.
H_KEEP=$(( (H_BASE2 * FLOOR + 9999) / 10000 ))
MAX=$(( H_ACC - H_KEEP ))
[ "$MAX" -lt 0 ] && MAX=0
PC_LEG=$(( H_ASSETS * POOL_CAP / 10000 - $(q0 "$ENGINE" charged_exposure --pool_id "$PC") ))
[ "$PC_LEG" -lt 0 ] && PC_LEG=0
[ "$PC_LEG" -gt "$MAX" ] && PC_LEG=$MAX
EF_ROOM2=$(( H_ASSETS * POOL_CAP / 10000 - $(q0 "$ENGINE" charged_exposure --pool_id "$EF") ))
[ "$EF_ROOM2" -lt 0 ] && EF_ROOM2=0
EF_LEG=$((MAX - PC_LEG))
[ "$EF_LEG" -gt "$EF_ROOM2" ] && EF_LEG=$EF_ROOM2
echo "  the floor releases $MAX of $H_ACC accounted, split $PC_LEG / $EF_LEG across the caps"
echo "  allocate $PC_LEG to private credit  tx $(tx "$ENGINE" allocate --admin "$ADMIN" --pool_id "$PC" --amount "$PC_LEG")"
if [ "$((PC_LEG + EF_LEG))" = "$MAX" ]; then
  refused 316 "one stroop past the Vault's floor is refused by the Vault" \
    "$ENGINE" allocate --admin "$ADMIN" --pool_id "$EF" --amount "$((EF_LEG + 1))"
else
  echo "  SKIP  the caps stop short of what the floor releases by $((MAX - PC_LEG - EF_LEG)),"
  echo "        so a stroop past the floor is refused by a cap and says nothing"
  echo "        about the Vault's own check"
fi
echo "  allocate $EF_LEG to etherfuse  tx $(tx "$ENGINE" allocate --admin "$ADMIN" --pool_id "$EF" --amount "$EF_LEG")"
assert_eq "the Vault booked what it released" "$(q "$VAULT" deployed_capital)" "$((H_DEP + PC_LEG + EF_LEG))"
assert_eq "accounted free reserves fell by exactly that" \
  "$(q "$VAULT" accounted_free_reserves)" "$((H_ACC - PC_LEG - EF_LEG))"
assert_eq "the reserve ratio agrees" "$(q "$ENGINE" get_reserve_ratio)" "$FLOOR"
refused 316 "and nothing more leaves, however small" \
  "$ENGINE" allocate --admin "$ADMIN" --pool_id "$EF" --amount 1

echo "  deallocate $PC_LEG    tx $(tx "$ENGINE" deallocate --pool_id "$PC" --amount "$PC_LEG")"
echo "  deallocate $EF_LEG    tx $(tx "$ENGINE" deallocate --pool_id "$EF" --amount "$EF_LEG")"
assert_eq "the Vault's book came down with the cash" "$(q "$VAULT" deployed_capital)" "0"
assert_eq "and the cash is back" "$(q "$VAULT" idle_reserves)" "$IDLE"
echo "  restore engine caps   tx $(tx "$ENGINE" set_caps --admin "$ADMIN" --pool_cap_bps "$POOL_CAP" --originator_cap_bps "$ORIG_CAP" --jurisdiction_cap_bps "$JUR_CAP")"
echo "  restore engine floor  tx $(tx "$ENGINE" set_reserve_floor --admin "$ADMIN" --floor_bps "$FLOOR")"

echo ""
echo "== FINDING 4: a third party settles the head claim, and the owner is paid =="
BEFORE=$(q0 "$USDC" balance --id "$ADMIN")
assert_eq "the head of the queue is the claim we made" "$(q "$VAULT" queue_head)" "$CLAIM"
# Submitted, and signed by alice. She owns no claim and holds no role: if the
# entry point were not genuinely permissionless this transaction would fail,
# and if it let the caller choose the recipient she would have the money.
OWED_BEFORE=$(q0 "$VAULT" outstanding_liabilities)
echo "  settle_withdrawal, signed by $OTHER  tx $(tx_other "$VAULT" settle_withdrawal)"
assert_eq "the recorded owner was paid" "$(q "$USDC" balance --id "$ADMIN")" "$((BEFORE + CLAIM_AMOUNT))"
CLAIM_OWNER=$(q "$VAULT" get_claim --claim_id "$CLAIM" | python3 -c 'import json,sys;print(json.load(sys.stdin)["owner"])')
assert_eq "the claim still records its own owner, not the caller" "$CLAIM_OWNER" "$ADMIN"
assert_eq "the queue advanced" "$(q "$VAULT" queue_head)" "$((CLAIM + 1))"
# Discharged by this claim's amount, not necessarily to zero. A claim whose
# owner cannot be paid in USDC is marked deferred and stays counted, which is
# the queue treating a delay as a delay rather than a forfeit, and an earlier
# suite leaves exactly one of those behind on purpose. So the assertion is the
# movement rather than the total.
assert_eq "and the liability is discharged" "$(q "$VAULT" outstanding_liabilities)" \
  "$((OWED_BEFORE - CLAIM_AMOUNT))"
DEFERRED=$(q0 "$VAULT" outstanding_liabilities)
if [ "${DEFERRED:-0}" = "0" ]; then
  refused 315 "settling an empty queue says so" "$VAULT" settle_withdrawal
else
  echo "  SKIP  $DEFERRED is still owed on a deferred claim, whose owner cannot"
  echo "        receive USDC, so the queue is not empty and cannot say it is"
fi

echo ""
echo "== FINDING 5: a credit loss can be recognised =="
# Measured on accounted free reserves and on what the pool has room for. The
# raw balance overstates both: it counts cash the books cannot explain, which
# the Engine will not deploy, and what the queue still owes on a deferred
# claim, which belongs to somebody. And a pool carrying charge from an earlier
# run has less room than its cap.
IDLE=$(q0 "$VAULT" idle_reserves)
H_FREE=$(q0 "$VAULT" accounted_free_reserves)
H_BASE=$(q0 "$VAULT" floor_base)
H_TOTAL=$(( H_FREE + $(q0 "$VAULT" deployed_capital) ))
H_ROOM=$(( H_FREE - (H_BASE * FLOOR + 9999) / 10000 ))
H_POOL=$(( H_TOTAL * POOL_CAP / 10000 - $(q0 "$ENGINE" charged_exposure --pool_id "$PC") ))
ALLOC=$(( H_ROOM < H_POOL ? H_ROOM : H_POOL ))
[ "$ALLOC" -lt 0 ] && ALLOC=0
if [ "$ALLOC" -lt 1 ]; then
  echo "  neither the floor nor the private credit cap leaves anything to deploy"
  echo "  ($H_ROOM under the floor, $H_POOL under the cap), so this finding cannot"
  echo "  be walked through on this book."
  exit 2
fi
echo "  allocate $ALLOC to private credit  tx $(tx "$ENGINE" allocate --admin "$ADMIN" --pool_id "$PC" --amount "$ALLOC")"
assert_eq "the Engine booked it" "$(q "$ENGINE" get_exposure --pool_id "$PC")" "$ALLOC"
assert_eq "the adapter booked it" "$(q "$PC" get_exposure)" "$ALLOC"
assert_eq "the Vault booked it" "$(q "$VAULT" deployed_capital)" "$ALLOC"

echo "  write_down $WRITE_OFF  tx $(tx "$ENGINE" write_down --admin "$ADMIN" --pool_id "$PC" --amount "$WRITE_OFF" --reason DEFAULT)"
assert_eq "the Engine's exposure fell" "$(q "$ENGINE" get_exposure --pool_id "$PC")" "$((ALLOC - WRITE_OFF))"
assert_eq "the adapter's did too" "$(q "$PC" get_exposure)" "$((ALLOC - WRITE_OFF))"
assert_eq "and so did the Vault's" "$(q "$VAULT" deployed_capital)" "$((ALLOC - WRITE_OFF))"
assert_eq "no cash moved: the loss is a loss" "$(q "$VAULT" idle_reserves)" "$((IDLE - ALLOC))"
refused 415 "more than is booked cannot be written off" \
  "$ENGINE" write_down --admin "$ADMIN" --pool_id "$PC" --amount "$((ALLOC * 10))" --reason DEFAULT

echo "  deallocate the rest    tx $(tx "$ENGINE" deallocate --pool_id "$PC" --amount "$((ALLOC - WRITE_OFF))")"
assert_eq "the recoverable part came back" "$(q "$ENGINE" get_exposure --pool_id "$PC")" "0"
assert_eq "the Vault's deployed book is clear" "$(q "$VAULT" deployed_capital)" "0"

echo ""
echo "== FINDING 6: an adapter that names a different Engine and Vault =="
echo "  candidate: $STALE_ADAPTER (a superseded adapter, still on the ledger)"
refused 414 "registering it is refused" \
  "$ENGINE" register_pool --admin "$ADMIN" --pool_id "$STALE_ADAPTER" \
  --originator QIRO --jurisdiction LU --cap_bps "$POOL_CAP"
assert_eq "the whitelist is unchanged" "$(q "$ENGINE" pools | python3 -c 'import json,sys;print(len(json.load(sys.stdin)))')" "2"

echo ""
echo "== FINDING 6: the oracle's band, and its rate limit =="
TS=$(( $(date +%s) - 120 ))
PC_INTERVAL=$(j "d['oracleFeeds']['PC_NAV']['minIntervalSecs']")
LAST_AT=$(q "$ORACLE" last_update --feed_id PC_NAV 2>/dev/null \
  | python3 -c 'import json,sys;print(json.load(sys.stdin)["recorded_at"])' 2>/dev/null || echo 0)
if [ $(( $(date +%s) - LAST_AT )) -ge "$PC_INTERVAL" ]; then
  echo "  push_nav PC_NAV 1.0    tx $(tx "$ORACLE" push_nav --reporter "$ADMIN" --feed_id PC_NAV --nav 10000000 --timestamp "$TS")"
else
  # A re-run inside the hour hits the feed's own rate limit, which is the guard
  # under test doing exactly what it is for. The last accepted value stands.
  ok "PC_NAV was accepted $(( $(date +%s) - LAST_AT ))s ago, inside its ${PC_INTERVAL}s interval, so a push now is refused"
fi
EXPECT_NAV=$(q "$ORACLE" get_nav --feed_id PC_NAV | tr -d '"')
assert_eq "the Vault reads its feed" "$(q "$VAULT" get_nav | tr -d '"')" "$EXPECT_NAV"
refused 513 "a value outside the band is refused, whatever the deviation" \
  "$ORACLE" push_nav --reporter "$ADMIN" --feed_id PC_NAV --nav 170141183460469231731687303715884105727 --timestamp "$((TS + 1))"
refused 514 "a second value inside the interval is refused" \
  "$ORACLE" push_nav --reporter "$ADMIN" --feed_id PC_NAV --nav 10200000 --timestamp "$((TS + 1))"

echo ""
echo "== FINDING 6: the breaker stops new obligations and pays the old ones =="
CLAIM2=$(num "$(q "$VAULT" queue_tail)")
echo "  request_withdrawal $CLAIM_AMOUNT, claim $CLAIM2  tx $(tx "$VAULT" request_withdrawal --from "$ADMIN" --amount "$CLAIM_AMOUNT")"
echo "  pause                  tx $(tx "$VAULT" set_paused --admin "$ADMIN" --paused true)"
refused 303 "deposits stop" "$VAULT" deposit --from "$ADMIN" --amount "$CLAIM_AMOUNT"
# Which answer is right here depends on which generation of Vault is deployed,
# so ask the contract rather than assume. The generation that answers
# exits_frozen_until has taken withdrawal requests out of this switch: holding
# them shut is freeze_exits, which is bounded at MAX_EXIT_FREEZE_SECS and rate
# limited after that, and the plain breaker no longer reaches them. Asserting
# one of the two unconditionally would make this suite wrong either side of that
# deployment, which is worse than it being longer.
if stellar contract info interface --id "$VAULT" --network "$NET" 2>/dev/null | grep -q "fn exits_frozen_until"; then
  FROZEN=$(num "$(q "$VAULT" exits_frozen_until)")
  assert_eq "exits are not frozen" "$([ "$FROZEN" -le "$(date -u +%s)" ] && echo open || echo shut)" "open"
  CLAIM_P=$(num "$(q "$VAULT" queue_tail)")
  echo "  request while paused, claim $CLAIM_P  tx $(tx "$VAULT" request_withdrawal --from "$ADMIN" --amount "$CLAIM_AMOUNT")"
  assert_eq "a request still queues while the breaker is on" \
    "$(num "$(q "$VAULT" queue_tail)")" "$((CLAIM_P + 1))"
  # A freeze can only be armed once per EXIT_FREEZE_COOLDOWN_SECS, seven days,
  # so this suite cannot arm one on demand and must not fail when it cannot.
  # Both outcomes are the design working: either the freeze goes on and requests
  # stop, or the rate limit refuses it, which is the half that makes the bound
  # mean anything. Asserting only the first would make a correct protocol look
  # broken for a week after any freeze.
  FREEZE_OUT=$(stellar contract invoke --id "$VAULT" --source $SRC --network $NET -- \
    freeze_exits --admin "$ADMIN" 2>&1 || true)
  if echo "$FREEZE_OUT" | grep -q "#329"; then
    echo "  freeze_exits refused with 329, so a freeze was armed inside the last"
    echo "  seven days and the rate limit is holding. That is the guarantee, not a"
    echo "  failure: exits cannot be shut again yet."
    assert_eq "and exits are open while it holds" \
      "$([ "$(num "$(q "$VAULT" exits_frozen_until)")" -le "$(date -u +%s)" ] && echo open || echo shut)" "open"
  else
    echo "  freeze_exits           armed until $(num "$(q "$VAULT" exits_frozen_until)")"
    refused 328 "and now requests stop" "$VAULT" request_withdrawal --from "$ADMIN" --amount "$CLAIM_AMOUNT"
    refused 329 "a second freeze is refused until the cooldown" "$VAULT" freeze_exits --admin "$ADMIN"
    echo "  thaw_exits             tx $(tx "$VAULT" thaw_exits --admin "$ADMIN")"
    assert_eq "exits are open again" \
      "$([ "$(num "$(q "$VAULT" exits_frozen_until)")" -le "$(date -u +%s)" ] && echo open || echo shut)" "open"
  fi
else
  refused 303 "new requests stop" "$VAULT" request_withdrawal --from "$ADMIN" --amount "$CLAIM_AMOUNT"
fi
BEFORE=$(num "$(q "$USDC" balance --id "$ADMIN")")
echo "  settle while paused, signed by $OTHER  tx $(tx_other "$VAULT" settle_withdrawal)"
assert_eq "the claim already queued is still paid" "$(q "$USDC" balance --id "$ADMIN")" "$((BEFORE + CLAIM_AMOUNT))"
echo "  unpause                tx $(tx "$VAULT" set_paused --admin "$ADMIN" --paused false)"
assert_eq "the breaker is off" "$(q "$VAULT" paused)" "false"

echo ""
echo "== FINDING 6: the admin role moves, in two steps =="
assert_eq "the Vault's admin is the deployer" "$(q "$VAULT" admin)" "$ADMIN"
echo "  propose_admin -> $OTHER  tx $(tx "$VAULT" propose_admin --admin "$ADMIN" --new_admin "$OTHER_ADDR")"
assert_eq "a handover is pending" "$(q "$VAULT" pending_admin)" "$OTHER_ADDR"
assert_eq "and nothing has moved yet" "$(q "$VAULT" admin)" "$ADMIN"
# Submitted, and signed by alice's own key. This is the step that cannot be
# faked by simulation: the network checks the signature.
echo "  accept_admin, signed by $OTHER  tx $(tx_other "$VAULT" accept_admin --new_admin "$OTHER_ADDR")"
assert_eq "the role moved" "$(q "$VAULT" admin)" "$OTHER_ADDR"
assert_eq "and the proposal is cleared" "$(q "$VAULT" pending_admin)" "null"
refused 302 "the old key is an ordinary address now" \
  "$VAULT" set_paused --admin "$ADMIN" --paused true
# Hand it back, the same way, so the deployment record stays true.
echo "  propose_admin -> deployer, signed by $OTHER  tx $(tx_other "$VAULT" propose_admin --admin "$OTHER_ADDR" --new_admin "$ADMIN")"
echo "  accept_admin, signed by the deployer  tx $(tx "$VAULT" accept_admin --new_admin "$ADMIN")"
assert_eq "the deployer is admin again" "$(q "$VAULT" admin)" "$ADMIN"

echo ""
echo "== sagUSD: yield still arrives, and only with the agUSD behind it =="
NAV0=$(q0 "$STAKING" nav)
HELD0=$(q0 "$AGUSD" balance --id "$STAKING")
STAKE=$CLAIM_AMOUNT
echo "  stake $STAKE           tx $(tx "$STAKING" stake --from "$ADMIN" --amount "$STAKE")"
assert_eq "the NAV rose by the stake" "$(q "$STAKING" nav)" "$((NAV0 + STAKE))"
# The movement, not the total. nav is what this contract is accountable for and
# the balance is what it holds, and the two part company the moment anybody
# transfers agUSD to it directly, which nothing forbids and which is the same
# unannounced arrival the Vault's own accounting is built to ignore. What is
# under test is that a stake moves both by the same amount.
assert_eq "and the agUSD actually held rose by the same" \
  "$(q "$AGUSD" balance --id "$STAKING")" "$((HELD0 + STAKE))"
echo "  distribute_yield $WRITE_OFF  tx $(tx "$STAKING" distribute_yield --amount "$WRITE_OFF")"
assert_eq "the NAV rose by exactly what arrived" "$(q "$STAKING" nav)" "$((NAV0 + STAKE + WRITE_OFF))"
assert_eq "and the agUSD is really there" "$(q "$AGUSD" balance --id "$STAKING")" "$((HELD0 + STAKE + WRITE_OFF))"

# Make the written down demonstration whole, and do it through the contracts
# rather than around them.
#
# This used to transfer the 0.1 USDC straight to the Vault. The comment on it
# said, correctly, that nothing in the contracts does that and nothing should be
# read as though something did. What it did not anticipate is that the Vault
# cannot account for cash that arrives that way: `idle_reserves` reads the real
# balance, so the money is there, and no call can book it, so agUSD supply stays
# permanently below the Vault's assets. Two other smoke scripts correctly flag
# that as an imbalance, and since `Engine::book_recovery` was removed there is no
# way to clear it. The last run left exactly that: 0.1 USDC in the Vault that
# nothing claims and nothing can attribute, which is finding M1 in the flesh.
#
# So the restoration goes to the adapter, which is where the loss was, and
# `recover` brings it home. That is the protocol mechanism for exactly this: it
# sweeps what an adapter holds above its booked exposure, the Vault verifies the
# arrival before it moves a number, and the recognised loss is released against
# it. It is still the operator putting their own money back, and who bears a
# credit loss is still an open product decision that this script does not make.
# What changes is that the books end consistent instead of one dollar apart.
echo "  restore it to the adapter        tx $(tx "$USDC" transfer --from "$ADMIN" --to "$PC" --amount "$WRITE_OFF")"
echo "  recover, which books it          tx $(tx "$ENGINE" recover --admin "$ADMIN" --pool_id "$PC")"
assert_eq "the loss is released" "$(q "$VAULT" recognised_losses)" "0"
# Measured as a change rather than against zero, and the reason is worth
# recording. An earlier version of this script transferred the restoration
# straight to the Vault, and the Vault cannot account for cash that arrives that
# way: no call books it, so it sits in the balance claimed by nothing. Those
# stroops are still there and nothing can clear them, because the one entry
# point that could was removed after an invariant fuzzer showed it lowered the
# reserve floor's base. So the standing gap is M1 in the flesh, and what this
# script is now responsible for is not adding to it.
UNACCOUNTED_AFTER=$(( $(num "$(q "$VAULT" idle_reserves)") - $(num "$(q "$VAULT" booked_reserves)") ))
assert_eq "this script added nothing the Vault cannot account for" \
  "$UNACCOUNTED_AFTER" "$UNACCOUNTED_BEFORE"

echo ""
echo "== closing state =="
echo "  vault idle reserves      $(q "$VAULT" idle_reserves)"
echo "  vault free reserves      $(q "$VAULT" free_reserves)"
echo "  vault deployed capital   $(q "$VAULT" deployed_capital)"
echo "  vault liabilities        $(q "$VAULT" outstanding_liabilities)"
echo "  engine total allocated   $(q "$ENGINE" total_allocated)"
echo "  engine reserve ratio     $(q "$ENGINE" get_reserve_ratio)"
echo "  agusd supply             $(q "$AGUSD" total_supply)"
echo "  sagusd nav               $(q "$STAKING" nav)"
echo "  private credit exposure  $(q "$PC" get_exposure)"

echo ""
echo "================================"
echo " SMOKE RESULT: $PASS passed, $FAIL failed"
echo "================================"
[ "$FAIL" = "0" ]
