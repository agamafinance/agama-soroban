#!/usr/bin/env bash
# The way home: sell the partner's shares, bring the USDC back to Stellar.
#
# This is the half of a user's claim that happens off Stellar. `unstake` and
# `request_withdrawal` burn sagUSD and agUSD on Stellar immediately, but the
# USDC that pays the queue is on an EVM chain inside a credit book, and getting
# it back is three steps that nothing on Stellar can trigger:
#
#   an ASK posted and settled by the partner's operator, which redeems shares
#   a CCTP burn towards domain 27
#   mint_and_forward on Stellar
#
# Only the last two are ours. The first is theirs, on their schedule, which is
# the whole reason Agama's withdrawal queue burns at request time and pays from
# a position in line rather than promising cash on demand.
#
# # The liquidity precondition, which is not a detail
#
# A redemption is paid in cash the vault holds, and most of the vault's assets
# are off chain with the fund administrator. So a NAV the administrator raised
# is a claim, not money, and the vault refuses a redemption it cannot fund
# rather than paying part of it. This script therefore has to bring cash back
# and write the book down before it can sell anything. On the real system those
# two calls are the partner's; here one key plays both sides, and the steps are
# labelled so nobody mistakes that for how it works in production.
#
# Needs: cast (foundry). Reads the counterparty from evm/deployments and the
# keys from evm/.env.local.
#
#   SHARES=10 bash scripts/e2e-evm-to-stellar.sh
set -uo pipefail
cd "$(dirname "$0")/.."
NET=${NET:-testnet}
SRC=${SRC:-agama-poc}
CCTP_CHAIN=${CCTP_CHAIN:-evmSepolia}
REC=evm/deployments/ethereum-sepolia.json
EVM_RPC=${EVM_RPC:-https://ethereum-sepolia-rpc.publicnode.com}
# Ethereum Sepolia charges about five times the gas foundry's local EVM
# estimates and an out of gas burns the whole limit, so every send here pins a
# limit rather than trusting an estimate.
GAS=${GAS:-20000000}
SHARES_WHOLE=${SHARES:-10}

k() { python3 -I -c "import json;print(json.load(open('$REC'))$1)"; }
VAULT=$(k "['contracts']['masterVault']")
ENGINE=$(k "['contracts']['matchingEngine']")
ORACLE=$(k "['contracts']['oracle']")
USDC=$(k "['contracts']['usdc']")
ME=$(k "['operator']")
KEY=$(grep '^SEPOLIA_DEPLOYER_KEY=' evm/.env.local | cut -d= -f2)
case "$KEY" in 0x*) ;; *) KEY="0x$KEY";; esac

pass=0; fail=0
ok(){ if [ -n "$2" ] && [ "$2" = "$3" ]; then printf '  PASS  %-48s %s\n' "$1" "$2"; pass=$((pass+1));
      else printf '  FAIL  %-48s expected %s, got %s\n' "$1" "$3" "${2:-<nothing>}"; fail=$((fail+1)); fi; }
die(){ printf '\n  %s\n' "$1"; exit 1; }
call(){ cast call "$@" --rpc-url "$EVM_RPC" 2>/dev/null | awk '{print $1}'; }

# Send, then wait for the account's nonce to move before returning.
#
# Without the wait, consecutive sends race: a public endpoint load balances over
# several nodes, so the nonce read for the second transaction can come from one
# that has not seen the first, and the send is rejected or silently replaced.
# That is what made an approve vanish here and the ASK three steps later fail
# with "insufficient allowance", which named the symptom and not the cause.
# Same fix as the burn leg in e2e-cctp-transfer.sh, for the same reason.
send(){
  local n0 out st n
  n0=$(cast nonce "$ME" --rpc-url "$EVM_RPC" 2>/dev/null)
  out=$(cast send "$@" --private-key "$KEY" --rpc-url "$EVM_RPC" --gas-limit "$GAS" 2>&1)
  st=$(printf '%s' "$out" | awk '/^status/{print $2}')
  for _ in $(seq 1 25); do
    n=$(cast nonce "$ME" --rpc-url "$EVM_RPC" 2>/dev/null)
    [ "${n:-0}" -gt "${n0:-0}" ] && break
    perl -e 'select(undef,undef,undef,2)'
  done
  printf '%s' "${st:-0}"
}

command -v cast >/dev/null || die "cast is not on PATH"
SHARES=$(python3 -I -c "print(int($SHARES_WHOLE * 10**6))")

echo "== the position"
HELD=$(call "$VAULT" 'balanceOf(address)(uint256)' "$ME")
[ "${HELD:-0}" -ge "$SHARES" ] || die "holding ${HELD:-0} shares, asked to sell $SHARES"
WORTH=$(call "$VAULT" 'convertToAssets(uint256)(uint256)' "$SHARES")
CASH=$(call "$VAULT" 'getAvailableAssets()(uint256)')
echo "  $SHARES shares are worth $WORTH, the vault holds $CASH in cash"

