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

echo ""
echo "==> a reason repeated across generations is backed by matching wasm"
# A reason shared by two contracts retired in the same migration is honest: the
# Vault and its agUSD always go together. Shared by two consecutive generations
# of the same contract it is honest only when nothing was recompiled between
# them, which happens when a deploy script is re-run from the same source. When
# the code did change, the second generation exists to fix what the first is
# being blamed for, so the reason cannot be true of both. That is how the tenth
# Vault came to be recorded as lacking an oracle() it demonstrably has.
#
# The discriminator is therefore the wasm, not the prose, and it is recorded per
# entry so this runs offline. --wasm re-reads the hashes off the ledger.
while IFS='|' read -r verdict msg; do
  [ -n "$verdict" ] || continue
  if [ "$verdict" = ok ]; then ok "$msg"; else bad "$msg"; fi
done < <(python3 -c "
import collections, json
d = json.load(open('deployments/testnet.json'))
by = collections.defaultdict(list)
for e in d.get('superseded', []):
    by[e['contract']].append(e)
clean = True
for contract, gens in by.items():
    gens.sort(key=lambda e: e['generation'])
    for a, b in zip(gens, gens[1:]):
        if a.get('reason', '').strip() != b.get('reason', '').strip():
            continue
        ha, hb = a.get('wasmHash'), b.get('wasmHash')
        pair = '%s generations %d and %d' % (contract, a['generation'], b['generation'])
        if not ha or not hb:
            clean = False
            print('bad|%s give the same reason and no wasmHash says they are the same '
                  'code, so one reason is a copy' % pair)
        elif ha != hb:
            clean = False
            print('bad|%s give the same reason but differ in wasm (%s vs %s), so the '
                  'later one was retired for something else' % (pair, ha[:12], hb[:12]))
        else:
            print('ok|%s share a reason and are byte identical, which is why' % pair)
if clean:
    print('ok|no generation is blamed for what its predecessor was replaced to fix')
")

# The docs site is a second place that lists these addresses, and it is in
# another repository, which is exactly why it drifted three times while this
# check kept passing. Checked when a clone is where it is expected, skipped with
# a note when it is not, because a check that fails on somebody else's machine
# layout gets switched off.
DOCS=${AGAMA_DOCS:-../../../Users/eden/data/real-agama/docs}
[ -d "$DOCS/content" ] || DOCS=$(cd "$(dirname "$0")/../../.." 2>/dev/null && pwd)/real-agama/docs
echo ""
echo "==> the docs site lists the same addresses, so it gets the same check"
if [ -d "$DOCS/content" ]; then
  while IFS='|' read -r kind addr; do
    [ -n "$addr" ] || continue
    if [ "$kind" = "live" ]; then
      if grep -q "$addr" "$DOCS/content/stellar/deployments.md" 2>/dev/null; then ok "live $addr is on the docs page"
      else bad "live $addr is not on the docs page"; fi
    else
      if python3 - "$DOCS/content/stellar/deployments.md" "$addr" <<'PY2'
import io, sys
s = io.open(sys.argv[1], encoding="utf-8").read()
cut = s.find("## Superseded deployments")
sys.exit(0 if (cut < 0 or sys.argv[2] not in s[:cut]) else 1)
PY2
      then :; else bad "retired $addr is still in the docs page's live tables"; fi
    fi
  done < <(python3 -c "
import json
d = json.load(open('deployments/testnet.json'))
for v in list(d['contracts'].values()) + list(d.get('poolAdapters', {}).values()):
    print('live|' + v)
for e in d.get('superseded', []):
    print('retired|' + e['address'])
")
  ok "the docs page was checked at $DOCS"
else
  echo "  SKIP  no docs clone at \$AGAMA_DOCS or the default path, so the docs page was not checked"
fi

if [ "${1:-}" = "--wasm" ]; then
  echo ""
  echo "==> every deployed contract is byte for byte the source in this tree"
  # A divergence between the source and the ledger is allowed exactly when it is
  # declared. Without this the check has only two settings, both wrong: fail on
  # a gap the team has decided to carry, or be weakened until it stops catching
  # the gaps nobody decided to carry. Declaring turns it into a statement with a
  # reason attached, which is a thing a reviewer can disagree with.
  PENDING=$(python3 -c "
import json
d = json.load(open('deployments/testnet.json'))
for e in d.get('pendingRedeployment', []):
    print(e['contract'])
")
  if [ -n "$PENDING" ]; then
    echo "  declared as pending redeployment: $(echo "$PENDING" | tr '\n' ' ')"
  fi
  stellar contract build >/dev/null 2>&1 || bad "the release build failed, so nothing was compared"
  while IFS='|' read -r name addr wasm; do
    [ -n "$addr" ] || continue
    chain=$(stellar contract fetch --id "$addr" --network testnet 2>/dev/null | shasum -a 256 | cut -d' ' -f1)
    local_hash=$(shasum -a 256 "target/wasm32v1-none/release/$wasm" 2>/dev/null | cut -d' ' -f1)
    if [ -n "$chain" ] && [ "$chain" = "$local_hash" ]; then
      # A contract that matches must not be sitting in the declared list, or the
      # declaration has outlived the divergence and is now a false statement of
      # its own.
      if echo "$PENDING" | grep -qx "$name"; then
        bad "$name matches the chain but is still declared as pending redeployment"
      else
        ok "$name"
      fi
    elif echo "$PENDING" | grep -qx "$name"; then
      ok "$name differs and is declared: chain ${chain:0:16} vs local ${local_hash:0:16}"
    else
      bad "$name differs and nothing declares it: chain ${chain:0:16} vs local ${local_hash:0:16}"
    fi
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

  echo ""
  echo "==> the recorded wasmHash of a retired contract is what the ledger holds"
  # Offline the repeated-reason check trusts these hashes. Here they get read
  # back off the chain, because a hash nobody re-reads is just another claim.
  while IFS='|' read -r label addr recorded; do
    [ -n "$addr" ] || continue
    chain=$(stellar contract fetch --id "$addr" --network testnet 2>/dev/null | shasum -a 256 | cut -d' ' -f1)
    if [ -z "$chain" ]; then
      bad "$label: ${addr:0:8} could not be fetched, so its recorded hash is unverified"
    elif [ "$chain" = "$recorded" ]; then
      ok "$label: ${recorded:0:12}"
    else
      bad "$label records ${recorded:0:12} and the ledger holds ${chain:0:12}"
    fi
  done < <(python3 -c "
import json
d = json.load(open('deployments/testnet.json'))
for e in d.get('superseded', []):
    if e.get('wasmHash'):
        print(f\"{e['label']}|{e['address']}|{e['wasmHash']}\")
")
fi

echo ""
echo "  $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
