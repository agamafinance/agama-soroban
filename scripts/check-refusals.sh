#!/usr/bin/env bash
# The four refusals, read back off the ledger rather than taken on trust.
#
# scripts/refusals-on-ledger.sh is the one that makes them: it narrows a cap,
# submits an allocation that breaches it, and lets the transaction fail on
# chain. That one needs the Engine's admin, so it is ours to run.
#
# This one is yours. It takes the four transaction hashes out of the evidence
# file, asks the public RPC for each, and checks three things: the transaction
# is on the ledger, it failed, and the contract error in its diagnostic events
# is the one the evidence file claims. No key, no identity, nothing of ours.
#
# The error code lives in the transaction meta, not in the result: a failed
# invoke returns "trapped" and nothing more, which is why reading the result
# alone would tell you a transaction failed without telling you why.
#
#   bash scripts/check-refusals.sh
set -euo pipefail
cd "$(dirname "$0")/.."

RPC=${RPC:-https://soroban-testnet.stellar.org}
DOC=${DOC:-docs/TRANCHE2_EVIDENCE.md}

python3 - "$RPC" "$DOC" <<'PY'
import json, re, subprocess, sys

rpc, doc = sys.argv[1], sys.argv[2]
text = open(doc).read()
line = next(l for l in text.splitlines() if 'failed transactions on the live Engine' in l)
claims = re.findall(r'\[`#(\d+)`\]\(https://stellar\.expert/\S+?/tx/([0-9a-f]{64})\)', line)
if not claims:
    sys.exit(f'no refusal hashes found in {doc}')

print(f'==> the {len(claims)} refusals the evidence file claims, asked of the ledger')
pas = fail = 0
for code, tx in claims:
    # curl, like the rest of this repository: the RPC answers urllib's default
    # user agent with a 403.
    body = json.dumps({'jsonrpc': '2.0', 'id': 1, 'method': 'getTransaction',
                       'params': {'hash': tx}})
    out = subprocess.run(['curl', '-s', '--max-time', '60', '-X', 'POST', rpc,
                          '-H', 'Content-Type: application/json', '-d', body],
                         capture_output=True, text=True).stdout
    res = json.loads(out)['result']
    found = set()
    for xdr in res.get('diagnosticEventsXdr', []):
        out = subprocess.run(['stellar', 'xdr', 'decode', '--type', 'DiagnosticEvent',
                              '--input', 'single-base64', '--output', 'json'],
                             input=xdr, capture_output=True, text=True).stdout
        found.update(re.findall(r'"contract":\s*(\d+)', out))
    ok = res.get('status') == 'FAILED' and code in found
    print(f'  {"PASS" if ok else "FAIL"}  #{code}  {tx[:12]}...  '
          f'{res.get("status")}, ledger {res.get("ledger")}, error {sorted(found) or "none"}')
    pas, fail = (pas + 1, fail) if ok else (pas, fail + 1)

print()
print(f'  {pas} passed, {fail} failed')
print('  the public RPC keeps about a week of meta: past that, the same codes are')
print('  on stellar.expert, which stores it for good.')
sys.exit(1 if fail else 0)
PY
