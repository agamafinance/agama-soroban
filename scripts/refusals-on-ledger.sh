#!/usr/bin/env bash
# The four allocation limits, refused on the live Engine, as failed
# transactions anyone can open.
#
# The README carries four refusal transactions from 8 September. They are real
# and they are still on the ledger, and they were sent to CAFJKWLU, the
# Allocation Engine's third deployment, which has since been retired. A refusal
# proven against a contract that no longer runs is a refusal proven about
# nothing, and that is the whole reason this repository re-proves Tranche 2
# after every redeployment.
#
# So this submits the same four against the Engine that is live now, and prints
# the hash of each one. A reviewer does not have to run anything: the evidence
# is a transaction on the public ledger carrying the Engine's own error code,
# and this script reads that code back off the ledger before calling a case
# passed.
#
# How a refusal gets onto the ledger at all, since the CLI will not send a
# transaction whose simulation fails and every refusal fails simulation:
# scripts/tx-patch.py takes a transaction the CLI did prepare, for a smaller
# allocation that simulates cleanly, and rewrites the amount in the operation
# and in its matching authorization entry. The footprint stays valid because
# the refused call reads the same ledger entries and writes none of them.
#
# Two of the four cannot be reached at the standing configuration: no two pools
# share an originator or a jurisdiction, so the per-pool cap refuses first, and
# the floor sits behind every cap. Those cases narrow the limit under test,
# submit, and restore it, which is visible in the Engine's own caps_updated and
# reserve_floor_updated events. A cap at 500 bps in that stream is this script.
#
# Needs the Engine's admin. Usage: bash scripts/refusals-on-ledger.sh
set -uo pipefail
cd "$(dirname "$0")/.."
NET=${NET:-testnet}
SRC=${SRC:-agama-poc}
RPC=https://soroban-testnet.stellar.org
HORIZON=https://horizon-testnet.stellar.org
DEP=deployments/testnet.json
j() { python3 -c "import json;print(json.load(open('$DEP'))$1)"; }
ENGINE=$(j "['contracts']['allocationEngine']")
VAULT=$(j "['contracts']['vault']")
ADMIN=$(j "['admin']")
PC=$(j "['poolAdapters']['private-credit']")

HARVEST=1234567   # 0.1234567 USDC: distinctive, so the rewrite cannot hit anything else

pass=0; fail=0
ok(){ printf '  PASS  %s\n' "$1"; pass=$((pass+1)); }
bad(){ printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); }
rd(){ stellar contract invoke --id "$1" --source "$SRC" --network "$NET" --send=no -- "${@:2}" 2>/dev/null | tail -1 | tr -d '"'; }
caps(){ stellar contract invoke --id "$ENGINE" --source "$SRC" --network "$NET" --send=no -- caps 2>/dev/null | tail -1; }
setcaps(){ stellar contract invoke --id "$ENGINE" --source "$SRC" --network "$NET" -- set_caps \
             --admin "$ADMIN" --pool_cap_bps "$1" --originator_cap_bps "$2" --jurisdiction_cap_bps "$3" >/dev/null 2>&1; }
setfloor(){ stellar contract invoke --id "$ENGINE" --source "$SRC" --network "$NET" -- set_reserve_floor \
              --admin "$ADMIN" --floor_bps "$1" >/dev/null 2>&1; }

next_seq() {
  curl -s "$HORIZON/accounts/$ADMIN" \
    | python3 -c "import json,sys;print(int(json.load(sys.stdin)['sequence'])+1)"
}