echo "== the partner's side: make the claim payable (testnet, one key plays both)"
if [ "${CASH:-0}" -lt "${WORTH:-0}" ]; then
  SHORT=$(( WORTH - CASH ))
  # Cash in and the book down. Doing one without the other leaves the vault
  # counting the same money twice, which is why they are adjacent here.
  send "$USDC" 'approve(address,uint256)' "$VAULT" "$SHORT" >/dev/null
  ok "the administrator returned the shortfall" "$(send "$VAULT" 'returnFromFund(uint256)' "$SHORT")" "1"
  NAV=$(call "$ORACLE" 'getLatestFundNav(address)(uint256)' "$VAULT")
  NEWNAV=$(( NAV - SHORT ))
  [ "$NEWNAV" -lt 0 ] && NEWNAV=0
  # One update per period, so a run inside the same period as the last one is
  # refused. That is the guard doing its job and not a failure of this script.
  send "$ORACLE" 'updateFundNav(address,uint256)' "$VAULT" "$NEWNAV" >/dev/null
  echo "  book written down from $NAV to $NEWNAV"
else
  echo "  the vault already holds enough cash, nothing to bring back"
fi

echo "== the ASK"
STATE=$(call "$ENGINE" 'engineState()(uint8)')
[ "${STATE:-0}" = "1" ] || send "$ENGINE" 'setEngineState()' >/dev/null
EXP=$(( $(date +%s) + 86400 )); SALT=0x$(openssl rand -hex 32)
Z=0x0000000000000000000000000000000000000000
Z32=0x0000000000000000000000000000000000000000000000000000000000000000
# orderType 1 is ASK. Price pinned to 10000, which is NAV: a price below it is a
# discount handed to the partner's treasury for nothing, and the keeper's
# permission set pins it for exactly that reason.
ORDER="((1,$VAULT,0,$SHARES,10000,$ME,$ME,$EXP,$SALT),($Z,$Z,0,0,0,$Z32,0x),$Z,0x)"
EMPTY="(((0,$Z,0,0,0,$Z,$Z,0,$Z32),($Z,$Z,0,0,0,$Z32,0x),$Z,0x),0)"
PSIG='postOrder(((uint8,address,uint256,uint256,uint256,address,address,uint256,bytes32),(address,address,uint256,uint256,uint256,bytes32,bytes),address,bytes),bool)'
MSIG='matchOrders((((uint8,address,uint256,uint256,uint256,address,address,uint256,bytes32),(address,address,uint256,uint256,uint256,bytes32,bytes),address,bytes),uint256),(((uint8,address,uint256,uint256,uint256,address,address,uint256,bytes32),(address,address,uint256,uint256,uint256,bytes32,bytes),address,bytes),uint256))'

USDC_BEFORE=$(call "$USDC" 'balanceOf(address)(uint256)' "$ME")
send "$VAULT" 'approve(address,uint256)' "$ENGINE" "$SHARES" >/dev/null
# Checked here rather than assumed. An approve that quietly did not land shows
# up at postOrder as "insufficient allowance", which is three steps from the
# thing that actually went wrong.
ok "the engine is approved over the shares" "$(call "$VAULT" 'allowance(address,address)(uint256)' "$ME" "$ENGINE")" "$SHARES"
ok "the ASK is posted" "$(send "$ENGINE" "$PSIG" "$ORDER" true)" "1"
ok "the shares are escrowed in the engine" "$(call "$ENGINE" 'tokenBalances(address,address)(uint256)' "$ME" "$VAULT")" "$SHARES"
send "$ENGINE" 'setEngineState()' >/dev/null
ok "the partner's operator settled it" "$(send "$ENGINE" "$MSIG" "$EMPTY" "($ORDER,$SHARES)")" "1"

# Reads straight after a write can hit a node that has not caught up, which has
# produced several false readings in this repository. Wait for the number to
# move rather than reading once.
USDC_AFTER="$USDC_BEFORE"
for _ in $(seq 1 20); do
  USDC_AFTER=$(call "$USDC" 'balanceOf(address)(uint256)' "$ME")
  [ "${USDC_AFTER:-0}" != "${USDC_BEFORE:-0}" ] && break
  perl -e 'select(undef,undef,undef,3)'
done
ok "the shares redeemed for their NAV value" "$(( ${USDC_AFTER:-0} - ${USDC_BEFORE:-0} ))" "$WORTH"
ok "no shares are left escrowed" "$(call "$ENGINE" 'tokenBalances(address,address)(uint256)' "$ME" "$VAULT")" "0"

echo
printf '  ASK leg: %s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ] || die "the ASK leg failed, nothing was bridged"

echo
echo "== the crossing home, handed to the suite that already proves it"
WHOLE=$(python3 -I -c "print(${WORTH} / 10**6)")
echo "  bridging $WHOLE USDC from $CCTP_CHAIN to Stellar"
exec env EVM_KEY="$KEY" CCTP_CHAIN="$CCTP_CHAIN" EVM_RPC="$EVM_RPC" GAS_LIMIT="$GAS" \
  AMOUNT="$WHOLE" SRC="$SRC" NET="$NET" bash scripts/e2e-cctp-transfer.sh
