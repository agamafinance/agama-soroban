#!/usr/bin/env bash
# Two originators, two NAVs, one wasm.
#
# The thing being proved is that onboarding a counterparty does not need a
# compiler. The private credit adapter used to carry its feed as a compiled
# constant, `pub const ORACLE_FEED: Symbol = symbol_short!("PC_NAV")`, so a
# second originator meant a second build of the same contract, and a protocol
# that needs a build to take on a counterparty will not take one on. The feed is
# a constructor parameter now, stored per instance.
#
# Why one instance per originator rather than one adapter holding several. An
# originator's NAV is a statement about its own book. Averaging two books into
# one number throws away the only thing a concentration cap can act on: the
# Engine's caps are keyed on originator and jurisdiction, and a blended feed
# would price capital at a number no originator reported. So the unit of
# everything is the pair, one instance and one feed, and the Engine and the
# keeper both already work that way.
#
#   bash scripts/e2e-two-originators.sh
set -uo pipefail
cd "$(dirname "$0")/.."

NET=${NET:-testnet}
SRC=${SRC:-agama-poc}
DEP=deployments/testnet.json
j() { python3 -c "import json;print(json.load(open('$DEP'))$1)"; }
ADMIN=$(j "['admin']")
ENGINE=$(j "['contracts']['allocationEngine']")
ORACLE=$(j "['contracts']['oracleAdapter']")
PC1=$(j "['poolAdapters']['private-credit']")
PC2=$(j "['poolAdapters']['private-credit-2']")

P=0; F=0
ok()  { printf '  PASS  %-52s %s\n' "$1" "${2:-}"; P=$((P+1)); }
bad() { printf '  FAIL  %-52s %s\n' "$1" "${2:-}"; F=$((F+1)); }
eq()  { [ "$2" = "$3" ] && ok "$1" "$2" || bad "$1" "got $2 want $3"; }
rd()  { stellar contract invoke --id "$1" --source "$SRC" --network "$NET" --send=no -- "${@:2}" 2>&1 \
        | tail -1 | tr -d '"'; }

echo "== 1. one wasm, two instances, two feeds"
eq "the first instance answers with its own feed"  "$(rd "$PC1" oracle_feed)" "PC_NAV"
eq "the second answers with a different one"       "$(rd "$PC2" oracle_feed)" "PC_NAV2"
eq "and they are the same kind of pool"            "$(rd "$PC2" pool_kind)" "$(rd "$PC1" pool_kind)"

echo
echo "== 2. the Engine holds them as separate counterparties"
O1=$(rd "$ENGINE" get_pool --pool_id "$PC1" | python3 -c "import sys;print(sys.stdin.read())" 2>/dev/null)
printf '        pool one %s\n' "$(printf '%s' "$O1" | head -c 160)"
O2=$(rd "$ENGINE" get_pool --pool_id "$PC2")
printf '        pool two %s\n' "$(printf '%s' "$O2" | head -c 160)"
printf '%s' "$O2" | grep -q "QIRO2" && ok "the second names its own originator" "QIRO2" \
  || bad "the second names its own originator" "$O2"
printf '%s' "$O2" | grep -q "IE" && ok "and its own jurisdiction" "IE" \
  || bad "and its own jurisdiction" "$O2"

echo
echo "== 3. both feeds are registered, bounded, and at quorum two"
for f in PC_NAV PC_NAV2; do
  FEED=$(rd "$ORACLE" get_feed --feed_id "$f")
  printf '%s' "$FEED" | grep -q "deviation_bps" && ok "$f is registered" \
    || bad "$f is registered" "$FEED"
  eq "$f needs two signatures"  "$(rd "$ORACLE" quorum_threshold --feed_id "$f")" "2"
done

echo
echo "== 4. the keeper prices each pool from the feed that pool names"
PLAN=$(DRY=1 bash scripts/keeper-yield.sh 2>&1)
printf '%s\n' "$PLAN" | sed 's/^/        /'
for f in EF_BOND PC_NAV PC_NAV2; do
  # Anchored, because PC_NAV2 contains PC_NAV and an unanchored count of the
  # shorter name matches the longer one's line as well.
  eq "$f is a line of its own"  "$(printf '%s' "$PLAN" | grep -cE "^ +$f +exposure")" "1"
done
# The reviewer's finding was that one feed's move was applied to every pool. The
# shape that makes that impossible is this one: a group per feed, and a feed read
# once per group.
EXP2=$(rd "$ENGINE" get_exposure --pool_id "$PC2")
printf '%s' "$PLAN" | grep "PC_NAV2" | grep -q "$EXP2" \
  && ok "the second originator's exposure sits under its own feed" "$EXP2" \
  || bad "the second originator's exposure sits under its own feed" "$EXP2"

echo
echo "== 5. the feed cannot move under live capital"
if [ "$EXP2" -gt 0 ]; then
  R=$(stellar contract invoke --id "$PC2" --source "$SRC" --network "$NET" -- \
      set_oracle_feed --admin "$ADMIN" --feed PC_NAV 2>&1 | grep -oE "Error\(Contract, #[0-9]+\)" | head -1)
  eq "repointing a funded instance is refused"  "$R" "Error(Contract, #605)"
  eq "and its feed did not move"                "$(rd "$PC2" oracle_feed)" "PC_NAV2"
else
  printf '        SKIP  the second instance is empty, so there is no live capital to guard.\n'
fi

echo
printf 'TOTAL: %s passed, %s failed\n' "$P" "$F"
[ "$F" -eq 0 ]
