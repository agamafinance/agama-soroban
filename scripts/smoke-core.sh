#!/usr/bin/env bash
# On-chain smoke test for the core contracts deployed by scripts/deploy-core.sh.
#
# Everything here runs against the LIVE testnet deployment recorded in
# deployments/testnet.json, with the real Circle USDC. It is repeatable: the
# allocation leg is unwound at the end, so the book is left as it was found.
#
# Covers, with assertions:
#   oracle : push NAV on the three registered feeds, read each one back,
#            and read the Vault's feed through the Vault itself
#   vault  : idle reserves, total assets, reserve ratio
#   engine : allocate to a pool adapter, check exposure and reserve ratio move
#            together, deallocate, check the capital came back
#   guards : an allocation past the per-pool concentration cap is refused
#
# The Vault needs a small idle USDC balance to exercise the allocation leg. If
# it has none, the script tops it up from the admin account, which needs USDC
# on its trustline (https://faucet.circle.com, USDC / Stellar Testnet).
#
# Written for the generation 2 deployment. The stack has since been redeployed
# and rewired; scripts/smoke-journey.sh covers the whole journey against the
# current one, including everything here. This is kept because the addresses and
# transactions it produced are still on the ledger and still recorded.
#
# Usage: bash scripts/smoke-core.sh
set -uo pipefail
cd "$(dirname "$0")/.."

NET=testnet
SRC=agama-poc
DEP=deployments/testnet.json
MIN_IDLE=10000000 # 1 USDC at 7 decimals

j() { python3 -c "import json;d=json.load(open('$DEP'));print($1)"; }
USDC=$(j "d['contracts']['usdc']")
ENGINE=$(j "d['contracts']['allocationEngine']")
ORACLE=$(j "d['contracts']['oracleAdapter']")
PC=$(j "d['poolAdapters']['private-credit']")
EF=$(j "d['poolAdapters']['etherfuse']")
POOL_CAP=$(j "d['engineConfig']['poolCapBps']")
ADMIN=$(stellar keys address $SRC)

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  PASS  $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL  $1"; }
num() { echo "$1" | tr -d '"'; }
assert_eq() { if [ "$(num "$2")" = "$3" ]; then ok "$1 ($2)"; else bad "$1: got $2, want $3"; fi; }

# Read-only: simulated, never submitted, so views cost nothing.
q()   { stellar contract invoke --id "$1" --source $SRC --network $NET --send=no -- "${@:2}" 2>/dev/null; }
# The Vault under test is the one the Engine points at, read from the Engine
# rather than from the deployment file. The Engine stores that address at
# initialize() and has no setter, so it still guards the superseded Vault while
# deployments/testnet.json already names its replacement. Asking the Engine
# keeps this script testing a pair that is actually wired together.
VAULT=$(q "$ENGINE" vault | tr -d '"')
# State changing: submitted, and the transaction hash is echoed.
tx()  { stellar contract invoke --id "$1" --source $SRC --network $NET -- "${@:2}" 2>&1 \
          | grep -oE '[0-9a-f]{64}' | head -1; }

echo "== deployment under test =="
echo "  vault             $VAULT (the Vault the Engine points at)"
echo "  allocation-engine $ENGINE"
echo "  oracle-adapter    $ORACLE"
echo "  private-credit    $PC"
echo "  etherfuse         $EF"

echo ""
echo "== ORACLE ADAPTER: push NAV, read it back =="
# Two minutes behind wall clock, so the report is safely behind ledger time (a
# future timestamp is refused) while still being strictly after the last one.
TS=$(( $(date +%s) - 120 ))
push() {
  local hash
  hash=$(tx "$ORACLE" push_nav --reporter "$ADMIN" --feed_id "$1" --nav "$2" --timestamp "$TS")
  echo "  push_nav $1 = $2  tx $hash"
  assert_eq "get_nav($1) reads back what was pushed" "$(q "$ORACLE" get_nav --feed_id "$1")" "$2"
}
push USDC_USD 10000000
push PC_NAV 10000000
push EF_BOND 10250000
assert_eq "Vault reads its own feed through the adapter" "$(q "$VAULT" get_nav)" "10000000"

echo ""
echo "== VAULT: reserves and total assets =="
IDLE=$(num "$(q "$VAULT" idle_reserves)")
if [ "$IDLE" -lt "$MIN_IDLE" ]; then
  TOPUP=$((MIN_IDLE - IDLE))
  echo "  topping the Vault up with $TOPUP (7dp) of USDC from the admin"
  echo "  tx $(tx "$USDC" transfer --from "$ADMIN" --to "$VAULT" --amount "$TOPUP")"
  IDLE=$(num "$(q "$VAULT" idle_reserves)")
fi
TOTAL=$(num "$(q "$VAULT" get_total_assets)")
DEPLOYED=$(num "$(q "$ENGINE" total_allocated)")
echo "  idle=$IDLE deployed=$DEPLOYED total=$TOTAL"
assert_eq "total assets are idle reserves plus deployed capital" "$TOTAL" "$((IDLE + DEPLOYED))"
assert_eq "reserve ratio matches idle over total" \
  "$(q "$ENGINE" get_reserve_ratio)" "$((IDLE * 10000 / TOTAL))"

echo ""
echo "== ALLOCATION ENGINE: allocate, then unwind =="
# 10% of total assets, comfortably inside the 30% per-pool cap.
AMOUNT=$((TOTAL / 10))
EXP0=$(num "$(q "$EF" get_exposure)")
echo "  allocate $AMOUNT to the Etherfuse adapter  tx $(tx "$ENGINE" allocate --admin "$ADMIN" --pool_id "$EF" --amount "$AMOUNT")"
assert_eq "adapter booked the exposure" "$(q "$EF" get_exposure)" "$((EXP0 + AMOUNT))"
assert_eq "Vault released exactly that much USDC" "$(q "$VAULT" idle_reserves)" "$((IDLE - AMOUNT))"
assert_eq "total assets are unchanged by an allocation" "$(q "$VAULT" get_total_assets)" "$TOTAL"
assert_eq "reserve ratio fell to match" \
  "$(q "$ENGINE" get_reserve_ratio)" "$(((IDLE - AMOUNT) * 10000 / TOTAL))"

echo "  deallocate $AMOUNT  tx $(tx "$ENGINE" deallocate --pool_id "$EF" --amount "$AMOUNT")"
assert_eq "exposure is back where it started" "$(q "$EF" get_exposure)" "$EXP0"
assert_eq "the capital came back to the Vault" "$(q "$VAULT" idle_reserves)" "$IDLE"

echo ""
echo "== GUARDS: the per-pool cap is enforced on-chain =="
# Simulated only. A rejected allocation is meant to move nothing, so there is
# nothing to submit; the point is that the Engine refuses it.
OVER=$(( TOTAL * (POOL_CAP + 1000) / 10000 ))
if stellar contract invoke --id "$ENGINE" --source $SRC --network $NET --send=no \
     -- allocate --admin "$ADMIN" --pool_id "$EF" --amount "$OVER" >/dev/null 2>&1; then
  bad "allocating $OVER (past the ${POOL_CAP} bps pool cap) should have been refused"
else
  ok "allocating $OVER is refused with PoolCapExceeded (contract error 407)"
fi

echo ""
echo "================================"
echo " SMOKE RESULT: $PASS passed, $FAIL failed"
echo "================================"
[ "$FAIL" = "0" ]
