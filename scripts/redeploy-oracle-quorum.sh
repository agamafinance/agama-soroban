#!/usr/bin/env bash
# Replace the Oracle Adapter with the one that carries a per-feed quorum
# threshold, and put the feeds back exactly as they were.
#
# Why redeploy at all
#
# The contracts in this repository are meant to be the contracts on the ledger.
# Every review so far has ended by fetching all seven deployed WASMs and hashing
# them against a local build, and a source tree that is one contract ahead of the
# chain turns that check into a claim. The Oracle Adapter is not upgradeable, so
# the only way to keep it true is a new deployment.
#
# What does not change
#
# Every feed's quorum threshold defaults to 1, and this script raises none of
# them. A threshold of 1 is V1: the first vote is quorum and it commits, with the
# staleness, band, deviation and rate limit guards running exactly as they did
# before. So the deployed behaviour after this script is the deployed behaviour
# before it, and what has changed is that the V2 path the architecture document
# describes now exists in the contract rather than only in the document. Raising
# a live feed to 2-of-3 needs a second and a third reporter key that are actually
# independent, which is an operational decision and not this script's to make.
#
# Only the Vault names the Oracle Adapter, so the rewiring is one setter.
#
# Usage: bash scripts/redeploy-oracle-quorum.sh
set -euo pipefail
cd "$(dirname "$0")/.."

NET=testnet
SRC=agama-poc
WASM=target/wasm32v1-none/release
DEP=deployments/testnet.json

j() { python3 -c "import json;d=json.load(open('$DEP'));print($1)"; }
ADMIN=$(stellar keys address "$SRC")
VAULT=$(j "d['contracts']['vault']")
OLD_ORACLE=$(j "d['contracts']['oracleAdapter']")
VAULT_FEED=$(j "d['vaultOracleFeed']")

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  PASS  $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL  $1"; }
num() { echo "$1" | tr -d '"'; }
assert_eq() { if [ "$(num "$2")" = "$(num "$3")" ]; then ok "$1 ($(num "$2"))"; else bad "$1: got $(num "$2"), want $(num "$3")"; fi; }

q()  { stellar contract invoke --id "$1" --source "$SRC" --network "$NET" --send=no -- "${@:2}" 2>/dev/null; }
q0() { q "$@" | tr -d '"'; }
tx() { stellar contract invoke --id "$1" --source "$SRC" --network "$NET" -- "${@:2}" 2>&1 \
         | grep -oE '[0-9a-f]{64}' | head -1; }

echo "vault (kept)     = $VAULT"
echo "outgoing oracle  = $OLD_ORACLE"

echo ""
echo "==> the values the outgoing feeds are carrying, to be restored"
for f in USDC_USD PC_NAV EF_BOND; do
  printf -v "NAV_$f" '%s' "$(q0 "$OLD_ORACLE" get_nav --feed_id "$f")"
  eval "echo \"    $f = \$NAV_$f\""
done

echo ""
echo "==> building"
stellar contract build >/dev/null

echo ""
echo "==> deploying the replacement"
OUT=$(stellar contract deploy --wasm "$WASM/oracle_adapter.wasm" --source "$SRC" --network "$NET" \
  -- --admin "$ADMIN" 2>&1)
echo "$OUT" | grep -oE 'Using wasm hash [0-9a-f]{64}' | sed 's/^/    /'
echo "$OUT" | grep -oE 'Transaction hash is [0-9a-f]{64}' | sed 's/Transaction hash is/    deploy tx/'
ORACLE=$(echo "$OUT" | grep -oE 'C[A-Z2-7]{55}' | tail -1)
echo "    oracle-adapter = $ORACLE"

echo ""
echo "==> the reporter, then the three feeds, with the recorded parameters"
echo "    add_reporter        tx $(tx "$ORACLE" add_reporter --admin "$ADMIN" --reporter "$ADMIN")"
for f in USDC_USD PC_NAV EF_BOND; do
  S=$(j "d['oracleFeeds']['$f']['stalenessSecs']")
  D=$(j "d['oracleFeeds']['$f']['deviationBps']")
  MIN=$(j "d['oracleFeeds']['$f']['minNav']")
  MAX=$(j "d['oracleFeeds']['$f']['maxNav']")
  I=$(j "d['oracleFeeds']['$f']['minIntervalSecs']")
  echo "    register $f  tx $(tx "$ORACLE" register_feed --admin "$ADMIN" --feed_id "$f" \
    --staleness_secs "$S" --deviation_bps "$D" --min_nav "$MIN" --max_nav "$MAX" --min_interval_secs "$I")"
done

