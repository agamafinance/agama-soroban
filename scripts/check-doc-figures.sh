#!/usr/bin/env bash
# Every suite figure quoted in the documentation, against one table.
#
# This repository's claim is that every number has a command next to it, which
# is only worth anything while the number is what the command prints. Six
# documents quote these figures and they drifted: on 2026-11-01 eleven were
# wrong, three of them presented as current, and the scratch check that was
# meant to catch them stopped at the first mention of each script and reported
# nothing.
#
# So the envelope lives here, once, and this walks every mention in every
# document. When a suite's assertion count changes deliberately, one number
# changes here and this says which documents disagree with it.
#
#   bash scripts/check-doc-figures.sh
#
# Needs nothing: no network, no keys, no build.
#
# The ranges are envelopes rather than values, because five of these suites
# legitimately print different totals on different runs. Every feed carries a
# minimum interval in ledger time, so a suite running inside one cannot push a
# value and skips the assertions that needed it. The low end of such a range is
# the rate-limited run and the high end is the one that could push. Where a
# figure is a single number the suite is deterministic and the range is a point.
set -uo pipefail
cd "$(dirname "$0")/.."

# script                        low  high  why the range, where there is one
RANGES="
check-deployment-record.sh      77   91    77 on 2026-10-19, 81 with private-credit-2, 91 with the live admin check
check-doc-entry-points.sh        9   10    9 on 2026-10-19, 10 since
check-refusals.sh                4    4
check-advisories.sh              2    2
check-ttl.sh                    10   11    10 on 2026-10-19, 11 since
verify-tranche2.sh              24   27    24 before it read its feed list from the record
check-source-invariants.sh      14   14
e2e-etherfuse.sh                22   27    22 when PC_NAV has capital behind two originators, so the keeper refuses to price one off the other
e2e-reconciliation.sh           11   13    the PC_NAV round, inside the hour or not
e2e-two-originators.sh          13   15
e2e-oracle-quorum.sh            11   12    11 before it submitted a value the feed did not hold
e2e-round-deadlock.sh            2    6    2 when the feed's own rate limit makes the round uncommittable
e2e-peg-gate.sh                 11   11
e2e-cctp-wiring.sh              10   10
e2e-allocation-guards.sh         1   12    1 when no pool has cap headroom, which is write-offs or live exposure and the skip now says which
e2e-concentration-caps.sh       10   10
e2e-generation3.sh              21   22    21 since the redemption asserts the USDC came back and not only that the agUSD burnt
e2e-test.sh                     24   25    one credit vault whose distribution does not always land; 25 since the cooldown exit asserts both halves
smoke-core.sh                   11   14    one assertion per feed that can take a value
smoke-agusd-core.sh             32   32
smoke-review2.sh                45   52    52 on 2026-09-09, 45 since assertions moved to other suites
smoke-review3.sh                38   42    42 on 2026-09-09, 38 since the pool took a write-off charge
smoke-mediums.sh                55   64    64 once the admin rotation stopped being skipped; 55 when the Vault cannot pay a queued claim
smoke-hardening.sh              62   64    the interval guard needs a round to commit first
"

DOCS="README.md SECURITY.md docs/TRANCHE1_EVIDENCE.md docs/TRANCHE2_EVIDENCE.md docs/ARCHITECTURE.md docs/NAV_RECONCILIATION.md"

python3 - "$RANGES" $DOCS <<'ZPY'
import re, sys

ranges = {}
for line in sys.argv[1].strip().split("\n"):
    parts = line.split()
    if len(parts) < 3:
        continue
    ranges[parts[0]] = (int(parts[1]), int(parts[2]))

def window(text, end):
    # Bounded by the row or the paragraph it is in. An unbounded window reads
    # the next table row's figure and reports it against this row's script,
    # which is twenty-four false positives on this repository.
    seg = text[end:end + 200]
    cuts = [c for c in (seg.find("\n|"), seg.find("\n\n")) if c >= 0]
    return seg[:min(cuts)] if cuts else seg

FIG = re.compile(r"\*{0,2}(\d+)\*{0,2}\s*(?:to\s*\*{0,2}(\d+)\*{0,2}\s*)?(assertions?|checks?|passed)")
bad = 0
seen = 0
for doc in sys.argv[2:]:
    try:
        text = open(doc).read()
    except OSError:
        continue
    for script, (lo, hi) in ranges.items():
        for m in re.finditer(re.escape(script), text):
            for f in FIG.finditer(window(text, m.end())):
                a = int(f.group(1))
                b = int(f.group(2)) if f.group(2) else a
                seen += 1
                if not (lo <= a <= hi and lo <= b <= hi):
                    line = text[: m.start()].count("\n") + 1
                    print("  FAIL  %s:%d  %s quotes %r, the envelope is %d..%d"
                          % (doc, line, script, f.group(0).strip(), lo, hi))
                    bad += 1
print("")
print("  %d figures checked across %d documents and %d scripts"
      % (seen, len(sys.argv) - 2, len(ranges)))
print("")
print("TOTAL: %d passed, %d failed" % (seen - bad, bad))
sys.exit(1 if bad else 0)
ZPY
