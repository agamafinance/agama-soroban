# Reconciling originator servicing data to NAV on chain

Tranche 2, Deliverable 2 of the SCF #45 award asks for this, in its own words:

> the reconciliation procedure between on-chain NAV and off-chain originator
> servicing data documented and executed end-to-end on testnet

This is the procedure. It is written so that a reviewer can disagree with our
NAV by rerunning the computation, rather than by deciding whether to trust us.

## What was wrong before

`scripts/keeper-oracle.sh` reposted the value already stored on the feed, to
keep it inside its staleness window. Its own header said so. That proves a feed
stays fresh and proves nothing about where the number came from, and the Stellar
reviewer said as much: *"Today the keeper reposts the stored value."*

## The chain of custody, five links

```
  1  a servicing tape           data/servicing/tape-YYYY-MM-DD.csv
  2  a pure function of it      scripts/reconcile-nav.py
  3  one vote per reporter      OracleAdapter::submit_nav
  4  the feed's own guards      staleness, deviation, band, interval
  5  yield, pool by pool        scripts/keeper-yield.sh -> distribute_yield
```

Run the whole thing with `bash scripts/e2e-reconciliation.sh`.

### 1. The tape

Loan level, one row per facility, as an originator remits it:

```
loan_id,originator,jurisdiction,asset_class,disbursed_on,maturity_on,
principal_usd,coupon_bps,status,days_past_due,principal_repaid_usd,
interest_received_usd
```

The sample in `data/servicing/` is twelve facilities across three signed
originators, two of them delinquent and, in the `-impaired` variant, one in
default at 112 days. It is a sample and is labelled as one: the real tapes
arrive under NDA and their digests, not their contents, are what belongs in a
public repository.

### 2. The computation

`scripts/reconcile-nav.py` is a function of the tape and the as-of date. Same
inputs, same integer, on any machine.

```
  pool value   = cash received to date
               + principal outstanding
               + interest accrued and not yet paid
               - provisions

  NAV per unit = pool value / principal committed        scaled to 7 decimals
```

Four of those lines are judgement rather than arithmetic, so they are named in
the script's own header and repeated here:

1. Interest accrues simple, actual/365, from disbursement to the as-of date, on
   outstanding principal. Not compounded: these are short facilities that pay
   periodically, and compounding would book interest the borrower never owes.
2. Cash already received stays in the pool's value. It is the originator's
   remittance, not a reduction of the position.
3. Provisions are a staircase on days past due, applied to outstanding
   principal: **0%** current, **2%** at 1 to 30, **10%** at 31 to 60, **35%** at
   61 to 90, **75%** past 90. A staircase is cruder than a loss model and that
   is the point: it has no parameters to tune after the fact, so it cannot be
   fitted to a NAV somebody wanted.
4. Accrued interest on a defaulted loan is not counted, or a default would
   raise the NAV for as long as it stayed unresolved.

The tape's `sha256` travels with the result. A NAV that cannot be tied to a
specific file is a NAV nobody can audit.

### 3 and 4. On chain

`submit_nav` once per reporter, at one timestamp. The quorum on `PC_NAV` is two
and the Adapter's guards are the award's own: 7 days of staleness, a 500 bps
deviation bound, a 0.5 to 2.0 band, and one point per hour.

**Both reporter keys are held by this project.** The reviewer is right to say
so. A two-of-two quorum among our own keys bounds operator error, not operator
intent: it stops one fat-fingered push, and it stops nothing that we decide to
do deliberately. A third reporter outside this project is what would turn it
into a reduction in trust, and it is listed as open in `TRANCHE2_EVIDENCE.md`
rather than presented as done.

### 5. Yield

`scripts/keeper-yield.sh` prices each pool from the feed that pool names, reads
every feed through the Adapter's `get_nav` so a stale one stops the whole run,
and clamps a falling feed to zero because a loss is a `write_down` and goes
through a different entry point.

## The run

`docs/evidence/reconciliation-2026-10-30.log`, in full. The short version:

| | |
|---|---|
| tape | `data/servicing/tape-2026-10-30.csv` |
| NAV computed | `10374235` (1.0374235) |
| PC_NAV before | `10181000`, a 189 bps move inside a 500 bps bound |
| quorum | `NavQuorumReached` votes 2 at timestamp 1793372104 |
| keeper | `PC_NAV` exposure 100000000, yield **1897996**; `EF_BOND` exposure 0, nothing |
| `exchange_rate` | 17138171 -> 17143622 |
| `total_shares` | 3481817847 -> 3481817847, no share minted |
| strategist | paid 1897996 agUSD |

Rerunning `e2e-reconciliation.sh` now takes its no-op branch and says so: this
NAV has been consumed, and distributing it twice would be a double payment.

## The impaired case

The same twelve facilities with the Tenka loan 112 days past due produce
`9973098`, below par. It is computed in the run and deliberately **not pushed**:
the keeper would correctly distribute nothing, and moving a live feed down four
percent and back up for the sake of a demonstration would leave two
unexplained points in its history. The behaviour itself is covered in the unit
suite.
