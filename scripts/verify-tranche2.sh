#!/usr/bin/env bash
# Tranche 2, checked by a stranger.
#
# Every other script here signs as the protocol's admin or as one of the
# oracle's reporters, because allocate, set_caps and submit_nav are gated on
# exactly those keys. That is the security property the tranche is about, and
# it is also what stops a reviewer from running those scripts: they do not have
# the keys, and they should not.
#
# So this one needs nothing. It makes its own account, funds it from friendbot,
# and then checks the submission against the ledger: the caps and the floor as
# the Engine holds them, the three adapters and their exposures, the two books
# agreeing with each other, the Vault pricing its book from the oracle, each
# feed inside its own window, the quorum thresholds, and the share price
# against the supply it is a price of.
#
# It also reproduces two of the four refusals. A contract error comes back from
# simulation, before any signature is involved, so an allocation over the pool
# cap and one that breaks the reserve floor can be refused at an account that
# holds nothing and is nobody. The originator and jurisdiction caps cannot be
# reached that way: no two pools share either, so the per-pool cap refuses
# first, and making them bind means narrowing them, which is admin only. Those
# two are in e2e-concentration-caps.sh and in the unit tests.
#
#   bash scripts/verify-tranche2.sh
#
# The only thing it needs is the stellar CLI and a network.
set -uo pipefail
cd "$(dirname "$0")/.."
NET=${NET:-testnet}
DEP=deployments/testnet.json
j() { python3 -c "import json;print(json.load(open('$DEP'))$1)"; }
ENGINE=$(j "['contracts']['allocationEngine']")
ORACLE=$(j "['contracts']['oracleAdapter']")
VAULT=$(j "['contracts']['vault']")
STAKING=$(j "['contracts']['staking']")
ADMIN=$(j "['admin']")
PC=$(j "['poolAdapters']['private-credit']")

SRC=${SRC:-}
if [ -z "$SRC" ]; then
  SRC=t2-verify-$(date +%s)
  echo "making an account to read with, funded by friendbot"
  stellar keys generate "$SRC" --network "$NET" --fund >/dev/null 2>&1 \
    || { echo "could not create a key; pass SRC=<your identity>"; exit 1; }
  echo "  $(stellar keys address "$SRC")"
fi

pass=0; fail=0
ok(){ if [ "$2" = "$3" ]; then printf '  PASS  %-44s %s\n' "$1" "$2"; pass=$((pass+1));
      else printf '  FAIL  %-44s expected %s, got %s\n' "$1" "$3" "$2"; fail=$((fail+1)); fi; }
atleast(){ if [ "${2:-0}" -ge "$3" ] 2>/dev/null; then printf '  PASS  %-44s %s\n' "$1" "$2"; pass=$((pass+1));
      else printf '  FAIL  %-44s wanted at least %s, got %s\n' "$1" "$3" "${2:-none}"; fail=$((fail+1)); fi; }
call(){ stellar contract invoke --id "$1" --source "$SRC" --network "$NET" --send=no -- "${@:2}" 2>&1 | tail -1; }
# A refusal does not come back on the last line: the CLI prints the error, then
# the event log, then a line about --help. Reading the tail of that finds
# nothing, which is how a guard that fires looks exactly like one that does not.
sim(){ stellar contract invoke --id "$1" --source "$SRC" --network "$NET" --send=no -- "${@:2}" 2>&1 \
         | grep -oE "Error\(Contract, #[0-9]+\)" | head -1; }
num(){ call "$@" | tr -d '"'; }
code(){ printf '%s' "$1" | grep -oE "Error\(Contract, #[0-9]+\)" | head -1; }

echo ""
echo "== the Engine's limits, as the ledger holds them"
CAPS=$(call "$ENGINE" caps)
read -r P O Ju <<<"$(printf '%s' "$CAPS" | python3 -c "import sys,json;c=json.load(sys.stdin);print(c['pool_bps'],c['originator_bps'],c['jurisdiction_bps'])")"
ok "per pool cap" "$P" "4000"
ok "per originator cap" "$O" "4500"
ok "per jurisdiction cap" "$Ju" "5000"
ok "reserve floor" "$(num "$ENGINE" reserve_floor_bps)" "2500"

