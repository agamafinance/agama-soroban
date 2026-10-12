#!/usr/bin/env bash
# USDC out of Stellar and into the EVM, start to finish.
#
# This is the direction the protocol needs and the one that did not exist.
# Deposits land on Stellar; the yield is earned in a credit book on an EVM
# chain. So reserves have to leave Stellar before anything is earned at all,
# and e2e-cctp-transfer.sh only ever proved the way in.
#
# What is different going this way, and it is not symmetric:
#
#   the allowance is the first gate. deposit_for_burn pulls through
#   transfer_from, so the Stellar account must approve the TokenMessengerMinter
#   on the USDC SAC, with an expiration_ledger. Skip it and the call fails in
#   simulation with Error(Contract, #9), and the only place the reason appears
#   is a diagnostic event reading "not enough allowance to spend". The inbound
#   direction never needs this, which is exactly why it is easy to miss.
#
#   no hook, and no forwarder. Those exist because Stellar needs a contract to
#   receive and forward. An EVM destination mints straight to an address, so
#   this calls deposit_for_burn and sets mintRecipient to the recipient's own
#   20 byte address left padded to 32. The trap that cost 2 USDC twice on the
#   way in does not apply on the way out.
#
# What arrives is still not what was sent. 7 decimals on Stellar against 6 on
# the EVM, plus Circle's fee, so the landed amount is read from the attestation
# and from the recipient's balance rather than computed from the burn.
#
# Needs: cast (foundry), and a Stellar key with USDC. RECIPIENT is the EVM
# address to mint to and defaults to the deployer recorded in evm/.env.local.
#
#   AMOUNT=50 RECIPIENT=0x... bash scripts/e2e-stellar-to-evm.sh
#
# Ethereum Sepolia charges roughly five times the gas foundry's local EVM
# estimates, and an out of gas burns the whole limit, so the receive leg sets an
# explicit limit well above any estimate rather than trusting one.
set -uo pipefail
cd "$(dirname "$0")/.."
NET=${NET:-testnet}
SRC=${SRC:-agama-poc}
DEP=deployments/testnet.json
AMOUNT=${AMOUNT:-1}
CHAIN=${CHAIN:-evmSepolia}

