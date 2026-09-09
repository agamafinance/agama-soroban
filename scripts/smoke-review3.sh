#!/usr/bin/env bash
# On-chain smoke test for the one High finding of the third adversarial
# security review.
#
# The finding. `register_pool` proves an adapter names this Engine and this
# Engine's Vault. Half of that condition is a fact about the Engine, and
# `set_vault` can change it; the registry is a map with no way to clear it, so
# the moment the Vault pointer moves, every pool already registered goes on
# naming the Vault the Engine has just stopped governing, and nothing re-checks.
# The next `allocate` releases the NEW Vault's USDC to an adapter that repays
# the OLD one, which in this protocol is a superseded Vault where nothing can
# move USDC at all, and the position cannot be unwound either, because
# `deallocate` sends the cash to the old Vault and then asks the new one to
# confirm it arrived.
#
# Three stages, each independently runnable.
#
#   exploit  the pre-fix Engine, built from the commit before the fix, with the
#            exploit run as a SUBMITTED transaction rather than described
#   fixed    the same construction against the Engine in this working tree
#   live     the production deployment, which is the one that matters
#
# On simulation, and it is worth being exact. Every state change here is a
# submitted transaction whose hash is echoed. A refusal cannot be submitted,
# because the CLI will not send a transaction whose simulation fails, so
# refusals are shown by simulation with the contract error code asserted. That
# is sound for a refusal, which is contract logic either way, and it is why the
# exploit itself is submitted: the interesting claim is that the pre-fix Engine
# ACCEPTS the call, and an acceptance can be, and is, put on the ledger.
#
# Working capital. The `exploit` and `fixed` stages use a mock USDC with an open
# faucet and their own Vaults, deliberately: the operator key holds well under a
# USDC of the real thing and some of it is stranded below the Vault's anti-dust
# minimum, and there is nothing about this finding that needs the real asset.
# The `live` stage uses the real Circle USDC Stellar Asset Contract and the real
# Vault, borrows half a USDC of the Vault's own reserves and hands every stroop
# of it straight back, so it is net zero for the operator and for the protocol.
#
# One warning about the `live` stage. It moves the production Engine's Vault
# pointer to a throwaway Vault, shows the refusal, and moves it back, in two
# submitted transactions. If it is interrupted between them, the live Engine
# points at the throwaway and the way back is
# `stellar contract invoke --id <engine> --source agama-poc --network testnet
#  -- set_vault --admin <admin> --vault <vault>`. The Engine's exposure book is
# empty at that point by construction, which is what `set_vault` requires.
#
# Usage: bash scripts/smoke-review3.sh [all|exploit|fixed|live]
set -uo pipefail
cd "$(dirname "$0")/.."

STAGE=${1:-all}
stage() { [ "$STAGE" = all ] || [ "$STAGE" = "$1" ]; }

NET=testnet
SRC=agama-poc
DEP=deployments/testnet.json
WASM=target/wasm32v1-none/release
# The commit before the fix. Named rather than derived, because "the parent of
# main" stops being the pre-fix Engine the moment anything else merges.
PRE_FIX_REV=ce8624b
PRE_FIX_TREE=/tmp/agama-soroban-pre-review3

j() { python3 -c "import json;d=json.load(open('$DEP'));print($1)"; }
ADMIN=$(stellar keys address $SRC)
USDC=$(j "d['contracts']['usdc']")
VAULT=$(j "d['contracts']['vault']")
ENGINE=$(j "d['contracts']['allocationEngine']")
PC=$(j "d['poolAdapters']['private-credit']")
POOL_CAP=$(j "d['engineConfig']['poolCapBps']")
ORIGINATOR_CAP=$(j "d['engineConfig']['originatorCapBps']")
JURISDICTION_CAP=$(j "d['engineConfig']['jurisdictionCapBps']")
FLOOR=$(j "d['engineConfig']['reserveFloorBps']")
PC_ORIGINATOR=$(j "d['engineConfig']['pools']['private-credit']['originator']")
PC_JURISDICTION=$(j "d['engineConfig']['pools']['private-credit']['jurisdiction']")

