#!/usr/bin/env bash
# The complete Agama user journey, executed against the LIVE testnet deployment
# recorded in deployments/testnet.json, with the real Circle USDC.
#
#   deposit USDC and receive agUSD 1:1
#   stake agUSD into sagUSD
#   allocate capital through the Allocation Engine into a pool adapter
#   push a NAV through the Oracle Adapter and read it back through the Vault
#   distribute yield and watch the sagUSD exchange rate rise
#   unstake, through the cooldown
#   request a withdrawal, watch the queue wait on the deployed capital
#   deallocate, and claim the withdrawal back into USDC
#
# and the four refusals that make the journey mean something:
#
#   a caller that is not the Vault cannot mint agUSD
#   a caller that is not the Engine cannot release the Vault's USDC
#   an allocation past a concentration cap is refused
#   an allocation that would breach the reserve floor is refused
#
# All four are submitted, not simulated. Simulation records authorization
# instead of enforcing it, so the first two only fail for real when they apply;
# and a refusal that is only ever simulated is not something a reviewer can look
# up. Every one of them is left on the ledger as a failed transaction carrying
# the contract's own error code, and this script reads that code back off the
# ledger before it calls the case passed. See scripts/tx-patch.py for how the
# two that fail in simulation are prepared.
#
# It is repeatable: the book is unwound at the end and the only lasting change
# is the working capital left in the Vault.
#
# Needs the admin account (agama-poc) to hold the deposit amount in real USDC.
# Get some at https://faucet.circle.com (USDC / Stellar Testnet).
#
# Usage: bash scripts/smoke-journey.sh
set -uo pipefail
cd "$(dirname "$0")/.."

NET=testnet
SRC=agama-poc
DEP=deployments/testnet.json
RPC=https://soroban-testnet.stellar.org
HORIZON=https://horizon-testnet.stellar.org

DEPOSIT=20000000   # 2 USDC at 7 decimals, and the total assets everything below is a share of
STAKE=10000000     # 1 agUSD staked into sagUSD
YIELD=1000000      # 0.1 agUSD of yield, which is a 10% move on the staked balance
WITHDRAW=10000000  # 1 agUSD out, which is also the Vault's anti-dust floor
PROBE=10000000     # size of the mint a non-Vault caller is not allowed to make
# Amounts used only to harvest a valid footprint for a refusal. They are chosen
# to be distinctive so the rewrite in tx-patch.py cannot hit anything else.
HARVEST_CAP=1234567
HARVEST_FLOOR=765432

j() { python3 -c "import json;d=json.load(open('$DEP'));print($1)"; }
USDC=$(j "d['contracts']['usdc']")
AGUSD=$(j "d['contracts']['agusdCore']")
VAULT=$(j "d['contracts']['vault']")
ENGINE=$(j "d['contracts']['allocationEngine']")
ORACLE=$(j "d['contracts']['oracleAdapter']")
STAKING=$(j "d['contracts']['staking']")
PC=$(j "d['poolAdapters']['private-credit']")
EF=$(j "d['poolAdapters']['etherfuse']")
POOL_CAP=$(j "d['engineConfig']['poolCapBps']")
FLOOR=$(j "d['engineConfig']['reserveFloorBps']")
COOLDOWN=$(j "d['cooldownSeconds']")
FEED=$(j "d['vaultOracleFeed']")
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

next_seq() {
  curl -s "$HORIZON/accounts/$ADMIN" \
    | python3 -c "import json,sys;print(int(json.load(sys.stdin)['sequence'])+1)"
}