echo "== the pools it routes into"
POOLS=$(call "$ENGINE" pools)
# Counted from the record rather than typed, because a fourth pool was added
# and both of these said three. A number in a verification script that has to be
# edited every time the thing it verifies changes is a number that will be wrong.
EXPECTED=$(python3 -c "import json;print(len(json.load(open('deployments/testnet.json'))['engineConfig']['pools']))")
ok "adapters registered" "$(printf '%s' "$POOLS" | python3 -c "import sys,json;print(len(json.load(sys.stdin)))")" "$EXPECTED"
# pools() hands back addresses; who each one is comes from get_pool. Printed
# because the reason the originator and jurisdiction caps cannot bind here is
# visible in these six values and nowhere else.
NAMED=0
for p in $(printf '%s' "$POOLS" | python3 -c "import sys,json;print(' '.join(json.load(sys.stdin)))"); do
  META=$(call "$ENGINE" get_pool --pool_id "$p")
  printf '        %s  %s\n' "${p:0:8}" "$(printf '%s' "$META" | python3 -c "
import sys, json
m = json.load(sys.stdin)
print('%-9s %-3s cap %s bps' % (m['originator'], m['jurisdiction'], m['cap_bps']))" 2>/dev/null)"
  printf '%s' "$META" | grep -q '"originator"' && printf '%s' "$META" | grep -q '"jurisdiction"' && NAMED=$((NAMED+1))
done
ok "each carries an originator and a jurisdiction" "$NAMED" "$EXPECTED"
# The six values above are the reason the aggregate caps cannot bind, and the
# record repeats them in prose. Printed and never compared is how a record and
# a ledger drift apart, so the classification itself is checked too.
ok "the record names the same originator and jurisdiction the Engine does" \
   "$(for p in $(printf '%s' "$POOLS" | python3 -c "import sys,json;print(' '.join(json.load(sys.stdin)))"); do
        printf '%s %s\n' "$p" "$(call "$ENGINE" get_pool --pool_id "$p" | tr -d '\n')"; done | python3 -c "
import sys, json
# dict() and not a literal: bash brace-expands a comma inside braces, even
# inside double quotes, and turns one python program into two broken ones.
rec = json.load(open('$DEP'))['engineConfig']['pools']
by_addr = dict()
for v in rec.values():
    if v.get('address'):
        by_addr[v['address']] = (v['originator'], v['jurisdiction'])
bad = []
for line in sys.stdin:
    addr, _, blob = line.partition(' ')
    if not blob.strip().startswith('{'):
        continue
    m = json.loads(blob)
    want = by_addr.get(addr)
    got = (m['originator'], m['jurisdiction'])
    if want is None:
        bad.append(addr[:8] + ' is not in the record')
    elif want != got:
        bad.append(addr[:8] + ': record says ' + str(want) + ', Engine says ' + str(got))
print('the same' if not bad else '; '.join(bad))
")" "the same"
ok "and no two share either, so the pool cap binds first" \
   "$(for p in $(printf '%s' "$POOLS" | python3 -c "import sys,json;print(' '.join(json.load(sys.stdin)))"); do
        call "$ENGINE" get_pool --pool_id "$p"; done | python3 -c "
import sys, json
rows = [json.loads(l) for l in sys.stdin if l.strip().startswith('{')]
o = len({r['originator'] for r in rows}); j = len({r['jurisdiction'] for r in rows})
print('yes' if o == len(rows) and j == len(rows) else 'no')")" "yes"

# The record is a claim about the ledger, so it gets checked against it. This
# list said two pools while the Engine said three, and that drift is what put
# "two adapters are registered" into a draft of the Tranche 2 submission.
echo "== the deployment record agrees with the Engine about who is registered"
ok "every record entry carries an address" "$(python3 -c "
import json, subprocess
rec = json.load(open('$DEP'))['engineConfig']['pools']
want = set()
for k, v in rec.items():
    a = v.get('address')
    if a: want.add(a)
print('listed' if len(want) == len(rec) else 'some entries carry no address')
" )" "listed"
# Both directions. The drift that put "two adapters are registered" into a
# draft was the record naming fewer than the Engine, so that is the direction
# this check was written for; a record naming a pool the Engine does not have
# is the same class of claim and was not caught at all.
ok "the record and the Engine name the same pools" \
   "$(printf '%s' "$POOLS" | python3 -c "
