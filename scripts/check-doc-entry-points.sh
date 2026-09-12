#!/usr/bin/env bash
# Check docs/ARCHITECTURE.md against the contracts actually on the ledger.
#
# Two questions, both of which had wrong answers when this was written:
#
#   1. Is every live entry point named in the architecture doc? Eleven were
#      not, including a staking setter nobody had documented anywhere and two
#      adapters with no section at all.
#   2. Does every signature the doc declares have the arity the ledger has?
#      The oracle pipeline showed push_nav(nav, timestamp) for a call that
#      takes four arguments.
#
# The ledger is the reference and not the source tree, deliberately: the source
# is what will be deployed, the ledger is what is deployed, and the doc makes
# claims about a running system.
#
#   bash scripts/check-doc-entry-points.sh
#   ENTRY_POINT_CACHE=/tmp/ifaces bash scripts/check-doc-entry-points.sh
set -euo pipefail

cd "$(dirname "$0")/.."
DOC=docs/ARCHITECTURE.md
DEP=deployments/testnet.json
CACHE=${ENTRY_POINT_CACHE:-$(mktemp -d)}
mkdir -p "$CACHE"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  PASS  $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL  $1"; }
report() {
  while IFS='|' read -r verdict msg; do
    [ -n "$verdict" ] || continue
    if [ "$verdict" = ok ]; then ok "$msg"; else bad "$msg"; fi
  done < "$1"
}

# usdc is Circle's Stellar asset contract and agusd is the retired generation 1
# design, a self-contained vault rather than a token. Neither is ours to
# document as current architecture.
SKIP="usdc agusd"

echo "==> fetching the live interfaces"
while IFS='|' read -r name addr; do
  [ -n "$addr" ] || continue
  case " $SKIP " in *" $name "*) continue;; esac
  f="$CACHE/$name.txt"
  if [ ! -s "$f" ]; then
    stellar contract info interface --network testnet --id "$addr" > "$f" 2>/dev/null \
      || { bad "$name: could not fetch $addr from the ledger"; rm -f "$f"; continue; }
  fi
  echo "      $name  $(grep -c 'fn ' "$f") functions"
done < <(python3 -c "
import json
d = json.load(open('$DEP'))
c = dict(d['contracts'])
c.update({'pa.' + k: v for k, v in d.get('poolAdapters', {}).items()})
for k, v in c.items():
    print(k + '|' + v)
")

echo ""
echo "==> every live entry point is named in $DOC"
python3 - "$CACHE" "$DOC" > "$CACHE/result" <<'PY'
import io, os, re, sys
cache, doc = sys.argv[1:3]
md = io.open(doc, encoding='utf-8').read()
# SEP-41 is a published standard; its methods are described once as "SEP-41"
# rather than re-listed per token, and listing them would not make the doc truer.
SEP41 = {'balance','transfer','transfer_from','approve','allowance','burn','burn_from',
         'decimals','name','symbol','mint','set_admin','admin','clawback',
         'set_authorized','authorized','total_supply'}
clean = True
for fn_file in sorted(os.listdir(cache)):
    if not fn_file.endswith('.txt'):
        continue
    name = fn_file[:-4]
    src = io.open(os.path.join(cache, fn_file), encoding='utf-8').read()
    fns = sorted({f for f in re.findall(r'\bfn ([a-z_][a-z0-9_]*)\(', src)
                  if not f.startswith('__') and f not in SEP41})
    absent = [f for f in fns if f not in md]
    if absent:
        clean = False
        print('bad|%s: %d entry point(s) the doc never names: %s'
              % (name, len(absent), ', '.join(absent)))
    else:
        print('ok|%s, all %d documented' % (name, len(fns)))
if not clean:
    print('bad|the architecture doc is not complete against the ledger')
PY
report "$CACHE/result"

echo ""
echo "==> every signature the doc declares has the arity the ledger has"
python3 - "$CACHE" "$DOC" > "$CACHE/result" <<'PY'
import io, os, re, sys
cache, doc = sys.argv[1:3]
arity = {}
for fn_file in os.listdir(cache):
    if not fn_file.endswith('.txt'):
        continue
    src = io.open(os.path.join(cache, fn_file), encoding='utf-8').read()
    for m in re.finditer(r'fn ([a-z_]+)\(([^;]*?)\)\s*(?:->|;)', src, flags=re.S):
        ps = [x.strip() for x in m.group(2).split(',') if x.strip()]
        arity.setdefault(m.group(1), set()).add(len([p for p in ps if not p.startswith('env')]))

bad = []
for i, line in enumerate(io.open(doc, encoding='utf-8').read().split('\n'), 1):
    # Only where the doc spells arguments out: a table row's first cell, or a
    # pipeline line naming a reporter call. `allocate()` in prose is a name, not
    # a claim about arity, and flagging it would train people to ignore this.
    cands = []
    parts = line.split('|')
    if line.startswith('|') and len(parts) > 1:
        cands = re.findall(r'`([a-z_][a-z0-9_]*)\(([^)`]*)\)', parts[1])
    elif re.search(r'\b(push_nav|submit_nav)\(', line):
        cands = re.findall(r'\b([a-z_][a-z0-9_]*)\(([^)]*)\)', line)
    for fn, args in cands:
        if fn not in arity:
            continue
        n = len([x for x in args.split(',') if x.strip()])
        if n == 0:            # a bare name reference
            continue
        if n not in arity[fn]:
            bad.append('bad|%s:%d declares %s with %d argument(s), the ledger has %s'
                       % (doc, i, fn, n, sorted(arity[fn])))
for b in bad:
    print(b)
if not bad:
    print('ok|no declared signature disagrees with the ledger')
PY
report "$CACHE/result"

echo ""
echo "  $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
