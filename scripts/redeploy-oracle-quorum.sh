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

# This migration repoints the contract every keeper writes to, so it takes the
# same lock the suites take and for a stronger reason: a keeper pushing to the
# outgoing oracle between the repoint and the record being rewritten is a value
# written somewhere nothing reads, and a keeper reaching for the operator's
# sequence number mid-migration is a half-applied migration. The keepers stand
# aside for this lock since 2026-11-01, so taking it is enough.
LOCK=/tmp/agama-smoke-$SRC.lock
if ! mkdir "$LOCK" 2>/dev/null; then
  echo "a suite or another migration holds $SRC ($(cat "$LOCK/owner" 2>/dev/null || echo unknown))." >&2
  echo "A migration is the last thing that should share this account. Wait for it." >&2
  exit 1
fi
echo "pid $$ at $(date -u +%H:%M:%S), redeploy-oracle-quorum" > "$LOCK/owner"
trap 'rm -rf "$LOCK"' EXIT

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  PASS  $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL  $1"; }
num() { echo "$1" | tr -d '"'; }
assert_eq() { if [ "$(num "$2")" = "$(num "$3")" ]; then ok "$1 ($(num "$2"))"; else bad "$1: got $(num "$2"), want $(num "$3")"; fi; }

q()  { stellar contract invoke --id "$1" --source "$SRC" --network "$NET" --send=no -- "${@:2}" 2>/dev/null; }
q0() { q "$@" | tr -d '"'; }
tx() { stellar contract invoke --id "$1" --source "$SRC" --network "$NET" -- "${@:2}" 2>&1 \
         | grep -oE '[0-9a-f]{64}' | head -1; }
# Signed by somebody other than $SRC. Needed since the oracle admin stopped
# being a reporter: carrying a value across now takes two reporter signatures.
tx_as() { stellar contract invoke --id "$2" --source "$1" --network "$NET" -- "${@:3}" 2>&1 \
         | grep -oE '[0-9a-f]{64}' | head -1; }

echo "vault (kept)     = $VAULT"
echo "outgoing oracle  = $OLD_ORACLE"

echo ""
echo "==> the values the outgoing feeds are carrying, to be restored"
for f in USDC_USD PC_NAV PC_NAV2 EF_BOND; do
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
echo "==> the reporters, then the four feeds, with the recorded parameters"
# The reporter set is the two dedicated reporter keys, and deliberately not the
# admin. An admin that is also a reporter can lower the quorum to one, remove
# the other reporter and then post any NAV on its own signature, so a quorum of
# two held by such a key is a quorum of one. The live instance was corrected on
# 2026-10-31; this line is what stops the next deployment undoing it.
for R in $(j "' '.join(d['oracleReporters']['addresses'])"); do
  [ "$R" = "$ADMIN" ] && { echo "    refusing to make the admin a reporter"; exit 1; }
  echo "    add_reporter ${R:0:8}  tx $(tx "$ORACLE" add_reporter --admin "$ADMIN" --reporter "$R")"
done
for f in USDC_USD PC_NAV PC_NAV2 EF_BOND; do
  S=$(j "d['oracleFeeds']['$f']['stalenessSecs']")
  D=$(j "d['oracleFeeds']['$f']['deviationBps']")
  MIN=$(j "d['oracleFeeds']['$f']['minNav']")
  MAX=$(j "d['oracleFeeds']['$f']['maxNav']")
  I=$(j "d['oracleFeeds']['$f']['minIntervalSecs']")
  echo "    register $f  tx $(tx "$ORACLE" register_feed --admin "$ADMIN" --feed_id "$f" \
    --staleness_secs "$S" --deviation_bps "$D" --min_nav "$MIN" --max_nav "$MAX" --min_interval_secs "$I")"
done

echo ""
echo "==> the quorum, before any value is carried"
# Before, and not after. A feed registered at the default threshold of 1 commits
# on the first of the two votes below, so the round that was meant to prove two
# reporters agreed would prove one reporter pushed, and the threshold would then
# be raised over a value that never needed it. The script did not set the
# threshold at all, which is how a replacement for the contract that introduced
# the quorum would have come up without one.
for f in USDC_USD PC_NAV PC_NAV2 EF_BOND; do
  echo "    set_quorum_threshold $f = 2  tx $(tx "$ORACLE" set_quorum_threshold --admin "$ADMIN" --feed_id "$f" --threshold 2)"
  assert_eq "$f is at two before a value is carried" "$(q0 "$ORACLE" quorum_threshold --feed_id "$f")" "2"
done

echo ""
echo "==> restoring the values, one report per feed"
# A reported timestamp ahead of the ledger's close time is refused as being
# in the future, and the local clock can be a few seconds ahead of it. Backing
# off a minute costs nothing: every feed's staleness window is hours or days.
NOW=$(( $(date -u +%s) - 60 ))
# Two reporter signatures per feed, and neither of them the admin.
#
# This was one push_nav signed by $ADMIN, which stopped working twice over on
# 2026-10-31: the admin was taken out of the reporter set, so it returns #503
# NotAReporter, and every feed runs at a quorum of two, so a single vote records
# a vote and commits nothing. A script that carries values across and silently
# carries none would leave the replacement with no value on any feed, which is
# every reader of it reverting until somebody noticed.
R1=${R1:-agama-oracle-2}
R2=${R2:-agama-reporter-2}
R1_ADDR=$(stellar keys address "$R1")
R2_ADDR=$(stellar keys address "$R2")
[ "$R1_ADDR" = "$ADMIN" ] || [ "$R2_ADDR" = "$ADMIN" ] && {
  echo "one of the reporter identities is the admin, which is the hole this fixed"; exit 1; }
