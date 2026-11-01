#!/usr/bin/env bash
# Put agUSD back on a classic Stellar asset, issued through its Stellar Asset
# Contract by the Vault.
#
# The mirror of deploy-sagusd-classic.sh, and it exists because the generation
# deployed on 2026-11-01 got this wrong. agUSD was replaced with agusd_core.wasm,
# a pure Soroban token, which the Vault accepts and which works for depositing
# and redeeming. What it cannot do is sit on an orderbook: the SDEX holds classic
# assets only. The generation before it was a classic asset for exactly that
# reason, so swapping in a contract token silently removed the venue the token
# trades on, and the market maker's offers were left quoting a retired asset.
#
# The order is the whole script, and it is the same order for the same reason.
# Hand the SAC's admin to the Vault, READ IT BACK, point the Vault at it, and
# only then lock the issuer. Locking first, or locking without checking, leaves
# an asset nobody can mint and whose admin nobody can move, because both need a
# signature the issuer no longer has. That is how the first sagUSD was lost.
#
#   bash scripts/deploy-agusd-classic.sh
#
# Preconditions: the Vault's current agUSD has zero supply, because set_agusd
# refuses to repoint a token that is still outstanding, with #333. Bring it to
# zero by redeeming, and unstake first if the staking contract holds any.
set -euo pipefail
cd "$(dirname "$0")/.."
NET=${NET:-testnet}
SRC=${SRC:-agama-poc}
DEP=deployments/testnet.json
j() { python3 -c "import json;d=json.load(open('$DEP'));print($1)"; }
ADMIN=$(stellar keys address "$SRC")
# Overridable, because this has to run against a Vault that has never taken a
# deposit and the record's Vault may already have. set_agusd is frozen by a
# cumulative deposit counter, not by the current balance, so a Vault that took
# one deposit and redeemed it is as frozen as one holding millions.
VAULT=${VAULT:-$(j "d['contracts']['vault']")}
GEN=${GEN:-3}
ISSUER_KEY=agusd-issuer$GEN
HOLDER_KEY=agusd-holder$GEN
q0() { stellar contract invoke --id "$1" --source "$SRC" --network "$NET" --send=no -- "${@:2}" 2>/dev/null | tr -d '"'; }

echo "== preconditions"
# A Vault that has never had set_agusd called answers nothing here, and that is
# the ideal state for this script rather than an error. Both probes need
# `|| true`: a bare assignment propagates the substitution's exit status, so
# asking an empty address for its supply is what kills the script under set -e,
# which is exactly what happened on the first run against a fresh Vault.
OLD=$(q0 "$VAULT" agusd || true)
echo "   vault  $VAULT"
if [ -z "$OLD" ]; then
  echo "   no agUSD set yet, which is the cleanest case: nothing to unwind"
else
  SUPPLY=$(q0 "$OLD" total_supply || true)
  echo "   agUSD  $OLD, supply ${SUPPLY:-unreadable}"
  [ "${SUPPLY:-x}" = "0" ] || {
    echo "   set_agusd refuses a token with supply outstanding (#333). Redeem it first."; exit 1; }
fi
DEPOSITS=$(q0 "$VAULT" deposits || true)
echo "   deposits taken so far: ${DEPOSITS:-unreadable}"
[ "${DEPOSITS:-x}" = "0" ] || {
  echo "   set_agusd is frozen by a cumulative deposit counter, not a balance (#312)."
  echo "   This Vault has taken a deposit, so its token pointer never thaws."
  echo "   Deploy a Vault that has not, and run this against it with VAULT=."; exit 1; }