j() { python3 -I -c "import json;print(json.load(open('$DEP'))$1)"; }
TM=$(j "['cctp']['stellar']['tokenMessengerMinter']")
USDC_S=$(j "['contracts']['usdc']")
DST_DOMAIN=$(j "['cctp']['$CHAIN']['domain']")
MT_EVM=$(j "['cctp']['$CHAIN']['messageTransmitterV2']")
USDC_EVM=$(j "['cctp']['$CHAIN']['usdc']")
IRIS=$(j "['cctp']['attestation']")
SRC_DOMAIN=$(j "['cctp']['stellar']['domain']")
EVM_RPC=${EVM_RPC:-https://ethereum-sepolia-rpc.publicnode.com}
GAS=${GAS:-20000000}

pass=0; fail=0
# An assertion whose observed value is empty is a broken probe, not a pass.
# A previous suite reported PASS comparing two empty strings.
ok(){ if [ -n "$2" ] && [ "$2" = "$3" ]; then printf '  PASS  %-48s %s\n' "$1" "$2"; pass=$((pass+1));
      else printf '  FAIL  %-48s expected %s, got %s\n' "$1" "$3" "${2:-<nothing>}"; fail=$((fail+1)); fi; }
die(){ printf '\n  %s\n' "$1"; exit 1; }

command -v cast >/dev/null || die "cast is not on PATH, try export PATH=\$HOME/.foundry/bin:\$PATH"
ME=$(stellar keys address "$SRC") || die "no such key $SRC"
RECIPIENT=${RECIPIENT:-$(grep '^SEPOLIA_DEPLOYER_ADDR=' evm/.env.local 2>/dev/null | cut -d= -f2)}
[ -n "$RECIPIENT" ] || die "set RECIPIENT to the EVM address to mint to"

UNITS=$(python3 -I -c "print(int($AMOUNT * 10**7))")       # Stellar USDC is 7 decimals
MAXFEE=$(( UNITS / 1000 > 0 ? UNITS / 1000 : 1 ))
MINTRECIP=$(python3 -I -c "
r = '$RECIPIENT'.lower().removeprefix('0x')
assert len(r) == 40, r
print(r.rjust(64, '0'))")
ZERO32=$(python3 -I -c "print('0'*64)")

echo "== before"
BEFORE_S=$(stellar contract invoke --id "$USDC_S" --source "$SRC" --network "$NET" --send=no -- \
  balance --id "$ME" 2>/dev/null | tr -d '"')
BEFORE_E=$(cast call "$USDC_EVM" 'balanceOf(address)(uint256)' "$RECIPIENT" --rpc-url "$EVM_RPC" 2>/dev/null | awk '{print $1}')
echo "  $ME holds $BEFORE_S (7dp) on Stellar"
echo "  $RECIPIENT holds ${BEFORE_E:-0} (6dp) on the destination"
# The recipient's 32 bytes, decoded back into an address, must be the address we
# meant. A padding mistake is unrecoverable and silent, so it is caught here.
ok "mintRecipient round trips to the recipient" \
  "$(python3 -I -c "print('0x' + '$MINTRECIP'[24:])")" "$(python3 -I -c "print('$RECIPIENT'.lower())")"

echo "== the allowance, which is the gate the inbound direction never needs"
SEQ=$(curl -s -X POST "${RPC:-https://soroban-testnet.stellar.org}" -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","id":1,"method":"getLatestLedger"}' \
  | python3 -I -c "import sys,json;print(json.load(sys.stdin)['result']['sequence'])")
[ -n "$SEQ" ] || die "the RPC did not answer with a ledger"
stellar contract invoke --id "$USDC_S" --source "$SRC" --network "$NET" -- \
  approve --from "$ME" --spender "$TM" --amount "$UNITS" --expiration_ledger "$(( SEQ + 100000 ))" >/dev/null 2>&1
ALLOW=$(stellar contract invoke --id "$USDC_S" --source "$SRC" --network "$NET" --send=no -- \
  allowance --from "$ME" --spender "$TM" 2>/dev/null | tr -d '"')
ok "the TokenMessengerMinter is approved" "$ALLOW" "$UNITS"

echo "== the burn on Stellar"
OUT=$(stellar contract invoke --id "$TM" --source "$SRC" --network "$NET" -- \
  deposit_for_burn --caller "$ME" --amount "$UNITS" --destination_domain "$DST_DOMAIN" \
  --mint_recipient "$MINTRECIP" --burn_token "$USDC_S" --destination_caller "$ZERO32" \
  --max_fee "$MAXFEE" --min_finality_threshold 1000 2>&1)
BURN=$(printf '%s' "$OUT" | grep -oE 'Signing transaction: [a-f0-9]+' | awk '{print $3}')
[ -n "$BURN" ] || die "the burn was refused: $(printf '%s' "$OUT" | tail -4)"
ok "the burn is on chain" "$([ -n "$BURN" ] && echo mined)" "mined"
echo "  burn tx $BURN"
AFTER_S=$(stellar contract invoke --id "$USDC_S" --source "$SRC" --network "$NET" --send=no -- \
  balance --id "$ME" 2>/dev/null | tr -d '"')
ok "Stellar fell by exactly the burned units" "$(( BEFORE_S - AFTER_S ))" "$UNITS"

echo "== Circle's attestation"
# The burn is permanent and so is the attestation, so a run that dies here has
# lost nothing: the same hash finishes the EVM leg later.
ATT=""
for i in $(seq 1 60); do
  R=$(curl -s "$IRIS/messages/$SRC_DOMAIN?transactionHash=$BURN")
  if printf '%s' "$R" | python3 -I -c "
import sys, json
b = json.load(sys.stdin)
m = (b.get('messages') or [None])[0]
raise SystemExit(0 if m and m.get('status') == 'complete' else 1)
" 2>/dev/null; then
    printf '%s' "$R" | python3 -I -c "
import sys, json
m = json.load(sys.stdin)['messages'][0]
open('/tmp/s2e-msg.hex','w').write(m['message'])
open('/tmp/s2e-att.hex','w').write(m['attestation'])
d = m.get('decodedMessage') or {}
b = d.get('decodedMessageBody') or {}
open('/tmp/s2e-meta','w').write('%s %s %s' % (d.get('destinationDomain'), b.get('mintRecipient'), b.get('amount')))
"
    ATT=yes; echo "  attested after ~$(( i * 5 ))s"; break
  fi
  perl -e 'select(undef,undef,undef,5)'
done
ok "Circle attested the burn" "$([ -n "$ATT" ] && echo complete)" "complete"
[ -n "$ATT" ] || die "no attestation, finish later with burn tx $BURN"
read -r ATT_DOMAIN ATT_RECIP ATT_AMOUNT < /tmp/s2e-meta
ok "attested to the domain we asked for" "$ATT_DOMAIN" "$DST_DOMAIN"
ok "attested to the recipient we meant" "$(python3 -I -c "print('$ATT_RECIP'.lower())")" \
  "$(python3 -I -c "print('$RECIPIENT'.lower())")"
# 7 decimals to 6 is a factor of ten and the fee comes off the top, so the
# attested amount is never the burned amount and must not be assumed equal.
ok "the 7 to 6 decimal rescale happened" "$([ "$ATT_AMOUNT" -lt "$UNITS" ] && echo yes)" "yes"
echo "  burned $UNITS at 7dp, attested $ATT_AMOUNT at 6dp"

echo "== the EVM leg"
RECV=$(cast send "$MT_EVM" 'receiveMessage(bytes,bytes)' \
  "$(cat /tmp/s2e-msg.hex)" "$(cat /tmp/s2e-att.hex)" \
  --private-key "${EVM_KEY:-$(grep '^SEPOLIA_DEPLOYER_KEY=' evm/.env.local | cut -d= -f2)}" \
  --rpc-url "$EVM_RPC" --gas-limit "$GAS" --json 2>/tmp/s2e-recv.err \
  | python3 -I -c "
import sys, json
t = sys.stdin.read().strip()
if not t: raise SystemExit
r = json.loads(t)
print(r['transactionHash'] if r.get('status') == '0x1' else '')
")
[ -n "$RECV" ] || die "receiveMessage was refused: $(tail -3 /tmp/s2e-recv.err)"
ok "receiveMessage succeeded" "$([ -n "$RECV" ] && echo mined)" "mined"

# Reads straight after a write can hit a node that has not caught up. This has
# produced three false readings in this repository already, including a balance
# of zero against a mint that had landed. So wait for the number to move rather
# than reading once and believing it.
AFTER_E="${BEFORE_E:-0}"
for _ in $(seq 1 20); do
  AFTER_E=$(cast call "$USDC_EVM" 'balanceOf(address)(uint256)' "$RECIPIENT" --rpc-url "$EVM_RPC" 2>/dev/null | awk '{print $1}')
  [ "${AFTER_E:-0}" != "${BEFORE_E:-0}" ] && break
  perl -e 'select(undef,undef,undef,3)'
done
ok "the recipient was paid the attested amount" "$(( ${AFTER_E:-0} - ${BEFORE_E:-0} ))" "$ATT_AMOUNT"

# A consumed message must not be replayable. This is the one assertion that
# costs nothing and would catch a transmitter that was not tracking nonces.
REPLAY=$(cast call "$MT_EVM" 'receiveMessage(bytes,bytes)(bool)' \
  "$(cat /tmp/s2e-msg.hex)" "$(cat /tmp/s2e-att.hex)" --from "$RECIPIENT" --rpc-url "$EVM_RPC" 2>&1 \
  | grep -oE 'Nonce already used' | head -1)
ok "the message cannot be replayed" "$REPLAY" "Nonce already used"

echo
printf '  TOTAL: %s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