ONE=10000000          # 1 unit at 7 decimals
FUND=$((100 * ONE))   # 100 mock USDC into the funding Vault
MOVE=$((20 * ONE))    # 20 of them, inside every cap and the floor

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  PASS  $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL  $1"; }
num() { echo "$1" | tr -d '"'; }
assert_eq() { if [ "$(num "$2")" = "$(num "$3")" ]; then ok "$1 ($(num "$2"))"; else bad "$1: got $(num "$2"), want $(num "$3")"; fi; }
assert_ne() { if [ "$(num "$2")" != "$(num "$3")" ]; then ok "$1"; else bad "$1: both are $(num "$2")"; fi; }

q()  { stellar contract invoke --id "$1" --source $SRC --network $NET --send=no -- "${@:2}" 2>/dev/null; }
q0() { q "$@" | tr -d '"'; }
tx() { stellar contract invoke --id "$1" --source $SRC --network $NET -- "${@:2}" 2>&1 \
         | grep -oE '[0-9a-f]{64}' | head -1; }
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
deploy() { # deploy <wasm> [ctor args...] -> contract id on stdout, tx hash on stderr
  local out; out=$(stellar contract deploy --wasm "$1" --source $SRC --network $NET -- "${@:2}" 2>&1)
  echo "$out" | grep -oE 'Transaction hash is [0-9a-f]{64}' | sed 's/Transaction hash is/      deploy tx/' >&2
  echo "$out" | grep -oE 'C[A-Z2-7]{55}' | tail -1
}

echo "== deployment under test =="
echo "  vault             $VAULT"
echo "  allocation-engine $ENGINE"
echo "  private-credit    $PC"
echo "  admin             $ADMIN"

# ---------------------------------------------------------------------------
# Stand up a two Vault stack around one Engine WASM and leave the Engine
# pointed at the second Vault while the adapter still names the first. That is
# the drift the finding is about, produced the way it is produced in practice:
# an Engine following its Vault to a new generation and an adapter not.
#
# The funding Vault is filled through `deposit` rather than by faucet, on
# purpose. A Vault that is handed USDC without being told holds cash it cannot
# account for, and `record_repayment` measures a repayment against exactly that
# difference, so a faucet-funded Vault would CONFIRM the repayment of money that
# went to a third party and settle the book on it. That is the same finding
# wearing a worse face, and the harder case to demonstrate is the honest Vault,
# so the honest Vault is what is built here.
# ---------------------------------------------------------------------------
build_drifted_stack() { # build_drifted_stack <engine wasm> -> "OLDVAULT NEWVAULT ENGINE POOL TUSDC"
  local engine_wasm=$1 tusdc vault_old vault_new agusd eng pool
  tusdc=$(deploy "$WASM/mock_usdc.wasm")
  stellar contract invoke --id "$tusdc" --source $SRC --network $NET -- initialize \
    --admin "$ADMIN" --decimal 7 --name '"Test USDC"' --symbol '"tUSDC"' >/dev/null 2>&1

  # The Vault the adapter will be left naming, and the one the Engine moves to.
  vault_old=$(deploy "$WASM/vault.wasm" --admin "$ADMIN" --usdc_token "$tusdc")
  vault_new=$(deploy "$WASM/vault.wasm" --admin "$ADMIN" --usdc_token "$tusdc")

  # Only the funding Vault needs to be able to mint, because only it takes a
  # deposit. Both need their own copy of the floor, which fails closed at 100%.
  agusd=$(deploy "$WASM/agusd_core.wasm" --admin "$ADMIN" --minter "$vault_new" \
    --decimal 7 --name '"agUSD"' --symbol '"agUSD"')
  tx "$vault_new" set_agusd --admin "$ADMIN" --agusd_token "$agusd" >/dev/null
  tx "$vault_new" set_reserve_floor --admin "$ADMIN" --floor_bps "$FLOOR" >/dev/null
  tx "$vault_old" set_reserve_floor --admin "$ADMIN" --floor_bps "$FLOOR" >/dev/null

  # The Engine is born against the first Vault, and the adapter against the
  # pair, so every check either of them runs has something real to check.
  eng=$(deploy "$engine_wasm" --admin "$ADMIN" --vault "$vault_old")
  tx "$vault_old" set_engine --admin "$ADMIN" --allocation_engine "$eng" >/dev/null
  pool=$(deploy "$WASM/private_credit.wasm" --admin "$ADMIN" --engine "$eng" \
    --vault "$vault_old" --usdc "$tusdc")
  tx "$eng" set_caps --admin "$ADMIN" --pool_cap_bps "$POOL_CAP" \
    --originator_cap_bps "$ORIGINATOR_CAP" --jurisdiction_cap_bps "$JURISDICTION_CAP" >/dev/null
  tx "$eng" set_reserve_floor --admin "$ADMIN" --floor_bps "$FLOOR" >/dev/null
  tx "$eng" register_pool --admin "$ADMIN" --pool_id "$pool" \
    --originator "$PC_ORIGINATOR" --jurisdiction "$PC_JURISDICTION" --cap_bps "$POOL_CAP" >/dev/null

  # Fund the second Vault honestly, then move the Engine to it and leave the
  # adapter where it is.
  stellar contract invoke --id "$tusdc" --source $SRC --network $NET -- faucet \
    --to "$ADMIN" --amount "$FUND" >/dev/null 2>&1
  tx "$vault_new" deposit --from "$ADMIN" --amount "$FUND" >/dev/null
  tx "$eng" set_vault --admin "$ADMIN" --vault "$vault_new" >/dev/null
  tx "$vault_new" set_engine --admin "$ADMIN" --allocation_engine "$eng" >/dev/null

  echo "$vault_old $vault_new $eng $pool $tusdc"
}