echo "== the classic asset, and one unit paid out so it exists"
stellar keys generate "$ISSUER_KEY" --network "$NET" --fund >/dev/null 2>&1 || true
ISSUER=$(stellar keys address "$ISSUER_KEY")
stellar keys generate "$HOLDER_KEY" --network "$NET" --fund >/dev/null 2>&1 || true
HOLDER=$(stellar keys address "$HOLDER_KEY")
# Every step below needs the issuer's signature, so an issuer already locked at
# weight 0 has to stop this here rather than at the set_admin, which would leave
# a deployed SAC nobody can administer.
SW=$(curl -s "${HORIZON:-https://horizon-testnet.stellar.org}/accounts/$ISSUER" \
  | python3 -c "
import json,sys
a=json.load(sys.stdin)
print(max((s['weight'] for s in a['signers'] if s['key']==a['account_id']), default=1))" 2>/dev/null || echo 1)
[ "${SW:-1}" != "0" ] && : || {
  echo "   $ISSUER_KEY is locked at master weight 0 and cannot issue. Use GEN=$((GEN+1))."; exit 1; }
stellar tx new change-trust --source-account "$HOLDER_KEY" --line "agUSD:$ISSUER" --network "$NET" >/dev/null
stellar tx new payment --source-account "$ISSUER_KEY" --destination "$HOLDER" \
  --asset "agUSD:$ISSUER" --amount 10000000 --network "$NET" >/dev/null
echo "   issuer $ISSUER"

echo "== its Stellar Asset Contract"
SAC=$(stellar contract asset deploy --asset "agUSD:$ISSUER" --source-account "$ISSUER_KEY" --network "$NET" 2>/dev/null | tail -1 | tr -d '"')
printf '%s' "$SAC" | grep -qE '^C[A-Z2-7]{55}$' || { echo "   deploy returned '$SAC'"; exit 1; }
echo "   $SAC"

echo "== admin to the Vault, then read it back"
# One shot. The issuer can hand this over once, and after that the admin is a
# contract, so only that contract could hand it on. Neither the Vault nor the
# staking contract has an entry point that does, by design. An asset handed to
# the wrong contract is not recoverable, it is replaced, which is why GEN exists
# and why the first agUSD asset made here on 2026-11-01 is still sitting with a
# Vault that cannot use it.
stellar contract invoke --id "$SAC" --source "$ISSUER_KEY" --network "$NET" -- \
  set_admin --new_admin "$VAULT" >/dev/null
GOT=$(q0 "$SAC" admin)
[ "$GOT" = "$VAULT" ] || {
  echo "   admin is $GOT, expected $VAULT. Stopping BEFORE the lock:"
  echo "   locking now would leave this asset unmintable for good."; exit 1; }
echo "   verified"

echo "== set_agusd, which interrogates the token before accepting it"
stellar contract invoke --id "$VAULT" --source "$SRC" --network "$NET" -- \
  set_agusd --admin "$ADMIN" --agusd_token "$SAC" >/dev/null
NOW=$(q0 "$VAULT" agusd)
[ "$NOW" = "$SAC" ] || { echo "   set_agusd did not take, the Vault still names $NOW"; exit 1; }
echo "   verified"

echo "== the operator's trustline, so a deposit has somewhere to mint to"
stellar tx new change-trust --source-account "$SRC" --line "agUSD:$ISSUER" --network "$NET" >/dev/null 2>&1 || true
echo "   done"

echo "== burn the unit that brought the asset into existence"
# Supply the Vault never minted against USDC it holds. An uncounted unit makes
# every agUSD slightly under-backed, which is the same class of error the sagUSD
# ceremony found by reconciling against Horizon rather than by reasoning.
stellar contract invoke --id "$SAC" --source "$HOLDER_KEY" --network "$NET" -- \
  burn --from "$HOLDER" --amount 10000000 >/dev/null
# A Stellar Asset Contract has no total_supply entry point: the supply of a
# classic asset is the sum of its trustlines, which Horizon reports and the
# contract does not. Asking the contract killed this script under set -e on the
# line after a burn that had already succeeded, which is the third time in two
# days that a probe written to check a result destroyed the run that produced it.
AFTER=$(curl -s "${HORIZON:-https://horizon-testnet.stellar.org}/assets?asset_code=agUSD&asset_issuer=$ISSUER" \
  | python3 -c "
import json,sys
r=json.load(sys.stdin)['_embedded']['records']
if not r: print('0'); raise SystemExit
# Horizon reports a classic asset's supply under balances, split by
# authorization state, and has no 'amount' field on this endpoint. All three
# are summed: an unauthorized balance is still supply.
b=r[0]['balances']
print('%.7f' % sum(float(b[k]) for k in ('authorized','authorized_to_maintain_liabilities','unauthorized')))" 2>/dev/null || echo unreadable)
case "$AFTER" in
  0|0.0000000) echo "   burned, supply 0" ;;
  unreadable)  echo "   could not read the supply off Horizon, refusing to lock on a guess"; exit 1 ;;
  *)           echo "   supply is $AFTER after the burn, expected 0, refusing to lock"; exit 1 ;;
esac

echo "== lock the issuer, irreversible, and only now"
stellar tx new set-options --source-account "$ISSUER_KEY" --master-weight 0 --network "$NET" >/dev/null
echo "   locked: the Vault is the only address that can mint agUSD"

echo ""
echo "vault  $VAULT"
echo "sac    $SAC"
echo "issuer $ISSUER"
