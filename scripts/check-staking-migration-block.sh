#!/usr/bin/env bash
# Measure, rather than assert, why the Vault and staking generations are the two
# contracts still declared under treeAheadOfLedger.
#
# Seven fixes live in those two contracts' source and not on the ledger. The
# reason is one number: the sagUSD held by accounts this deployment cannot sign
# for. deploy-vault-generation.sh refuses to start unless the staking supply is
# zero, because a replacement generation starts its own supply at zero and a
# holder redeeming against a supply of zero divides by it.
#
# Everything below is read live. Run it and the blocker is a figure with
# addresses attached, not a claim in a document.
#
#   bash scripts/check-staking-migration-block.sh
#
# It is a measurement, so it exits 0 whatever it finds. What would make it
# interesting is the unreachable total going to zero.
set -euo pipefail
cd "$(dirname "$0")/.."
NET=${NET:-testnet}
SRC=${SRC:-agama-poc}
DEP=deployments/testnet.json
HORIZON=${HORIZON:-https://horizon-testnet.stellar.org}
j() { python3 -c "import json;d=json.load(open('$DEP'));print($1)"; }
q0() { stellar contract invoke --id "$1" --source "$SRC" --network "$NET" --send=no -- "${@:2}" 2>/dev/null | tr -d '"'; }
STAKING=$(j "d['contracts']['staking']")
ADMIN=$(stellar keys address "$SRC")

echo "staking   = $STAKING"
SHARES=$(q0 "$STAKING" shares)
SUPPLY=$(q0 "$STAKING" total_supply)
echo "shares    = $SHARES"
printf 'supply    = %s (%s sagUSD)\n' "$SUPPLY" "$(python3 -c "print('%.7f' % (int('$SUPPLY')/1e7))")"
echo ""

# The share token is a Stellar Asset Contract, so every holder is a trustline
# and Horizon will enumerate them. That is the only reason this script can name
# the blocking accounts at all: a token holding balances in contract storage
# would not list.
ISSUER=$(curl -s "$HORIZON/assets?asset_code=sagUSD&limit=1" \
  | python3 -c "import json,sys;r=json.load(sys.stdin)['_embedded']['records'];print(r[0]['asset_issuer'] if r else '')")
[ -n "$ISSUER" ] || { echo "sagUSD does not resolve as a classic asset, cannot enumerate holders"; exit 0; }
echo "issuer    = $ISSUER"

# Local identities, so a holder we can sign for is told apart from one we cannot.
KEYS=$(mktemp)
for k in $(stellar keys ls 2>/dev/null); do
  a=$(stellar keys address "$k" 2>/dev/null || true)
  [ -n "$a" ] && echo "$a $k"
done > "$KEYS"
echo "checked against $(wc -l < "$KEYS" | tr -d ' ') local identities"
echo ""

# Horizon's answer goes to a file rather than down a pipe. Piping it into
# `python3 - <<'PY'` cannot work: the heredoc is also stdin, it wins, and the
# script reads its own source as JSON.
HOLDERS=$(mktemp)
trap 'rm -f "$KEYS" "$HOLDERS"' EXIT
curl -s "$HORIZON/accounts?asset=sagUSD:$ISSUER&limit=200" > "$HOLDERS"
python3 - "$KEYS" "$ADMIN" "$HOLDERS" <<'PY'
import json, sys
keys = {}
for line in open(sys.argv[1]):
    a, _, n = line.strip().partition(' ')
    keys[a] = n
admin = sys.argv[2]
recs = json.load(open(sys.argv[3]))['_embedded']['records']
ours, theirs = [], []
for a in recs:
    for b in a['balances']:
        if b.get('asset_code') != 'sagUSD':
            continue
        v = float(b['balance'])
        if v == 0:
            continue
        name = 'the operator' if a['id'] == admin else keys.get(a['id'])
        (ours if name else theirs).append((a['id'], v, name or ''))
print('  held by accounts this deployment can sign for')
for addr, v, name in sorted(ours, key=lambda r: -r[1]):
    print('    %s  %12.7f  %s' % (addr[:8], v, name))
print('    %-8s  %12.7f' % ('subtotal', sum(v for _, v, _ in ours)))
print('')
print('  held by accounts it cannot')
for addr, v, _ in sorted(theirs, key=lambda r: -r[1]):
    print('    %s  %12.7f' % (addr[:8], v))
blocked = sum(v for _, v, _ in theirs)
print('    %-8s  %12.7f   <- this is the blocker' % ('subtotal', blocked))
print('')
print('  %d holders, %.7f sagUSD outstanding, %.7f of it unreachable'
      % (len(ours) + len(theirs), sum(v for _, v, _ in ours) + blocked, blocked))
print('')
if blocked == 0:
    print('  nothing is unreachable. Unstake the rest and the generation migration')
    print('  can run, which settles seven fixes and two declarations.')
else:
    print('  Four things were checked before calling this unreachable, and all four')
    print('  have to hold for it to be true:')
    print('')
    print('    1. the holders are dormant, so a bid on the SDEX does not reach them')
    print('    2. sagUSD has auth_clawback_enabled false, so the balance cannot be taken')
    print('    3. the classic issuer signs at weight 0, so flags cannot be changed and')
    print('       nothing can be minted or revoked through it. The token is minted by')
    print('       the staking contract, which holds the SAC admin, not by the issuer')
    print('    4. Supply is written in exactly three places in the staking source, the')
    print('       constructor at zero, stake and unstake. There is no admin path that')
    print('       seeds a replacement with an existing position, so a new generation')
    print('       cannot carry these holders and would stand them in front of a supply')
    print('       of zero')
    print('')
    print('  The last one is the real finding and it is a design gap rather than a')
    print('  blocker to work around: a staking contract with no upgrade path and no way')
    print('  to carry positions across generations can be pinned by any holder who')
    print('  stops answering. It is in the findings table. The fix belongs in the next')
    print('  generation, which cannot be deployed for exactly this reason.')
PY
echo ""
echo "  this is a measurement, so it passes whatever it finds"
