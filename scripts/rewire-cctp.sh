#!/usr/bin/env bash
# Replace the CCTP adapter, carrying its configuration out of its own storage.
#
# This migration was abandoned once, on 2026-11-01, because max_fee_bps is set
# by the constructor and exposed by no entry point, so there was no way to carry
# it across without guessing. The value was never hidden: instance storage is a
# ledger entry and a ledger entry can be read whether or not the contract has an
# opinion about it. Every constructor argument here is read off the outgoing
# contract by scripts/read-instance-storage.sh rather than typed, which is the
# only version of this script worth running: a cross chain adapter that silently
# comes back with a different fee ceiling or a different recipient is the worst
# possible outcome of a migration meant to change nothing.
#
# What it deploys does change something. The replacement puts set_destination
# behind a 72 hour announce then apply delay, so the domain and recipient that
# receive burned USDC can no longer be moved in a single transaction, and adds
# the max_fee_bps getter whose absence stopped this the first time.
#
#   bash scripts/rewire-cctp.sh
#
# The adapter is also the cross-chain pool on the Engine, so this unregisters it
# and registers the replacement. unregister_pool refuses a pool that holds
# exposure or carries a write-off charge, and all of that is checked up front.
set -euo pipefail
cd "$(dirname "$0")/.."
NET=${NET:-testnet}
SRC=${SRC:-agama-poc}
DEP=deployments/testnet.json
WASM=target/wasm32v1-none/release
j() { python3 -c "import json;d=json.load(open('$DEP'));print($1)"; }
ADMIN=$(stellar keys address "$SRC")
OLD=$(j "d['contracts']['cctpAdapter']")
ENGINE=$(j "d['contracts']['allocationEngine']")
VAULT=$(j "d['contracts']['vault']")
ORIGINATOR=$(j "d['engineConfig']['pools']['cross-chain']['originator']")
JURISDICTION=$(j "d['engineConfig']['pools']['cross-chain']['jurisdiction']")
CAP=$(j "d['engineConfig']['pools']['cross-chain']['capBps']")

LOCK=/tmp/agama-smoke-$SRC.lock
if ! mkdir "$LOCK" 2>/dev/null; then
  echo "a suite or another migration holds $SRC ($(cat "$LOCK/owner" 2>/dev/null || echo unknown))." >&2
  exit 1
fi
echo "pid $$ at $(date -u +%H:%M:%S), rewire-cctp" > "$LOCK/owner"
trap 'rm -rf "$LOCK"' EXIT

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  PASS  $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL  $1"; }
q()  { stellar contract invoke --id "$1" --source "$SRC" --network "$NET" --send=no -- "${@:2}" 2>/dev/null; }
q0() { q "$@" | tr -d '"'; }
num(){ printf '%s' "${1:-}" | tr -d '"'; }
assert_eq() { if [ "$(num "$2")" = "$(num "$3")" ]; then ok "$1 ($(num "$2"))"; else bad "$1: got $(num "$2"), want $(num "$3")"; fi; }
# Errors are looked for first, and that order is the whole point. The previous
# version searched the output for a 64 hex transaction hash and reported success
# on the first match, but --recipient is 64 hex characters, so a call refused
# with #715 printed its own argument back and was read as a hash. It reported
# three refusals as landed transactions.
_tx() {
  local out err h
  out=$("$@" 2>&1) || true
  # The contract's own code is looked for in its own grep, not as the first
  # alternative of one. grep -oE returns the earliest match in the string rather
  # than the earliest alternative, and the CLI prints a generic "error:
  # transaction simulation failed" line above the contract error, so a single
  # alternation reports "error: transaction" for every refusal and loses the
  # number that says which guard fired.
  err=$(printf '%s' "$out" | tr '\n' ' ' | grep -oE 'Error\(Contract, #[0-9]+\)' | head -1 || true)
  [ -n "$err" ] || err=$(printf '%s' "$out" | tr '\n' ' ' | grep -oE 'TxBadSeq|error: [^ ]+' | head -1 || true)
  if [ -n "$err" ]; then printf 'FAILED %s' "$err"; return 1; fi
  h=$(printf '%s' "$out" | grep -oE 'Transaction hash is [0-9a-f]{64}' | grep -oE '[0-9a-f]{64}' | head -1 || true)
  [ -n "$h" ] || h=$(printf '%s' "$out" | grep -oE '[0-9a-f]{64}' | head -1 || true)
  if [ -n "$h" ]; then printf '%s' "$h"; return 0; fi
  printf 'landed, no hash printed'
}
tx() { _tx stellar contract invoke --id "$1" --source "$SRC" --network "$NET" -- "${@:2}"; }

