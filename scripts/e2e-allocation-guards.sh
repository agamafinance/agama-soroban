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
ok "nothing deployed at the start" "$(rd $VAULT deployed_capital)" "0"

echo "== capital out through the Engine"
ok "first allocation accepted" "$(err $PC 10000000000)" "Success"
ok "the Engine booked it" "$(rd $ENGINE total_allocated)" "10000000000"
ok "the Vault booked the same" "$(rd $VAULT deployed_capital)" "10000000000"
ok "the pool holds the USDC" "$(stellar contract invoke --id $USDC --source $SRC --network $NET --send=no -- balance --id $PC 2>/dev/null | tr -d '\"')" "10000000000"

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
for p in "$PC" "$EF"; do
  X=$(expo "$p")
  [ "${X:-0}" -gt 0 ] 2>/dev/null && \
    stellar contract invoke --id "$ENGINE" --source "$SRC" --network "$NET" -- \
      deallocate --pool_id "$p" --amount "$X" >/dev/null 2>&1
done
ok "Engine book empty" "$(rd $ENGINE total_allocated)" "0"
ok "Vault book empty" "$(rd $VAULT deployed_capital)" "0"
ok "reserves whole again" "$(rd $VAULT free_reserves)" "$(rd $VAULT idle_reserves)"
echo ""
echo "TOTAL: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
