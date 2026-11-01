#!/usr/bin/env bash
# The peg gate, demonstrated on testnet without retiring anything.
#
# Tranche 2, Deliverable 2 of the award registers "The Reflector USDC/USD feed"
# as validating "peg integrity of the vault base asset". What that means
# operationally is in docs/NAV_RECONCILIATION.md and in the Vault's own doc
# comment: agUSD is minted one for one against USDC, so a deposit is an
# exchange at par, and the base asset has to be at par for it to be a fair one.
# Below par a deposit buys agUSD at a discount and dilutes everyone who came in
# at a dollar; above par a withdrawal at par takes out more than was put in.
#
# The gate is in the Vault source with nine unit cases. The deployed Vault
# predates it, and no contract in this repository has an `upgrade` entry point,
# so carrying it to the live instance means a generation migration: a new
# Vault, a new agUSD because agusd-core::set_minter freezes after the first
# mint, a redeployed staking for the same reason, and the outstanding supply
# redeemed first. That is scripts/deploy-vault-generation.sh and it is a
# decision rather than a deployment step.
#
# So this proves the gate on a Vault of its own instead. Two things make that
# honest rather than a dodge:
#
#   1. it is the same wasm, built from the same tree as the live suite
#   2. it uses its own feed, PEGTEST, so moving a price around to show a
#      refusal does not put invented points into the history of USDC_USD, which
#      is now sourced from Reflector and has to stay sourced
#
# What it cannot show is a successful deposit, because a Vault with no agUSD
# cannot mint. That turns out to be the cleaner demonstration: `require_peg`
# runs before the mint, so the gate's two outcomes are two different errors.
# PegBroken means the gate refused. NotInitialized means the gate let the call
# through and the next check stopped it.
#
#   bash scripts/e2e-peg-gate.sh
set -uo pipefail
cd "$(dirname "$0")/.."
NET=${NET:-testnet}
SRC=${SRC:-agama-poc}
# Two reporter identities, because every feed runs at a quorum of two and the
# admin is not one of them. The second was the only one named here, which was
# enough while the first signature came from $ADMIN and PEGTEST sat at the
# threshold-1 default.
REPORTER1_KEY=${REPORTER1_KEY:-agama-oracle-2}
REPORTER2_KEY=${REPORTER2_KEY:-agama-reporter-2}
DEP=deployments/testnet.json
j() { python3 -c "import json;print(json.load(open('$DEP'))$1)"; }
ADMIN=$(j "['admin']"); USDC=$(j "['contracts']['usdc']"); ORACLE=$(j "['contracts']['oracleAdapter']")
REPORTER1=$(stellar keys address "$REPORTER1_KEY")
REPORTER2=$(stellar keys address "$REPORTER2_KEY")
WHO=$(stellar keys address "${USER_KEY:-agama-user}")
SHADOW=${SHADOW:-$(python3 -c "
import json
d=json.load(open('$DEP'))
print((d.get('demonstrations') or {}).get('pegGate',{}).get('vault',''))")}

rd()  { stellar contract invoke --id "$1" --source "$SRC" --network "$NET" --send=no -- "${@:2}" 2>&1 | tail -1 | tr -d '"'; }
err() { stellar contract invoke --id "$1" --source "${USER_KEY:-agama-user}" --network "$NET" --send=no -- "${@:2}" 2>&1 | grep -oE "Error\(Contract, #[0-9]+\)" | head -1; }
push() {
  # A minute back: the ledger's close time trails the wall clock and a
  # timestamp in its future is refused with TimestampInFuture, 509.
  #
  # Both signatures are reporter keys. The first was $ADMIN, which stopped being
  # a reporter on 2026-10-31 and returns #503 NotAReporter, and the failure was
  # swallowed here: one vote landed, the quorum on a fresh PEGTEST is 1 so it
  # committed anyway, and nothing noticed the suite was running on half the
  # signatures it claimed.
  local t=$(( $(date -u +%s) - 60 ))
  stellar contract invoke --id "$ORACLE" --source "$REPORTER1_KEY" --network "$NET" -- \
    submit_nav --reporter "$REPORTER1" --feed_id PEGTEST --nav "$1" --timestamp "$t" >/dev/null 2>&1
  stellar contract invoke --id "$ORACLE" --source "$REPORTER2_KEY" --network "$NET" -- \
    submit_nav --reporter "$REPORTER2" --feed_id PEGTEST --nav "$1" --timestamp "$t" >/dev/null 2>&1
}

P=0; F=0
ok()  { P=$((P+1)); printf '  PASS  %-52s %s\n' "$1" "${2-}"; }
bad() { F=$((F+1)); printf '  FAIL  %-52s %s\n' "$1" "${2-}"; }
eq()  { [ "$2" = "$3" ] && ok "$1" "$2" || bad "$1" "got $2 want $3"; }

if [ -z "$SHADOW" ]; then
  echo "== deploying the Vault this runs against"
  SHADOW=$(stellar contract deploy --wasm target/wasm32v1-none/release/vault.wasm \
            --source "$SRC" --network "$NET" -- --admin "$ADMIN" --usdc_token "$USDC" 2>&1 | tail -1)
  echo "   $SHADOW"
fi

# The wiring runs every time, not only on the run that deploys the Vault.
#
# It used to sit inside the branch above, so a recorded Vault was assumed to be
# wired to whatever oracle the record names today. That assumption broke the
# first time the oracle was replaced: on 2026-11-01 the migration repointed the
# live Vault and the Etherfuse adapter, which are the two contracts that name it
# in the record, and this demonstration Vault is a third. It went on reading the
# retired oracle, PEGTEST did not exist on the replacement, and the suite came
# back 2 passed 9 failed with every deposit refused #511 OracleStale.
#
# Each of these is idempotent and each is silenced for the same reason: a feed
# already registered, a pointer already correct and a tolerance already set all
# return errors that mean "nothing to do here".
stellar contract invoke --id "$ORACLE" --source "$SRC" --network "$NET" -- \
  register_feed --admin "$ADMIN" --feed_id PEGTEST --staleness_secs 3600 \
  --deviation_bps 1000 --min_nav 9000000 --max_nav 11000000 --min_interval_secs 0 >/dev/null 2>&1
stellar contract invoke --id "$SHADOW" --source "$SRC" --network "$NET" -- \
  set_oracle --admin "$ADMIN" --oracle "$ORACLE" --feed_id PC_NAV >/dev/null 2>&1
stellar contract invoke --id "$SHADOW" --source "$SRC" --network "$NET" -- \
  set_peg_feed --admin "$ADMIN" --feed_id PEGTEST --tolerance_bps 200 >/dev/null 2>&1
push 10000000
# And it is checked rather than assumed, because every call above is silenced.
if [ -z "$(rd "$ORACLE" get_nav --feed_id PEGTEST)" ]; then
  echo "   PEGTEST has no value on $ORACLE after the wiring, so there is nothing"
  echo "   to demonstrate a gate against. Stopping rather than reporting a feed"
  echo "   that was never there as a gate that did not fire."
  exit 1
fi

echo "== 0. the Vault under test"
echo "   $SHADOW"
eq "it is pointed at a peg feed"              "$(rd "$SHADOW" peg_feed)" "PEGTEST"
eq "with the award's 200 bps tolerance"       "$(rd "$SHADOW" peg_tolerance_bps)" "200"

echo
echo "== 1. at par, the gate lets the call through"
push 10000000
eq "the feed reads par"                       "$(rd "$SHADOW" peg)" "10000000"
E=$(err "$SHADOW" deposit --from "$WHO" --amount 10000000)
eq "deposit is not refused by the peg"        "$E" "Error(Contract, #301)"
echo "        301 is NotInitialized: this Vault has no agUSD to mint, which is"
echo "        the check after the gate. The gate did not stop it."

echo
echo "== 2. three percent below par, the gate refuses"
push 9700000
eq "the feed reads 0.97"                      "$(rd "$SHADOW" peg)" "9700000"
E=$(err "$SHADOW" deposit --from "$WHO" --amount 10000000)
eq "deposit is refused with PegBroken"        "$E" "Error(Contract, #331)"

echo
echo "== 3. inside the tolerance, through again"
push 9850000
eq "the feed reads 0.985, 150 bps off par"    "$(rd "$SHADOW" peg)" "9850000"
E=$(err "$SHADOW" deposit --from "$WHO" --amount 10000000)
eq "deposit is not refused by the peg"        "$E" "Error(Contract, #301)"

echo
echo "== 4. three percent above par, refused too"
# Not symmetric in who it costs. Below par a deposit dilutes the holders who
# came in at a dollar; above par a withdrawal at par takes out more than was
# put in. The bound is on the absolute deviation for that reason.
push 10300000
eq "the feed reads 1.03"                      "$(rd "$SHADOW" peg)" "10300000"
E=$(err "$SHADOW" deposit --from "$WHO" --amount 10000000)
eq "deposit is refused with PegBroken"        "$E" "Error(Contract, #331)"

echo
echo "== 5. back to par, and the gate is open again"
push 10000000
E=$(err "$SHADOW" deposit --from "$WHO" --amount 10000000)
eq "deposit is not refused by the peg"        "$E" "Error(Contract, #301)"

echo
printf 'TOTAL: %d passed, %d failed\n' "$P" "$F"
[ "$F" -eq 0 ] || exit 1