echo "==> the outgoing adapter's configuration, read off its own storage"
ST=$(bash scripts/read-instance-storage.sh cctpAdapter)
printf '%s\n' "$ST" | sed -n '3,$p'
g() { printf '%s' "$ST" | awk -v k="$1" '$1==k {print $2}'; }
C_ADMIN=$(g Admin); C_ENGINE=$(g Engine); C_VAULT=$(g Vault); C_USDC=$(g Usdc)
C_MESSENGER=$(g Messenger); C_DOMAIN=$(g Domain); C_RECIPIENT=$(g Recipient); C_MAXFEE=$(g MaxFeeBps)
for v in C_ADMIN C_ENGINE C_VAULT C_USDC C_MESSENGER C_DOMAIN C_RECIPIENT C_MAXFEE; do
  [ -n "${!v}" ] || { echo "could not read $v out of the instance storage, refusing to guess it" >&2; exit 1; }
done

echo ""
echo "==> preconditions, checked before anything is deployed"
fail=0
chk0() {
  local label=$1; shift
  local v; v=$(q0 "$@")
  if [ "${v:-x}" = "0" ]; then echo "    $label = 0"
  else echo "    $label = ${v:-unreadable}, and it has to be 0"; fail=1; fi
}
chk0 "adapter exposure"         "$OLD" get_exposure
chk0 "adapter usdc"             "$C_USDC" balance --id "$OLD"
chk0 "engine exposure for it"   "$ENGINE" get_exposure --pool_id "$OLD"
chk0 "engine charge against it" "$ENGINE" written_off_pool --pool_id "$OLD"
# The storage has to agree with the record, or the record is describing a
# different contract than the one being replaced.
[ "$C_ENGINE" = "$ENGINE" ] || { echo "    its stored engine is $C_ENGINE, the record says $ENGINE"; fail=1; }
[ "$C_VAULT"  = "$VAULT"  ] || { echo "    its stored vault is $C_VAULT, the record says $VAULT"; fail=1; }
[ "$C_ADMIN"  = "$ADMIN"  ] || { echo "    its stored admin is $C_ADMIN, we sign as $ADMIN"; fail=1; }
[ "$fail" = 0 ] || { echo "refusing to start a migration that cannot finish"; exit 1; }

echo ""
echo "==> building"
stellar contract build >/dev/null

echo ""
echo "==> the replacement, every argument carried from the storage above"
if [ -n "${NEW:-}" ]; then
  echo "    adopting the already deployed $NEW"
else
  OUT=$(stellar contract deploy --wasm "$WASM/cctp_adapter.wasm" --source "$SRC" --network "$NET" \
    -- --admin "$C_ADMIN" --engine "$C_ENGINE" --vault "$C_VAULT" --usdc "$C_USDC" \
       --messenger "$C_MESSENGER" --domain "$C_DOMAIN" --recipient "$C_RECIPIENT" \
       --max_fee_bps "$C_MAXFEE" 2>&1)
  echo "$OUT" | grep -oE 'Using wasm hash [0-9a-f]{64}' | sed 's/^/    /' || true
  NEW=$(echo "$OUT" | grep -oE 'C[A-Z2-7]{55}' | tail -1 || true)
  if [ -z "$NEW" ]; then
    echo "    the deploy produced no contract address. Output follows:" >&2
    printf '%s\n' "$OUT" | tail -20 >&2
    exit 1
  fi
  echo "    cctp-adapter = $NEW"
