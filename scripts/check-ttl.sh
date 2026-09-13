#!/usr/bin/env bash
# How long before a live contract archives itself.
#
# A Soroban contract's instance entry has a time to live, and when it runs out
# the entry is archived: the contract stops answering until somebody restores
# it. Contracts bump their own entries as they are used, so an active
# deployment looks after itself and an idle one does not. A testnet deployment
# that a reviewer is pointed at can sit idle for weeks, which is exactly when
# this bites and exactly when nobody is watching.
#
# Nothing else here reads this. The record check compares addresses and hashes,
# the entry point check compares interfaces, and both would go on passing right
# up until the day the contract stopped existing.
#
# Extending is not a one-time repair. Testnet caps a single extension at 535679
# ledgers, about 31 days, so a deployment nobody touches needs extending every
# month for as long as it is meant to answer. That is the reason this exists as
# a check rather than as a note: the number only means anything if somebody
# reads it before it runs out.
#
#   bash scripts/check-ttl.sh          warn under 20 days, fail under 7
#   MIN_DAYS=30 bash scripts/check-ttl.sh
set -euo pipefail
cd "$(dirname "$0")/.."

WARN_DAYS=${WARN_DAYS:-20}
MIN_DAYS=${MIN_DAYS:-7}
RPC=${RPC:-https://soroban-testnet.stellar.org}

python3 - "$RPC" "$WARN_DAYS" "$MIN_DAYS" <<'PY'
import base64, json, struct, subprocess, sys

rpc, warn_days, min_days = sys.argv[1], float(sys.argv[2]), float(sys.argv[3])
dep = json.load(open('deployments/testnet.json'))
live = dict(dep['contracts'])
live.update({'poolAdapters.' + k: v for k, v in dep.get('poolAdapters', {}).items()})

def contract_hash(strkey):
    pad = '=' * ((8 - len(strkey) % 8) % 8)
    return base64.b32decode(strkey + pad)[1:-2]

def instance_key(strkey):
    # ContractData / contract address / SCV_LEDGER_KEY_CONTRACT_INSTANCE / PERSISTENT
    return base64.b64encode(
        struct.pack('>I', 6) + struct.pack('>I', 1) + contract_hash(strkey)
        + struct.pack('>I', 20) + struct.pack('>I', 1)
    ).decode()

keys = {name: instance_key(addr) for name, addr in live.items()}
payload = {"jsonrpc": "2.0", "id": 1, "method": "getLedgerEntries",
           "params": {"keys": list(keys.values())}}
out = subprocess.run(['curl', '-s', '-X', 'POST', rpc, '-H', 'Content-Type: application/json',
                      '-d', json.dumps(payload)], capture_output=True, text=True)
d = json.loads(out.stdout)
res = d.get('result') or {}
latest = res.get('latestLedger')
if not latest:
    print('  FAIL  the RPC returned no ledger: %s' % json.dumps(d)[:200])
    raise SystemExit(1)

by_key = {e['key']: e for e in res.get('entries', [])}
print('  latest ledger %d, about five seconds each' % latest)
print()
passed = failed = 0
for name, k in sorted(keys.items()):
    e = by_key.get(k)
    if not e:
        print('  FAIL  %s has no instance entry at all, so it is already archived' % name)
        failed += 1
        continue
    left = e['liveUntilLedgerSeq'] - latest
    days = left * 5 / 86400
    if days < min_days:
        print('  FAIL  %-28s %5.0f days left, under the %.0f this fails at' % (name, days, min_days))
        failed += 1
    elif days < warn_days:
        print('  WARN  %-28s %5.0f days left, under the %.0f worth watching' % (name, days, warn_days))
        passed += 1
    else:
        print('  PASS  %-28s %5.0f days left' % (name, days))
        passed += 1

print()
print('  extend with: stellar contract extend --id <address> --durability persistent \\')
print('                 --ledgers-to-extend 535679 --source-account agama-poc --network testnet')
print()
print('  %d passed, %d failed' % (passed, failed))
raise SystemExit(1 if failed else 0)
PY
