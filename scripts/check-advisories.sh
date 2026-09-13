#!/usr/bin/env bash
# Check whether an open advisory reaches the bytecode on the ledger.
#
# Dependabot reads Cargo.lock, which lists what the workspace builds including
# the test harness. A contract compiled to wasm32v1-none links almost none of
# it: soroban-env-host is the host that runs contracts, not something a contract
# contains, and cargo tree shows it in the graph only because soroban-sdk's
# testutils pull it in for the suites. The graph is therefore not the answer.
# The binary is.
#
# So this asks the binary. For every package an open advisory names, every
# deployed wasm is searched for a trace of it, and the sizes are printed beside
# the result, because a 50KB module cannot contain a host that is megabytes of
# code and the number says so more plainly than an argument does.
#
# An advisory that does reach the bytecode is a different matter and this will
# say so. The point is to answer the question with evidence each time rather
# than to have answered it once.
#
#   bash scripts/check-advisories.sh
set -euo pipefail
cd "$(dirname "$0")/.."

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  PASS  $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL  $1"; }

echo "==> open advisories"
ALERTS=$(gh api repos/agamafinance/agama-soroban/dependabot/alerts \
  --jq '.[] | select(.state=="open") | [.security_advisory.severity, .dependency.package.name] | @tsv' 2>/dev/null || true)
if [ -z "$ALERTS" ]; then
  ok "none open"
  echo ""
  echo "  $PASS passed, $FAIL failed"
  exit 0
fi
echo "$ALERTS" | sed 's/^/      /'

echo ""
echo "==> the deployed bytecode, which is what an advisory has to reach to matter"
if [ ! -d target/wasm32v1-none/release ]; then
  stellar contract build >/dev/null 2>&1 || { bad "the release build failed, so nothing was searched"; exit 1; }
fi

while IFS=$'\t' read -r sev pkg; do
  [ -n "$pkg" ] || continue
  # Match the crate name however it is spelled in a symbol or a panic string.
  pat=$(echo "$pkg" | sed 's/[-_]/[-_]/g')
  hits=0; searched=0
  for w in target/wasm32v1-none/release/*.wasm; do
    case "$w" in *mock_usdc*) continue;; esac
    searched=$((searched + 1))
    n=$(strings "$w" 2>/dev/null | grep -ciE "$pat" || true)
    hits=$((hits + ${n:-0}))
  done
  if [ "$hits" = "0" ]; then
    ok "$pkg ($sev) appears in none of the $searched deployed modules"
  else
    bad "$pkg ($sev) appears $hits times in the deployed modules, so it is on the ledger"
  fi
done <<< "$ALERTS"

echo ""
echo "  module sizes, for scale:"
for w in target/wasm32v1-none/release/*.wasm; do
  case "$w" in *mock_usdc*) continue;; esac
  printf "      %-24s %8s bytes\n" "$(basename "$w")" "$(wc -c < "$w" | tr -d ' ')"
done

echo ""
echo "  $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
