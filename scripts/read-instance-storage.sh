#!/usr/bin/env bash
# Print a deployed contract's instance storage, whether or not it has getters.
#
# This exists because a migration stopped on 2026-11-01. The CCTP adapter stores
# max_fee_bps in its constructor and exposes it through nothing, so the value
# could not be carried to a replacement and the replacement was abandoned with
# the fix still in the tree. The value was never actually hidden: instance
# storage is a ledger entry, and a ledger entry can be read without the contract
# having an opinion about it.
#
# Reach for this before concluding that a value on a deployed contract is
# unrecoverable. Guessing it, or asking a human to remember what they passed
# months ago, is how a migration quietly changes behaviour.
#
#   bash scripts/read-instance-storage.sh <contract-id|record-key>
#   bash scripts/read-instance-storage.sh cctpAdapter
set -euo pipefail
cd "$(dirname "$0")/.."
NET=${NET:-testnet}
DEP=deployments/testnet.json
[ $# -ge 1 ] || { echo "usage: $0 <contract-id|record-key>" >&2; exit 2; }

ID=$1
case "$ID" in
  C*) ;;  # already an address
  *)  ID=$(python3 -c "
import json,sys
d=json.load(open('$DEP'))
k='$1'
for src in (d['contracts'], d.get('poolAdapters', {})):
    if k in src:
        v=src[k]
        print(v['address'] if isinstance(v, dict) else v); sys.exit()
print('', end='')") ;;
esac
[ -n "$ID" ] || { echo "no contract named '$1' in $DEP" >&2; exit 2; }
echo "$1 = $ID"
echo ""

stellar contract read --id "$ID" --durability persistent --network "$NET" --output json 2>/dev/null \
| python3 -c "
import sys, json
raw = sys.stdin.read()
# The CLI emits CSV with JSON inside, so every quote arrives doubled.
s = raw.replace('\"\"', '\"')
try:
    obj = json.loads(s[s.index('{'):s.rindex('}') + 1])
    storage = obj['contract_instance']['storage']
except Exception as exc:
    print('could not parse the instance entry: %s' % exc); raise SystemExit(1)
if not storage:
    print('  the instance storage is empty'); raise SystemExit(0)
def name(k):
    if 'vec' in k:            # an enum variant, possibly with arguments
        head = k['vec'][0].get('symbol', '?')
        rest = [json.dumps(a) for a in k['vec'][1:]]
        return head + ('(' + ', '.join(rest) + ')' if rest else '')
    return k.get('symbol', json.dumps(k))
def value(v):
    # One key, one scalar, in the common case. Print the scalar, not its wrapper.
    if len(v) == 1:
        (t, x), = v.items()
        return x if isinstance(x, str) else json.dumps(x)
    return json.dumps(v)
for e in storage:
    print('  %-14s %s' % (name(e['key']), value(e['val'])))
"