fi

echo ""
echo "==> swapping it in as the cross-chain pool"
if [ "$OLD" = "$NEW" ]; then
  echo "    already swapped in, the record names it as the cross-chain pool"
else
  echo "    unregister the outgoing  tx $(tx "$ENGINE" unregister_pool --admin "$ADMIN" --pool_id "$OLD")"
  echo "    register the replacement tx $(tx "$ENGINE" register_pool --admin "$ADMIN" --pool_id "$NEW" \
    --originator "$ORIGINATOR" --jurisdiction "$JURISDICTION" --cap_bps "$CAP")"
fi

echo ""
echo "==> checking it came back identical, and that the new guard is there"
assert_eq "it names the same engine"      "$(q0 "$NEW" engine)"      "$ENGINE"
assert_eq "it names the same vault"       "$(q0 "$NEW" vault)"       "$VAULT"
assert_eq "the same admin"                "$(q0 "$NEW" admin)"       "$ADMIN"
# One getter, returning the pair. Asking for `domain` and `recipient` separately
# returns nothing, which compares unequal to everything and accuses a correct
# contract of having lost its configuration.
DEST=$(q "$NEW" destination)
assert_eq "the same destination domain"   "$(printf '%s' "$DEST" | python3 -c 'import sys,json;print(json.load(sys.stdin)[0])')" "$C_DOMAIN"
assert_eq "the same recipient"            "$(printf '%s' "$DEST" | python3 -c 'import sys,json;print(json.load(sys.stdin)[1])')" "$C_RECIPIENT"
assert_eq "the same fee ceiling"          "$(q0 "$NEW" max_fee_bps)" "$C_MAXFEE"
assert_eq "no exposure on a fresh deploy" "$(q0 "$NEW" get_exposure)" "0"
# A pending announcement is only interesting if it points somewhere else. One
# that names the destination already in force is how an unwanted announcement
# gets cleaned up, since the contract has no cancel, and it is what this script's
# own timelock check leaves behind.
PD=$(q "$NEW" pending_destination)
case "$PD" in
  *null*|"") ok "no destination change pending (null)" ;;
  *) if [ "$(printf '%s' "$PD" | python3 -c 'import sys,json;print(json.load(sys.stdin)[1])')" = "$C_RECIPIENT" ]; then
       ok "a destination change is pending, towards the destination already in force"
     else
       bad "a destination change is pending towards somewhere else: $PD"
     fi ;;
esac
assert_eq "the engine registered it"      "$(q "$ENGINE" pools | python3 -c "import sys,json;print('$NEW' in json.load(sys.stdin))")" "True"
if [ "$OLD" = "$NEW" ]; then
  ok "the outgoing pool was already swapped out (adopting $NEW)"
else
  assert_eq "and dropped the outgoing one" "$(q "$ENGINE" pools | python3 -c "import sys,json;print('$OLD' in json.load(sys.stdin))")" "False"
fi
assert_eq "still four pools"              "$(q "$ENGINE" pools | python3 -c "import sys,json;print(len(json.load(sys.stdin)))")" "4"
# The reason this deploy exists: moving the destination now takes two calls 72
# hours apart. The announcement made here is the destination the contract
# already has, so the pending entry this leaves behind changes nothing if it is
# ever applied. The first version of this check announced an address of its own
# invention and left it live and appliable, on the contract that decides where
# the Vault's USDC goes when it is burned. There is no cancel: an announcement
# can only be superseded, which is how that one was cleaned up.
# On a fresh deploy nothing is announced and this lands. On a re-run the
# identical announcement is already pending, which the contract answers with
# #715, and that answer proves the same property rather than contradicting it.
H=$(tx "$NEW" set_destination --admin "$ADMIN" --domain "$C_DOMAIN" --recipient "$C_RECIPIENT" || true)
case "$H" in
  *715*)   ok "the same destination change is already announced and not yet appliable" ;;
  FAILED*) bad "announcing a destination change is accepted ($H)" ;;
  *)       ok "announcing a destination change is accepted" ;;
