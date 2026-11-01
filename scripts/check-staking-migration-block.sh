#!/usr/bin/env bash
# Measure which retired staking generations still hold positions, and how much
# of each is held by accounts this deployment cannot sign for.
#
# This is the number that decides whether a generation can be retired at zero or
# has to be left running. deploy-vault-generation.sh refuses to start above a
# staking supply of zero, because a replacement starts its own supply at zero
# and a holder redeeming against zero divides by it, and nothing in the staking
# source lets an admin seed a replacement with an existing position.
#
#   bash scripts/check-staking-migration-block.sh
#
# It walks every staking generation in the record, live and retired, because
# picking one is how this gets the wrong answer. An earlier version took the
# most recently retired generation, which on 2026-11-01 was a contract with no
# supply at all, and reported zero blocked while three accounts were holding
# 8.19 sagUSD on the generation before it.
#
# A measurement, so it exits 0 whatever it finds. What would make it interesting
# is every unreachable subtotal going to zero.
set -euo pipefail
cd "$(dirname "$0")/.."
NET=${NET:-testnet}
SRC=${SRC:-agama-poc}
DEP=deployments/testnet.json
HORIZON=${HORIZON:-https://horizon-testnet.stellar.org}
ADMIN=$(stellar keys address "$SRC")
q0() { stellar contract invoke --id "$1" --source "$SRC" --network "$NET" --send=no -- "${@:2}" 2>/dev/null | tr -d '"'; }

# Local identities, so a holder we can sign for is told apart from one we cannot.
KEYS=$(mktemp); HOLDERS=$(mktemp)
trap 'rm -f "$KEYS" "$HOLDERS"' EXIT
for k in $(stellar keys ls 2>/dev/null); do
  a=$(stellar keys address "$k" 2>/dev/null || true)
  [ -n "$a" ] && echo "$a $k"
done > "$KEYS"
echo "checked against $(wc -l < "$KEYS" | tr -d ' ') local identities"
echo ""

GENS=$(python3 -c "
import json
d = json.load(open('$DEP'))
seen = []
for e in d['superseded']:
    if e['contract'] == 'staking':
        seen.append(('retired gen %s' % e['generation'], e['address']))
seen.append(('live', d['contracts']['staking']))
for label, addr in seen:
    print('%s|%s' % (label, addr))")

TOTAL_BLOCKED=0
while IFS='|' read -r label addr; do
  [ -n "$addr" ] || continue
  SUPPLY=$(q0 "$addr" total_supply || true)
  # A generation whose contract has been archived answers nothing. That is not
  # the same as holding nothing, so it is reported as unreadable rather than as
  # zero, and `|| true` keeps the probe from taking the script down under set -e.
  case "${SUPPLY:-}" in
    "")  printf '%-14s %s  unreadable, the contract may be archived\n' "$label" "${addr:0:8}"; continue ;;
    0)   printf '%-14s %s  empty\n' "$label" "${addr:0:8}"; continue ;;
  esac
  SHARES=$(q0 "$addr" shares || true)
  [ -n "$SHARES" ] || { printf '%-14s %s  supply %s with no share token set\n' "$label" "${addr:0:8}" "$SUPPLY"; continue; }
  # The asset comes off the token. A Stellar Asset Contract answers `name` with
  # code:issuer, and that pair is the only identifier that means anything: there
  # is one sagUSD asset per generation on this network, and looking one up by its
  # code alone returns whichever Horizon lists first.
  NAME=$(q0 "$SHARES" name || true)
  case "$NAME" in
    *:G*) CODE=${NAME%%:*}; ISSUER=${NAME#*:} ;;
    *)    printf '%-14s %s  share token is not a classic asset (%s), holders are not trustlines\n' \
            "$label" "${addr:0:8}" "${NAME:-unreadable}"; continue ;;
  esac
  printf '%-14s %s  supply %s of %s issued by %s\n' "$label" "${addr:0:8}" "$SUPPLY" "$CODE" "${ISSUER:0:8}"
  curl -s "$HORIZON/accounts?asset=$CODE:$ISSUER&limit=200" > "$HOLDERS"
  BLOCKED=$(python3 - "$KEYS" "$ADMIN" "$HOLDERS" "$CODE" <<'PY'
import json, sys
keys = {}
for line in open(sys.argv[1]):
    a, _, n = line.strip().partition(' ')
    keys[a] = n
admin, code = sys.argv[2], sys.argv[4]
try:
    recs = json.load(open(sys.argv[3]))['_embedded']['records']
except Exception:
    print('0'); raise SystemExit
ours, theirs = [], []
for a in recs:
    for b in a['balances']:
        if b.get('asset_code') != code or float(b['balance']) == 0:
            continue
        v = float(b['balance'])
        name = 'the operator' if a['id'] == admin else keys.get(a['id'])
        (ours if name else theirs).append((a['id'], v, name or ''))
for addr, v, name in sorted(ours, key=lambda r: -r[1]):
    print('    ours        %s  %12.7f  %s' % (addr[:8], v, name), file=sys.stderr)
for addr, v, _ in sorted(theirs, key=lambda r: -r[1]):
    print('    UNREACHABLE %s  %12.7f' % (addr[:8], v), file=sys.stderr)
print('%.7f' % sum(v for _, v, _ in theirs))
PY
)
  printf '    unreachable on this generation: %s %s\n' "$BLOCKED" "$CODE"
  TOTAL_BLOCKED=$(python3 -c "print('%.7f' % (float('$TOTAL_BLOCKED') + float('$BLOCKED')))")
  echo ""
done <<< "$GENS"

echo "unreachable across every generation: $TOTAL_BLOCKED sagUSD"
echo ""
if [ "$(python3 -c "print(1 if float('$TOTAL_BLOCKED') > 0 else 0)")" = "1" ]; then
  cat <<'TXT'
  Four things have to hold for that to be unreachable rather than merely
  inconvenient, and all four do:

    1. the holders are dormant, so a bid on the SDEX does not reach them
    2. the asset has auth_clawback_enabled false, so a balance cannot be taken
    3. its classic issuer signs at master weight 0. That is deliberate, and it is
       what makes the staking contract the only address able to mint shares; it
       also means nothing can be revoked through the issuer
    4. Supply is written in exactly three places in the staking source, the
       constructor at zero, stake and unstake. No admin path seeds a replacement
       with an existing position

  So a generation holding any of this cannot be retired at zero, and the one
  that holds it has to stay up, funded, able to pay. That is a finding in
  docs/TRANCHE2_EVIDENCE.md rather than a blocker: the fixes went out beside the
  old generation instead of replacing it. The gap is untouched, so the next
  replacement meets the same wall.
TXT
else
  echo "  Nothing is unreachable. Every generation holding supply can be unwound by"
  echo "  this deployment, so the next replacement can retire its predecessor at zero."
fi
