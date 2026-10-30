#!/usr/bin/env bash
# Make sure this account holds enough USDC to run, by redeeming its own agUSD.
#
# These suites deposit USDC and receive agUSD, and most of them do not redeem it
# back. Run one after another, the account ends up holding the value in agUSD
# and reporting almost no USDC, so the next suite stops and points at Circle's
# faucet. The faucet is not the problem: the money is in the Vault, the account
# holds the claim on it, and redeeming is a call away.
#
# So it settles the queue first, which delivers claims already owed, and then
# redeems agUSD for the shortfall if there is still one. Both are ordinary user
# actions on this account's own position. It stops and points at the faucet only
# when the account genuinely has neither the USDC nor the agUSD.
#
# One thing it has to measure carefully, because it did not and this is what
# that looked like. For a classic asset the SAC's `balance` returns the
# trustline's balance, and a trustline's balance includes whatever its own open
# SDEX offers have locked as selling liabilities. The sagUSD market maker
# (keeper-sagusd-book.sh) posts USDC-side offers from this same account, so
# `balance` read 1013.85 USDC while 1013.59 of it was committed to offers and
# 0.26 was spendable. Every suite that asked this helper for working capital was
# told it had plenty, and then every transfer failed with BalanceError, 10,
# reported as "got 0" and looking exactly like a protocol failure.
#
# So the number that decides whether a transfer will go through is balance minus
# selling liabilities, and that is the number this helper uses.
#
#   ensure_usdc <vault> <usdc> <agusd> <need> <source> <network> <admin>
#     0  the account holds at least <need> spendable
#     2  it does not, and cannot get there from what it holds
MIN_WITHDRAWAL=10000000  # 1 agUSD, the Vault's anti-dust floor

ensure_usdc() {
  local VAULT=$1 USDC=$2 AGUSD=$3 NEED=$4 SRC=$5 NET=$6 ADMIN=$7
  local bal ag short want i

  _eu_q() { stellar contract invoke --id "$1" --source "$SRC" --network "$NET" --send=no -- "${@:2}" 2>/dev/null | tr -d '"'; }
  # Spendable, not held: balance less what this account's own open offers have
  # locked. Horizon is the only place that reports liabilities, so this reads
  # Horizon for a classic asset and falls back to the contract balance for an
  # asset that has no trustline to read.
  _eu_spendable() {
    local code issuer horizon out
    case "$NET" in (testnet) horizon=https://horizon-testnet.stellar.org;; (*) horizon=https://horizon.stellar.org;; esac
    out=$(curl -s --max-time 20 "$horizon/accounts/$ADMIN" | ADMIN="$ADMIN" python3 -c "
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(1)
for b in d.get('balances', []):
    if b.get('asset_code') == 'USDC':
        bal = float(b['balance']); sell = float(b.get('selling_liabilities', 0) or 0)
        print(int(round(max(0.0, bal - sell) * 10_000_000)))
        break
" 2>/dev/null)
    case "$out" in (*[!0-9]*|"") _eu_q "$USDC" balance --id "$ADMIN";; (*) echo "$out";; esac
  }
  # Only report a hash when the call actually succeeded. Scraping any 64-hex
  # string out of combined output prints one from a diagnostic event on failure
  # too, which is how a redemption that never reached the ledger came back with
  # a transaction hash beside it.
  _eu_tx() {
    local out
    if out=$(stellar contract invoke --id "$1" --source "$SRC" --network "$NET" -- "${@:2}" 2>&1); then
      echo "$out" | grep -oE '[0-9a-f]{64}' | head -1
      return 0
    fi
    echo "failed: $(echo "$out" | grep -oE 'Error\(Contract, #[0-9]+\)|TxBadSeq|error:.*' | head -1)"
    return 1
  }

  bal=$(_eu_spendable)
  [ "${bal:-0}" -ge "$NEED" ] && return 0

  # shellcheck source=lib-settle-queue.sh
  . "$(dirname "${BASH_SOURCE[0]}")/lib-settle-queue.sh"
  settle_queue "$VAULT" "$SRC" "$NET"
  bal=$(_eu_spendable)
  [ "${bal:-0}" -ge "$NEED" ] && return 0

  short=$((NEED - bal))
  ag=$(_eu_q "$AGUSD" balance --id "$ADMIN")
  local held locked
  held=$(_eu_q "$USDC" balance --id "$ADMIN")
  locked=$(( ${held:-0} - ${bal:-0} ))
  echo "  spendable ${bal} USDC and needs ${NEED}, short ${short}; holds ${ag} agUSD"
  if [ "$locked" -gt 0 ]; then
    echo "  of the ${held} it holds, ${locked} is locked by its own open SDEX offers."
    echo "  That is the sagUSD market maker. Freeing it is a choice, not a faucet:"
    echo "    curl -s $( [ "$NET" = testnet ] && echo https://horizon-testnet.stellar.org || echo https://horizon.stellar.org )/accounts/$ADMIN/offers"
    echo "    stellar tx new manage-sell-offer --offer-id <id> --amount 0 ..."
  fi
  if [ "${ag:-0}" -lt "$short" ]; then
    echo "  not enough agUSD to redeem the shortfall either"
    return 2
  fi
  # Redeem at least the anti-dust floor, and round up to it when the shortfall
  # is smaller, because a request under the floor is refused outright.
  want=$short
  [ "$want" -lt "$MIN_WITHDRAWAL" ] && want=$MIN_WITHDRAWAL
  [ "$want" -gt "${ag:-0}" ] && want=$ag
  if ! echo "  redeeming ${want} agUSD for USDC   tx $(_eu_tx "$VAULT" request_withdrawal --from "$ADMIN" --amount "$want")" | grep -q '[0-9a-f]\{64\}'; then
    echo "  the redemption did not reach the ledger, so nothing was recovered"
    return 2
  fi
  # The request has to be in a ledger before a settle can see it. Issued back to
  # back, the settle is simulated against a view where the queue is still empty
  # and comes back QueueEmpty, so this waits and retries rather than treating
  # the first refusal as the answer.
  for ((i = 0; i < 12; i++)); do
    sleep 3
    _eu_tx "$VAULT" settle_withdrawal >/dev/null 2>&1
    bal=$(_eu_q "$USDC" balance --id "$ADMIN")
    [ "${bal:-0}" -ge "$NEED" ] && break
  done
  bal=$(_eu_q "$USDC" balance --id "$ADMIN")
  echo "  holds ${bal} USDC now"
  [ "${bal:-0}" -ge "$NEED" ] && return 0
  return 2
}