esac
P=$(q "$NEW" pending_destination)
case "$P" in *null*|"") bad "the announcement was not recorded as pending";;
             *) ok "it is recorded as pending, ready at $(printf '%s' "$P" | python3 -c 'import sys,json;print(json.load(sys.stdin)[2])')" ;; esac
H=$(tx "$NEW" set_destination --admin "$ADMIN" --domain "$C_DOMAIN" --recipient "$C_RECIPIENT" || true)
case "$H" in *715*) ok "and applying it before the delay is refused with #715";;
             *) bad "applying it early was not refused (got $H)" ;; esac
DEST=$(q "$NEW" destination)
assert_eq "the destination is untouched either way" \
  "$(printf '%s' "$DEST" | python3 -c 'import sys,json;print(json.load(sys.stdin)[1])')" "$C_RECIPIENT"

echo ""
echo "==> writing $DEP"
# OLD is read out of the record, so on a re-run with NEW= it is already the
# replacement, and appending an entry then records the live contract as having
# been retired by itself. Three re-runs of this script did exactly that and put
# the live address in the superseded list three times.
python3 - "$DEP" "$NEW" "$OLD" "$C_MAXFEE" <<'ZPY'
import json, sys, collections
path, new, old, maxfee = sys.argv[1:]
dep = json.loads(open(path).read(), object_pairs_hook=collections.OrderedDict)
hist = dep.get('superseded', [])
if old == new:
    print('    the record already names it, leaving the superseded list alone')
    hist = None
if hist is not None:
  g = max((e['generation'] for e in hist if e['contract'] == 'cctpAdapter'), default=0) + 1
  hist.append(collections.OrderedDict([
      ('contract', 'cctpAdapter'),
      ('generation', g),
      ('label', 'CCTP adapter, generation %d' % g),
      ('address', old),
      ('supersededBy', 'cctpAdapter'),
      ('reason', (
          'Replaced by scripts/rewire-cctp.sh to put set_destination behind a 72 hour announce then apply '
          'delay and to expose max_fee_bps, which the outgoing contract stored and no entry point returned. '
          'That missing getter is why this migration was abandoned on its first attempt the same day: there '
          'was no way to carry the fee ceiling across without guessing it. Instance storage turned out to be '
          'readable as a ledger entry regardless of what the contract exposes, so every constructor argument '
          'here was read off the outgoing contract by scripts/read-instance-storage.sh rather than typed, and '
          'the replacement was checked field by field against it afterwards. The fee ceiling is %s bps on '
          'both. The adapter is also the cross-chain pool, so it was unregistered and the replacement '
          'registered with the same originator, jurisdiction and cap.' % maxfee))
  ]))
  dep['superseded'] = hist
dep['contracts']['cctpAdapter'] = new
if 'cross-chain' in dep.get('poolAdapters', {}):
    dep['poolAdapters']['cross-chain'] = new
if 'cross-chain' in dep.get('engineConfig', {}).get('pools', {}):
    dep['engineConfig']['pools']['cross-chain']['address'] = new
ahead = dep.get('treeAheadOfLedger') or []
if any(e.get('contract') == 'cctpAdapter' for e in ahead):
    print('    dropped the treeAheadOfLedger entry for cctpAdapter, which this deploy settles')
dep['treeAheadOfLedger'] = [e for e in ahead if e.get('contract') != 'cctpAdapter']
open(path, 'w').write(json.dumps(dep, indent=2, ensure_ascii=False) + '\n')
print('    cctpAdapter = %s' % new)
print('    and the same address under poolAdapters and engineConfig.pools, which is one contract')
ZPY

echo ""
echo "  $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
