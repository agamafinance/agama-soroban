# Reconciling originator servicing data to NAV on chain

Tranche 2, Deliverable 2 of the SCF #45 award asks for this, in its own words:

> the reconciliation procedure between on-chain NAV and off-chain originator
> servicing data documented and executed end-to-end on testnet

This is the procedure. It is written so that a reviewer can disagree with our
NAV by rerunning the computation, rather than by deciding whether to trust us.

## Several originators

The unit of everything is a pair: **one adapter instance and one feed**, one
originator each.

| what it holds | where |
|---|---|
| who is in, and under what name and jurisdiction | `register_pool` on the Engine |
| how much each one may hold at most | `set_caps`, nested pool under originator under jurisdiction |
| what range of each one's number is acceptable | `register_feed`, deviation, floor, ceiling, staleness, interval |
| how many signatures move each number | `set_quorum_threshold`, per feed |
| whether capital goes there at all | `allocate`, and not allocating is the strongest of these |

The weights are not a judgement call. A pool's share of the blended return is
the capital placed in it, which is already on the ledger as its exposure, so
`keeper-yield.sh` groups exposure by the feed each adapter names and prices each
group against its own. Three originators at 40/40/20 need no new arithmetic:
they need three rows.

Nothing is averaged. An originator's NAV is a statement about its own book, and
blending two books into one number would price capital at a figure no originator
reported, while throwing away the only thing a concentration cap can act on.

### What this cost, and what it was

The feed used to be compiled into the adapter:

```rust
pub const ORACLE_FEED: Symbol = symbol_short!("PC_NAV");
```

So a second originator needed a second **build** of the same contract, and a
protocol that needs a compiler to take on a counterparty will not take one on.
It is a constructor parameter now, stored per instance, movable by the admin
only while the instance is empty: repointing a funded one would reprice live
capital against a different originator's book in a single transaction, with the
exposure unchanged, the NAV it is multiplied by changed, and the share price
moving for a reason no event explains.

Proved on testnet rather than argued. `bash scripts/e2e-two-originators.sh`,
**15 passed, 0 failed**: one wasm, two instances answering `PC_NAV` and
`PC_NAV2`, two originators and two jurisdictions on the Engine, both feeds
bounded and at quorum two, the keeper showing three feed groups with the new
exposure under its own, and a funded instance refusing to be repointed with
`#605`.

## Who does what, and who touches nothing

The chain has exactly three parties and only one of them operates anything.

| party | what it does | what it holds |
|---|---|---|
| the originator | remits a servicing report, loan level, on a cadence set by the facility agreement, and repays | nothing. No key, no transaction, no access to any contract or script here |
| Agama | receives the report, computes the NAV from it with `reconcile-nav.py`, and submits that number | the two dedicated reporter keys, and separately the oracle admin key |
| the Oracle Adapter | accepts or refuses the number against bounds set in advance | the stored reading |

The originator reporting its own book is not a trust problem to engineer away,
it is what lending is: a lender's figures come from the borrower's statements in
every private credit facility that has ever existed. What matters is that the
step from that statement to a number on a public ledger is **mechanical and
reproducible**, which is why `reconcile-nav.py` is a pure function of a tape and
an as-of date and emits the tape's sha256 next to its result. Anyone with the
tape recomputes the number.

What would be a trust problem is the originator holding a reporter key, because
then the borrower would be voting on the value of its own debt and on the share
price of depositors who never agreed to that. It holds no key.

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
specific file is a NAV nobody can external review.

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

## The peg feed, and what it gates

The reviewer asked us to say this plainly, so: **`Vault::deposit`**.

agUSD is minted one for one against USDC and withdrawals are paid one for one
in USDC, so both are exchanges at par, and both hand the difference to one side
when the base asset is not at par. Below par a deposit buys agUSD at a discount
and dilutes everyone who came in at a dollar. Above par a withdrawal at par
takes out more value than was put in, at the expense of whoever stays. The
bound is on the absolute deviation for that reason, and it is 200 basis points,
the figure the award names.

Staleness is not a separate check. The read goes through the Oracle Adapter's
`get_nav`, so a peg feed nobody has updated inside its one hour window stops
deposits with `OracleStale`, for the same reason an off-peg one does.

The feed itself is sourced from Reflector by `scripts/keeper-reflector.sh`, not
reposted. It currently reads `10013012`, which is Reflector's
`lastprice(Other("USDC"))` of 1.00130125419644 rescaled from its 14 decimals to
our 7.

Demonstrated on chain by `scripts/e2e-peg-gate.sh`, 11 assertions, on a Vault
deployed for the purpose and declared as such in the deployment record under
`demonstrations.pegGate`. The live Vault predates the gate and no contract in
this repository has an `upgrade` entry point, so carrying it there is the
generation migration in `scripts/deploy-vault-generation.sh`.
