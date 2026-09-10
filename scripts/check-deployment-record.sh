#!/usr/bin/env bash
# Check that the deployment record, the README and the ledger still agree.
#
# Three contracts have been replaced on their own in the last two days, each
# time by a script that rewrites deployments/testnet.json and each time leaving
# a table in README.md to be updated by hand. That worked until it did not: the
# README went on naming a superseded Oracle Adapter as the live one, and nothing
# failed, because nothing was checking. This is what checks.
#
#   bash scripts/check-deployment-record.sh          record and README only
#   bash scripts/check-deployment-record.sh --wasm   also hash every deployed
#                                                    contract against a local build
#
# The --wasm pass is the claim every adversarial review has ended on, that the
# contracts in this repository are the contracts on the ledger. It needs the
# network and a release build, so it is opt-in rather than the default.
set -uo pipefail
cd "$(dirname "$0")/.."

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  PASS  $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL  $1"; }

echo "==> every live address is in the README, and no retired one is"
while IFS='|' read -r name addr; do
  [ -n "$addr" ] || continue
  if grep -q "$addr" README.md; then ok "$name is in the README"
  else bad "$name ($addr) is live and the README does not mention it"; fi
done < <(python3 -c "
import json
d = json.load(open('deployments/testnet.json'))
for k, v in d['contracts'].items():
    print(f'{k}|{v}')
for k, v in d.get('poolAdapters', {}).items():
    print(f'poolAdapters.{k}|{v}')
")

# The README's live table is the block between the Deployed Contracts heading
# and the superseded section. A retired address inside it is the exact drift
# this script exists for.
LIVE_TABLE=$(python3 -c "
import re, io
s = io.open('README.md', encoding='utf-8').read()
m = re.search(r'### Core Contracts(.*?)### Superseded Contracts', s, re.S)
print(m.group(1) if m else '')
")
if [ -z "$LIVE_TABLE" ]; then
  bad "could not find the README's live contract table, so nothing below it was checked"
else
  while read -r addr; do
    [ -n "$addr" ] || continue
    if echo "$LIVE_TABLE" | grep -q "$addr"; then
      bad "a superseded address is still in the README's live table: $addr"
    fi
  done < <(python3 -c "
import json
d = json.load(open('deployments/testnet.json'))
for e in d.get('superseded', []):
    print(e['address'])
")
  ok "no superseded address appears in the README's live table"
fi

echo ""
echo "==> every superseded entry carries a reason"
while IFS='|' read -r label n; do
  [ -n "$label" ] || continue
  if [ "$n" -gt 80 ]; then ok "$label"; else bad "$label has a $n character reason, which is not one"; fi
done < <(python3 -c "
import json
d = json.load(open('deployments/testnet.json'))
for e in d.get('superseded', []):
    print(f\"{e['label']}|{len(e.get('reason', ''))}\")
" | tail -4)
echo "  (showing the four most recent)"

if [ "${1:-}" = "--wasm" ]; then
  echo ""
  echo "==> every deployed contract is byte for byte the source in this tree"
  stellar contract build >/dev/null 2>&1 || bad "the release build failed, so nothing was compared"
  while IFS='|' read -r name addr wasm; do
    [ -n "$addr" ] || continue
    chain=$(stellar contract fetch --id "$addr" --network testnet 2>/dev/null | shasum -a 256 | cut -d' ' -f1)
    local_hash=$(shasum -a 256 "target/wasm32v1-none/release/$wasm" 2>/dev/null | cut -d' ' -f1)
    if [ -n "$chain" ] && [ "$chain" = "$local_hash" ]; then ok "$name"
    else bad "$name differs: chain ${chain:0:16} vs local ${local_hash:0:16}"; fi
  done < <(python3 -c "
import json
d = json.load(open('deployments/testnet.json'))
c, p = d['contracts'], d['poolAdapters']
for name, addr, wasm in [
    ('vault', c['vault'], 'vault.wasm'),
    ('agusdCore', c['agusdCore'], 'agusd_core.wasm'),
    ('staking', c['staking'], 'staking.wasm'),
    ('allocationEngine', c['allocationEngine'], 'allocation_engine.wasm'),
    ('oracleAdapter', c['oracleAdapter'], 'oracle_adapter.wasm'),
    ('private-credit', p['private-credit'], 'private_credit.wasm'),
    ('etherfuse', p['etherfuse'], 'etherfuse.wasm'),
]:
    print(f'{name}|{addr}|{wasm}')
")
fi

echo ""
echo "  $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