# ---------------------------------------------------------------------------
if stage exploit; then
echo ""
echo "== the pre-fix Engine, and the exploit submitted =="
echo "-- Built from $PRE_FIX_REV, the commit before the fix, so this is the"
echo "-- contract that has the bug rather than a description of it."

rm -rf "$PRE_FIX_TREE"
git worktree add --detach "$PRE_FIX_TREE" "$PRE_FIX_REV" >/dev/null 2>&1
( cd "$PRE_FIX_TREE" && stellar contract build >/dev/null 2>&1 )
PRE_WASM="$PRE_FIX_TREE/target/wasm32v1-none/release/allocation_engine.wasm"
if [ -f "$PRE_WASM" ]; then ok "pre-fix Engine WASM built from $PRE_FIX_REV"; else bad "could not build the pre-fix Engine"; fi

read -r OLDV NEWV OLDE POOL TUSDC <<<"$(build_drifted_stack "$PRE_WASM")"
echo "  old vault  $OLDV"
echo "  new vault  $NEWV"
echo "  engine     $OLDE"
echo "  pool       $POOL"

assert_eq "the Engine has followed its Vault" "$(q0 "$OLDE" vault)" "$NEWV"
assert_eq "the adapter has not"               "$(q0 "$POOL" vault)" "$OLDV"
assert_eq "and it still answers to this Engine, which is why it accepts" \
  "$(q0 "$POOL" engine)" "$OLDE"
assert_ne "so the registry names a Vault the Engine does not govern" \
  "$(q0 "$POOL" vault)" "$(q0 "$OLDE" vault)"
assert_eq "the funding Vault's book is honest: booked equals idle" \
  "$(q0 "$NEWV" booked_reserves)" "$(q0 "$NEWV" idle_reserves)"

