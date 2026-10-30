#!/usr/bin/env bash
# Tranche 2 on the live deployment: capital leaves the Vault through the Engine,
# both concentration and reserve guards refuse the call that should be refused,
# and everything comes back.
#
# Written because Tranche 2 was proven on a generation of contracts that has
# since been retired. The Engine and both adapters were redeployed when agUSD
# moved to a classic asset, and a redeployed contract has proven nothing: this
# one had total_allocated of zero, so the claim was true of an address nobody
# uses any more. Re-run it after any redeployment for the same reason.
#
# The two guards do not bind at the same time, and getting the floor to bind
# takes arranging for it. Each pool is capped at 40 percent, so one pool alone
# hits its own cap long before idle reserves approach the 25 percent floor. Both
# pools have to be driven near their caps first; only then is the floor the thing
# refusing the next call.
set -uo pipefail
cd "$(dirname "$0")/.."
NET=${NET:-testnet}
SRC=${SRC:-agama-poc}
DEP=deployments/testnet.json
j() { python3 -c "import json;print(json.load(open('$DEP'))$1)"; }
ENGINE=$(j "['contracts']['allocationEngine']")
VAULT=$(j "['contracts']['vault']")
PC=$(j "['poolAdapters']['private-credit']")
EF=$(j "['poolAdapters']['etherfuse']")
EF=${EF:-$(j "['poolAdapters']['etherfuse']")}
POOL_CAP_BPS=$(j "['engineConfig']['poolCapBps']")

# Which pool to drive the guards through.
#
# The three caps are measured on charged exposure, live plus everything ever
# written off against that pool and not recovered, and that charge is permanent
# because a write-down reopening a cap was a finding this Engine closed. So on a
# book that has absorbed test write-downs a pool can read zero live exposure and
# have no room at all, and an allocation into it is correctly refused with #407.
# Asserting through that reports the Engine failing to do something it was right
# to refuse.
#
# So the pool is chosen rather than assumed: the first registered one with room
# for what this run needs, preferring private credit because that is what these
# guards were written against. If none has room the run says so instead of
# failing, because a book with no headroom is an operational fact and not a
# defect in the Engine.
headroom() {
  local pool=$1 charged cap
  charged=$(stellar contract invoke --id "$ENGINE" --source "$SRC" --network "$NET" --send=no \
              -- charged_exposure --pool_id "$pool" 2>/dev/null | tr -d '"')
  cap=$(( $(stellar contract invoke --id "$VAULT" --source "$SRC" --network "$NET" --send=no \
              -- get_net_assets 2>/dev/null | tr -d '"') * POOL_CAP_BPS / 10000 ))
  echo $(( cap - ${charged:-0} ))
}
pick_pool() {   # pick_pool <amount needed> -> prints the pool, or nothing
  local need=$1 cand
  for cand in "$PC" "$EF"; do
    [ -n "$cand" ] || continue
    if [ "$(headroom "$cand")" -ge "$need" ] 2>/dev/null; then echo "$cand"; return; fi
  done
}

USDC=$(j "['contracts']['usdc']")
ADMIN=$(j "['admin']")

pass=0; fail=0
ok(){ if [ "$2" = "$3" ]; then printf '  PASS  %-46s %s\n' "$1" "$2"; pass=$((pass+1));
      else printf '  FAIL  %-46s expected %s, got %s\n' "$1" "$3" "$2"; fail=$((fail+1)); fi; }
rd(){ stellar contract invoke --id "$1" --source "$SRC" --network "$NET" --send=no -- "$2" 2>/dev/null | tr -d '"'; }
expo(){ stellar contract invoke --id "$ENGINE" --source "$SRC" --network "$NET" --send=no -- get_exposure --pool_id "$1" 2>/dev/null | tr -d '"'; }
err(){ stellar contract invoke --id "$ENGINE" --source "$SRC" --network "$NET" -- allocate \
        --admin "$ADMIN" --pool_id "$1" --amount "$2" 2>&1 | grep -oE "Error\(Contract, #[0-9]+\)|Success" | head -1; }

NETA=$(rd "$VAULT" get_net_assets)
CAP=$(( NETA * 4000 / 10000 ))
MAXDEP=$(( NETA * 7500 / 10000 ))
printf 'net assets %s, per pool cap %s, deployable before the floor %s\n\n' "$NETA" "$CAP" "$MAXDEP"
# Measured as deltas against whatever is already deployed, not against zero.
#
# This suite used to assert an empty book at the start and an empty book at the
# end, and it unwinds only the two pools it touches. So any other pool holding a
# position made five assertions fail at once and none of them was about this
# suite's subject: the cross chain pool had 10 USDC outstanding and the guards
# themselves, the cap and the floor, went on passing underneath the noise. An
# empty protocol is also a state that stops recurring the moment this is real.
BASE_ENGINE=$(rd $ENGINE total_allocated)
BASE_VAULT=$(rd $VAULT deployed_capital)
# Per pool as well as in total. This suite used to end by emptying the two
# pools it touches, which is the same thing as the baseline only while the
# baseline is zero. Leave a standing allocation in either pool, the way a book
# with positions on it looks, and the closing assertions failed on the book
# this suite had just wiped rather than on anything it was testing.
BASE_PC=$(expo $PC); BASE_EF=$(expo $EF)
# And the pool's own USDC balance, for the same reason: a pool that already
# holds a position holds that much more than this run put there.
BASE_PC_USDC=$(stellar contract invoke --id "$USDC" --source "$SRC" --network "$NET" --send=no -- balance --id "$PC" 2>/dev/null | tr -d '"')
BASE_PC_USDC=${BASE_PC_USDC:-0}
printf '  baseline: engine %s, vault %s\n' "$BASE_ENGINE" "$BASE_VAULT"
# The invariant that matters at the start is not that the book is empty, it is
# that the Engine's book and the Vault's agree about what is deployed.
ok "the two books agree at the start" "$BASE_ENGINE" "$BASE_VAULT"

