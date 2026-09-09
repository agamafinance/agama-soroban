#!/usr/bin/env bash
# Redeploy sagUSD (contracts/staking) so that the deployed contract carries the
# names Agama committed to, and point it at the live agUSD.
#
# Why sagUSD and nothing else
#
# The team's answer to the SCF panel says sagUSD adopts the `distribute_yield` /
# assets-per-share accounting convention, and DeFindex compatibility is a funded
# grant deliverable. The deployed sagUSD exposes `accrue_yield` and
# `share_price`, so a wallet that goes looking for the committed names does not
# find them. That is a gap between what was promised and what is on the ledger,
# and it cannot be closed by editing a document: a Soroban contract has no
# upgrade entry point here, so honouring the commitment means a new deployment.
#
# Nothing else moves. The Vault, the Allocation Engine, both pool adapters, the
# Oracle Adapter, the real Circle USDC SAC, the generation 1 agUSD and the six
# credit vaults are all read out of deployments/testnet.json and reused exactly
# as they are. sagUSD is a leaf: no other contract in the stack stores its
# address, so replacing it strands no pointer. That is the whole reason this is
# a one contract deployment and the rewire was a six contract one.
#
# What the superseded sagUSD is left holding: nothing. Its NAV and its share
# supply are both zero, so it has no staker to strand and no balance to move.
# The script checks that before it deploys and refuses to run if it is wrong,
# because retiring a contract that still owes somebody agUSD is a different
# operation from this one and should not happen by accident.
#
# The interface is checked against the deployed WASM at the end rather than
# against the source, because the source is not what a wallet reads.
#
# Usage: bash scripts/deploy-sagusd.sh
#
# Requires the `agama-poc` identity, which is the admin recorded in
# deployments/testnet.json.
set -euo pipefail
cd "$(dirname "$0")/.."

NET=testnet
SRC=agama-poc
WASM=target/wasm32v1-none/release/staking.wasm
DEP=deployments/testnet.json

DECIMALS=7
SAGUSD_NAME="Staked agUSD"
SAGUSD_SYMBOL=sagUSD

# Goes into deployments/testnet.json against the address this run replaces, so
# it is the sentence a reviewer reads next to a dead contract.
RETIREMENT_REASON="Replaced by scripts/deploy-sagusd.sh. Exposes accrue_yield and share_price, the names this contract shipped with, rather than distribute_yield and exchange_rate, the names Agama committed to in its answer to the SCF panel and that DeFindex compatibility is a funded deliverable for. A wallet looking for the committed convention did not find it on this contract. Superseded holding nothing: NAV and share supply were both zero at handover, so it strands no staker."

j() { python3 -c "import json;d=json.load(open('$DEP'));print($1)"; }
ADMIN=$(stellar keys address "$SRC")
AGUSD=$(j "d['contracts']['agusdCore']")
COOLDOWN=$(j "d['cooldownSeconds']")
OLD_STAKING=$(j "d['contracts']['staking']")

# Deploy, echoing the install and create transaction hashes so a run leaves a
# record that can be checked against the ledger, and returning the contract id.
deploy() {
  local out
  out=$(stellar contract deploy --wasm "$1" --source "$SRC" --network "$NET" 2>&1)
  echo "$out" | grep -oE '[0-9a-f]{64}' | sed 's/^/    tx or wasm hash /' >&2
  echo "$out" | grep -oE 'C[A-Z2-7]{55}' | tail -1
}
# State changing: submitted, and the transaction hash is echoed.
tx() { stellar contract invoke --id "$1" --source "$SRC" --network "$NET" -- "${@:2}" 2>&1 \
         | grep -oE '[0-9a-f]{64}' | head -1; }
# Read-only: simulated, never submitted, so the wiring checks cost nothing.
q() { stellar contract invoke --id "$1" --source "$SRC" --network "$NET" --send=no -- "${@:2}" 2>/dev/null; }