# Every error a failed transaction left on the ledger, one per line, as
# "contract:407" or "auth:invalid_action". Read back off the ledger rather than
# out of this script's own expectations: the point of submitting a refusal is
# that the network's record of why it failed is the evidence, not ours.
ledger_errors() {
  local hash=$1 attempt out
  for attempt in 1 2 3 4 5; do
    out=$(curl -s -X POST "$RPC" -H 'Content-Type: application/json' \
      -d "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"getTransaction\",\"params\":{\"hash\":\"$hash\"}}" \
      | python3 -c '
import json, subprocess, sys
result = json.load(sys.stdin).get("result", {})
for raw in result.get("diagnosticEventsXdr", []):
    decoded = subprocess.run(
        ["stellar", "xdr", "decode", "--type", "DiagnosticEvent", "--output", "json"],
        input=raw, capture_output=True, text=True).stdout
    try:
        event = json.loads(decoded)
    except Exception:
        continue
    for topic in event["event"]["body"]["v0"]["topics"]:
        if isinstance(topic, dict) and isinstance(topic.get("error"), dict):
            for kind, detail in topic["error"].items():
                print(f"{kind}:{detail}")
')
    [ -n "$out" ] && { echo "$out"; return; }
    python3 -c "import time;time.sleep(2)"
  done
  echo "unknown:unknown"
}

# A call whose authorization the caller cannot produce. Simulation records
# authorization rather than enforcing it, so this is submitted for real: the
# transaction goes out with a contract address's authorization entry unsatisfied
# and the network traps it when it applies. Building, simulating, signing and
# sending are split apart because the CLI will not sign for a contract address.
traps() { # traps <label> <contract id> <args...>
  local label="$1" id="$2"; shift 2
  local out hash
  out=$(stellar contract invoke --id "$id" --source $SRC --network $NET --build-only -- "$@" 2>/dev/null \
        | stellar tx simulate --source $SRC --network $NET 2>/dev/null \
        | stellar tx sign --sign-with-key $SRC --network $NET 2>/dev/null | tail -1 \
        | stellar tx send --network $NET 2>&1)
  hash=$(echo "$out" | grep -oE '[0-9a-f]{64}' | head -1)
  if ! echo "$out" | grep -q "TxFailed"; then
    bad "$label: it was not refused (tx ${hash:-none})"
  elif ledger_errors "$hash" | grep -qx "auth:invalid_action"; then
    ok "$label (tx $hash, refused for want of authorization on the ledger)"
  else
    bad "$label: tx $hash failed, but not on authorization"
  fi
}

# Prepare a refusal the CLI would otherwise never let us send. The Engine
# refuses the call we want to submit, so it fails simulation and there is
# nothing to sign; instead a smaller allocation that does simulate is prepared,
# and the amount is rewritten in both the operation and its authorization entry.
# The footprint stays valid because the refused call reads the same entries and
# writes none of them.
harvest_refusal() { # harvest_refusal <out file> <pool> <harvest amount> <real amount>
  local out=$1 pool=$2 harvest=$3 real=$4
  stellar contract invoke --id "$ENGINE" --source $SRC --network $NET --build-only \
    -- allocate --admin "$ADMIN" --pool_id "$pool" --amount "$harvest" 2>/dev/null | tail -1 \
  | stellar tx simulate --source $SRC --network $NET 2>/dev/null | tail -1 \
  | python3 scripts/tx-patch.py amount "$harvest" "$real" 2>/dev/null > "$out"
  [ -s "$out" ]
}

# Send a harvested refusal and check the ledger agrees about why it failed.
submit_refusal() { # submit_refusal <label> <expected error code> <envelope file>
  local label="$1" code="$2" file="$3" out hash found
  out=$(python3 scripts/tx-patch.py seq "$(next_seq)" < "$file" 2>/dev/null \
        | stellar tx sign --sign-with-key $SRC --network $NET 2>/dev/null | tail -1 \
        | stellar tx send --network $NET 2>&1)
  hash=$(echo "$out" | grep -oE '[0-9a-f]{64}' | head -1)
  if ! echo "$out" | grep -q "TxFailed"; then
    bad "$label: the transaction was not refused (tx $hash)"
    return
  fi
  found=$(ledger_errors "$hash")
  if echo "$found" | grep -qx "contract:$code"; then
    ok "$label (tx $hash, contract error #$code on the ledger)"
  else
    bad "$label: tx $hash failed, but carrying $(echo "$found" | tr '\n' ' ') rather than contract:$code"
  fi
}

echo "== deployment under test =="
echo "  vault              $VAULT"
echo "  agusd-core         $AGUSD"
echo "  sagUSD staking     $STAKING"
echo "  allocation-engine  $ENGINE"
echo "  oracle-adapter     $ORACLE"
echo "  private-credit     $PC"
echo "  etherfuse          $EF"
echo "  usdc               $USDC"

echo ""
echo "== WIRING: every pointer, in both directions =="
assert_eq "the Vault mints agusd-core" "$(q "$VAULT" agusd)" "$AGUSD"
assert_eq "agusd-core's minter is the Vault" "$(q "$AGUSD" minter)" "$VAULT"
assert_eq "the Vault answers to the Engine" "$(q "$VAULT" allocation_engine)" "$ENGINE"
assert_eq "the Engine governs the Vault" "$(q "$ENGINE" vault)" "$VAULT"
assert_eq "private credit answers to the Engine" "$(q "$PC" engine)" "$ENGINE"
assert_eq "private credit returns capital to the Vault" "$(q "$PC" vault)" "$VAULT"
assert_eq "etherfuse answers to the Engine" "$(q "$EF" engine)" "$ENGINE"
assert_eq "etherfuse returns capital to the Vault" "$(q "$EF" vault)" "$VAULT"
assert_eq "sagUSD stakes agusd-core" "$(q "$STAKING" agusd)" "$AGUSD"
assert_eq "the Vault holds the real USDC" "$(q "$VAULT" usdc)" "$USDC"

echo ""
echo "== MINT AUTHORITY: the Vault, and nothing else =="
SUPPLY0=$(num "$(q "$AGUSD" total_supply)")
traps "the admin, who deployed the token, cannot mint it" \
  "$AGUSD" mint --to "$ADMIN" --amount "$PROBE"
assert_eq "total supply did not move" "$(q "$AGUSD" total_supply)" "$SUPPLY0"

echo ""
echo "== 1. DEPOSIT: USDC in, agUSD out 1:1 =="
U0=$(num "$(q "$USDC" balance --id "$ADMIN")")
if [ "$U0" -lt "$DEPOSIT" ]; then
  echo "  the admin holds $U0 (7dp) of USDC and the deposit is $DEPOSIT"
  echo "  top up at https://faucet.circle.com (USDC / Stellar Testnet) for $ADMIN"
  exit 2
fi
A0=$(num "$(q "$AGUSD" balance --id "$ADMIN")")
R0=$(num "$(q "$VAULT" idle_reserves)")
echo "  deposit $DEPOSIT  tx $(tx "$VAULT" deposit --from "$ADMIN" --amount "$DEPOSIT")"
assert_eq "the depositor was minted 1 agUSD per USDC" \
  "$(q "$AGUSD" balance --id "$ADMIN")" "$((A0 + DEPOSIT))"
assert_eq "the USDC is in the Vault" "$(q "$VAULT" idle_reserves)" "$((R0 + DEPOSIT))"
assert_eq "and out of the depositor's account" \
  "$(q "$USDC" balance --id "$ADMIN")" "$((U0 - DEPOSIT))"

TOTAL=$(num "$(q "$VAULT" get_total_assets)")
echo "  total assets under the Engine's limits: $TOTAL"

echo ""
echo "== 2. STAKE: agUSD into sagUSD =="
echo "  stake $STAKE  tx $(tx "$STAKING" stake --from "$ADMIN" --amount "$STAKE")"
assert_eq "shares were issued one for one at a share price of 1.0" \
  "$(q "$STAKING" balance --id "$ADMIN")" "$STAKE"
assert_eq "the share price starts at 1.0" "$(q "$STAKING" share_price)" "10000000"
assert_eq "the staking contract custodies the agUSD" \
  "$(q "$AGUSD" balance --id "$STAKING")" "$STAKE"

echo ""
echo "== 3. ALLOCATE: capital out through the Engine =="
PC_ALLOC=$(( TOTAL * 4000 / 10000 ))
EF_ALLOC=$(( TOTAL * 3500 / 10000 ))
OVER_CAP=$(( TOTAL * 4250 / 10000 ))
OVER_FLOOR=$(( TOTAL * 500 / 10000 ))
echo "  private credit takes $PC_ALLOC, which is the whole of its ${POOL_CAP} bps cap"
echo "  allocate  tx $(tx "$ENGINE" allocate --admin "$ADMIN" --pool_id "$PC" --amount "$PC_ALLOC")"
assert_eq "the adapter booked the exposure" "$(q "$PC" get_exposure)" "$PC_ALLOC"
assert_eq "the Vault released exactly that much" \
  "$(q "$VAULT" idle_reserves)" "$((TOTAL - PC_ALLOC))"
assert_eq "an allocation does not change total assets" "$(q "$VAULT" get_total_assets)" "$TOTAL"
assert_eq "the reserve ratio fell to match" "$(q "$ENGINE" get_reserve_ratio)" \
  "$(( (TOTAL - PC_ALLOC) * 10000 / TOTAL ))"

# Both refusals are prepared here, while an allocation to Etherfuse still
# simulates cleanly. The reserve floor one cannot be prepared later: once the
# book is full to the floor, no allocation simulates at all, which is the whole
# point of the guard.
harvest_refusal /tmp/agama-refusal-cap.txt "$EF" "$HARVEST_CAP" "$OVER_CAP" \
  || bad "could not prepare the concentration cap refusal"
harvest_refusal /tmp/agama-refusal-floor.txt "$EF" "$HARVEST_FLOOR" "$OVER_FLOOR" \
  || bad "could not prepare the reserve floor refusal"

echo ""
echo "== 4. ORACLE: push a NAV, read it back through the Vault =="
TS=$(( $(date +%s) - 120 ))
push() {
  echo "  push_nav $1 = $2  tx $(tx "$ORACLE" push_nav --reporter "$ADMIN" --feed_id "$1" --nav "$2" --timestamp "$TS")"
  assert_eq "get_nav($1) reads back what was pushed" "$(q "$ORACLE" get_nav --feed_id "$1")" "$2"
}
push USDC_USD 10000000
push PC_NAV 10100000   # a 1% revaluation of the private credit book, inside the feed's 500 bps bound
push EF_BOND 10260000
assert_eq "the Vault reads its own feed ($FEED) through the adapter" "$(q "$VAULT" get_nav)" "10100000"

echo ""
echo "== 5. YIELD: the sagUSD exchange rate rises =="
NAV0=$(num "$(q "$STAKING" nav)")
echo "  accrue_yield $YIELD  tx $(tx "$STAKING" accrue_yield --amount "$YIELD")"
assert_eq "the staking NAV rose by the yield delivered" "$(q "$STAKING" nav)" "$((NAV0 + YIELD))"
assert_eq "and the share price rose with it, to 1.1" "$(q "$STAKING" share_price)" \
  "$(( (NAV0 + YIELD) * 10000000 / STAKE ))"
assert_eq "nobody minted shares to do it" "$(q "$STAKING" total_shares)" "$STAKE"

echo ""
echo "== 6. GUARDS: the concentration cap, refused on the ledger =="
echo "  $OVER_CAP into Etherfuse would be 4250 bps of the book against a ${POOL_CAP} bps cap"
submit_refusal "an allocation past the per-pool concentration cap is refused" 407 \
  /tmp/agama-refusal-cap.txt
assert_eq "the refused allocation booked nothing" "$(q "$EF" get_exposure)" "0"
assert_eq "and moved nothing" "$(q "$VAULT" idle_reserves)" "$((TOTAL - PC_ALLOC))"

echo ""
echo "== 7. ALLOCATE: fill the book down to the reserve floor =="
echo "  etherfuse takes $EF_ALLOC, 3500 bps, which lands idle reserves on the ${FLOOR} bps floor"
echo "  allocate  tx $(tx "$ENGINE" allocate --admin "$ADMIN" --pool_id "$EF" --amount "$EF_ALLOC")"
IDLE_AT_FLOOR=$((TOTAL - PC_ALLOC - EF_ALLOC))
assert_eq "the adapter booked the exposure" "$(q "$EF" get_exposure)" "$EF_ALLOC"
assert_eq "idle reserves are on the floor" "$(q "$ENGINE" get_reserve_ratio)" "$FLOOR"
assert_eq "which is what the Vault is holding" "$(q "$VAULT" idle_reserves)" "$IDLE_AT_FLOOR"

echo ""
echo "== 8. GUARDS: the reserve floor, refused on the ledger =="
# This is the case the previous configuration could not produce. Etherfuse is
# at 3500 bps and its cap is 4000, so 500 bps more is inside its own cap, inside
# the global pool cap, inside the originator cap and inside the jurisdiction
# cap. Every concentration limit says yes. The floor is the only one left.
echo "  $OVER_FLOOR more into Etherfuse takes it to exactly its ${POOL_CAP} bps cap,"
echo "  and takes idle reserves below the ${FLOOR} bps floor"
submit_refusal "an allocation that breaches the reserve floor is refused" 410 \
  /tmp/agama-refusal-floor.txt
assert_eq "Etherfuse exposure is unchanged" "$(q "$EF" get_exposure)" "$EF_ALLOC"
assert_eq "and the reserves are still on the floor" "$(q "$VAULT" idle_reserves)" "$IDLE_AT_FLOOR"

echo ""
echo "== 9. CUSTODY: only the Engine can release the Vault's USDC =="
# The probe has to be an amount the Vault could actually pay, or the release
# fails on the balance in simulation and never reaches the authorization check
# that is the point of the test.
SETTLE_PROBE=$((IDLE_AT_FLOOR / 2))
traps "an admin signed settle_allocation cannot release the Vault's USDC" \
  "$VAULT" settle_allocation --pool "$PC" --amount "$SETTLE_PROBE"
assert_eq "the reserves are untouched" "$(q "$VAULT" idle_reserves)" "$IDLE_AT_FLOOR"

echo ""
echo "== 10. UNSTAKE: shares back into agUSD, through the cooldown =="
AG_BEFORE=$(num "$(q "$AGUSD" balance --id "$ADMIN")")
echo "  request_unstake $STAKE  tx $(tx "$STAKING" request_unstake --from "$ADMIN" --shares "$STAKE")"
OWED=$(num "$(q "$STAKING" pending --addr "$ADMIN" | python3 -c "import sys,json;print(json.load(sys.stdin)['assets'])")")
assert_eq "the shares are burned at request time" "$(q "$STAKING" balance --id "$ADMIN")" "0"
assert_eq "and the position is worth its appreciated value" "$OWED" "$((STAKE + YIELD))"
echo "  waiting out the ${COOLDOWN}s cooldown"
python3 -c "import time;time.sleep($COOLDOWN + 10)"
echo "  claim  tx $(tx "$STAKING" claim --from "$ADMIN")"
assert_eq "the staker got back more agUSD than they staked" \
  "$(q "$AGUSD" balance --id "$ADMIN")" "$((AG_BEFORE + STAKE + YIELD))"
assert_eq "the staking contract is empty" "$(q "$AGUSD" balance --id "$STAKING")" "0"

echo ""
echo "== 11. EXIT: request burns, the queue waits on the book =="
CLAIM_ID=$(num "$(q "$VAULT" queue_tail)")
A1=$(num "$(q "$AGUSD" balance --id "$ADMIN")")
U1=$(num "$(q "$USDC" balance --id "$ADMIN")")
echo "  request_withdrawal $WITHDRAW (claim $CLAIM_ID)  tx $(tx "$VAULT" request_withdrawal --from "$ADMIN" --amount "$WITHDRAW")"
assert_eq "the agUSD is burned at request time" \
  "$(q "$AGUSD" balance --id "$ADMIN")" "$((A1 - WITHDRAW))"
# The whole reason withdrawals are two steps. The Vault is holding less than the
# claim is worth, because the rest of it is deployed into positions that settle
# in D+15 to D+90, so the claim is at the head of the queue and still not ready.
assert_eq "the claim is queued but not payable, the capital is deployed" \
  "$(q "$VAULT" claim_status --claim_id "$CLAIM_ID")" "Pending"

echo "  deallocate $EF_ALLOC from etherfuse  tx $(tx "$ENGINE" deallocate --pool_id "$EF" --amount "$EF_ALLOC")"
assert_eq "the capital came back to the Vault" \
  "$(q "$VAULT" idle_reserves)" "$((IDLE_AT_FLOOR + EF_ALLOC))"
assert_eq "and the claim became payable without anybody touching it" \
  "$(q "$VAULT" claim_status --claim_id "$CLAIM_ID")" "Ready"

echo "  claim_withdrawal $CLAIM_ID  tx $(tx "$VAULT" claim_withdrawal --from "$ADMIN" --claim_id "$CLAIM_ID")"
assert_eq "the USDC came back" "$(q "$USDC" balance --id "$ADMIN")" "$((U1 + WITHDRAW))"
assert_eq "the claim is settled" "$(q "$VAULT" claim_status --claim_id "$CLAIM_ID")" "Claimed"
assert_eq "the queue is empty again" "$(q "$VAULT" queue_length)" "0"

echo ""
echo "== 12. UNWIND: the book back to cash =="
echo "  deallocate $PC_ALLOC from private credit  tx $(tx "$ENGINE" deallocate --pool_id "$PC" --amount "$PC_ALLOC")"
assert_eq "nothing is deployed" "$(q "$ENGINE" total_allocated)" "0"
assert_eq "the reserve is complete again" "$(q "$ENGINE" get_reserve_ratio)" "10000"
# The invariant the whole generation exists to make true: the Vault is the only
# thing that can create agUSD, so every unit in circulation is a dollar this
# Vault is accountable for.
assert_eq "one agUSD in circulation, one dollar of assets in the Vault" \
  "$(q "$AGUSD" total_supply)" "$(num "$(q "$VAULT" get_total_assets)")"

echo ""
echo "================================"
echo " JOURNEY RESULT: $PASS passed, $FAIL failed"
echo "================================"
[ "$FAIL" = "0" ]
