#!/usr/bin/env bash
# Pay out every matured withdrawal claim before checking a balance.
#
# The suites here queue withdrawals and do not always settle them, so a run
# leaves USDC behind in the Vault owed to the account that will drive the next
# run. That account then reads its own balance, finds it short, and stops,
# which looked like a faucet problem and was not: the money was in the queue
# the whole time. One run left 38.3 USDC sitting there against an account
# reporting zero.
#
# `settle_withdrawal` is permissionless by design and pays whichever claim is at
# the head to the owner recorded on it, so calling it here takes nothing from
# anybody and delivers what is already owed. It is the honest way to make these
# suites composable, as opposed to scaling a deposit down to whatever happens to
# be left, which drains the account further and makes the next run worse.
#
#   settle_queue <vault_id> <source> <network> [max_iterations]
settle_queue() {
  local VAULT=$1 SRC=$2 NET=$3 MAX=${4:-12}
  local owed i
  owed=$(stellar contract invoke --id "$VAULT" --source "$SRC" --network "$NET" --send=no \
           -- outstanding_liabilities 2>/dev/null | tr -d '"')
  if [ "${owed:-0}" = "0" ]; then
    echo "  the withdrawal queue owes nothing"
    return 0
  fi
  echo "  the withdrawal queue owes $owed, settling it before reading balances"
  for ((i = 0; i < MAX; i++)); do
    stellar contract invoke --id "$VAULT" --source "$SRC" --network "$NET" \
      -- settle_withdrawal >/dev/null 2>&1 || break
    owed=$(stellar contract invoke --id "$VAULT" --source "$SRC" --network "$NET" --send=no \
             -- outstanding_liabilities 2>/dev/null | tr -d '"')
    [ "${owed:-0}" = "0" ] && break
  done
  echo "  the queue owes $owed now"
}