echo ""
echo "==> restoring the values, one report per feed"
# A reported timestamp ahead of the ledger's close time is refused as being
# in the future, and the local clock can be a few seconds ahead of it. Backing
# off a minute costs nothing: every feed's staleness window is hours or days.
NOW=$(( $(date -u +%s) - 60 ))
for f in USDC_USD PC_NAV EF_BOND; do
  eval "V=\$NAV_$f"
  echo "    push $f      tx $(tx "$ORACLE" push_nav --reporter "$ADMIN" --feed_id "$f" --nav "$V" --timestamp "$NOW")"
done

echo ""
echo "==> repointing the one contract that names it"
echo "    vault.set_oracle    tx $(tx "$VAULT" set_oracle --admin "$ADMIN" --oracle "$ORACLE" --feed_id "$VAULT_FEED")"

echo ""
echo "==> checking"
# The Vault exposes no getter for its oracle pointer or its feed id, which every
# other pointer on it has. So the pair is checked by what it produces rather
# than by reading it back: get_nav() has to answer, and answer with the value
# that was just restored. Confirming it against a value only the replacement
# holds means moving a feed, and every feed is inside its own minimum interval
# for the first hour after this runs, which is the rate limit working rather
# than an obstacle to work around.
for f in USDC_USD PC_NAV EF_BOND; do
  eval "V=\$NAV_$f"
  assert_eq "$f is back where it was" "$(q0 "$ORACLE" get_nav --feed_id "$f")" "$V"
  assert_eq "$f quorum threshold is still the V1 default" "$(q0 "$ORACLE" quorum_threshold --feed_id "$f")" "1"
done
eval "VF=\$NAV_$VAULT_FEED"
assert_eq "the Vault reads its feed and gets the restored value" "$(q0 "$VAULT" get_nav)" "$VF"
echo "    reporters()  = $(q "$ORACLE" reporters)"

echo ""
echo "==> writing $DEP"
python3 - "$DEP" "$ORACLE" "$OLD_ORACLE" <<'PY'
import json, sys
path, oracle, old = sys.argv[1:]
dep = json.load(open(path))
history = dep.get('superseded', [])
ORDINALS = ['first', 'second', 'third', 'fourth', 'fifth', 'sixth', 'seventh',
            'eighth', 'ninth', 'tenth', 'eleventh', 'twelfth']
generation = 1 + sum(1 for e in history if e['contract'] == 'oracleAdapter')
history.append({
    'contract': 'oracleAdapter',
    'generation': generation,
    'label': 'Oracle Adapter, %s deployment' % ORDINALS[generation - 1],
    'address': old,
    'supersededBy': 'oracleAdapter',
    'reason': (
        'Replaced by scripts/redeploy-oracle-quorum.sh so that the deployed '
        'Oracle Adapter is the one in this repository. It has no per-feed '
        'quorum threshold, so the V2 path the architecture document describes, '
        'a value committing only once N distinct authorized reporters have '
        'submitted it for the same round, existed only in the document. The '
        'replacement carries it with every feed defaulting to a threshold of 1, '
        'which is V1 exactly: the first vote is quorum and it commits, and the '
        'staleness, band, deviation and rate limit guards run unchanged. No '
        'live feed was raised above 1 by that deployment, because a real 2-of-3 '
        'needs reporter keys that are actually independent and that is an '
        'operational decision. Only the Vault names this contract, so the '
        'rewiring was one set_oracle and the three feeds re-registered with '
        'their recorded parameters and their values restored.'
    ),
})
dep['contracts']['oracleAdapter'] = oracle
dep['superseded'] = history
dep['oracleQuorum'] = (
    'Every feed carries a quorum threshold, defaulting to 1. Above 1, a value '
    'commits only once that many distinct authorized reporters have submitted '
    'the same value for the same round, a round being one feed and one reported '
    'timestamp. A reporter gets one vote per round whatever it votes for. The '
    'record of who has voted is cleared when a round commits, because the '
    'feed timestamp then advances and monotonicity closes the round behind it, '
    'and is deliberately kept when a round is refused, because a refusal moves '
    'no state and leaves the round open: without it a reporter could seed a '
    'value, wait for the round to be refused on another, vote for its own a '
    'second time and carry a quorum of two alone. A threshold of 1 is exempt '
    'from that, since one vote is the whole round. Reaching quorum changes how '
    'many reporters must agree before the per-feed guards run, never whether '
    'they run. It defends against one compromised or malfunctioning reporter, '
    'not against a colluding majority and not against a reporter set that '
    'honestly agrees on the same wrong upstream source. Testnet runs every feed '
    'at 1.'
)
json.dump(dep, open(path, 'w'), indent=2)
open(path, 'a').write('\n')
print(json.dumps(dep['contracts'], indent=2))
PY

echo ""
echo "  $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
