#!/usr/bin/env bash
# The whole path on the live deployment, USDC to USDC, asserted at every step.
#
# Reads every address from the deployment record rather than from anywhere else.
# An earlier run of this work took an address from a scratch file in /tmp, the
# file was gone the next day, a deploy produced an empty address, and the step
# that followed was not checked. That cost an asset: the issuer was locked while
# it was still its own token's admin, so nobody can mint it or move its admin
# ever again. Hence both habits here: read the record, and assert each step
# before the next one depends on it.
set -uo pipefail
cd "$(dirname "$0")/.."
NET=${NET:-testnet}
SRC=${SRC:-agama-poc}
DEP=deployments/testnet.json
j() { python3 -c "import json;print(json.load(open('$DEP'))$1)"; }

VAULT=$(j "['contracts']['vault']")
STAKING=$(j "['contracts']['staking']")
AGUSD=$(j "['contracts']['agusd']")
USDC=$(j "['contracts']['usdc']")
AG_ISS=$(j "['agusdClassic']['issuer']")
SAG=$(j "['sagusdClassic']['sac']")
SAG_ISS=$(j "['sagusdClassic']['issuer']")
U_ISS=$(j "['usdcIssuer']")
ROUTER=CCJUD55AG6W5HAI5LRVNKAE5WDP5XGZBUDS5WNTIVDU7O264UZZE7BRD

pass=0; fail=0
ok(){ if [ "$2" = "$3" ]; then printf '  PASS  %-48s %s\n' "$1" "$2"; pass=$((pass+1));
      else printf '  FAIL  %-48s expected %s, got %s\n' "$1" "$3" "$2"; fail=$((fail+1)); fi; }
gt(){ if [ "$2" -gt "$3" ] 2>/dev/null; then printf '  PASS  %-48s %s\n' "$1" "$2"; pass=$((pass+1));
      else printf '  FAIL  %-48s %s not above %s\n' "$1" "$2" "$3"; fail=$((fail+1)); fi; }
