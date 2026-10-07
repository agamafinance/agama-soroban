#!/bin/zsh
export PATH="/opt/homebrew/bin:/Users/eden/.cargo/bin:/usr/bin:/bin:$PATH"
cd /Users/eden/data/real-agama/agama-soroban
exec bash scripts/keeper-oracle.sh
