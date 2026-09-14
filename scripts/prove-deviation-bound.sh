#!/usr/bin/env bash
# Prove on the ledger that the Oracle Adapter's deviation bound is the bound it
# advertises, not a basis point wider.
#
#   bash scripts/prove-deviation-bound.sh
#
# The live Oracle Adapter cannot be used for this. Its feeds carry a minimum
# update interval, 3600 seconds on PC_NAV, so a push made to test the bound is
# refused by the rate limit instead and answers 514, TooSoon, which proves
# nothing about the bound. That is not a reason to settle for the unit test: it
# is a reason to give the bound a feed where it is the only gate.
#
# So this deploys a throwaway contract from the same wasm as the live one, with
# one feed carrying the same 500 bps bound as PC_NAV and min_interval_secs of
# zero, and pushes four values through it. The wasm is the discriminator, and
# the script prints its hash next to the live contract's so the two can be seen
# to be the same code.
#
# The defect this rules out: the check used to compute the move as
# delta * BPS / last.nav and compare the quotient against deviation_bps.
# Integer division truncates toward zero, so on a NAV of 10000000 against a
# 500 bps bound, 10500001 through 10500999 all computed as 500 and were
# accepted. The bound advertised 5 percent and enforced 5.00999 percent. The
# retired CBH7NW5L still accepts 10500999 if anybody wants to see the other
# half of this.
#
# Costs a deploy on testnet and leaves the throwaway contract behind, in nobody's
# record and pointed at by nothing.
set -euo pipefail
cd "$(dirname "$0")/.."

NET=testnet
SRC=${SRC:-agama-poc}
WASM=target/wasm32v1-none/release/oracle_adapter.wasm
LIVE=$(python3 -c "import json;print(json.load(open('deployments/testnet.json'))['contracts']['oracleAdapter'])")

[ -f "$WASM" ] || { echo "no build at $WASM; run: stellar contract build" >&2; exit 2; }
ADMIN=$(stellar keys address "$SRC")

echo "==> the code under test is the code on the ledger"
LOCAL_HASH=$(shasum -a 256 "$WASM" | cut -d' ' -f1)
LEDGER_HASH=$(stellar contract info interface --id "$LIVE" --network "$NET" >/dev/null 2>&1 \
  && stellar contract fetch --id "$LIVE" --network "$NET" 2>/dev/null | shasum -a 256 | cut -d' ' -f1)
echo "    local build       ${LOCAL_HASH:0:32}"
echo "    live $LIVE"
echo "                      ${LEDGER_HASH:0:32}"
if [ "$LOCAL_HASH" != "$LEDGER_HASH" ]; then
  echo "    they differ, so this proves something about the local build only." >&2
  echo "    check-deployment-record.sh --wasm says why." >&2
fi

echo ""
echo "==> a throwaway contract from that wasm, one feed, the bound as its only gate"
S=$(stellar contract deploy --wasm "$WASM" --source "$SRC" --network "$NET" -- --admin "$ADMIN" 2>&1 | tail -1)
case "$S" in C*) echo "    $S" ;; *) echo "    deploy failed: $S" >&2; exit 1 ;; esac
inv() { stellar contract invoke --id "$S" --source "$SRC" --network "$NET" -- "$@" 2>&1; }
inv register_feed --admin "$ADMIN" --feed_id BOUND --staleness_secs 604800 \
  --deviation_bps 500 --min_nav 5000000 --max_nav 20000000 --min_interval_secs 0 >/dev/null
inv add_reporter --admin "$ADMIN" --reporter "$ADMIN" >/dev/null
echo "    BOUND: 500 bps, band 5000000 to 20000000, no minimum interval"

# The reported timestamp is held 60 seconds back. Ledger close time trails wall
# clock, and a timestamp equal to now is read as being in the future: 509, which
# is a different error and would look like a rejection if it were not read.
push() {
  local out; out=$(inv push_nav --reporter "$ADMIN" --feed_id BOUND --nav "$1" \
    --timestamp "$(( $(date -u +%s) - 60 ))" || true)
  local err; err=$(echo "$out" | grep -oE 'Error\(Contract, #[0-9]+\)' | head -1 || true)
  if [ -n "$err" ]; then echo "REJECTED $err"; else echo "ACCEPTED"; fi
}
nav() { inv get_nav --feed_id BOUND | tail -1 | tr -d '"'; }

PASS=0; FAIL=0
case_is() { # nav, expected, what it shows
  local got; got=$(push "$1")
  case "$got" in "$2"*) PASS=$((PASS+1)); echo "  PASS  $1  $got   $3" ;;
                     *) FAIL=$((FAIL+1)); echo "  FAIL  $1  expected $2, got $got   $3" ;; esac
}

echo ""
echo "==> four values against a baseline of 10000000"
push 10000000 >/dev/null
[ "$(nav)" = "10000000" ] || { echo "  the baseline did not take" >&2; exit 1; }
case_is 10500000 ACCEPTED "exactly 500 bps, the bound is inclusive"
case_is 10000000 ACCEPTED "back down, which resets the baseline"
case_is 10500001 REJECTED "one stroop past the bound"
case_is 10500999 REJECTED "the widest point the old division let through"
[ "$(nav)" = "10000000" ] || { echo "  a rejected push moved the stored value" >&2; FAIL=$((FAIL+1)); }

echo ""
echo "  the rejections answer 510, DeviationOutOfBounds. 509 is TimestampInFuture"
echo "  and 514 is TooSoon: neither is this bound, and reading one as the other is"
echo "  how a rate limit gets mistaken for a proof."
echo ""
echo "  $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
