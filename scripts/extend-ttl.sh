#!/usr/bin/env bash
# Push every live contract's instance entry back to the network maximum.
#
# Extending is permissionless. An ExtendFootprintTTLOp carries no authorization
# for the entry it touches; the source account only pays the fee. Verified by
# extending this Vault from an account generated a second earlier that holds no
# role in the protocol at all. So this needs a funded account and not a
# privileged one, which is what makes it safe to run from somewhere that must
# never be given the deployer's key.
#
# Testnet caps one extension at 535679 ledgers, about 31 days, so running this
# is a standing chore rather than a repair. scripts/check-ttl.sh is how you know
# when, and it is run here before and after so the output says what moved.
#
#   bash scripts/extend-ttl.sh                     generates and funds a throwaway
#   SOURCE=agama-poc bash scripts/extend-ttl.sh    or uses an account you name
set -euo pipefail
cd "$(dirname "$0")/.."

NET=${NET:-testnet}
MAX_LEDGERS=535679

echo "==> before"
bash scripts/check-ttl.sh || true

if [ -z "${SOURCE:-}" ]; then
  # A throwaway, because nothing here needs authority and a key that can only
  # pay a fee is a key worth nothing to anyone who takes it.
  SOURCE="ttl-extender-$$"
  echo ""
  echo "==> generating and funding $SOURCE, which holds no role in the protocol"
  stellar keys generate "$SOURCE" --network "$NET" --fund >/dev/null 2>&1
  trap 'stellar keys rm "$SOURCE" >/dev/null 2>&1 || true' EXIT
fi
echo "    source $(stellar keys address "$SOURCE")"

echo ""
echo "==> extending"
FAILED=0
while IFS='|' read -r name addr; do
  [ -n "$addr" ] || continue
  out=$(stellar contract extend --id "$addr" --durability persistent \
          --ledgers-to-extend "$MAX_LEDGERS" --source-account "$SOURCE" \
          --network "$NET" 2>&1 || true)
  ttl=$(echo "$out" | grep -oE "New ttl ledger: [0-9]+" | grep -oE "[0-9]+$" | head -1)
  if [ -n "$ttl" ]; then
    printf "    %-28s to ledger %s\n" "$name" "$ttl"
  else
    printf "    %-28s FAILED: %s\n" "$name" "$(echo "$out" | tail -1 | cut -c1-80)"
    FAILED=$((FAILED + 1))
  fi
done < <(python3 -c "
import json
d = json.load(open('deployments/testnet.json'))
c = dict(d['contracts'])
c.update({'poolAdapters.' + k: v for k, v in d.get('poolAdapters', {}).items()})
for k, v in c.items():
    # Circle's asset contract is not ours to keep alive and does not need it.
    if k != 'usdc':
        print(k + '|' + v)
")

echo ""
echo "==> after"
bash scripts/check-ttl.sh
[ "$FAILED" = 0 ]
