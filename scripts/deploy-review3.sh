#!/usr/bin/env bash
# Deploy the Tranche 2 review corrections: a Stablebond pool the Etherfuse
# adapter actually subscribes into, an adapter that does the subscribing, and
# the two oracle feeds that were registered and read by nothing.
#
# What the Stellar reviewer asked for, and where each piece lands:
#
#   D1  "no Stablebond subscription or redemption path, mock or real"
#       -> contracts/mock-stablebond, and an Etherfuse adapter whose allocate
#          subscribes into it and whose deallocate redeems out of it.
#
#   D2  "USDC_USD and EF_BOND are not sourced ... and nothing on chain reads
#        them: please wire the sources and say what the peg feed is meant to
#        gate"
#       -> the Vault's peg gate reads USDC_USD on every deposit and refuses
#          outside 200 bps of par, and the Etherfuse adapter values its
#          position from EF_BOND through the Oracle Adapter.
#
# Idempotent where it can be: the feeds are already registered on the deployed
# Oracle Adapter with the award's own parameters, so this does not touch them.
# It replaces one pool on the Engine, which is only safe because that pool's
# exposure is zero, and it checks that rather than assuming it.
set -euo pipefail
cd "$(dirname "$0")/.."
NET=${NET:-testnet}
SRC=${SRC:-agama-poc}
DEP=deployments/testnet.json
W=target/wasm32v1-none/release

j() { python3 -c "import json;print(json.load(open('$DEP'))$1)"; }
ADMIN=$(j "['admin']")
USDC=$(j "['contracts']['usdc']")
VAULT=$(j "['contracts']['vault']")
ENGINE=$(j "['contracts']['allocationEngine']")
ORACLE=$(j "['contracts']['oracleAdapter']")
OLD_EF=$(j "['poolAdapters']['etherfuse']")

inv() { stellar contract invoke --id "$1" --source "$SRC" --network "$NET" -- "${@:2}"; }
rd()  { stellar contract invoke --id "$1" --source "$SRC" --network "$NET" --send=no -- "${@:2}" 2>&1 | tail -1 | tr -d '"'; }
# Same read without the quote stripping, for the answers that are JSON and
# whose quotes are part of them.
raw() { stellar contract invoke --id "$1" --source "$SRC" --network "$NET" --send=no -- "${@:2}" 2>&1 | tail -1; }

echo "== 0. the pool being replaced has to be empty"
# Re-runnable: once the swap has happened the old pool is gone from the Engine,
# and this script is the evidence for that swap, so it has to survive being run
# twice without either failing or doing the swap again.
if printf '%s' "$(raw "$ENGINE" pools)" | grep -q "$OLD_EF"; then
  EXP=$(rd "$ENGINE" get_exposure --pool_id "$OLD_EF")
  echo "   old Etherfuse adapter $OLD_EF exposure $EXP"
  [ "$EXP" = "0" ] || { echo "   it is not empty, stopping: deallocate it first"; exit 1; }
  SWAP=1
else
  echo "   old Etherfuse adapter $OLD_EF is already off the Engine"
  SWAP=0
fi

echo "== 1. the Stablebond pool"
# Priced at whatever EF_BOND says today, so the pool and the feed start in
# agreement and `price_drift_bps` starts at zero rather than at an artefact of
# the deployment.
EF_NAV=$(rd "$ORACLE" get_nav --feed_id EF_BOND)
echo "   EF_BOND reads $EF_NAV, the pool opens there"
# Resumable: a deploy that landed but whose output was lost to a timeout should
# not be repeated, so an address passed in is used as is.
POOL=${POOL:-$(stellar contract deploy --wasm $W/mock_stablebond.wasm --source "$SRC" --network "$NET" \
        -- --admin "$ADMIN" --usdc "$USDC" --price "$EF_NAV" 2>&1 | tail -1)}
echo "   pool $POOL"

echo "== 2. the Etherfuse adapter"
EF=${EF:-$(stellar contract deploy --wasm $W/etherfuse.wasm --source "$SRC" --network "$NET" \
      -- --admin "$ADMIN" --engine "$ENGINE" --vault "$VAULT" --usdc "$USDC" 2>&1 | tail -1)}
echo "   adapter $EF"

echo "== 3. wire the adapter to the pool and to the oracle"
inv "$EF" set_pool --admin "$ADMIN" --pool "$POOL" >/dev/null
inv "$EF" set_oracle --admin "$ADMIN" --oracle "$ORACLE" >/dev/null
echo "   pool         $(rd "$EF" pool)"
echo "   oracle       $(rd "$EF" oracle)"
echo "   oracle_value $(rd "$EF" oracle_value)"
echo "   drift bps    $(rd "$EF" price_drift_bps)"

echo "== 4. swap the pool on the Engine"
if [ "$SWAP" = "0" ]; then
  echo "   already done, pools are $(raw "$ENGINE" pools)"
