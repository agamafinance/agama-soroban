#!/usr/bin/env bash
# Properties of the source that nothing on the ledger can prove.
#
# Three of the controls this protocol relies on are not entry points and not
# state. They are shapes the source has to keep, and the only thing that had
# been holding them was a comment and whoever read it last. A comment is not a
# check: the oracle admin was in the reporter set for weeks under a comment that
# explained why it should not be.
#
#   bash scripts/check-source-invariants.sh
#
# Needs nothing: no network, no keys, no build. It reads the tree.
set -uo pipefail
cd "$(dirname "$0")/.."

pass=0; fail=0
ok()  { printf '  PASS  %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); }

echo "== no current deployment script makes the oracle admin a reporter =="
# A key that can call set_quorum_threshold and remove_reporter and also vote can
# dissolve its own quorum. The live instance was corrected on 2026-10-31, and the
# correction survives a redeployment only if the scripts that do the redeploying
# refuse the admin. deploy-core is the one exception and says so in its header:
# it cannot run against these contracts at all, every one of them having replaced
# initialize with a __constructor, and it is kept as the record of what was done.
OFFENDERS=""
for f in scripts/deploy-*.sh scripts/redeploy-*.sh scripts/rewire-*.sh; do
  [ -f "$f" ] || continue
  case "$f" in scripts/deploy-core.sh) continue;; esac
  if grep -qE 'add_reporter[^#]*--reporter *"?\$ADMIN"?' "$f"; then
    OFFENDERS="$OFFENDERS $f"
  fi
done
if [ -n "$OFFENDERS" ]; then
  bad "these seed the reporter set with the admin:$OFFENDERS"
else
  ok "none of them passes \$ADMIN to add_reporter"
fi

# And the ones that do seed a reporter set read it from the record, so there is
# one place the addresses live.
# Two sources of truth are acceptable and a third is not. Reading
# oracleReporters.addresses out of the record is one; carrying the set across
# from the contract being replaced, which is what redeploy-oracle-exact-bound
# does, is the other and is arguably better, because it preserves whatever is
# actually live. Typing an address into the script is the one that is not.
SEEDERS=$(grep -lE "add_reporter" scripts/deploy-*.sh scripts/redeploy-*.sh 2>/dev/null | grep -v deploy-core || true)
for f in $SEEDERS; do
  if grep -q "oracleReporters" "$f"; then
    ok "$(basename "$f") seeds reporters from oracleReporters.addresses"
  elif grep -qE '\$\(q "\$OLD" reporters|reporters\)' "$f"; then
    ok "$(basename "$f") carries the reporter set across from the contract it replaces"
  else
    bad "$(basename "$f") calls add_reporter without reading the record or the live set"
  fi
done

echo ""
echo "== the record's reporter set does not contain its admin =="
R=$(python3 -c "
import json
d = json.load(open('deployments/testnet.json'))
o = d['oracleReporters']
print('yes' if o['admin'] in o['addresses'] else 'no')")
[ "$R" = "no" ] && ok "oracleReporters.admin is not in oracleReporters.addresses" \
                || bad "oracleReporters.admin is one of the addresses, which is the hole itself"

echo ""
echo "== every contract that keeps a loss counter says it can fall =="
# "cumulative, never fall" was in the README for weeks and the ledger disproved
# it: written_off went 100000000 to 99000000 to 97000000 as recoveries landed.
# What is true is narrower, that a write-down takes nothing out of them, and the
# narrower sentence is the one the reserve floor actually needs. This checks the
# false one has not come back.
# The claim and the correction use the same words, so the lines that disclaim it
# are excluded by name rather than by pattern: a check that cannot tell "X is
# false" from "X" is a check that has to be ignored, and an ignored check is
# worse than none.
HITS=$(grep -rniE "recognised_losses[^.]{0,40}never fall|written_off[^.]{0,40}never fall|cumulative, never fall" \
         README.md docs/ contracts/ adapters/ 2>/dev/null \
       | grep -viE "is not true|used to say|disprove|was the wording|never takes anything out" || true)
if [ -n "$HITS" ]; then
  bad "something claims the loss counters never fall, which the ledger disproves:"
  printf '%s\n' "$HITS" | sed 's/^/          /'
else
  ok "nothing claims the loss counters never fall"
fi

echo ""
echo "== every keeper stands aside for a suite holding its account =="
# The suites lock the operator account because two signers on one sequence
# number is TxBadSeq for both. The keepers sign as the same key under launchd
# and were never part of it, which cost five assertions in smoke-mediums on
# 2026-11-01.
for f in scripts/keeper-oracle.sh scripts/keeper-reflector.sh scripts/keeper-etherfuse.sh \
         scripts/keeper-yield.sh scripts/keeper-sagusd-book.sh; do
  [ -f "$f" ] || continue
  if grep -q "keeper_stand_aside_if_suite_running" "$f"; then
    ok "$(basename "$f") stands aside"
  else
    bad "$(basename "$f") signs as the operator and does not check the suite lock"
  fi
done

echo ""
printf 'TOTAL: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
