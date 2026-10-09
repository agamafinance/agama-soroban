#!/usr/bin/env bash
# The CCTP path, checked on the ledger rather than quoted from a receipt.
#
# 950 USDC has crossed from Base Sepolia through this bridge, but every tranche
# predates the move of agUSD to a classic asset and the three generations of
# contracts that came with it. A receipt from September says the bridge worked
# in September. This asks the chain whether the pieces it needs are still there
# and still pointed at each other, which is the part a redeployment can break
# and the part nobody re-reads.
#
# What it cannot do is move money. The burn leg is an EVM transaction from a
# funded Base Sepolia account, and funding one means a faucet, so a full replay
# is a human action and is reported as outstanding rather than quietly skipped.
# Everything on the Stellar side of the bridge, which is the half that was got
# wrong twice and cost 2 USDC each time, is checked here.
set -uo pipefail
cd "$(dirname "$0")/.."
NET=${NET:-testnet}
SRC=${SRC:-agama-poc}
DEP=deployments/testnet.json
j() { python3 -c "import json;print(json.load(open('$DEP'))$1)"; }

FW=$(j "['cctp']['stellar']['forwarder']")
TM=$(j "['cctp']['stellar']['tokenMessengerMinter']")
MT=$(j "['cctp']['stellar']['messageTransmitter']")
EVM_DOMAIN=$(j "['cctp']['evm']['domain']")
EVM_USDC=$(j "['cctp']['evm']['usdc']")
USDC=$(j "['contracts']['usdc']")

pass=0; fail=0
ok(){ if [ "$2" = "$3" ]; then printf '  PASS  %-48s %s\n' "$1" "$2"; pass=$((pass+1));
      else printf '  FAIL  %-48s expected %s, got %s\n' "$1" "$3" "$2"; fail=$((fail+1)); fi; }
iface(){ stellar contract info interface --id "$1" --network "$NET" 2>/dev/null; }
rd(){ stellar contract invoke --id "$1" --source "$SRC" --network "$NET" --send=no -- "${@:2}" 2>/dev/null | tr -d '"'; }

echo "== the three contracts are live"
for pair in "forwarder $FW" "token messenger minter $TM" "message transmitter $MT"; do
  set -- $pair
  name="${*:1:$#-1}"; id="${!#}"
  ok "$name answers" "$(stellar contract fetch --id "$id" --network "$NET" 2>/dev/null | wc -c | tr -d ' ' | awk '$1>0{print "yes"} $1==0{print "no"}')" "yes"
done

echo "== none of them is paused"
ok "forwarder not paused" "$(rd "$FW" paused)" "false"
ok "token messenger minter not paused" "$(rd "$TM" paused)" "false"
ok "message transmitter not paused" "$(rd "$MT" paused)" "false"

echo "== the entry point the application actually calls"
# receive_message on the transmitter also succeeds, also returns true, also
# mints, and leaves the USDC short of the recipient. Both exist, so the check
# that matters is that the one with the forwarding in it is the one that is
# there to be called.
ok "the forwarder exposes mint_and_forward" \
  "$(iface "$FW" | grep -c 'fn mint_and_forward')" "1"
ok "it takes a message and an attestation, nothing else" \
  "$(iface "$FW" | grep -A 4 'fn mint_and_forward' | grep -cE 'message: soroban_sdk::Bytes|attestation: soroban_sdk::Bytes')" "2"

echo "== the token the remote domain maps to is the USDC this protocol holds"
# The one check that catches a bridge aimed at the wrong asset. remote_token is
# the EVM USDC address, left padded into 32 bytes, which is how CCTP addresses
# a 20 byte token in a 32 byte field.
REMOTE32=$(python3 -c "
a = '$EVM_USDC'.lower().replace('0x','')
print('0'*24 + a)
")
LOCAL=$(stellar contract invoke --id "$TM" --source "$SRC" --network "$NET" --send=no -- \
  get_local_token --remote_domain "$EVM_DOMAIN" --remote_token "$REMOTE32" 2>/dev/null | tr -d '"')
ok "domain $EVM_DOMAIN's USDC maps to this protocol's USDC" "$LOCAL" "$USDC"

echo "== the recipient encoding, round tripped"
# mintRecipient is the forwarder, and the real recipient rides in the hook as 32
# bare bytes. A strkey carries a version byte and a two byte checksum around the
# key, and getting that slice wrong is how 2 USDC went to an address that looks
# like an account and is a contract. This encodes and decodes it back.
ROUND=$(python3 -c "
B32 = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567'
import binascii, struct
def payload(strkey):
    bits = ''.join(bin(B32.index(c))[2:].zfill(5) for c in strkey.rstrip('='))
    b = bytes(int(bits[i:i+8], 2) for i in range(0, len(bits)//8*8, 8))
    return b[1:33]
def crc16(data):
    crc = 0
    for b in data:
        crc ^= b << 8
        for _ in range(8):
            crc = ((crc << 1) ^ 0x1021) & 0xFFFF if crc & 0x8000 else (crc << 1) & 0xFFFF
    return crc
def strkey(ver, p):
    body = bytes([ver]) + p
    full = body + struct.pack('<H', crc16(body))
    bits = ''.join(bin(x)[2:].zfill(8) for x in full)
    bits += '0' * ((5 - len(bits) % 5) % 5)
    return ''.join(B32[int(bits[i:i+5], 2)] for i in range(0, len(bits), 5))
src = '$(stellar keys address $SRC)'
print('same' if strkey(6*8, payload(src)) == src else 'different')
")
ok "a G strkey survives the 32 byte round trip" "$ROUND" "same"

echo
printf '  TOTAL: %s passed, %s failed\n' "$pass" "$fail"
echo "  Not covered here: a live burn on Base Sepolia. That needs a funded EVM"
echo "  account, which needs a faucet, which is a human action."
[ "$fail" -eq 0 ]
