#!/usr/bin/env bash
# One USDC transfer across CCTP, Base Sepolia to Stellar, start to finish.
#
# e2e-cctp-wiring.sh proves the three Circle contracts are live, unpaused and
# pointed at each other. That is worth having and it is not the same thing as
# moving money: every wiring assertion passed during the two failed attempts
# that cost 2 USDC each. Wiring says the pieces exist. This says the path pays.
#
# The two mistakes it refuses to repeat, both of which lose the funds for good:
#
#   mintRecipient is the forwarder, never the recipient's own key. A CCTP
#   message carries 32 bare bytes with no type tag, and the same Stellar key
#   encodes as both G and C. Minting to the key credits the contract form, which
#   has no signer. So this computes mintRecipient from the forwarder's strkey
#   and then encodes those 32 bytes back into a strkey and asserts it is the
#   forwarder again. A wrong address that round trips to something else is
#   caught here rather than on the ledger.
#
#   the Stellar leg calls the forwarder's mint_and_forward, not the
#   MessageTransmitter's receive_message. receive_message succeeds, returns
#   true and mints, and then nothing forwards: the USDC stops at the forwarder
#   and the recipient's balance never moves. A green transaction and a missing
#   payment is the worst shape a failure can take, so the assertion here is the
#   recipient's balance delta and not the transaction's status.
#
# What arrives is not what was sent. USDC is 6 decimals on Base and 7 on
# Stellar, CCTP rescales and takes a fee, so the landed amount is read from the
# ledger rather than computed from the burn. The fee is small and it is not zero.
#
# Needs: cast (foundry) for the EVM leg, and the burn key in EVM_KEY. That key
# lives in the application's .env.local as DEMO_PRIVATE_KEY and is passed in
# rather than read from here, because this repo has no business reaching into
# another one's secrets:
#
#   EVM_KEY=$(grep '^DEMO_PRIVATE_KEY=' ../app/.env.local | cut -d= -f2) \
#     bash scripts/e2e-cctp-transfer.sh
#
# AMOUNT is in whole USDC and defaults to 1. Testnet USDC arrives from Circle's
# faucet behind a captcha, so it is not replenishable by a script and this
# spends as little as proves the point.
set -uo pipefail
cd "$(dirname "$0")/.."
NET=${NET:-testnet}
SRC=${SRC:-agama-poc}
DEP=deployments/testnet.json
AMOUNT=${AMOUNT:-1}
HORIZON=${HORIZON:-https://horizon-testnet.stellar.org}

j() { python3 -I -c "import json;print(json.load(open('$DEP'))$1)"; }
EVM_RPC=${EVM_RPC:-https://sepolia.base.org}
TM=$(j "['cctp']['evm']['tokenMessengerV2']")
USDC_EVM=$(j "['cctp']['evm']['usdc']")
SRC_DOMAIN=$(j "['cctp']['evm']['domain']")
DST_DOMAIN=$(j "['cctp']['stellar']['domain']")
FORWARDER=$(j "['cctp']['stellar']['forwarder']")
IRIS=$(j "['cctp']['attestation']")

pass=0; fail=0
ok(){ if [ -n "$2" ] && [ "$2" = "$3" ]; then printf '  PASS  %-46s %s\n' "$1" "$2"; pass=$((pass+1));
      else printf '  FAIL  %-46s expected %s, got %s\n' "$1" "$3" "${2:-<nothing>}"; fail=$((fail+1)); fi; }
die(){ printf '  FAIL  %s\n' "$1"; printf '\n  TOTAL: %s passed, %s failed\n' "$pass" "$((fail+1))"; exit 1; }

command -v cast >/dev/null || die "cast is not installed, the EVM leg cannot run"
[ -n "${EVM_KEY:-}" ] || die "EVM_KEY is unset, see the header for where the key lives"

UNITS=$(python3 -I -c "print(int($AMOUNT * 10**6))")
# A tenth of a percent, the same ceiling the application offers. maxFee is a
# ceiling and not a payment: Circle takes what it takes and the difference is
# not charged. Zero would be refused by the fast path.
MAXFEE=$(( UNITS / 1000 > 0 ? UNITS / 1000 : 1 ))
RECIP=$(stellar keys address "$SRC") || die "no such key $SRC"
BURNER=$(cast wallet address --private-key "$EVM_KEY") || die "EVM_KEY is not a usable key"

echo "== the destination, before anything is burned"
read -r MINTRECIP HOOK ROUNDTRIP <<EOF
$(python3 -I - "$FORWARDER" "$RECIP" <<'PY'
import sys
B32 = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567'

def payload(sk):
    bits = ''.join(format(B32.index(c), '05b') for c in sk.rstrip('='))
    raw = bytes(int(bits[i:i+8], 2) for i in range(0, len(bits) - 7, 8))
    return raw[0], raw[1:33]

def crc16(data):
    crc = 0
    for b in data:
        crc ^= b << 8
        for _ in range(8):
            crc = ((crc << 1) ^ 0x1021) & 0xFFFF if crc & 0x8000 else (crc << 1) & 0xFFFF
    return crc

def strkey(ver, key):
    body = bytes([ver]) + key
    full = body + crc16(body).to_bytes(2, 'little')
    bits = ''.join(format(b, '08b') for b in full)
    bits += '0' * ((5 - len(bits) % 5) % 5)
    return ''.join(B32[int(bits[i:i+5], 2)] for i in range(0, len(bits), 5))

fwd, recip = sys.argv[1], sys.argv[2]
ver, key = payload(fwd)
assert len(key) == 32, f'{len(key)} bytes, not 32'

# The forwarder's hook data, Circle's layout: 24 reserved zero bytes, a u32
# version of 0, a u32 length, then the recipient's strkey as UTF-8 rather than
# as bytes. The strkey carries its own version byte, which is how the forwarder
# tells an account from a contract where the bare 32 byte mintRecipient could
# not. This is the whole reason the hook exists.
rec = recip.encode()
hook = bytearray(32 + len(rec))
hook[28:32] = len(rec).to_bytes(4, 'big')
hook[32:] = rec

print('0x' + key.hex(), '0x' + hook.hex(), strkey(ver, key))
PY
)
EOF
ok "mintRecipient round trips to the forwarder" "$ROUNDTRIP" "$FORWARDER"

usdc_on_stellar() {
  curl -s "$HORIZON/accounts/$RECIP" | python3 -I -c "
import sys, json
for b in json.load(sys.stdin).get('balances', []):
    if b.get('asset_code') == 'USDC':
        print(b['balance']); raise SystemExit
print('0')
"
}
BEFORE=$(usdc_on_stellar)
EVM_BEFORE=$(cast call "$USDC_EVM" 'balanceOf(address)(uint256)' "$BURNER" --rpc-url "$EVM_RPC" | awk '{print $1}')
echo "  $BURNER holds $EVM_BEFORE units on domain $SRC_DOMAIN"
echo "  $RECIP holds $BEFORE USDC on Stellar"
ok "the burner can cover $AMOUNT USDC" "$([ "$EVM_BEFORE" -ge "$UNITS" ] && echo yes)" "yes"

echo "== burning $UNITS units on domain $SRC_DOMAIN"
NONCE0=$(cast nonce "$BURNER" --rpc-url "$EVM_RPC")
cast send "$USDC_EVM" 'approve(address,uint256)' "$TM" "$UNITS" \
  --private-key "$EVM_KEY" --rpc-url "$EVM_RPC" >/dev/null 2>/tmp/cctp-approve.err \
  || die "the approve was refused: $(tail -2 /tmp/cctp-approve.err)"
# Wait for the approve to be visible, do not assume the receipt settles it.
#
# The public Base Sepolia endpoint is a load balancer over several nodes, so a
# read issued straight after a write can land on one that has not caught up and
# answer with the old value. That is a stale node, not a slow chain, and it cost
# two assertions on the first run of this script: the allowance read came back 0
# on an approve that had already mined, and then the burn was simulated against
# that same stale state, reverted on the allowance it could not see, and was
# never submitted at all. Nothing was lost, because a transaction that fails
# simulation never reaches the chain, but the run reported a refused burn and
# the real cause was two blocks of RPC lag.
# It showed up twice, once per read the burn depends on. First the allowance
# came back 0 on an approve that had already mined, which failed the assertion
# below and then made the burn revert in simulation on an allowance the node
# could not see, so it was never submitted. With that waited out it moved to the
# nonce: cast read 3 from a lagging node while the chain was already at 4, and
# the burn came back 'nonce too low: next nonce 4, tx nonce 3'. Neither lost
# anything, because a transaction rejected before submission never reaches the
# chain, but both reported as a refused burn and neither was one.
#
# So wait for both facts to be visible, and then pin the nonce rather than let
# cast fetch it again and race a second time.
ALLOW=0; NONCE=$NONCE0
for _ in $(seq 1 30); do
  ALLOW=$(cast call "$USDC_EVM" 'allowance(address,address)(uint256)' "$BURNER" "$TM" \
    --rpc-url "$EVM_RPC" 2>/dev/null | awk '{print $1}')
  NONCE=$(cast nonce "$BURNER" --rpc-url "$EVM_RPC" 2>/dev/null)
  if [ "${ALLOW:-0}" = "$UNITS" ] && [ "${NONCE:-0}" -gt "$NONCE0" ]; then break; fi
  perl -e 'select(undef,undef,undef,2)'
done
ok "the TokenMessenger is approved for the amount" "${ALLOW:-0}" "$UNITS"
ok "the approve's nonce is visible on chain" "$([ "${NONCE:-0}" -gt "$NONCE0" ] && echo yes)" "yes"

# depositForBurnWithHook, not depositForBurn. Without the hook the forwarder has
# nowhere to send the USDC and mint_and_forward rejects the message.
BURN=$(cast send "$TM" \
  'depositForBurnWithHook(uint256,uint32,bytes32,address,bytes32,uint256,uint32,bytes)' \
  "$UNITS" "$DST_DOMAIN" "$MINTRECIP" "$USDC_EVM" "0x$(printf '00%.0s' $(seq 1 32))" \
  "$MAXFEE" 1000 "$HOOK" \
  --private-key "$EVM_KEY" --rpc-url "$EVM_RPC" --nonce "$NONCE" --json 2>/tmp/cctp-burn.err \
  | python3 -I -c "
import sys, json
t = sys.stdin.read().strip()
if not t: raise SystemExit
r = json.loads(t)
print(r['transactionHash'] if r.get('status') == '0x1' else '')
")
# The reason, not just the fact. An earlier version sent stderr to /dev/null,
# so a burn that never left the machine reported as 'refused' with a json
# traceback where the revert reason should have been.
[ -n "$BURN" ] || die "the burn was refused: $(tail -3 /tmp/cctp-burn.err)"
ok "the burn is on chain" "$([ -n "$BURN" ] && echo mined)" "mined"
echo "  burn tx $BURN"

echo "== Circle's attestation"
# The burn is permanent and so is the attestation, so a run that dies here has
# not lost anything: the same transaction hash finishes it later.
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
open('/tmp/cctp-msg.hex', 'w').write(m['message'][2:])
open('/tmp/cctp-att.hex', 'w').write(m['attestation'][2:])
"
    ATT=yes; echo "  attested after ~$(( i * 5 ))s"; break
  fi
  perl -e 'select(undef,undef,undef,5)'
done
ok "Circle attested the burn" "$([ -n "$ATT" ] && echo complete)" "complete"
[ -n "$ATT" ] || die "no attestation, finish later with burn tx $BURN"

echo "== the Stellar leg"
OUT=$(stellar contract invoke --id "$FORWARDER" --source "$SRC" --network "$NET" -- \
  mint_and_forward --message "$(cat /tmp/cctp-msg.hex)" \
  --attestation "$(cat /tmp/cctp-att.hex)" 2>&1)
ok "mint_and_forward succeeded" "$(printf '%s' "$OUT" | grep -c 'mint_and_forward')" "1"
# The forwarder says where it sent the USDC. Asserting on this rather than on
# the transaction's success is the difference between this script and the two
# attempts that mined cleanly and paid nobody.
FORWARDED=$(printf '%s' "$OUT" | python3 -I -c "
import sys, re
t = sys.stdin.read()
line = [l for l in t.splitlines() if '\"mint_and_forward\"' in l]
if not line: print('none none'); raise SystemExit
amt = re.search(r'\"amount\"\},\"val\":\{\"i128\":\"(-?\d+)\"', line[-1])
who = re.search(r'\"forward_recipient\"\},\"val\":\{\"address\":\"([A-Z0-9]+)\"', line[-1])
print(amt.group(1) if amt else 'none', who.group(1) if who else 'none')
")
set -- $FORWARDED
FWD_AMT=$1; FWD_WHO=$2
ok "it forwarded to the intended recipient" "$FWD_WHO" "$RECIP"

AFTER=$(usdc_on_stellar)
trim() { python3 -I -c "
import sys
print(('%.7f' % float(sys.argv[1])).rstrip('0').rstrip('.'))
" "$1"; }
DELTA=$(trim "$(python3 -I -c "
import sys
print(float(sys.argv[1]) - float(sys.argv[2]))
" "$AFTER" "$BEFORE")")
# 7 decimals on Stellar against 6 on Base, which is the factor of ten, minus
# Circle's fee. Read off the forwarder's own event, not predicted from the burn.
EXPECT=$(trim "$(python3 -I -c "
import sys
print(int(sys.argv[1]) / 10**7)
" "$FWD_AMT")")
ok "the recipient's balance moved by the forwarded amount" "$DELTA" "$EXPECT"
ok "and it is more than nothing" "$(python3 -I -c "
import sys
print('yes' if float(sys.argv[1]) > 0 else 'no')
" "${DELTA:-0}")" "yes"
FEE=$(python3 -I -c "
import sys
print('%.7f' % ((int(sys.argv[1]) * 10 - int(sys.argv[2])) / 10**7))
" "$UNITS" "$FWD_AMT")
echo "  burned $UNITS units on domain $SRC_DOMAIN, $EXPECT USDC landed on Stellar, Circle took $FEE"
echo "  burn $BURN"

echo
printf '  TOTAL: %s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
