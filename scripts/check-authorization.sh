#!/usr/bin/env bash
# Every entry point that changes state is authorized, or is on the list of the
# ones that deliberately are not.
#
# Why a script rather than a test
#
# It is a property of the source rather than of a running contract: "no public
# function mutates without asking somebody first". A Rust test cannot see that
# without introspecting the source, and the thing most likely to go wrong is a
# new entry point added later by somebody who did not know the rule. So it is a
# check that reads the files.
#
# It follows helpers. Several entry points here mutate only through a private
# helper, and several authorize only inside one: the oracle's push_nav and
# submit_nav both call process(), which is where reporter.require_auth() lives,
# and agUSD's burn delegates to the token crate, which authorizes there. A check
# that only looked at the entry point's own body would report both as gaps and
# be ignored within a week.
#
# The allowlist is the point
#
# Three calls here are permissionless on purpose, and each one is a decision an
# adversarial review made for a reason. Listing them with the reason means a
# fourth cannot be added quietly: it has to be written down next to the three
# that were argued for.
#
#   bash scripts/check-authorization.sh
set -uo pipefail
cd "$(dirname "$0")/.."

python3 - <<'PY'
import io, re, sys

FILES = {
    "vault": "contracts/vault/src/lib.rs",
    "allocation-engine": "contracts/allocation-engine/src/lib.rs",
    "staking": "contracts/staking/src/lib.rs",
    "agusd-core": "contracts/agusd-core/src/lib.rs",
    "oracle-adapter": "contracts/oracle-adapter/src/lib.rs",
    "adapters/private-credit": "adapters/private-credit/src/lib.rs",
    "adapters/etherfuse": "adapters/etherfuse/src/lib.rs",
}

# Permissionless on purpose. Each one is a decision, with the reason it was made.
ALLOWED = {
    ("vault", "settle_withdrawal"):
        "Review 1. A single unclaimed withdrawal froze the queue for everyone "
        "behind it. The caller chooses neither the claim nor the recipient, so "
        "there is nothing here to aim.",
    ("vault", "bump_claim"):
        "Review 2. A claim waiting on liquidity is a claim nothing writes to, "
        "so nothing extends its TTL and it archives. Cannot shorten a TTL, "
        "cannot alter a claim, and the caller pays the rent.",
    ("staking", "bump_pending"):
        "The same argument for a pending unstake, which a cooldown guarantees "
        "nobody is watching. Requiring the owner's signature would mean the one "
        "person who might have lost their key is the only one who can keep "
        "their claim alive.",
    # These authorize, just not in their own body.
    ("agusd-core", "burn"): "Authorizes in the token crate: from.require_auth().",
    ("agusd-core", "burn_from"): "Authorizes in the token crate: spender.require_auth().",
}

MUT = re.compile(r"storage\(\)\s*\.\s*\w+\(\)\s*\.\s*(set|remove)\(|\btok::(mint|burn)|\.transfer\(")
AUTH = re.compile(r"require_auth\(\)|require_admin\(|require_engine\(|require_reporter")

failures, checked, allowed_hits = [], 0, set()
for name, path in FILES.items():
    s = io.open(path, encoding="utf-8").read()
    marks = [(m.group(2), m.group(1) is not None, m.start()) for m in re.finditer(r"\n    (pub )?fn (\w+)\(", s)]
    bodies = {}
    for i, (fn, is_pub, a) in enumerate(marks):
        b = marks[i + 1][2] if i + 1 < len(marks) else len(s)
        bodies[fn] = (is_pub, s[a:b])

    # Mutation and authorization both propagate through helpers, so both are
    # closed over calls before anything is judged.
    mutating = {fn for fn, (_, body) in bodies.items() if MUT.search(body)}
    authorizing = {fn for fn, (_, body) in bodies.items() if AUTH.search(body)}
    for _ in range(5):
        for fn, (_, body) in bodies.items():
            calls = set(re.findall(r"\b(?:Self::)?(\w+)\(", body)) - {fn}
            if fn not in mutating and calls & mutating:
                mutating.add(fn)
            if fn not in authorizing and calls & authorizing:
                authorizing.add(fn)

    for fn, (is_pub, _) in sorted(bodies.items()):
        if not is_pub or fn.startswith("__") or fn not in mutating:
            continue
        checked += 1
        if fn in authorizing:
            continue
        key = (name, fn)
        if key in ALLOWED:
            allowed_hits.add(key)
            print(f"  ALLOWED  {name}::{fn}")
            print(f"           {ALLOWED[key]}")
        else:
            failures.append(f"{name}::{fn} changes state and asks nobody, and is not on the allowlist")

stale = set(ALLOWED) - allowed_hits
for name, fn in sorted(stale):
    failures.append(f"{name}::{fn} is on the allowlist and no longer needs to be")

print(f"\n  {checked} state-changing entry points checked, {len(allowed_hits)} deliberately permissionless")
for f in failures:
    print(f"  FAIL  {f}")
print(f"\n  {'0 failures' if not failures else str(len(failures)) + ' failures'}")
sys.exit(1 if failures else 0)
PY
