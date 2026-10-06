#!/bin/zsh
# launchd wrapper: a login shell's PATH is not what launchd gives us.
export PATH="/opt/homebrew/bin:/Users/eden/.cargo/bin:/Users/eden/.nvm/versions/node/v22.22.2/bin:/usr/bin:/bin:$PATH"
cd /Users/eden/data/real-agama/agama-soroban
exec bash scripts/keeper-sagusd-book.sh
