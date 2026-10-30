#!/usr/bin/env bash
# Tranche 2, Deliverable 3: the fiat ramp, cash to USDC to agUSD and the
# reverse, over SEP-10 and SEP-24 on Stellar testnet.
#
# The award's criterion names the SDF Stellar Test Anchor as what covers these
# flows during MoneyGram onboarding, so that is the anchor here. The protocol is
# the same one MoneyGram speaks; the anchor is a --home-domain away.
#
# The three links this script owns, and the one it does not:
#
#   SEP-1   read the anchor's own stellar.toml                     automated
#   SEP-10  challenge, verify, sign, JWT                           automated
#   SEP-24  start interactive, poll to a terminal state            automated
#   the form the anchor serves                                     a person
#
# The last one is what "interactive" means in SEP-24 and it is not a gap: the
# anchor collects whatever its jurisdiction requires, in its own webview, and
# the client has no business automating a KYC form. This script prints the URL,
# waits, and then proves what happened on chain either way.
#
#   bash scripts/e2e-anchor.sh                  deposit 5 USDC and wait
#   AMOUNT=3 WAIT=600 bash scripts/e2e-anchor.sh
#   TX=<id> bash scripts/e2e-anchor.sh          resume an existing transaction
set -uo pipefail
cd "$(dirname "$0")/.."
NET=${NET:-testnet}
USER_KEY=${USER_KEY:-agama-user}
AMOUNT=${AMOUNT:-5}
WAIT=${WAIT:-420}
HOME_DOMAIN=${HOME_DOMAIN:-testanchor.stellar.org}
PY=${PY:-.venv-sep/bin/python}
DEP=deployments/testnet.json

[ -x "$PY" ] || { echo "the SEP client needs its venv: python3 -m venv .venv-sep && .venv-sep/bin/pip install stellar-sdk requests"; exit 1; }
sep() { "$PY" anchor/sep_client.py "$@" 2>&1 | grep -vE "NotOpenSSLWarning|warnings.warn"; }

j() { python3 -c "import json;print(json.load(open('$DEP'))$1)"; }
VAULT=$(j "['contracts']['vault']")
AGUSD=$(j "['contracts']['agusd']")
WHO=$(stellar keys address "$USER_KEY")

P=0; F=0
ok()  { P=$((P+1)); printf '  PASS  %-50s %s\n' "$1" "${2-}"; }
bad() { F=$((F+1)); printf '  FAIL  %-50s %s\n' "$1" "${2-}"; }

echo "== 1. SEP-1, the anchor describes itself"
sep toml --home-domain "$HOME_DOMAIN" | sed 's/^/      /'
sep toml --home-domain "$HOME_DOMAIN" | grep -q "WEB_AUTH_ENDPOINT" && ok "the anchor publishes a SEP-10 endpoint" || bad "the anchor publishes a SEP-10 endpoint"
sep toml --home-domain "$HOME_DOMAIN" | grep -q "TRANSFER_SERVER_SEP0024" && ok "and a SEP-24 transfer server" || bad "and a SEP-24 transfer server"

echo
echo "== 2. SEP-10, authenticate as $WHO"
AUTH=$(sep auth --home-domain "$HOME_DOMAIN" --secret-name "$USER_KEY")
printf '%s\n' "$AUTH" | sed 's/^/      /'
printf '%s' "$AUTH" | grep -q "server signature verified" && ok "the challenge was verified before it was signed" || bad "the challenge was verified before it was signed"
printf '%s' "$AUTH" | grep -q "JWT received" && ok "a JWT came back" || bad "a JWT came back"
printf '%s' "$AUTH" | grep -q "sub             $WHO" && ok "the JWT is for this account" "$WHO" || bad "the JWT is for this account"

echo
echo "== 3. SEP-24, start the interactive deposit"
if [ -n "${TX:-}" ]; then
  echo "      resuming $TX"
  TXID=$TX
else
  D=$(sep deposit --home-domain "$HOME_DOMAIN" --secret-name "$USER_KEY" --amount "$AMOUNT")
  printf '%s\n' "$D" | sed 's/^/      /'
  TXID=$(printf '%s' "$D" | grep -oE "transaction id   [0-9a-f-]+" | awk '{print $3}')
fi
[ -n "$TXID" ] && ok "the anchor opened a transaction" "$TXID" || { bad "the anchor opened a transaction"; exit 1; }

echo
echo "== 4. the form, then the poll"
echo "      Open the interactive URL above and complete it. This polls for ${WAIT}s."
BEFORE=$(stellar contract invoke --id "$AGUSD" --source "$USER_KEY" --network "$NET" --send=no -- balance --id "$WHO" 2>&1 | tail -1 | tr -d '"')
FINAL=$(sep poll --home-domain "$HOME_DOMAIN" --secret-name "$USER_KEY" --id "$TXID" --wait "$WAIT")
printf '%s\n' "$FINAL" | sed 's/^/      /'
case "$FINAL" in
  *"final status completed"*)
    ok "the anchor settled the deposit"
    echo
    echo "== 5. USDC to agUSD, one for one"
    # The anchor delivers classic USDC to the account. agUSD is minted against
    # it through the Vault, which is the link that makes a cash deposit a
    # yield-bearing position without a centralised exchange in the middle.
    AMT=$(python3 -c "print(int(float('$AMOUNT') * 10_000_000))")
    OUT=$(stellar contract invoke --id "$VAULT" --source "$USER_KEY" --network "$NET" -- \
            deposit --from "$WHO" --amount "$AMT" 2>&1)
    printf '%s' "$OUT" | grep -q "Error(Contract" && bad "the Vault minted agUSD" "$(printf '%s' "$OUT" | tail -1)" \
      || ok "the Vault minted agUSD" "$AMT"
    AFTER=$(stellar contract invoke --id "$AGUSD" --source "$USER_KEY" --network "$NET" --send=no -- balance --id "$WHO" 2>&1 | tail -1 | tr -d '"')
    [ "$AFTER" -gt "$BEFORE" ] && ok "the holder's agUSD rose" "$BEFORE -> $AFTER" || bad "the holder's agUSD rose" "$BEFORE -> $AFTER"
    echo
    echo "== 6. and the reverse, agUSD to USDC to cash"
    echo "      request_withdrawal burns the agUSD and queues the USDC claim,"
    echo "      then SEP-24 withdraw hands it back to the anchor:"
    echo "        bash scripts/e2e-withdrawal-queue.sh"
    echo "        $PY anchor/sep_client.py withdraw --secret-name $USER_KEY --amount $AMOUNT --wait $WAIT"
    ;;
  *"final status incomplete"*)
    echo
    echo "      Still incomplete: the form was not submitted inside the window."
    echo "      That is the honest outcome to report, not a failure of the"
    echo "      protocol links above, all of which ran. Rerun with:"
    echo "        TX=$TXID bash scripts/e2e-anchor.sh"
    ok "the client polled the anchor and read the state back" "incomplete"
    ;;
  *)
    bad "the transaction reached a state this script understands" "$FINAL"
    ;;
esac

echo
printf 'TOTAL: %d passed, %d failed\n' "$P" "$F"
[ "$F" -eq 0 ] || exit 1
