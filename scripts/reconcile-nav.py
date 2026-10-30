#!/usr/bin/env python3
"""Compute the private credit pool's NAV from an originator servicing tape.

Tranche 2, Deliverable 2 of the SCF #45 award asks for "the reconciliation
procedure between on-chain NAV and off-chain originator servicing data
documented and executed end-to-end on testnet". The Stellar reviewer put the
gap plainly: "Today the keeper reposts the stored value". This is the
replacement, and the property that matters about it is that it is a function:
the same tape and the same as-of date produce the same NAV, on anyone's
machine, so a reviewer can disagree with the number by rerunning it rather than
by taking our word.

The valuation, in full, with nothing held back for a footnote:

    pool value = cash received to date
               + principal outstanding
               + interest accrued and not yet paid
               - provisions

    NAV per unit = pool value / principal committed

Scaled to 7 decimals, so par is 10,000,000, which is the scale the Oracle
Adapter stores and the Vault reads.

Four choices in there are judgement rather than arithmetic, so they are named:

1.  Interest accrues on a simple actual/365 basis from disbursement to the
    as-of date, on the outstanding principal. Not compounded: these are short
    duration facilities that pay periodically, and compounding would book
    interest on interest the borrower never owes.

2.  Cash already received stays in the pool's value. It is the originator's
    remittance, not a reduction of the position, and a valuation that dropped
    it would make every repayment look like a loss.

3.  Provisions are a staircase on days past due, applied to outstanding
    principal: 0% current, 2% at 1-30, 10% at 31-60, 35% at 61-90, 75% past 90.
    A staircase is cruder than a loss model and that is the point: it has no
    parameters to tune after the fact, so it cannot be fitted to a NAV somebody
    wanted. The last bucket is a 25% recovery assumption on a senior secured
    position, which is conservative for trade receivables and is meant to be.

4.  Accrued interest on a defaulted loan is not counted. A loan 112 days past
    due is not accruing anything collectable, and carrying the accrual would
    let a default increase the NAV for as long as it stayed unresolved.

Usage:
    python3 scripts/reconcile-nav.py data/servicing/tape-2026-10-30.csv
    python3 scripts/reconcile-nav.py <tape> --as-of 2026-10-30 --json
"""
import argparse
import csv
import datetime
import hashlib
import json
import sys

SCALE = 10_000_000

# Days past due -> fraction of outstanding principal provisioned.
PROVISION_STAIRCASE = ((0, 0.00), (30, 0.02), (60, 0.10), (90, 0.35), (10**9, 0.75))


def provision_rate(dpd: int) -> float:
    for ceiling, rate in PROVISION_STAIRCASE:
        if dpd <= ceiling:
            return rate
    return PROVISION_STAIRCASE[-1][1]


def load(path):
    with open(path, newline="") as fh:
        return list(csv.DictReader(fh))


def value(rows, as_of):
    committed = cash = outstanding = accrued = provisions = 0.0
    lines = []
    for r in rows:
        principal = float(r["principal_usd"])
        repaid = float(r["principal_repaid_usd"])
        interest = float(r["interest_received_usd"])
        dpd = int(r["days_past_due"])
        status = r["status"]
        out = principal - repaid
        disbursed = datetime.date.fromisoformat(r["disbursed_on"])
        days = (as_of - disbursed).days
        # Choice 1 and choice 4, in two lines.
        acc = 0.0 if status == "default" else out * (int(r["coupon_bps"]) / 10_000) * days / 365
        # Interest already remitted is cash; only the unpaid remainder accrues.
        acc = max(0.0, acc - interest)
        prov = out * provision_rate(dpd)

        committed += principal
        cash += repaid + interest
        outstanding += out
        accrued += acc
        provisions += prov
        lines.append(
            {
                "loan_id": r["loan_id"],
                "originator": r["originator"],
                "status": status,
                "dpd": dpd,
                "outstanding": round(out, 2),
                "accrued": round(acc, 2),
                "provision": round(prov, 2),
                "provision_rate": provision_rate(dpd),
            }
        )

    pool_value = cash + outstanding + accrued - provisions
    nav = int(round(pool_value / committed * SCALE))
    return {
        "as_of": as_of.isoformat(),
        "loans": len(rows),
        "committed_usd": round(committed, 2),
        "cash_received_usd": round(cash, 2),
        "principal_outstanding_usd": round(outstanding, 2),
        "interest_accrued_usd": round(accrued, 2),
        "provisions_usd": round(provisions, 2),
        "pool_value_usd": round(pool_value, 2),
        "nav": nav,
        "nav_decimal": nav / SCALE,
        "lines": lines,
    }


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("tape")
    ap.add_argument("--as-of", default=None, help="YYYY-MM-DD, defaults to today UTC")
    ap.add_argument("--json", action="store_true")
    a = ap.parse_args()

    as_of = (
        datetime.date.fromisoformat(a.as_of)
        if a.as_of
        else datetime.datetime.now(datetime.timezone.utc).date()
    )
    rows = load(a.tape)
    out = value(rows, as_of)
    # The tape is the input to a number that moves money, so its digest travels
    # with the result. A NAV that cannot be tied back to a specific file is a
    # NAV nobody can audit.
    with open(a.tape, "rb") as fh:
        out["tape"] = a.tape
        out["tape_sha256"] = hashlib.sha256(fh.read()).hexdigest()

    if a.json:
        print(json.dumps(out, indent=1))
        return

    print(f"tape        {out['tape']}")
    print(f"sha256      {out['tape_sha256']}")
    print(f"as of       {out['as_of']}, {out['loans']} loans")
    print()
    print(f"  {'loan':<24}{'status':<12}{'dpd':>5}{'outstanding':>14}{'accrued':>12}{'provision':>12}")
    for l in out["lines"]:
        print(
            f"  {l['loan_id']:<24}{l['status']:<12}{l['dpd']:>5}"
            f"{l['outstanding']:>14,.2f}{l['accrued']:>12,.2f}{l['provision']:>12,.2f}"
        )
    print()
    print(f"  principal committed      {out['committed_usd']:>16,.2f}")
    print(f"  cash received            {out['cash_received_usd']:>16,.2f}")
    print(f"  principal outstanding    {out['principal_outstanding_usd']:>16,.2f}")
    print(f"  interest accrued         {out['interest_accrued_usd']:>16,.2f}")
    print(f"  provisions              -{out['provisions_usd']:>16,.2f}")
    print(f"  pool value               {out['pool_value_usd']:>16,.2f}")
    print()
    print(f"  NAV   {out['nav']}   ({out['nav_decimal']:.7f} per unit committed)")


if __name__ == "__main__":
    sys.exit(main())
