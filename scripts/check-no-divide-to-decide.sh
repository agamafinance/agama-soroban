#!/usr/bin/env bash
# Every division in a contract has to say why it is allowed to be there.
#
#   bash scripts/check-no-divide-to-decide.sh
#
# The Oracle Adapter's deviation bound decided by dividing. Integer division
# truncates toward zero, so the computed move understated the real one and the
# bound enforced 5.00999 percent while advertising 5. The rule this protocol
# follows everywhere else is to compare by multiplying: the reserve floor tests
# idle * BPS < floor_bps * base, the concentration caps test
# charged * BPS > cap_bps * total_assets, and neither can round a value onto the
# wrong side of its limit.
#
# The oracle turned out to be the only place that broke the rule. That is worth
# very little on its own, because it was also true the day before the defect was
# found and nobody could have said so. So this enumerates every division in
# every contract and requires each one to be named below with a reason. A new
# one fails until somebody writes down why it is not a decision.
#
# Keyed on the source line rather than the line number, so moving code around
# does not trip it and changing what a division computes does.
set -euo pipefail
cd "$(dirname "$0")/.."

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  PASS  $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL  $1"; }

echo "==> every division in a contract is accounted for"
while IFS='|' read -r where code reason; do
  case "$reason" in
    "") bad "$where divides and nothing says why: $code" ;;
     *) ok "$where: $reason" ;;
  esac
done < <(python3 - <<'PY'
import io, re, glob

# The reason each division is not a decision. Keyed on the trimmed source line.
ALLOWED = {
 # Generation 1 agUSD. Not part of the live protocol, nothing names it, and its
 # bytecode predates both reviews: see notCompared in deployments/testnet.json.
 # Listed rather than skipped, because a file excluded from a check is a file
 # nobody looks at.
 "let buffer_target = supply * (buffer_bps as i128) / BPS;":
   "generation 1, sizes a buffer, not a limit anything is tested against",
 "let part = excess * (t.weight_bps as i128) / BPS;":
   "generation 1, splits an amount by weight, truncation loses dust to the reserve",
 "let part = shortfall * (t.weight_bps as i128) / BPS;":
   "generation 1, splits an amount by weight, truncation asks back slightly less",
 "let mut shares = part * SHARE_ONE / sp;":
   "generation 1, converts assets to shares, truncation asks for fewer shares",
 "total += c.balance(&me) * c.share_price() / SHARE_ONE;":
   "generation 1, values a holding for reporting",

 "Ok((idle * BPS / base) as u32)":
   "get_reserve_ratio reports a figure, the floor itself compares by multiplying at line 964",

 "pub const REFLECTOR_MIN_NAV: i128 = ONE * 9 / 10;":
   "compile time constant, evaluated once by the compiler on exact literals",
 "pub const REFLECTOR_MAX_NAV: i128 = ONE * 11 / 10;":
   "compile time constant, evaluated once by the compiler on exact literals",
 "pub const NAV_BAND_MIN: i128 = ONE / 2;":
   "compile time constant, evaluated once by the compiler on exact literals",
 "let deviation_bps = delta * BPS / last.nav;":
   "runs only after the bound has already been decided by multiplying, and only to fill the rejection event a human reads",

 "amount * supply / nav":
   "mints shares, truncation gives the staker fewer shares, so it favours the pool",
 "let assets = shares * nav / supply;":
   "values shares, truncation pays the staker less, so it favours the pool",
 "Self::nav(e.clone()) * ONE / supply":
   "share_price reports a figure, no decision is taken on it",
}

# Which files to read is derived from the workspace, not written out here.
# The first version of this script globbed contracts/*/src/lib.rs, which silently
# left out adapters/* and crates/token, and a scope written by hand is the exact
# failure this whole family of checks exists to prevent. Nothing was hiding in
# them, but that is luck, not coverage.
members = []
for line in io.open('Cargo.toml', encoding='utf-8'):
    t = line.strip()
    if t.startswith('"') and t.endswith('",'):
        members.append(t.strip('",'))
files = []
for m in members:
    files += glob.glob('%s/src/*.rs' % m)
files = sorted(f for f in files if not f.endswith(('test.rs', 'fuzz.rs')))
if not files:
    raise SystemExit('no workspace sources found, so nothing was scanned')

for f in files:
    name = f.split('/')[-2] if f.endswith('lib.rs') else f
    if f.endswith('lib.rs'):
        name = f.rsplit('/src/', 1)[0].split('/')[-1]
    for i, line in enumerate(io.open(f, encoding='utf-8'), 1):
        t = line.strip()
        if t.startswith('//'):
            continue
        code = t.split('//')[0].strip()
        if re.search(r'(?<![/*])/(?![/*])', code):
            print('%s:%d|%s|%s' % (name, i, code, ALLOWED.get(code, '')))
PY
)

echo ""
echo "  $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