echo ""
echo "-- The exploit. Not simulated: submitted."
EXPLOIT_TX=$(tx "$OLDE" allocate --admin "$ADMIN" --pool_id "$POOL" --amount "$MOVE")
echo "  allocate tx $EXPLOIT_TX"
if [ -n "$EXPLOIT_TX" ]; then ok "the pre-fix Engine accepted it"; else bad "the allocation did not go through"; fi
assert_eq "the new Vault paid"                "$(q0 "$NEWV" idle_reserves)" "$((FUND - MOVE))"
assert_eq "the adapter holds it"              "$(q0 "$TUSDC" balance --id "$POOL")" "$MOVE"
assert_eq "and the adapter repays the OTHER Vault" "$(q0 "$POOL" vault)" "$OLDV"
assert_eq "the new Vault's deployed book carries it" "$(q0 "$NEWV" deployed_capital)" "$MOVE"

echo ""
echo "-- And it cannot be unwound. deallocate sends the cash to the old Vault"
echo "-- and asks the new one to confirm it arrived, which it cannot."
refused 317 "deallocate is refused with the Vault's RepaymentNotReceived" \
  "$OLDE" deallocate --pool_id "$POOL" --amount "$MOVE"
assert_eq "so the capital stays out, on a book that cannot settle it" \
  "$(q0 "$OLDE" get_exposure --pool_id "$POOL")" "$MOVE"
fi

# ---------------------------------------------------------------------------
if stage fixed; then
echo ""
echo "== the same construction against the Engine in this tree =="
stellar contract build >/dev/null 2>&1
read -r OLDV2 NEWV2 NEWE POOL2 TUSDC2 <<<"$(build_drifted_stack "$WASM/allocation_engine.wasm")"
echo "  old vault  $OLDV2"
echo "  new vault  $NEWV2"
echo "  engine     $NEWE"
echo "  pool       $POOL2"

assert_ne "the same drift is set up" "$(q0 "$POOL2" vault)" "$(q0 "$NEWE" vault)"
refused 414 "the identical allocation is refused with AdapterMismatch" \
  "$NEWE" allocate --admin "$ADMIN" --pool_id "$POOL2" --amount "$MOVE"
assert_eq "and nothing moved: the Vault still holds every stroop" \
  "$(q0 "$NEWV2" idle_reserves)" "$FUND"
assert_eq "the adapter holds nothing" "$(q0 "$TUSDC2" balance --id "$POOL2")" "0"
assert_eq "and no exposure was booked" "$(q0 "$NEWE" total_allocated)" "0"

echo ""
echo "-- The other two calls that move capital are closed the same way."
refused 414 "deallocate is refused before it can settle the wrong book" \
  "$NEWE" deallocate --pool_id "$POOL2" --amount "$MOVE"
stellar contract invoke --id "$TUSDC2" --source $SRC --network $NET -- faucet \
  --to "$POOL2" --amount "$ONE" >/dev/null 2>&1
refused 414 "recover is refused rather than sweeping to the wrong Vault" \
  "$NEWE" recover --admin "$ADMIN" --pool_id "$POOL2"
assert_eq "the surplus is untouched" "$(q0 "$TUSDC2" balance --id "$POOL2")" "$ONE"

echo ""
echo "-- That surplus now has to be cleared before the adapter can be repointed,"
echo "-- because set_counterparties refuses an adapter holding a stroop. The"
echo "-- adapter admin's own recover_surplus is the path that still works, and it"
echo "-- sends the cash to the Vault the adapter names, which is the old one."
refused 605 "set_counterparties is refused while the adapter holds the surplus" \
  "$POOL2" set_counterparties --admin "$ADMIN" --engine "$NEWE" --vault "$NEWV2"
echo "  recover_surplus tx $(tx "$POOL2" recover_surplus --caller "$ADMIN")"
assert_eq "the adapter is empty" "$(q0 "$TUSDC2" balance --id "$POOL2")" "0"
assert_eq "and the old Vault, which it names, is what received it" \
  "$(q0 "$TUSDC2" balance --id "$OLDV2")" "$ONE"