ledger_errors() {
  local hash=$1 attempt out
  for attempt in 1 2 3 4 5; do
    out=$(curl -s -X POST "$RPC" -H 'Content-Type: application/json' \
      -d "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"getTransaction\",\"params\":{\"hash\":\"$hash\"}}" \
      | python3 -c '
import json, subprocess, sys
result = json.load(sys.stdin).get("result", {})
for raw in result.get("diagnosticEventsXdr", []):
    decoded = subprocess.run(
        ["stellar", "xdr", "decode", "--type", "DiagnosticEvent", "--output", "json"],
        input=raw, capture_output=True, text=True).stdout
    try:
        event = json.loads(decoded)
    except Exception:
        continue
    for topic in event["event"]["body"]["v0"]["topics"]:
        if isinstance(topic, dict) and isinstance(topic.get("error"), dict):
            for kind, detail in topic["error"].items():
                print(f"{kind}:{detail}")
')
    [ -n "$out" ] && { echo "$out"; return; }
    python3 -c "import time;time.sleep(2)"
  done
  echo "unknown:unknown"
}

refuse(){ # refuse <label> <expected code> <pool> <real amount>
  local label="$1" code="$2" pool="$3" real="$4" env out hash found
  env=$(stellar contract invoke --id "$ENGINE" --source "$SRC" --network "$NET" --build-only \
          -- allocate --admin "$ADMIN" --pool_id "$pool" --amount "$HARVEST" 2>/dev/null | tail -1 \
        | stellar tx simulate --source "$SRC" --network "$NET" 2>/dev/null | tail -1 \
        | python3 scripts/tx-patch.py amount "$HARVEST" "$real" 2>/dev/null)
  if [ -z "$env" ]; then bad "$label: nothing to send, the harvest did not simulate"; return; fi
  # Three outcomes, not two. A send can come back with a hash that never
  # reaches a ledger, and reading that as "the guard did not fire" reports a
  # hole in the contract when what happened was a submission that did not
  # land: this case said exactly that once, about a transaction the RPC had
  # never heard of. So the ledger is asked, and a submission that is not there
  # is sent again rather than counted.
  local attempt
  for attempt in 1 2 3; do
    out=$(printf '%s' "$env" | python3 scripts/tx-patch.py seq "$(next_seq)" 2>/dev/null \
          | stellar tx sign --sign-with-key "$SRC" --network "$NET" 2>/dev/null | tail -1 \
          | stellar tx send --network "$NET" 2>&1)
    hash=$(printf '%s' "$out" | grep -oE '[0-9a-f]{64}' | head -1)
    [ -z "$hash" ] && { python3 -c "import time;time.sleep(3)"; continue; }
    local status
    status=$(curl -s -X POST "$RPC" -H 'Content-Type: application/json' \
      -d "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"getTransaction\",\"params\":{\"hash\":\"$hash\"}}" \
      | python3 -c "import sys,json;print(json.load(sys.stdin).get('result',{}).get('status','NONE'))")
    case "$status" in
      SUCCESS) bad "$label: the Engine accepted it (tx $hash)"; return;;
      FAILED) break;;
      *) printf '        submission %s did not reach a ledger (%s), sending again\n' "${hash:0:8}" "$status"
         python3 -c "import time;time.sleep(3)";;
    esac
  done
  if ! printf '%s' "$out" | grep -q "TxFailed"; then
    bad "$label: no refusal on the ledger after three attempts (last tx ${hash:-none})"; return
  fi
  found=$(ledger_errors "$hash")
  if printf '%s' "$found" | grep -qx "contract:$code"; then
    ok "$label"
    printf '        #%s  https://stellar.expert/explorer/testnet/tx/%s\n' "$code" "$hash"
  else
    bad "$label: tx $hash failed carrying $(printf '%s' "$found" | tr '\n' ' ') rather than contract:$code"
  fi
}

read -r P O Ju <<<"$(caps | python3 -c "import sys,json;c=json.load(sys.stdin);print(c['pool_bps'],c['originator_bps'],c['jurisdiction_bps'])")"
FLOOR=$(rd "$ENGINE" reserve_floor_bps)
restore(){ setcaps "$P" "$O" "$Ju"; setfloor "$FLOOR"; }
trap restore EXIT
NETA=$(rd "$VAULT" get_net_assets)
printf 'Engine %s\ncaps %s/%s/%s bps over a %s bps floor, net assets %s\n\n' \
  "$ENGINE" "$P" "$O" "$Ju" "$FLOOR" "$NETA"

echo "== the per pool cap"
refuse "an allocation past the per pool cap is refused on the ledger" 407 "$PC" \
       "$(python3 -c "print(int($NETA * 0.45))")"

# The narrowed cap has to sit above what the pool already holds and below what
# the refusal asks for. Narrowing to a flat 500 bps worked while the book was
# empty and stopped working the moment it was not: the harvest, the small
# allocation whose footprint the refusal borrows, was itself over the cap, so
# there was nothing to send and the case reported a hole where the guard is.
EXPO=$(rd "$ENGINE" get_exposure --pool_id "$PC")
NARROW=$(python3 -c "print(int($EXPO * 10000 / $NETA) + 200)")
ASK=$(python3 -c "print(int($NETA * 0.10))")
printf '  private credit holds %s, so the cap under test goes to %s bps and the refusal asks for %s\n' \
  "$EXPO" "$NARROW" "$ASK"

echo "== the per originator cap, with the cap narrowed under it"
setcaps "$P" "$NARROW" "$Ju"
refuse "an allocation past the per originator cap is refused on the ledger" 408 "$PC" "$ASK"
setcaps "$P" "$O" "$Ju"

echo "== the per jurisdiction cap, same"
setcaps "$P" "$O" "$NARROW"
refuse "an allocation past the per jurisdiction cap is refused on the ledger" 409 "$PC" "$ASK"
setcaps "$P" "$O" "$Ju"

echo "== the reserve floor, with the floor raised under it"
setfloor 8000
refuse "an allocation that would breach the reserve floor is refused on the ledger" 410 "$PC" \
       "$(python3 -c "print(int($NETA * 0.15))")"
setfloor "$FLOOR"

echo ""
echo "== the configuration is back"
NOW_CAPS=$(caps | python3 -c "import sys,json;c=json.load(sys.stdin);print(c['pool_bps'],c['originator_bps'],c['jurisdiction_bps'])")
[ "$NOW_CAPS" = "$P $O $Ju" ] && ok "caps restored: $NOW_CAPS" || bad "caps are $NOW_CAPS, were $P $O $Ju"
[ "$(rd "$ENGINE" reserve_floor_bps)" = "$FLOOR" ] && ok "floor restored: $FLOOR" || bad "floor not restored"

echo ""
echo "TOTAL: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