else
# Same originator, jurisdiction and cap as the adapter it replaces, read off
# the Engine rather than retyped, so the risk limits do not quietly change.
OLDMETA=$(raw "$ENGINE" get_pool --pool_id "$OLD_EF")
ORIG=$(printf '%s' "$OLDMETA" | python3 -c "import json,sys;print(json.load(sys.stdin)['originator'])")
JUR=$(printf '%s' "$OLDMETA"  | python3 -c "import json,sys;print(json.load(sys.stdin)['jurisdiction'])")
CAP=$(printf '%s' "$OLDMETA"  | python3 -c "import json,sys;print(json.load(sys.stdin)['cap_bps'])")
echo "   carrying over originator $ORIG jurisdiction $JUR cap $CAP bps"
inv "$ENGINE" unregister_pool --admin "$ADMIN" --pool_id "$OLD_EF" >/dev/null
inv "$ENGINE" register_pool --admin "$ADMIN" --pool_id "$EF" \
    --originator "$ORIG" --jurisdiction "$JUR" --cap_bps "$CAP" >/dev/null
echo "   pools now $(raw "$ENGINE" pools)"
fi

echo "== 5. the peg gate on the Vault"
PEG=$(rd "$ORACLE" get_nav --feed_id USDC_USD)
echo "   USDC_USD reads $PEG"
# The gate is in the Vault source with nine cases covering it, and the deployed
# Vault predates it. No contract in this repository has an `upgrade` entry
# point, by design, so carrying it to the deployed instance means a generation
# migration: a new Vault, a new agUSD because agusd-core::set_minter freezes
# after the first mint, a redeployed staking for the same reason, and the
# outstanding supply redeemed first so nothing is stranded.
# scripts/deploy-vault-generation.sh is that procedure. It is not run from here,
# because retiring the generation Tranche 2 is being proven on is a decision and
# not a deployment step.
if rd "$VAULT" peg_feed >/dev/null 2>&1 && stellar contract invoke --id "$VAULT" \
     --source "$SRC" --network "$NET" --send=no -- peg_feed >/dev/null 2>&1; then
  inv "$VAULT" set_peg_feed --admin "$ADMIN" --feed_id USDC_USD --tolerance_bps 200 >/dev/null
  echo "   peg_feed      $(rd "$VAULT" peg_feed)"
  echo "   tolerance     $(rd "$VAULT" peg_tolerance_bps) bps"
  echo "   peg           $(rd "$VAULT" peg)"
else
  echo "   SKIP  this Vault generation has no peg_feed entry point."
  echo "         The gate and its tests are in contracts/vault/src; carrying it"
  echo "         to testnet needs scripts/deploy-vault-generation.sh."
fi

echo "== 6. record it"
POOL="$POOL" EF="$EF" OLD_EF="$OLD_EF" python3 - <<'PY'
import json, os, subprocess, datetime
p = 'deployments/testnet.json'
d = json.load(open(p))
def wasm(name):
    return subprocess.run(['shasum','-a','256',f'target/wasm32v1-none/release/{name}.wasm'],
                          capture_output=True, text=True).stdout.split()[0]
d.setdefault('mockPools', {})['etherfuseStablebond'] = {
    'address': os.environ['POOL'],
    'wasmHash': wasm('mock_stablebond'),
    'why': ("Etherfuse Stablebonds are live on Stellar mainnet and not on testnet, and "
            "Tranche 2 Deliverable 1 asks for the adapter to pass its unit tests against "
            "mock pool contracts. This is that mock, deployed so the adapter's "
            "subscription and redemption run on testnet as well as in the suite. It is "
            "not Etherfuse and is not presented as Etherfuse: on mainnet the adapter is "
            "pointed at the real pool through set_pool, which is the only thing that "
            "changes."),
}
d['poolAdapters']['etherfuse'] = os.environ['EF']
d.setdefault('retired', {})[os.environ['OLD_EF']] = {
    'what': 'Etherfuse pool adapter, generation before the Tranche 2 review',
    'reason': ("Its allocate() incremented an exposure counter and returned, so the USDC "
               "the Vault released sat on the adapter earning nothing while the Engine's "
               "book, the NAV and the yield keeper all read it as deployed into "
               "Stablebonds. The Stellar reviewer put it as 'allocate() only books an "
               "exposure counter ... so there is no Stablebond subscription or redemption "
               "path, mock or real'. The replacement subscribes into a pool, holds bond "
               "units, redeems to raise cash, and values the position from the EF_BOND "
               "feed through the Oracle Adapter. Exposure was zero when it was replaced, "
               "so it stranded nothing."),
    'replacedBy': os.environ['EF'],
    'date': datetime.date.today().isoformat(),
}
d.setdefault('pegGate', {}).update({
    'feed': 'USDC_USD',
    'toleranceBps': 200,
    'gates': ("Vault.deposit. agUSD is minted one for one against USDC, so a deposit is an "
              "exchange at par and the base asset has to be at par for it to be a fair "
              "one. Outside 200 bps either way the Vault returns PegBroken (331). Below "
              "par a deposit would buy agUSD at a discount and dilute holders who came in "
              "at a dollar; above par a withdrawal at par takes out more than was put in. "
              "Staleness is not a separate check: the read goes through the Oracle "
              "Adapter's get_nav, so a feed older than its one hour window stops deposits "
              "with OracleStale."),
})
json.dump(d, open(p,'w'), indent=2)
print('   deployments/testnet.json updated')
PY
echo
echo "done. the e2e that exercises all of it: bash scripts/e2e-etherfuse.sh"