echo ""
echo "-- It is a check and not a wall: bring the adapter across and the same"
echo "-- allocation goes through. Submitted."
echo "  set_counterparties tx $(tx "$POOL2" set_counterparties --admin "$ADMIN" --engine "$NEWE" --vault "$NEWV2")"
FIXED_TX=$(tx "$NEWE" allocate --admin "$ADMIN" --pool_id "$POOL2" --amount "$MOVE")
echo "  allocate tx $FIXED_TX"
if [ -n "$FIXED_TX" ]; then ok "the repaired wiring allocates"; else bad "the repaired wiring still refuses"; fi
assert_eq "the cash left the Vault that funded it" "$(q0 "$NEWV2" idle_reserves)" "$((FUND - MOVE))"
assert_eq "and the adapter it reached repays that same Vault" "$(q0 "$POOL2" vault)" "$NEWV2"
echo "  deallocate tx $(tx "$NEWE" deallocate --pool_id "$POOL2" --amount "$MOVE")"
assert_eq "and the position unwinds, which is what the pre-fix stack could not do" \
  "$(q0 "$NEWV2" idle_reserves)" "$FUND"
fi

# ---------------------------------------------------------------------------
if stage live; then
echo ""
echo "== the production deployment =="
echo "-- The real Circle USDC, the real Vault, the real adapters. Two claims:"
echo "-- the honest path still works with the extra check in it, and moving the"
echo "-- Vault pointer now refuses the next allocation instead of funding it."

assert_eq "the live Engine governs the live Vault" "$(q0 "$ENGINE" vault)" "$VAULT"
assert_eq "the live Vault authorizes the live Engine" "$(q0 "$VAULT" allocation_engine)" "$ENGINE"
assert_eq "the private credit adapter names both" "$(q0 "$PC" vault)" "$VAULT"
assert_eq "the book is empty to start with" "$(q0 "$ENGINE" total_allocated)" "0"

BEFORE=$(q0 "$VAULT" idle_reserves)
LIVE_MOVE=$(( $(q0 "$VAULT" free_reserves) / 4 ))
echo ""
echo "-- The honest path, on the production wiring. Borrowed and handed back."
echo "  allocate tx   $(tx "$ENGINE" allocate --admin "$ADMIN" --pool_id "$PC" --amount "$LIVE_MOVE")"
assert_eq "the Vault released it"  "$(q0 "$VAULT" idle_reserves)" "$((BEFORE - LIVE_MOVE))"
assert_eq "the adapter booked it"  "$(q0 "$PC" get_exposure)" "$LIVE_MOVE"
echo "  deallocate tx $(tx "$ENGINE" deallocate --pool_id "$PC" --amount "$LIVE_MOVE")"
assert_eq "and it came home to the stroop" "$(q0 "$VAULT" idle_reserves)" "$BEFORE"
assert_eq "leaving no exposure behind"     "$(q0 "$ENGINE" total_allocated)" "0"

echo ""
echo "-- Now the finding, on the live Engine. A throwaway Vault stands in for a"
echo "-- new generation; the registered adapters stay where they are."
STANDIN=$(deploy "$WASM/vault.wasm" --admin "$ADMIN" --usdc_token "$USDC")
echo "  stand-in vault $STANDIN"
echo "  set_vault tx   $(tx "$ENGINE" set_vault --admin "$ADMIN" --vault "$STANDIN")"
assert_eq "the live Engine now governs the stand-in" "$(q0 "$ENGINE" vault)" "$STANDIN"
assert_eq "and the registered adapter still names the real Vault" "$(q0 "$PC" vault)" "$VAULT"
refused 414 "the next allocation is refused with AdapterMismatch" \
  "$ENGINE" allocate --admin "$ADMIN" --pool_id "$PC" --amount "$LIVE_MOVE"
echo "  set_vault back tx $(tx "$ENGINE" set_vault --admin "$ADMIN" --vault "$VAULT")"
assert_eq "the Engine is back on the real Vault" "$(q0 "$ENGINE" vault)" "$VAULT"
assert_eq "and the real Vault's reserves never moved" "$(q0 "$VAULT" idle_reserves)" "$BEFORE"
assert_eq "the deployment is exactly where it started" "$(q0 "$ENGINE" total_allocated)" "0"
fi

echo ""
echo "== $PASS passed, $FAIL failed =="
[ "$FAIL" = 0 ]
