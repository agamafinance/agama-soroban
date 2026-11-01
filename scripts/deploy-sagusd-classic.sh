#!/usr/bin/env bash
# Move sagUSD onto a classic Stellar asset, issued through its Stellar Asset
# Contract by the staking contract.
#
# Why: a share token's fair price is a contract read, not something a market has
# to discover. A constant product pool quotes a token that only appreciates at
# yesterday's rate between trades, and the gap is taken by arbitrage out of the
# liquidity providers, so for sagUSD an orderbook is the right venue and an
# orderbook can only hold a classic asset.
#
# The order below is the whole script. Hand the SAC's admin to the staking
# contract, READ IT BACK, and only then lock the issuer. Locking first, or
# locking without checking, destroys the asset for good: nobody can mint it and
# nobody can move its admin, because both need a signature the issuer no longer
# has. That is not hypothetical, it is how the first sagUSD asset was lost, and
# it is why every step here is asserted rather than assumed.
set -euo pipefail
NET=${NET:-testnet}
SRC=${SRC:-agama-poc}
DEP=deployments/testnet.json
j() { python3 -c "import json;print(json.load(open('$DEP'))$1)"; }

ADMIN=$(j "['admin']")
AGUSD=${AGUSD:-$(j "['contracts'].get('agusdCore') or d['contracts']['agusd']")}
COOLDOWN=$(j "['cooldownSeconds']")
# GEN names the issuer and holder keys, because an asset is its code and its
# issuer together: a new share token for a new staking generation needs a new
# issuer, and the previous one cannot be reused. Its master weight is set to 0
# at the end of this script, deliberately, so it can never mint or move its
# admin again.
GEN=${GEN:-2}
ISSUER_KEY=sagusd-issuer$GEN
HOLDER_KEY=sagusd-holder$GEN

echo "== staking, three argument constructor: it has no share token yet"
if [ -n "${STAKING:-}" ]; then
  echo "   adopting the already deployed $STAKING"
  [ "$(stellar contract invoke --id "$STAKING" --source "$SRC" --network "$NET" --send=no -- agusd | tr -d '"')" = "$AGUSD" ] \
    || { echo "   that contract does not name $AGUSD as its agUSD"; exit 1; }
else
  STAKING=$(stellar contract deploy --wasm target/wasm32v1-none/release/staking.wasm \
    --source-account "$SRC" --network "$NET" -- \
    --admin "$ADMIN" --agusd "$AGUSD" --cooldown_seconds "$COOLDOWN" | tail -1)
  [ -n "$STAKING" ] || { echo "deploy produced no address"; exit 1; }
  echo "   $STAKING"
fi

echo "== classic sagUSD, and one unit paid out so the asset exists"
stellar keys generate "$ISSUER_KEY" --network "$NET" --fund >/dev/null 2>&1 || true
ISSUER=$(stellar keys address "$ISSUER_KEY")
stellar keys generate "$HOLDER_KEY" --network "$NET" --fund >/dev/null 2>&1 || true
HOLDER=$(stellar keys address "$HOLDER_KEY")
# An issuer whose weight is already 0 cannot sign anything below this line, and
# every step below needs its signature. Checked here rather than discovered at
# the set_admin, which would leave a deployed SAC nobody can administer.
W=$(curl -s "${HORIZON:-https://horizon-testnet.stellar.org}/accounts/$ISSUER" \
  | python3 -c "import json,sys;print(json.load(sys.stdin)['thresholds']['med_threshold'])" 2>/dev/null || echo 0)
SW=$(curl -s "${HORIZON:-https://horizon-testnet.stellar.org}/accounts/$ISSUER" \
  | python3 -c "
import json,sys
a=json.load(sys.stdin)
print(max((s['weight'] for s in a['signers'] if s['key']==a['account_id']), default=0))" 2>/dev/null || echo 1)
if [ "${SW:-1}" = "0" ]; then
  echo "   $ISSUER_KEY is already locked at master weight 0, so it cannot issue this asset."
  echo "   Run with GEN set to a number that has not been used: GEN=3 bash \$0"
  exit 1
fi
stellar tx new change-trust --source-account "$HOLDER_KEY" --line "sagUSD:$ISSUER" --network "$NET" >/dev/null
stellar tx new payment --source-account "$ISSUER_KEY" --destination "$HOLDER" \
  --asset "sagUSD:$ISSUER" --amount 10000000 --network "$NET" >/dev/null
echo "   issuer $ISSUER"

echo "== its Stellar Asset Contract"
SAC=$(stellar contract asset deploy --asset "sagUSD:$ISSUER" --source-account "$ISSUER_KEY" --network "$NET" | tail -1)
echo "   $SAC"

echo "== admin to the staking contract, then read it back"
stellar contract invoke --id "$SAC" --source "$ISSUER_KEY" --network "$NET" -- \
  set_admin --new_admin "$STAKING" >/dev/null
GOT=$(stellar contract invoke --id "$SAC" --source "$SRC" --network "$NET" --send=no -- admin | tr -d '"')
[ "$GOT" = "$STAKING" ] || {
  echo "   admin is $GOT, expected $STAKING. Stopping BEFORE the lock:"
  echo "   locking now would leave this asset unmintable for good."
  exit 1
}
echo "   verified"

echo "== set_shares, which refuses any token that does not name the contract back"
stellar contract invoke --id "$STAKING" --source "$SRC" --network "$NET" -- \
  set_shares --admin "$ADMIN" --shares_token "$SAC" >/dev/null
SH=$(stellar contract invoke --id "$STAKING" --source "$SRC" --network "$NET" --send=no -- shares | tr -d '"')
[ "$SH" = "$SAC" ] || { echo "   set_shares did not take"; exit 1; }
echo "   verified"

echo "== burn the unit that brought the asset into existence"
# That payment is supply the staking contract never issued and does not count,
# and an uncounted unit prices every share slightly too high, so a redemption
# pays more than its share of the assets. It is one unit and it was still worth
# measuring: the first time round the gap sat there until a reconciliation
# against Horizon found it.
stellar contract invoke --id "$SAC" --source "$HOLDER_KEY" --network "$NET" -- \
  burn --from "$HOLDER" --amount 10000000 >/dev/null
echo "   burned"

echo "== lock the issuer, irreversible, and only now"
stellar tx new set-options --source-account "$ISSUER_KEY" --master-weight 0 --network "$NET" >/dev/null
echo "   locked: the staking contract is the only address that can mint sagUSD"

echo ""
echo "staking $STAKING"
echo "sac     $SAC"
echo "issuer  $ISSUER"