echo "admin                    = $ADMIN"
echo "agusd (live, reused)     = $AGUSD"
echo "superseded sagUSD        = $OLD_STAKING"
echo "cooldown                 = ${COOLDOWN}s"

echo ""
echo "==> checking the superseded sagUSD owes nobody anything"
OLD_NAV=$(q "$OLD_STAKING" nav | tr -d '"')
OLD_SHARES=$(q "$OLD_STAKING" total_shares | tr -d '"')
echo "    nav          = $OLD_NAV"
echo "    total_shares = $OLD_SHARES"
if [ "${OLD_NAV:-1}" != "0" ] || [ "${OLD_SHARES:-1}" != "0" ]; then
  echo "    it is still holding a position; unwind it before retiring the contract" >&2
  exit 1
fi

echo ""
echo "==> building"
stellar contract build >/dev/null

echo ""
echo "==> deploying"
STAKING=$(deploy "$WASM")
echo "    staking (sagUSD) = $STAKING"

# Initialized straight onto the live agUSD. The rewire had to detour through the
# superseded addresses because it was proving the setters worked; there is no
# such thing to prove here, the token this contract should accept is already the
# one the Vault mints, and initialize writes it correctly the first time.
echo ""
echo "==> sagUSD: initialized on the live agUSD"
echo "    initialize        tx $(tx "$STAKING" initialize --admin "$ADMIN" --agusd "$AGUSD" \
  --cooldown_seconds "$COOLDOWN" --decimal "$DECIMALS" --name "$SAGUSD_NAME" --symbol "$SAGUSD_SYMBOL")"

echo ""
echo "==> checking the wiring"
echo "    staking.agusd()         = $(q "$STAKING" agusd)"
echo "    staking.admin()         = $(q "$STAKING" admin)"
echo "    staking.cooldown()      = $(q "$STAKING" cooldown)"
echo "    staking.exchange_rate() = $(q "$STAKING" exchange_rate)"
echo "    staking.share_price()   = $(q "$STAKING" share_price)"
echo "    staking.total_shares()  = $(q "$STAKING" total_shares)"

# The point of the whole deployment, read off the ledger rather than off the
# source tree. A wallet reads the deployed interface, so that is what is checked.
echo ""
echo "==> checking the deployed interface carries the committed names"
IFACE=$(stellar contract info interface --id "$STAKING" --network "$NET" 2>/dev/null)
for fn in distribute_yield exchange_rate share_price request_unstake claim cooldown; do
  if echo "$IFACE" | grep -q "fn $fn"; then
    echo "    present  $fn"
  else
    echo "    MISSING  $fn" >&2
    exit 1
  fi
done
if echo "$IFACE" | grep -q "fn accrue_yield"; then
  echo "    MISSING  accrue_yield should be gone, it was renamed not aliased" >&2
  exit 1
fi
echo "    absent   accrue_yield, renamed rather than aliased"

echo ""
echo "==> writing $DEP"
python3 - "$DEP" "$STAKING" "$OLD_STAKING" "$RETIREMENT_REASON" <<'PY'
import json, sys
path, staking, old_staking, reason = sys.argv[1:]
dep = json.load(open(path))

ORDINALS = ['first', 'second', 'third', 'fourth', 'fifth', 'sixth', 'seventh']

# Whatever was recorded as superseded before stays recorded, and the new entry
# is numbered after the ones already there.
history = dep.get('superseded', [])
generation = 1 + sum(1 for e in history if e['contract'] == 'staking')
history.append({
    'contract': 'staking',
    'generation': generation,
    'label': 'sagUSD staking, %s deployment' % ORDINALS[generation - 1],
    'address': old_staking,
    'supersededBy': 'staking',
    'reason': reason,
})

dep['contracts']['staking'] = staking
dep['superseded'] = history
json.dump(dep, open(path, 'w'), indent=2)
open(path, 'a').write('\n')
print(json.dumps({'staking': staking}, indent=2))
PY
echo "==> done"