for f in USDC_USD PC_NAV PC_NAV2 EF_BOND; do
  eval "V=\$NAV_$f"
  stellar contract invoke --id "$ORACLE" --source "$R1" --network $NET -- submit_nav \
    --reporter "$R1_ADDR" --feed_id "$f" --nav "$V" --timestamp "$NOW" >/dev/null 2>&1
  echo "    submit $f    tx $(tx_as "$R2" "$ORACLE" submit_nav --reporter "$R2_ADDR" --feed_id "$f" --nav "$V" --timestamp "$NOW")"
done

echo ""
echo "==> repointing the two contracts that name it"
# Two, not one. The Vault stores the address and so does the Etherfuse adapter,
# which prices its bond position through `oracle_value`; the private credit
# adapters store only a feed symbol and reach the oracle through nothing, so
# they need no repointing. This step said "the one contract that names it" and
# repointed the Vault alone, which would have left the adapter valuing its
# position against an oracle nothing updates any more.
echo "    vault.set_oracle    tx $(tx "$VAULT" set_oracle --admin "$ADMIN" --oracle "$ORACLE" --feed_id "$VAULT_FEED")"
EF=$(j "d['poolAdapters']['etherfuse']")
echo "    etherfuse.set_oracle tx $(tx "$EF" set_oracle --admin "$ADMIN" --oracle "$ORACLE")"
assert_eq "the adapter names the replacement" "$(q0 "$EF" oracle)" "$ORACLE"

echo ""
echo "==> checking"
# The Vault exposes no getter for its oracle pointer or its feed id, which every
# other pointer on it has. So the pair is checked by what it produces rather
# than by reading it back: get_nav() has to answer, and answer with the value
# that was just restored. Confirming it against a value only the replacement
# holds means moving a feed, and every feed is inside its own minimum interval
# for the first hour after this runs, which is the rate limit working rather
# than an obstacle to work around.
for f in USDC_USD PC_NAV PC_NAV2 EF_BOND; do
  eval "V=\$NAV_$f"
  assert_eq "$f is back where it was" "$(q0 "$ORACLE" get_nav --feed_id "$f")" "$V"
  # Read back rather than assumed from the call that set it, because the value
  # that matters is the one the contract holds. This asserted the V1 default of
  # 1, which was true when the quorum was the thing being introduced.
  assert_eq "$f runs at a quorum of two" "$(q0 "$ORACLE" quorum_threshold --feed_id "$f")" "2"
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
        'Oracle Adapter is the one in this repository, carrying three fixes '
        'that could not reach it any other way: no contract here has an '
        'upgrade entry point. (1) A round is keyed on (feed, timestamp) and the '
        'tally on the value, and the outgoing instance stored a flag for who '
        'had voted rather than what they voted for, so a reporter was locked to '
        'its first value: two reporters who disagreed at one timestamp split '
        'the tally one and one, neither could revote, the round was dead, and a '
        'reporter that disagreed on every round stopped the feed for good. A '
        'feed any single reporter can switch off does not have a quorum of two, '
        'it has a veto. Raised by an outside reader of the repository on '
        '2026-10-27. The replacement stores the value and lets a reporter move '
        'its vote, which cannot manufacture a quorum because the value a vote '
        'leaves is decremented in the call that increments the one it joins. '
        '(2) set_quorum_threshold had no floor above one, so the admin key '
        'could drop a quorum of two to one, post alone and put it back, in '
        'three transactions with nothing visible in advance. Raising is still '
        'immediate; lowering is announced, waits 72 hours and is applied by a '
        'second call with the same value, readable in pending_quorum_reduction. '
        'An upward-only ratchet was the obvious alternative and is worse: it '
        'turns one lost reporter key into a feed nobody can ever price again. '
        '(3) The staleness window is measured against the timestamp the '
        'reporter attests to and nothing checked that timestamp was inside it, '
        'so a reading could be stored already expired and would read as current '
        'until the window ran out from the moment of its own obsolescence. '
        'ReportAlreadyStale 520. Two contracts name this one, the Vault and the '
        'Etherfuse adapter, so the rewiring was two set_oracle calls, four feeds '
        're-registered with their recorded parameters, the reporter set seeded '
        'from oracleReporters.addresses with the admin refused outright, every '
        'feed set to a quorum of two before any value was carried, and the four '
        'values restored by two reporter signatures each.'
    ),
})
dep['contracts']['oracleAdapter'] = oracle
dep['superseded'] = history

# The declaration that the tree was ahead of this contract stops being true the
# moment the replacement is the tree. check-deployment-record refuses a contract
# that "matches the chain but is still declared as source ahead of it", and it is
# right to: a declaration that has outlived its divergence is a false statement
# of its own, and this one would have gone red within a minute of the deploy.
ahead = dep.get('treeAheadOfLedger') or []
dropped = [e for e in ahead if e.get('contract') == 'oracleAdapter']
dep['treeAheadOfLedger'] = [e for e in ahead if e.get('contract') != 'oracleAdapter']
for e in dropped:
    print('dropped the treeAheadOfLedger entry for %s, which this deploy settles'
          % e.get('contract'))
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
    'at 2, set before any value is carried across a migration so that the '
    'round proving two reporters agree is not a round one reporter committed '
    'at the default. A reporter may move its vote inside a round, which is not '
    'a second vote: the value it leaves is decremented in the call that '
    'increments the one it joins, so the sum of a round tally never counts a '
    'reporter twice however many times it changes its mind. Without that, two '
    'reporters who disagreed at one timestamp killed the round and a reporter '
    'that disagreed on every round killed the feed. Lowering a threshold is '
    'announced and waits 72 hours; raising one is immediate.'
)
json.dump(dep, open(path, 'w'), indent=2)
open(path, 'a').write('\n')
print(json.dumps(dep['contracts'], indent=2))
PY

echo ""
echo "  $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