bal(){ stellar contract invoke --id "$1" --source "$SRC" --network "$NET" --send=no -- balance --id "$2" 2>/dev/null | tr -d '"'; }
rd(){ stellar contract invoke --id "$1" --source "$SRC" --network "$NET" --send=no -- "$2" 2>/dev/null | tr -d '"'; }
# What Horizon says exists of a classic asset, every form of it summed. The only
# figure that can contradict a contract's own count of what it issued.
circulating(){ curl -s "https://horizon-testnet.stellar.org/assets?asset_code=$1&asset_issuer=$2" | python3 -c "
import sys,json
r=json.load(sys.stdin).get('_embedded',{}).get('records',[])
if not r: print(0); raise SystemExit
a=r[0]
print(int(round((sum(float(v) for v in a['balances'].values())+float(a['contracts_amount'])+float(a['liquidity_pools_amount'])+float(a['claimable_balances_amount']))*1e7)))"; }
classic(){ curl -s "https://horizon-testnet.stellar.org/accounts/$1" | python3 -c "
import sys,json
for b in json.load(sys.stdin).get('balances',[]):
    if b.get('asset_code')=='$2': print(b['balance']); raise SystemExit
print('0')"; }

echo "== setup"
# A fresh account per run. Reusing one carries the last run's balance into this
# run's assertions, which then pass or fail on history rather than on what this
# run did.
KEY=e2e-g3-$(date +%s)
stellar keys generate "$KEY" --network "$NET" --fund >/dev/null 2>&1
E=$(stellar keys address "$KEY")
for a in "USDC:$U_ISS" "agUSD:$AG_ISS" "sagUSD:$SAG_ISS"; do
  stellar tx new change-trust --source-account "$KEY" --line "$a" --network "$NET" >/dev/null 2>&1
done
# Funded from whichever test account still has enough, rather than one named
# here. The treasury is not a candidate: its balance is pledged to the
# orderbook, and a pledged balance is not free to Soroban either.
NEED=200000000
FUNDER=""
for cand in ${FUNDERS:-sag-user e2e-gen3 proof-user gen3-user sag-buyer dex-user}; do
  addr=$(stellar keys address "$cand" 2>/dev/null) || continue
  [ -n "$addr" ] || continue
  have=$(bal $USDC "$addr"); have=${have:-0}
  if [ "$have" -ge "$NEED" ] 2>/dev/null; then FUNDER=$cand; break; fi
done
[ -n "$FUNDER" ] || { echo "  no test account holds $NEED stroops of USDC; top one up and rerun"; exit 1; }
echo "  funded by $FUNDER"
stellar contract invoke --id "$USDC" --source "$FUNDER" --network "$NET" -- \
  transfer --from "$(stellar keys address $FUNDER)" --to "$E" --amount "$NEED" >/dev/null 2>&1
ok "starting USDC" "$(bal $USDC $E)" "$NEED"

echo "== 1. deposit 60 USDC, agUSD minted at par"
stellar contract invoke --id "$VAULT" --source "$KEY" --network "$NET" -- deposit --from "$E" --amount 200000000 >/dev/null 2>&1
ok "agUSD one for one" "$(bal $AGUSD $E)" "200000000"
ok "USDC spent" "$(bal $USDC $E)" "0"

echo "== 2. the same balance, seen as a classic asset"
ok "Horizon reports the trustline" "$(classic $E agUSD)" "20.0000000"

echo "== 3. stake, shares minted through the sagUSD SAC"
# This contract is not empty: the book keeper holds a position in it. So the
# assertions below are about the change this user causes, not about absolute
# totals, which would only hold on a contract nobody else uses.
SUP_BEFORE=$(rd $STAKING total_supply)
AG_BEFORE_STAKE=$(bal $AGUSD $E)
stellar contract invoke --id "$STAKING" --source "$KEY" --network "$NET" -- stake --from "$E" --amount 200000000 >/dev/null 2>&1
S=$(bal $SAG $E)
gt "sagUSD issued" "$S" "0"
ok "tracked supply matches Horizon" "$(rd $STAKING total_supply)" "$(circulating sagUSD $SAG_ISS)"
ok "sagUSD is classic too" "$(classic $E sagUSD)" "$(python3 -c "print('%.7f' % ($S/1e7))")"

echo "== 4. yield, the rate moves and the share count does not"
R0=$(rd $STAKING exchange_rate); SUP0=$(rd $STAKING total_supply)
stellar contract invoke --id "$USDC" --source "$FUNDER" --network "$NET" -- \
  transfer --from "$(stellar keys address $FUNDER)" --to "$(stellar keys address $SRC)" --amount 50000000 >/dev/null 2>&1
stellar contract invoke --id "$VAULT" --source "$SRC" --network "$NET" -- deposit --from "$(stellar keys address $SRC)" --amount 50000000 >/dev/null 2>&1
stellar contract invoke --id "$STAKING" --source "$SRC" --network "$NET" -- distribute_yield --amount 50000000 >/dev/null 2>&1
gt "rate rose" "$(rd $STAKING exchange_rate)" "$R0"
ok "no shares minted" "$(rd $STAKING total_supply)" "$SUP0"
ok "held equals NAV, no stray surplus" "$(bal $AGUSD $STAKING)" "$(rd $STAKING nav)"
ok "DeFindex agrees with the rate" "$(stellar contract invoke --id $STAKING --source $SRC --network $NET --send=no -- get_asset_amounts_per_shares --vault_shares 10000000 2>/dev/null | tr -d '[]\"')" "$(rd $STAKING exchange_rate)"

echo "== 5. unstake, shares burnt through the SAC"
stellar contract invoke --id "$STAKING" --source "$KEY" --network "$NET" -- request_unstake --from "$E" --shares "$S" >/dev/null 2>&1
ok "shares gone" "$(bal $SAG $E)" "0"
ok "supply back to where it started" "$(rd $STAKING total_supply)" "$SUP_BEFORE"
perl -e 'select(undef,undef,undef,65)'
stellar contract invoke --id "$STAKING" --source "$KEY" --network "$NET" -- claim --from "$E" >/dev/null 2>&1
gt "agUSD returned with the yield" "$(bal $AGUSD $E)" "$AG_BEFORE_STAKE"

echo "== 6. Soroswap, the Tranche 1 Deliverable 2 criterion"
B=$(bal $USDC $E); DL=$(( $(date +%s) + 3600 ))
stellar contract invoke --id "$ROUTER" --source "$KEY" --network "$NET" -- swap_exact_tokens_for_tokens \
  --amount_in 50000000 --amount_out_min 45000000 --path "[\"$AGUSD\",\"$USDC\"]" --to "$E" --deadline "$DL" >/dev/null 2>&1
gt "swap executed on the pool" "$(bal $USDC $E)" "$B"

echo "== 7. SDEX, the venue a Soroban-only token could not reach"
B=$(bal $USDC $E)
stellar tx new path-payment-strict-send --source-account "$KEY" --destination "$E" \
  --send-asset "agUSD:$AG_ISS" --send-amount 50000000 --dest-asset "USDC:$U_ISS" --dest-min 45000000 \
  --network "$NET" >/tmp/e2e-pp.log 2>&1 || sed -n '1,2p' /tmp/e2e-pp.log
perl -e 'select(undef,undef,undef,6)'
gt "path payment executed on the book" "$(bal $USDC $E)" "$B"

echo "== 8. circulation against backing, the two reconciliations"
# agUSD is minted one for one against USDC, so what exists of it and what the
# Vault holds have to be the same number. They were not at first: the payment
# that brings a classic asset into existence had left one unit in circulation
# that the Vault never took USDC for, and nothing noticed until this was
# written. The same shape on sagUSD, against the share count instead.
ok "agUSD in circulation equals the Vault's USDC" "$(circulating agUSD $AG_ISS)" "$(bal $USDC $VAULT)"
ok "sagUSD in circulation equals the tracked count" "$(circulating sagUSD $SAG_ISS)" "$(rd $STAKING total_supply)"

echo "== 9. redeem the rest through the Vault queue"
REST=$(bal $AGUSD $E)
ID=$(stellar contract invoke --id "$VAULT" --source "$KEY" --network "$NET" -- request_withdrawal --from "$E" --amount "$REST" 2>/dev/null | tr -d '"' | tail -1)
stellar contract invoke --id "$VAULT" --source "$KEY" --network "$NET" -- claim_withdrawal --from "$E" --claim_id "$ID" >/dev/null 2>&1
ok "agUSD fully burnt" "$(bal $AGUSD $E)" "0"
echo ""
echo "  user ends with $(bal $USDC $E) stroops of USDC, having deposited 20"
echo ""
echo "TOTAL: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