import json, sys
on_chain = set(json.load(sys.stdin))
rec = json.load(open('$DEP'))['engineConfig']['pools']
listed = {v.get('address') for v in rec.values() if v.get('address')}
missing = on_chain - listed
extra = listed - on_chain
if missing:
    print('the record is missing ' + ', '.join(sorted(missing)))
elif extra:
    print('the record names ' + ', '.join(sorted(extra)) + ', which the Engine does not')
else:
    print('the same pools')
")" "the same pools"

echo "== the two books agree"
TA=$(num "$ENGINE" total_allocated)
DC=$(num "$VAULT" deployed_capital)
ok "Engine total_allocated = Vault deployed_capital" "$TA" "$DC"
NETA=$(num "$VAULT" get_net_assets)
IDLE=$(num "$VAULT" idle_reserves)
printf '        net assets %s, idle %s, deployed %s\n' "$NETA" "$IDLE" "$DC"
ok "reserves are above the floor" "$(python3 -c "print(1 if $IDLE * 10000 >= $NETA * 2500 else 0)")" "1"

echo "== the Vault prices its book from the oracle, not from itself"
ok "Vault get_nav = Oracle PC_NAV" "$(num "$VAULT" get_nav)" "$(num "$ORACLE" get_nav --feed_id PC_NAV)"

echo "== every feed inside its own window"
NOW=$(date +%s)
for f in USDC_USD PC_NAV EF_BOND; do
  W=$(j "['oracleFeeds']['$f']['stalenessSecs']")
  LU=$(call "$ORACLE" last_update --feed_id "$f" | python3 -c "import sys,json;print(json.load(sys.stdin)['timestamp'])" 2>/dev/null)
  AGE=$(( NOW - ${LU:-0} ))
  if [ "${LU:-0}" -gt 0 ] && [ "$AGE" -lt "$W" ]; then
    printf '  PASS  %-44s %s min into a %s min window\n' "$f fresh" "$(( AGE / 60 ))" "$(( W / 60 ))"; pass=$((pass+1))
  else
    printf '  FAIL  %-44s %s s old, window %s s\n' "$f fresh" "$AGE" "$W"; fail=$((fail+1))
  fi
done

echo "== a NAV takes more than one key"
for f in USDC_USD PC_NAV EF_BOND; do
  atleast "$f quorum threshold" "$(num "$ORACLE" quorum_threshold --feed_id "$f")" 2
done
atleast "reporters registered" "$(call "$ORACLE" reporters | python3 -c "import sys,json;print(len(json.load(sys.stdin)))")" 2

echo "== the share price is a price of the supply it is quoted on"
NAV=$(num "$STAKING" nav)
SUP=$(num "$STAKING" total_shares)
RATE=$(num "$STAKING" exchange_rate)
ok "exchange_rate = nav / shares" "$RATE" "$(python3 -c "print($NAV * 10**7 // $SUP if $SUP else 0)")"
ok "DeFindex reads the same rate" \
   "$(call "$STAKING" get_asset_amounts_per_shares --vault_shares 10000000 | python3 -c "
import sys, json
v = json.load(sys.stdin)
print(v[0] if isinstance(v, list) else v)" 2>/dev/null)" "$RATE"

echo "== the refusals a stranger can reproduce, by simulation"
# The limits are checked in order: reserves, then the pool cap, then the
# originator cap, then the jurisdiction cap, then the floor. The first one that
# binds is the error you get, which is why only two of the five can be isolated
# from a cold start. The pool cap at 40 percent binds before the floor at 75
# could, and the originator and jurisdiction caps sit behind the pool cap on
# every pool here. e2e-allocation-guards.sh loads two pools up to arrange for
# the floor to be the thing refusing; e2e-concentration-caps.sh narrows the two
# middle caps. Both sign as the admin.
OVER=$(python3 -c "print(int($NETA * 0.45))")
ok "over the per pool cap" "$(sim "$ENGINE" allocate --admin "$ADMIN" --pool_id "$PC" --amount "$OVER")" "Error(Contract, #407)"
MORE=$(python3 -c "print(int($NETA) + 1)")
ok "more than the Vault holds idle" "$(sim "$ENGINE" allocate --admin "$ADMIN" --pool_id "$PC" --amount "$MORE")" "Error(Contract, #411)"

echo ""
echo "TOTAL: $pass passed, $fail failed"
echo "Signing as the admin is what the other suites need, and what this one deliberately does not."
[ "$fail" -eq 0 ]
