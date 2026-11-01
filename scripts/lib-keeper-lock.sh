#!/usr/bin/env bash
# Stand aside while a suite is running against the same account.
#
# The suites take an exclusive lock per source account because two of them at
# once collide on its sequence number: calls come back TxBadSeq, reads come back
# empty, and the result reads as a protocol failure. lib-baseline says all of
# that and the keepers were never part of it, which left the collision the lock
# was built for wide open in the one direction nobody had closed.
#
# The keepers sign as the same operator key and run under launchd every ten
# minutes. So `smoke-mediums` asked the Engine to propose a new admin, a keeper
# reached for the same sequence number in the same second, the proposal came
# back TxBadSeq, and five assertions then compared the Engine against an admin
# it had never been given. Nothing was wrong with the protocol and nothing was
# wrong with the keeper.
#
# Skipping a pass costs nothing here, which is why standing aside is the right
# answer rather than waiting: every feed this touches has a window measured in
# hours or days, the next pass is ten minutes away, and the keepers already
# handle a refused push as an ordinary outcome.
#
#   . "$(dirname "$0")/lib-keeper-lock.sh"
#   keeper_stand_aside_if_suite_running "$SRC" || exit 0
#
# A lock left behind by a suite that was killed rather than finished would
# otherwise stop the keepers for good, which is a worse failure than the one
# this prevents: a feed nobody refreshes goes stale and every reader of it
# reverts. So a lock older than STALE_LOCK_SECS is treated as abandoned and the
# pass goes ahead, loudly.
STALE_LOCK_SECS=${STALE_LOCK_SECS:-1800}

keeper_stand_aside_if_suite_running() {
  local src=$1 lock="/tmp/agama-smoke-$1.lock" age
  [ -d "$lock" ] || return 0
  age=$(( $(date +%s) - $(stat -f %m "$lock" 2>/dev/null || stat -c %Y "$lock" 2>/dev/null || echo 0) ))
  if [ "$age" -ge "$STALE_LOCK_SECS" ]; then
    echo "   a suite lock on $src is ${age}s old, past ${STALE_LOCK_SECS}s, so it is"
    echo "   treated as abandoned and this pass goes ahead. Held by:" \
         "$(cat "$lock/owner" 2>/dev/null || echo unknown)"
    return 0
  fi
  echo "   a suite is running against $src ($(cat "$lock/owner" 2>/dev/null || echo unknown))."
  echo "   Standing aside: one more signer on that account is TxBadSeq for both"
  echo "   of us, and the next pass is minutes away."
  return 1
}
