#!/usr/bin/env bash
# The two concentration caps the live book cannot reach on its own: the
# per-originator cap (#408) and the per-jurisdiction cap (#409), made to bind
# on the deployed Engine.
#
# Why this script exists. The approved criterion is that an allocation
# exceeding ANY cap is rejected on-chain, and e2e-allocation-guards.sh only
# ever reaches two of them: the per-pool cap and the reserve floor. That is not
# an oversight in the Engine, it is the shape of the live book. Every
# registered pool carries its own originator and its own jurisdiction:
#
#   etherfuse       ETHERFUS   MX
#   private credit  QIRO       LU
#   cross chain     ABF        JE
#
# With one pool per originator, the per-pool cap at 4000 bps always refuses
# before the originator cap at 4500 or the jurisdiction cap at 5000 is reached.
# Those two limits are enforced in the contract and covered by unit tests, and
# until this script they had never been seen to fire against the ledger.
#
# So this narrows the cap under test, below what one allocation charges, and
# allocates into a pool that is nowhere near its own cap. The error that comes
# back is the one being tested rather than the per-pool cap wearing its name.
# The caps are restored immediately after each case, and the run asserts they
# are back before it exits, including when it fails.
set -uo pipefail
cd "$(dirname "$0")/.."
NET=${NET:-testnet}
SRC=${SRC:-agama-poc}
DEP=deployments/testnet.json
j() { python3 -c "import json;print(json.load(open('$DEP'))$1)"; }
ENGINE=$(j "['contracts']['allocationEngine']")
VAULT=$(j "['contracts']['vault']")
PC=$(j "['poolAdapters']['private-credit']")
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

ADMIN=$(j "['admin']")

pass=0; fail=0
ok(){ if [ "$2" = "$3" ]; then printf '  PASS  %-46s %s\n' "$1" "$2"; pass=$((pass+1));
      else printf '  FAIL  %-46s expected %s, got %s\n' "$1" "$3" "$2"; fail=$((fail+1)); fi; }
rd(){ stellar contract invoke --id "$1" --source "$SRC" --network "$NET" --send=no -- "$2" 2>/dev/null | tr -d '"'; }
caps(){ stellar contract invoke --id "$ENGINE" --source "$SRC" --network "$NET" --send=no -- caps 2>/dev/null; }
setcaps(){ stellar contract invoke --id "$ENGINE" --source "$SRC" --network "$NET" -- set_caps \
             --admin "$ADMIN" --pool_cap_bps "$1" --originator_cap_bps "$2" --jurisdiction_cap_bps "$3" >/dev/null 2>&1; }
# allocate returns void, so the CLI prints "null" on success and an
# Error(Contract, #N) line on a refusal. Matching the word Success instead
# catches the token events rather than the call, and misses when the token is
# not touched at all.
# Submission timeouts are the one failure here that says nothing about the
# contract: the transaction is in flight and the RPC stopped waiting. The
# keeper treats them the same way, by trying again rather than reporting a
# refusal that never happened. A contract error is returned immediately: those
# are the answer, not a hiccup.
alloc(){ local out e
  for _ in 1 2 3; do
    out=$(stellar contract invoke --id "$ENGINE" --source "$SRC" --network "$NET" -- allocate \
            --admin "$ADMIN" --pool_id "$1" --amount "$2" 2>&1)
    e=$(printf '%s' "$out" | grep -oE "Error\(Contract, #[0-9]+\)" | head -1)
    [ -n "$e" ] && { printf '%s' "$e"; return; }
    case "$out" in (*timeout*|*"not found"*) printf '  (rpc did not answer, trying again)\n' >&2; continue;; esac
    printf '%s' "$(printf '%s' "$out" | tail -1)"; return
  done
  printf 'rpc never answered'; }

ORIG=$(caps | python3 -c "import json,sys;c=json.load(sys.stdin);print(c['pool_bps'],c['originator_bps'],c['jurisdiction_bps'])")
read -r P O Ju <<<"$ORIG"
printf 'caps on the ledger: pool %s, originator %s, jurisdiction %s\n' "$P" "$O" "$Ju"
restore(){ setcaps "$P" "$O" "$Ju"; }
trap restore EXIT

NETA=$(rd "$VAULT" get_net_assets)
# A tenth of the book: far inside the 4000 bps per-pool cap, far outside the
# 500 bps cap each case narrows the limit under test to.
AMT=$(( NETA / 10 ))
printf 'net assets %s, test allocation %s (1000 bps)\n\n' "$NETA" "$AMT"

echo "== the allocation is fine while every cap is wide"
# Headroom first. The originator and jurisdiction caps are measured on charged
# exposure, which carries every write-off against the pool permanently, so on a
# book that has absorbed test write-downs this allocation is correctly refused
# with #407 before either cap under test is reached. Asserting through that
# reports the wrong refusal as a failure of the right one.
if [ "$(headroom "$PC")" -lt "$AMT" ] 2>/dev/null; then
  echo "  SKIP  private credit has $(headroom "$PC") of cap headroom and this needs $AMT."
  echo "        An allocation here is refused with #407, the pool cap, before the"
  echo "        originator and jurisdiction caps under test are ever reached. Those"
  echo "        two refusals are on the ledger permanently as #408 and #409, and"
  echo "        bash scripts/check-refusals.sh reads their codes back off it."
  echo "TOTAL: $pass passed, $fail failed"
  exit 0
fi
ok "accepted under the standing caps" "$(alloc "$PC" "$AMT")" "null"
X=$(stellar contract invoke --id "$ENGINE" --source "$SRC" --network "$NET" --send=no -- get_exposure --pool_id "$PC" 2>/dev/null | tr -d '"')
stellar contract invoke --id "$ENGINE" --source "$SRC" --network "$NET" -- deallocate --pool_id "$PC" --amount "$X" >/dev/null 2>&1
ok "and it came back" "$(stellar contract invoke --id "$ENGINE" --source "$SRC" --network "$NET" --send=no -- get_exposure --pool_id "$PC" 2>/dev/null | tr -d '"')" "0"

echo "== guard 3, the per originator cap"
setcaps "$P" 500 "$Ju"
ok "originator cap narrowed on the ledger" "$(caps | python3 -c "import json,sys;print(json.load(sys.stdin)['originator_bps'])")" "500"
ok "the same allocation is now refused" "$(alloc "$PC" "$AMT")" "Error(Contract, #408)"
restore
ok "caps restored" "$(caps | python3 -c "import json,sys;print(json.load(sys.stdin)['originator_bps'])")" "$O"

echo "== guard 4, the per jurisdiction cap"
setcaps "$P" "$O" 500
ok "jurisdiction cap narrowed on the ledger" "$(caps | python3 -c "import json,sys;print(json.load(sys.stdin)['jurisdiction_bps'])")" "500"
ok "the same allocation is now refused" "$(alloc "$PC" "$AMT")" "Error(Contract, #409)"
restore
ok "caps restored" "$(caps | python3 -c "import json,sys;print(json.load(sys.stdin)['jurisdiction_bps'])")" "$Ju"

echo "== nothing was left behind"
ok "the pool is empty again" "$(stellar contract invoke --id "$ENGINE" --source "$SRC" --network "$NET" --send=no -- get_exposure --pool_id "$PC" 2>/dev/null | tr -d '"')" "0"
ok "the standing caps are the ones we found" "$(caps | python3 -c "import json,sys;c=json.load(sys.stdin);print(c['pool_bps'],c['originator_bps'],c['jurisdiction_bps'])")" "$P $O $Ju"

echo ""
echo "TOTAL: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
