#!/usr/bin/env bash
# Put the deployment back into the shape every suite here implicitly assumes.
#
# These scripts walk end to end against one shared testnet deployment, and each
# one assumes a book that is roughly at rest: nothing owed to the queue, nothing
# standing at a pool, the account holding enough USDC to work with. None of them
# establishes that, so the first suite in a run gets what it expects and the
# ones after it get whatever the previous one happened to leave. Patching the
# assertions one at a time makes each suite tolerate one more shape and does not
# fix the class; establishing the shape once does.
#
# Nothing here takes anything from anybody. Settling pays queued claims to their
# recorded owners. Deallocating returns capital from an adapter to the Vault
# that adapter already stores. Both are ordinary operator calls.
#
#   normalise_book <vault> <engine> <usdc> <source> <network> <admin>
# Only one suite at a time, per source account.
#
# Two of these running together submit from the same account and collide on its
# sequence number: calls fail with TxBadSeq, reads come back empty, and one
# empty read poisons everything after it because the Vault address is itself
# read from the Engine. It looks exactly like a protocol failure and is not.
# It has happened twice, both times by running one suite while a whole chain was
# still going in the background, so it is a lock rather than a warning.
_acquire_suite_lock() {
  local src=$1 lock="/tmp/agama-smoke-$1.lock" holder
  if ! mkdir "$lock" 2>/dev/null; then
    holder=$(cat "$lock/owner" 2>/dev/null || echo "unknown")
    echo "  another suite is already running against $src (started by $holder)." >&2
    echo "  Two at once collide on the account's sequence number and both report" >&2
    echo "  failures that are not real. Wait for it, or remove $lock if it is stale." >&2
    return 1
  fi
  echo "pid $$ at $(date -u +%H:%M:%S)" > "$lock/owner"
  _SUITE_LOCK=$lock
  # Released however the script ends, including on a failed assertion. A script
  # that needs its own EXIT trap has to call release_suite_lock from it: bash
  # keeps one trap per signal, so setting another silently replaces this one and
  # leaves a lock nobody holds, which blocks every run after it. That happened.
  trap 'release_suite_lock' EXIT
  return 0
}

release_suite_lock() { [ -n "${_SUITE_LOCK:-}" ] && rm -rf "$_SUITE_LOCK"; return 0; }

normalise_book() {
  local VAULT=$1 ENGINE=$2 USDC=$3 SRC=$4 NET=$5 ADMIN=$6
  local pools p exp held dep

  _acquire_suite_lock "$SRC" || exit 3

  _nb_q() { stellar contract invoke --id "$1" --source "$SRC" --network "$NET" --send=no -- "${@:2}" 2>/dev/null | tr -d '"'; }
  _nb_tx() { stellar contract invoke --id "$1" --source "$SRC" --network "$NET" -- "${@:2}" >/dev/null 2>&1; }

  echo "  normalising the book before this suite reads it"

  # 1. Pay out whatever the queue owes. A deferred claim survives, and should:
  #    its owner cannot receive the token and the cash stays reserved for them.
  # shellcheck source=lib-settle-queue.sh
  . "$(dirname "${BASH_SOURCE[0]}")/lib-settle-queue.sh"
  settle_queue "$VAULT" "$SRC" "$NET"

  # 2. Bring home anything still standing at a pool. An adapter that holds the
  #    cash can be deallocated; one that was written down holds nothing and its
  #    exposure is already zero, so there is nothing to do and nothing to force.
  dep=$(_nb_q "$VAULT" deployed_capital)
  if [ "${dep:-0}" != "0" ]; then
    pools=$(_nb_q "$ENGINE" pools | tr -d '[]"' | tr ',' ' ')
    for p in $pools; do
      exp=$(_nb_q "$p" get_exposure)
      held=$(_nb_q "$USDC" balance --id "$p")
      [ "${exp:-0}" = "0" ] && continue
      if [ "${held:-0}" -ge "${exp:-0}" ]; then
        echo "    deallocating ${exp} from ${p:0:8}"
        _nb_tx "$ENGINE" deallocate --pool_id "$p" --amount "$exp"
      else
        echo "    ${p:0:8} has ${exp} booked and holds ${held}, so it cannot be"
        echo "    deallocated; that is a written down position, left alone"
      fi
    done
  fi

  # 3. Unpause. Deposits, requests and allocations are all refused while the
  #    breaker is on, so a run that pauses and then fails to turn it back off
  #    leaves every later suite failing at its first deposit. That happened:
  #    an unpause was refused, the transaction helper printed a hash anyway,
  #    and the next run read as a broken Vault rather than a paused one.
  if [ "$(_nb_q "$VAULT" is_paused)" = "true" ]; then
    echo "    the Vault is paused, from a run that did not turn the breaker back off"
    _nb_tx "$VAULT" set_paused --admin "$ADMIN" --paused false
    echo "    paused now: $(_nb_q "$VAULT" is_paused)"
  fi

  echo "    idle $(_nb_q "$VAULT" idle_reserves) booked $(_nb_q "$VAULT" booked_reserves) deployed $(_nb_q "$VAULT" deployed_capital) owed $(_nb_q "$VAULT" outstanding_liabilities)"
}
