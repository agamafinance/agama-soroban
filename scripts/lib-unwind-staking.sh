#!/usr/bin/env bash
# Empty the staking contract, but only when this account is the whole of it.
#
# Two smoke suites measure share issuance and the exchange rate from a standing
# start, so both need staking empty, and both used to refuse and exit 2 saying
# unwinding is the operator's call. That is right in general and wrong in the
# one case that actually blocks a run: when the account driving the script holds
# every share in existence, unwinding strands nobody, and refusing only means
# the suites cannot be run back to back.
#
# So it is conditional. Anything less than the whole supply and it still
# refuses, because then the shares do belong to somebody else and this is not
# the script to decide about them.
#
#   unwind_staking <staking_id> <source> <network> <admin_address>
#     0  staking is empty, by finding it that way or by emptying it
#     2  not empty and not this account's to empty, with the reason printed

_us_q() { stellar contract invoke --id "$1" --source "$_US_SRC" --network "$_US_NET" --send=no -- "${@:2}" 2>/dev/null | tr -d '"'; }
_us_tx() { stellar contract invoke --id "$1" --source "$_US_SRC" --network "$_US_NET" -- "${@:2}" 2>&1; }

unwind_staking() {
  local STAKING=$1 ADMIN=$4
  _US_SRC=$2
  _US_NET=$3

  local supply nav mine cooldown
  supply=$(_us_q "$STAKING" total_supply)
  nav=$(_us_q "$STAKING" nav)
  if [ "${supply:-x}" = "0" ] && [ "${nav:-x}" = "0" ]; then
    echo "  staking is empty: supply 0, nav 0"
    return 0
  fi

  mine=$(_us_q "$STAKING" balance --id "$ADMIN")
  echo "  staking holds supply ${supply:-?}, nav ${nav:-?}, of which this account holds ${mine:-?}"
  if [ "${supply:-0}" = "0" ] || [ "${mine:-0}" != "${supply}" ]; then
    echo "  this account does not hold the whole supply, so the shares belong to"
    echo "  somebody else and unwinding them is not this script's decision."
    echo "  By hand: request_unstake the whole balance, wait out the cooldown, claim."
    return 2
  fi

  echo "  this account is the whole supply, so unwinding it strands nobody"
  echo "  request_unstake $mine   tx $(_us_tx "$STAKING" request_unstake --from "$ADMIN" --shares "$mine" | grep -oE '[0-9a-f]{64}' | head -1)"

  cooldown=$(_us_q "$STAKING" cooldown)
  # A claim before the cooldown matures reverts, so this waits it out rather
  # than retrying into a guaranteed failure.
  echo "  waiting out the ${cooldown:-60}s cooldown"
  sleep $(( ${cooldown:-60} + 5 ))
  echo "  claim                   tx $(_us_tx "$STAKING" claim --from "$ADMIN" | grep -oE '[0-9a-f]{64}' | head -1)"

  supply=$(_us_q "$STAKING" total_supply)
  nav=$(_us_q "$STAKING" nav)
  if [ "${supply:-x}" = "0" ] && [ "${nav:-x}" = "0" ]; then
    echo "  staking is empty now: supply 0, nav 0"
    return 0
  fi
  echo "  unwinding did not finish: supply ${supply:-?}, nav ${nav:-?}"
  return 2
}