echo "== capital out through the Engine"
MOVE=10000000000
GUARD_POOL=$(pick_pool "$MOVE")
if [ -z "$GUARD_POOL" ]; then
  echo "  SKIP  no registered pool has $MOVE of cap headroom left:"
  printf '        private credit %s, etherfuse %s, against a %s bps cap\n' \
    "$(headroom "$PC")" "$(headroom "$EF")" "$POOL_CAP_BPS"
  echo "        That charge is accumulated write-offs and it is permanent by"
  echo "        design. The Engine refusing here is the guard working, so the"
  echo "        guards below are skipped rather than asserted through a #407."
  echo "TOTAL: $pass passed, $fail failed"
  exit 0
fi
# Deliberately not retargeted at another pool. The baselines above were taken
# on this one, and swapping the pool underneath them makes the closing
# assertions compare a restored book against a baseline that was never its own.
# The guards are about the Engine, not about which pool it refuses for.
if [ "$GUARD_POOL" != "$PC" ]; then
  echo "  SKIP  private credit has no cap headroom left, $(headroom "$PC") against"
  printf '        a %s bps cap, so an allocation into it is correctly refused\n' "$POOL_CAP_BPS"
  echo "        with #407 and the guards below cannot be armed on this book."
  echo "        The refusals themselves are on the ledger permanently and"
  echo "        bash scripts/check-refusals.sh reads their codes back."
  echo "TOTAL: $pass passed, $fail failed"
  exit 0
fi
ok "first allocation accepted" "$(err $PC $MOVE)" "Success"
ok "the Engine booked it" "$(( $(rd $ENGINE total_allocated) - BASE_ENGINE ))" "10000000000"
ok "the Vault booked the same" "$(( $(rd $VAULT deployed_capital) - BASE_VAULT ))" "10000000000"
ok "the pool holds the USDC" "$(( $(stellar contract invoke --id $USDC --source $SRC --network $NET --send=no -- balance --id $PC 2>/dev/null | tr -d '\"') - BASE_PC_USDC ))" "10000000000"

echo "== guard 1, the per pool concentration cap"
ok "over cap on one pool refused" "$(err $PC $(( CAP )) )" "Error(Contract, #407)"

echo "== guard 2, the reserve floor"
# Both pools up near their caps, so that the floor is what refuses the next one
# rather than a cap. Ten USDC of headroom left on each so neither cap binds.
err "$PC" $(( CAP - $(expo $PC) - 100000000 )) >/dev/null
err "$EF" $(( MAXDEP - $(rd $VAULT deployed_capital) - 100000000 )) >/dev/null
printf '  deployed now %s against a ceiling of %s\n' "$(rd $VAULT deployed_capital)" "$MAXDEP"
ok "the step that breaches the floor refused" "$(err $EF 200000000)" "Error(Contract, #410)"

echo "== and it all comes back"
unwind(){ # back down to where this pool started, not to zero
  local X; X=$(expo "$1"); local DELTA=$(( ${X:-0} - $2 ))
  [ "$DELTA" -gt 0 ] 2>/dev/null && \
    stellar contract invoke --id "$ENGINE" --source "$SRC" --network "$NET" -- \
      deallocate --pool_id "$1" --amount "$DELTA" >/dev/null 2>&1
  return 0; }
unwind "$PC" "$BASE_PC"
unwind "$EF" "$BASE_EF"
ok "the Engine is back to its baseline" "$(rd $ENGINE total_allocated)" "$BASE_ENGINE"
ok "the Vault is back to its baseline" "$(rd $VAULT deployed_capital)" "$BASE_VAULT"
# Free reserves are idle less what is owed, and the two are equal only while
# nothing is queued. A claim left by another suite made this fail by exactly
# that claim, which says nothing about the guards this suite tests: the
# invariant is the subtraction, so that is what is asserted.
ok "reserves whole again" "$(rd "$VAULT" free_reserves)" \
   "$(( $(rd "$VAULT" idle_reserves) - $(rd "$VAULT" outstanding_liabilities) ))"
echo ""
echo "TOTAL: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
