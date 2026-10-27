#!/usr/bin/env bash
# The multi-day campaign, counted off the public ledger rather than off our logs.
#
# "It has been running for weeks" is the one claim in this repository that our
# own output cannot settle. The keeper writes to a file on the machine that runs
# it, that file has no timestamps in it, and a reviewer has neither. So the
# number that matters is the one Horizon holds: every submit_nav the registered
# reporters ever signed, with the day it landed on and whether it succeeded.
#
# This needs no key, no identity and nothing of ours. It asks Horizon for the
# history of the dedicated reporter account, the one that has never been used
# for anything but reporting NAV, and counts. Where the local keeper logs
# happen to exist it prints their counts too, clearly marked as ours, after
# the part anyone can check.
#
# The reporter set has two keys and the other one is the deployment admin,
# which has signed every deploy, every allocation and every test run this
# project has ever made: more than twelve thousand operations, which Horizon
# serves two hundred at a time. Scanning it takes minutes and proves nothing
# the dedicated account does not prove faster, so it is behind ALL=1.
#
# The two counts do not match and are not meant to: the keeper runs on a timer
# and submits only when a feed is near the end of its window, so most passes
# push nothing. The ledger count is the lower one and the honest one.
#
#   bash scripts/campaign-report.sh
set -euo pipefail
cd "$(dirname "$0")/.."

HORIZON=${HORIZON:-https://horizon-testnet.stellar.org}

python3 - "$HORIZON" <<'PY'
import base64, collections, json, os, sys, urllib.request
from datetime import date, datetime

horizon = sys.argv[1]
dep = json.load(open('deployments/testnet.json'))
reporters = dep['oracleReporters']['addresses']
if not os.environ.get('ALL'):
    # the dedicated one: every operation it has ever signed is a submit_nav
    reporters = [a for a in reporters if a != dep['admin']]

def pages(url):
    # include_failed, because Horizon leaves failed transactions out of this
    # endpoint by default and a campaign report that counts only the
    # successes would print "0 failed" whatever had happened.
    while url:
        with urllib.request.urlopen(url, timeout=60) as fh:
            body = json.load(fh)
        recs = body['_embedded']['records']
        if not recs:
            return
        yield recs
        url = body['_links']['next']['href'] if len(recs) == 200 else None

def symbol(op):
    """The contract function an invoke_host_function called, if it says.

    Horizon hands the parameter back as a base64 SCVal: four bytes of type,
    four of length, then the symbol. Reading from the wrong offset gives an
    empty answer rather than an error, which is how this first reported that
    the reporters had never submitted anything.
    """
    for p in op.get('parameters') or []:
        if p.get('type') == 'Sym':
            try:
                raw = base64.b64decode(p['value'])
                n = int.from_bytes(raw[4:8], 'big')
                return raw[8:8 + n].decode()
            except Exception:
                return None
    return None

which = 'the reporter set' if os.environ.get('ALL') else 'the dedicated reporter'
print(f'== every submit_nav {which} has signed, read off Horizon')
total, days, stamps, failed = 0, collections.Counter(), [], 0
for who in reporters:
    n = 0
    for recs in pages(f'{horizon}/accounts/{who}/operations?limit=200&order=asc&include_failed=true'):
        for op in recs:
            if op['type'] != 'invoke_host_function' or symbol(op) != 'submit_nav':
                continue
            n += 1
            days[op['created_at'][:10]] += 1
            stamps.append(op['created_at'])
            if op.get('transaction_successful') is False:
                failed += 1
    total += n
    print(f'  {who[:8]}...{who[-4:]}  {n:5d} submit_nav')
if not os.environ.get('ALL'):
    print(f'  {dep["admin"][:8]}...{dep["admin"][-4:]}  the other key in the quorum, and the'
          ' deployment admin: ALL=1 counts it too, slowly')

stamps.sort()
first, last = stamps[0], stamps[-1]
# Calendar dates, not elapsed time. Counting the span as a timedelta made the
# denominator the number of whole 24 hour periods, so a run from the 9th at
# 13:11 to the 27th at 10:49 printed "19 of 18", which is the sort of line
# that makes a reader stop trusting the rest of the output.
span_days = ((date.fromisoformat(last[:10]) - date.fromisoformat(first[:10])).days + 1)
ts = [datetime.strptime(s, '%Y-%m-%dT%H:%M:%SZ') for s in stamps]
gap = max((ts[i + 1] - ts[i]).total_seconds() for i in range(len(ts) - 1)) / 3600

print(f'  total                       {total}')
print(f'  failed                      {failed}')
print(f'  first                       {first}')
print(f'  last                        {last}')
print(f'  calendar days with activity {len(days)} of {span_days} in the span')
print(f'  longest gap between two     {gap:.1f} hours')
print()
print('  per day:')
for day in sorted(days):
    print(f'    {day}  {days[day]:3d}  {"#" * min(days[day], 60)}')

print()
print('== and the keeper that signed them, from our own logs, which are ours')
for name, path, mark in (
        ('oracle keeper passes', '/tmp/agama-oracle-keeper.log', '  pushed'),
        ('market maker cycles', '/tmp/agama-sagusd-keeper.log', 'state written')):
    try:
        lines = open(path).read().splitlines()
    except OSError:
        print(f'  {name:28s} no log here, which is expected on any machine but ours')
        continue
    runs = sum(1 for l in lines if l.startswith(mark) or mark in l)
    bad = sum(1 for l in lines if 'failed 1' in l or 'failed 2' in l or 'failed 3' in l)
    print(f'  {name:28s} {runs}' + (f', {bad} with a failed push' if bad else ', no error'))
PY
