#!/usr/bin/env bash
# Rewrite docs/evidence/observed-counts.tsv from a sweep's results.
#
# Takes a file of lines like "e2e-etherfuse  rc=0  TOTAL: 25 passed, 0 failed",
# which is what a serial sweep produces, and records the count per script. Only
# runs that reported zero failures are recorded: a count taken from a failing run
# is a count of how far it got, not of what the suite returns.
#
#   bash scripts/record-observed-counts.sh /tmp/sweep/results.txt
set -euo pipefail
cd "$(dirname "$0")/.."
SRC_FILE=${1:-}
[ -n "$SRC_FILE" ] && [ -f "$SRC_FILE" ] || { echo "usage: $0 <sweep-results-file>" >&2; exit 2; }
OUT=docs/evidence/observed-counts.tsv
TODAY=$(date -u +%Y-%m-%d)
python3 - "$SRC_FILE" "$OUT" "$TODAY" <<'PY'
import os, re, sys, collections
SELF = {'check-doc-figures.sh'}
src, out, today = sys.argv[1:]
seen = collections.OrderedDict()
for line in open(src):
    m = re.match(r'\s*([a-z0-9][a-z0-9-]*)\s', line)
    c = re.search(r'(\d+) passed, (\d+) failed', line)
    if not (m and c):
        continue
    if int(c.group(2)) != 0:
        print('  skipped %s: %s failed, so its count is how far it got' % (m.group(1), c.group(2)))
        continue
    name = m.group(1) + '.sh'
    # Only scripts that exist, because a sweep's labels are not all script
    # names: "cargo-test" and "findings-arithmetic" are a cargo invocation and a
    # python file, and recording them invented two entries the envelope could
    # never have. And not this check's own count, which would be circular: it
    # would be asserting its own total against an envelope it reads itself.
    if not os.path.exists(os.path.join('scripts', name)):
        print('  skipped %s: no such script, so the envelope cannot cover it' % name)
        continue
    if name in SELF:
        print('  skipped %s: it reads this file, so measuring it here is circular' % name)
        continue
    seen[name] = c.group(1)
head, rows = [], {}
for line in open(out):
    if line.startswith('#'):
        head.append(line.rstrip('\n'))
    elif line.strip():
        parts = line.rstrip('\n').split('\t')
        if len(parts) == 3:
            rows[parts[0]] = (parts[1], parts[2])
changed = 0
for k, v in seen.items():
    if rows.get(k, ('',))[0] != v:
        changed += 1
        print('  %-32s %s -> %s' % (k, rows.get(k, ('none',))[0], v))
    rows[k] = (v, today)
with open(out, 'w') as f:
    f.write('\n'.join(head) + '\n')
    for k in sorted(rows):
        f.write('%s\t%s\t%s\n' % (k, rows[k][0], rows[k][1]))
print('  %d changed, %d recorded' % (changed, len(rows)))
PY
