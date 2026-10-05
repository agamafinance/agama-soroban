#!/usr/bin/env bash
# Parcours complet sur la generation 3, de l USDC a l USDC.
set -uo pipefail
NV=$(cat /tmp/agusd-newvault.txt); NS=$(cat /tmp/agusd-newstaking.txt)
SAC=$(cat /tmp/agusd-sac.txt); ISS=$(cat /tmp/agusd-issuer.txt)
U=CBIELTK6YBZJU5UP2WWQEUCYKLPU6AUNZ2BQ4WWFEIE3USCIHMXQDAMA
UISS=GBBD47IF6LWK7P7MDEVSCWR7DPUWV3NY3DTQEVFL4NAT4AQH3ZLLFLA5
R=CCJUD55AG6W5HAI5LRVNKAE5WDP5XGZBUDS5WNTIVDU7O264UZZE7BRD
ADMIN=GBSX2ZFLIJVE75VFWJURAXPSS4TBOV4FZ34VCRLWM2D7GKI37AD3FFNV
pass=0; fail=0
ok(){ if [ "$2" = "$3" ]; then printf '  PASS  %-46s %s\n' "$1" "$2"; pass=$((pass+1));
      else printf '  FAIL  %-46s attendu %s, obtenu %s\n' "$1" "$3" "$2"; fail=$((fail+1)); fi; }
bal(){ stellar contract invoke --id "$1" --source agama-poc --network testnet --send=no -- balance --id "$2" 2>/dev/null | tr -d '"'; }
rd(){ stellar contract invoke --id "$1" --source agama-poc --network testnet --send=no -- "$2" 2>/dev/null | tr -d '"'; }

echo "== mise en place"
stellar keys generate e2e-gen3 --network testnet --fund >/dev/null 2>&1
E=$(stellar keys address e2e-gen3)
stellar tx new change-trust --source-account e2e-gen3 --line "USDC:$UISS" --network testnet >/dev/null 2>&1
stellar tx new change-trust --source-account e2e-gen3 --line "agUSD:$ISS" --network testnet >/dev/null 2>&1
stellar contract invoke --id $U --source proof-user --network testnet -- transfer --from $(stellar keys address proof-user) --to "$E" --amount 600000000 >/dev/null 2>&1
ok "USDC de depart" "$(bal $U $E)" "600000000"

echo "== 1. depot: 60 USDC -> agUSD au pair"
stellar contract invoke --id $NV --source e2e-gen3 --network testnet -- deposit --from "$E" --amount 600000000 >/dev/null 2>&1
ok "agUSD emis, un pour un" "$(bal $SAC $E)" "600000000"
ok "USDC consomme" "$(bal $U $E)" "0"

echo "== 2. le meme solde, vu en classique"
H=$(curl -s "https://horizon-testnet.stellar.org/accounts/$E" | python3 -c "
import sys,json
for b in json.load(sys.stdin).get('balances',[]):
    if b.get('asset_code')=='agUSD': print(b['balance']); raise SystemExit
print('0')")
ok "Horizon voit le solde classique" "$H" "60.0000000"

echo "== 3. stake: 60 agUSD -> sagUSD"
stellar contract invoke --id $NS --source e2e-gen3 --network testnet -- stake --from "$E" --amount 600000000 >/dev/null 2>&1
ok "parts recues a 1.0" "$(bal $NS $E)" "600000000"
ok "taux initial" "$(rd $NS share_price)" "10000000"
ok "DeFindex, 1 part" "$(stellar contract invoke --id $NS --source agama-poc --network testnet --send=no -- get_asset_amounts_per_shares --vault_shares 10000000 2>/dev/null | tr -d '[]\"')" "10000000"

echo "== 4. rendement: 15 agUSD distribues"
stellar contract invoke --id $NV --source agama-poc --network testnet -- deposit --from $ADMIN --amount 150000000 >/dev/null 2>&1
stellar contract invoke --id $NS --source agama-poc --network testnet -- distribute_yield --amount 150000000 >/dev/null 2>&1
ok "NAV montee" "$(rd $NS nav)" "750000000"
ok "parts inchangees" "$(rd $NS total_supply)" "600000000"
ok "taux a 1.25" "$(rd $NS share_price)" "12500000"
ok "detenu == NAV, pas d excedent" "$(bal $SAC $NS)" "750000000"

echo "== 5. unstake: 60 parts -> 75 agUSD"
stellar contract invoke --id $NS --source e2e-gen3 --network testnet -- request_unstake --from "$E" --shares 600000000 >/dev/null 2>&1
ok "parts brulees" "$(rd $NS total_supply)" "0"
perl -e 'select(undef,undef,undef,65)'
stellar contract invoke --id $NS --source e2e-gen3 --network testnet -- claim --from "$E" >/dev/null 2>&1
ok "agUSD rendus, rendement compris" "$(bal $SAC $E)" "750000000"
ok "staking vide" "$(bal $SAC $NS)" "0"

echo "== 6. Soroswap: 10 agUSD -> USDC (critere D2)"
B=$(bal $U $E); DL=$(( $(date +%s) + 3600 ))
stellar contract invoke --id $R --source e2e-gen3 --network testnet -- swap_exact_tokens_for_tokens \
  --amount_in 100000000 --amount_out_min 90000000 --path "[\"$SAC\",\"$U\"]" --to "$E" --deadline $DL >/dev/null 2>&1
A=$(bal $U $E)
[ "$A" -gt "$B" ] && { printf '  PASS  %-46s %s stroops\n' "swap Soroswap execute" "$((A-B))"; pass=$((pass+1)); } \
                  || { printf '  FAIL  %-46s rien recu\n' "swap Soroswap execute"; fail=$((fail+1)); }

echo "== 7. SDEX: 10 agUSD -> USDC"
B=$(bal $U $E)
stellar tx new path-payment-strict-send --source-account e2e-gen3 --destination "$E" \
  --send-asset "agUSD:$ISS" --send-amount 100000000 --dest-asset "USDC:$UISS" --dest-min 90000000 --network testnet >/dev/null 2>&1
perl -e 'select(undef,undef,undef,6)'
A=$(bal $U $E)
[ "$A" -gt "$B" ] && { printf '  PASS  %-46s %s stroops\n' "path payment SDEX executee" "$((A-B))"; pass=$((pass+1)); } \
                  || { printf '  FAIL  %-46s rien recu\n' "path payment SDEX executee"; fail=$((fail+1)); }

echo "== 8. retrait du Vault: le reste en USDC"
REST=$(bal $SAC $E)
ID=$(stellar contract invoke --id $NV --source e2e-gen3 --network testnet -- request_withdrawal --from "$E" --amount "$REST" 2>/dev/null | tr -d '"' | tail -1)
ok "file alimentee" "$(rd $NV queue_length)" "1"
stellar contract invoke --id $NV --source e2e-gen3 --network testnet -- claim_withdrawal --from "$E" --claim_id "$ID" >/dev/null 2>&1
ok "agUSD entierement brule" "$(bal $SAC $E)" "0"
ok "file videe" "$(rd $NV queue_length)" "0"
echo ""
echo "  USDC final de l utilisateur : $(bal $U $E) stroops, pour 60 USDC deposes"
echo ""
echo "TOTAL : $pass reussis, $fail echoues"
[ "$fail" -eq 0 ]
