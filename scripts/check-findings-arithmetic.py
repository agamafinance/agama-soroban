#!/usr/bin/env python3
"""The findings table's own arithmetic, against the prose above it.

The paragraph above that table counts the findings and the table marks them one
by one, and the two drifted within an hour of each other being written: the prose
said nine fixes where the table had eleven, because fixes kept landing and the
sentence was written once. A count in prose that nobody checks is the same kind
of claim as a figure in prose that nobody checks, and this repository already
learned that lesson about figures.

    python3 scripts/check-findings-arithmetic.py

No network, no keys, no build. Run from the repository root.
"""
import re, sys
t = open('docs/TRANCHE2_EVIDENCE.md').read()
dep = len(re.findall(r'\*\*(?:fixed|closed) and deployed', t))
src = len(re.findall(r'\*\*fixed in source [^*]*not deployed\*\*', t))
openn = len(re.findall(r'\*\*open\*\*', t))
bad = 0
for label, pattern, actual in [
    ('fixed in source', r'\*\*(\w+) are now fixed in\nsource with a test each\*\*', dep + src),
    ('on the ledger',   r'\*\*(\w+) of the \w+ are on the\nledger\*\*',             dep),
]:
    m = re.search(pattern, t)
    if not m:
        print(f'  FAIL  the sentence about "{label}" is not where this expects it'); bad += 1; continue
    words = {'one':1,'two':2,'three':3,'four':4,'five':5,'six':6,'seven':7,'eight':8,
             'nine':9,'ten':10,'eleven':11,'twelve':12,'thirteen':13}
    claimed = words.get(m.group(1).lower())
    if claimed != actual:
        print(f'  FAIL  the prose says {m.group(1)} {label}, the table has {actual}'); bad += 1
    else:
        print(f'  PASS  {label}: prose and table both say {actual}')
if openn:
    print(f'  NOTE  {openn} findings still read **open**')
print()
print(f'TOTAL: {2 - bad} passed, {bad} failed')
sys.exit(1 if bad else 0)
