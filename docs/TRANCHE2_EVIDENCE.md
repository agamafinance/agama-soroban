# Tranche 2, Evidence

Every claim below is a command anyone can run or a transaction anyone can open.

Generated 2026-10-26. Network: Stellar testnet.

Tranche 2 is three deliverables: the Allocation Engine with on-chain risk caps,
the oracle pipeline for NAV and yield, and hardening for the audit. Each one
is taken criterion by criterion, in the words the award was approved on.

A note on what changed since Tranche 1, because it affects how to read this
file. Nothing here was re-proven on a fixture. Where a criterion could only be
met in a unit test, it says so and the gap was closed rather than argued; two
of the criteria below have an on-chain proof that did not exist a week ago.

## Deliverable 1, Allocation Engine with on-chain risk caps

| Criterion | How to check it | Result |
|---|---|---|
| engine live on testnet with whitelisted pools | `pools()` on the Engine | **three adapters**, each with its own originator and jurisdiction: ETHERFUS/MX, QIRO/LU, ABF/JE |
| allocations exceeding any cap rejected on-chain, as transactions anyone can open | four failed transactions on the live Engine, 26 October | [`#407`](https://stellar.expert/explorer/testnet/tx/3495b21279599c0c0bc208b8cba70ada1d336121b06d899e4c8f83bb59fc850d) · [`#408`](https://stellar.expert/explorer/testnet/tx/2617441d7d7eb1e4d95d83fac38b06e217550762cfb213301bf7e4d118837307) · [`#409`](https://stellar.expert/explorer/testnet/tx/44fa4542be207a7bf13a4603c1441dda853e280493354a5b8c5ae3e7e9d044da) · [`#410`](https://stellar.expert/explorer/testnet/tx/16de0ecf1dab8e8a79802c5cd95f7eaa0c7509ebb84efa8cc15460ba1ad4d181). `bash scripts/refusals-on-ledger.sh` produced them and read each code back off the ledger |
| the same four, run as a suite | `bash scripts/e2e-allocation-guards.sh` | **10 passed, 0 failed**: over the per-pool cap is `#407`, breaking the reserve floor is `#410` |
| the other two caps, on the same Engine | `bash scripts/e2e-concentration-caps.sh` | **10 passed, 0 failed**: the originator cap is `#408`, the jurisdiction cap is `#409` |
| and that run is in the ledger, not just in our terminal | `caps_updated` events, ledgers 5401518 to 5401526, at [/api/events](https://app.agama.finance/api/events) | 500 bps in and back out, twice. A cap at 500 bps in that stream is the script proving the limit it narrowed |
| current exposures readable via contract calls | `get_exposures()`, `get_exposure(pool)`, `caps()`, `reserve_floor_bps()` | pool by pool, and the caps as the ledger holds them: 4000 / 4500 / 5000 bps over a 2500 bps floor |
| source code public throughout development | [the repository](https://github.com/agamafinance/agama-soroban) | Apache-2.0 from the first commit |

**Why the second script exists.** The first suite reaches the per-pool cap and
the reserve floor and stops there, and that is the shape of the live book
rather than an oversight in the Engine. With one pool per originator and one
per jurisdiction, the per-pool cap at 4000 bps always refuses before the
originator cap at 4500 or the jurisdiction cap at 5000 can be reached. Those
two limits were enforced in the contract and covered by unit tests
(`allocation_is_rejected_when_it_breaches_the_originator_cap`, and the
jurisdiction twin), and had never been seen to fire against the ledger.
`e2e-concentration-caps.sh` narrows the cap under test below what one
allocation charges, allocates into a pool nowhere near its own cap so the
error that comes back is the one being tested, and restores the caps
afterwards, asserting they are back even when it exits through a failure.

## Deliverable 2, Oracle pipeline for NAV and yield

| Criterion | How to check it | Result |
|---|---|---|
| NAV updates flowing from all three feed types | `get_nav(feed)` and `last_update(feed)` on the Oracle Adapter | all three inside their own windows on 26 October: USDC_USD 14 min into a 60 min window, PC_NAV 69 h into 168 h, EF_BOND 21 h into 48 h |
| the windows and bounds are the ones approved | `deployments/testnet.json`, `oracleFeeds`, and the contract's own reads | USDC_USD 3600 s / 200 bps, PC_NAV 604800 s / 500 bps, EF_BOND 172800 s / no deviation bound |
| stale reports revert with OracleStale | `cargo test --workspace` | `stale_read_errors_with_oracle_stale`, `get_nav_reads_the_oracle_and_propagates_staleness` |
| out-of-bounds reports rejected | same | `out_of_bounds_deviation_fails_push_nav`, `out_of_bounds_deviation_emits_nav_rejected_on_submit_nav`, `the_deviation_bound_is_exact_to_the_stroop`, and `NavOutOfBand` (513) and `TooSoon` (514) in `smoke-hardening.sh`, which shows those two by simulation rather than on the ledger: the CLI will not submit a transaction whose simulation fails, and the four refusals that are on the ledger got there by patching a prepared transaction |
| a NAV cannot be moved by one reporter | `bash scripts/e2e-oracle-quorum.sh` | **11 passed, 0 failed** against a quorum of two: one reporter gets `Pending` and moves nothing, a repeat vote is `#518`, a second distinct reporter commits. What it does not cover, stated here rather than left to be found: the threshold is admin settable with no floor above one, and the admin is also the first reporter, so the quorum holds against a compromised reporter and not against the admin key. A threshold that only ratchets upward is a one line change we are taking to the audit rather than redeploying under a submitted milestone |
| yield distribution driven by oracle data | `bash scripts/keeper-yield.sh` | **proven on chain twice on 26 October**: PC_NAV 10150500 to 10181000 through a quorum of two, 1210 USDC of deployed capital, 36357814 stroops distributed, share price moved with it, no share minted. Earlier the same day on 100 USDC: 10100000 to 10150500, 500000 stroops, 16320400 to 16321847 |
| reconciled against what backs it | `bash scripts/e2e-generation3.sh`, section 8 | agUSD in circulation against its backing, and sagUSD against the tracked share count, both closing in the same run |

**What drives what, exactly.** The Vault prices its book by reading PC_NAV
through its own `get_nav`, and a stale feed makes that read revert rather than
return a number. Staleness is measured against the timestamp the reporter
attests to, and `keeper-oracle.sh` reposts the value already on the feed with
the current time once half a window has gone, because testnet has no upstream
private credit NAV to re-source from. So on this deployment a feed expires when
its reporters stop, not when the number behind it gets old, which is why the
staleness suite has to pause the keeper to show the guard at all. Re-sourcing
on every pass, and refusing a report already outside its own window on the way
in, are what make this mechanism mean on mainnet what it reads like here.
`keeper-yield.sh` reads the same way, so the keeper stops
where the Vault stops, and computes `deployed capital x (PC_NAV now / PC_NAV at
the last distribution - 1)`. The distribution itself still requires the agUSD
to be transferred: an oracle that doubles overnight asks the strategist for
agUSD they have to actually hold, which is what keeps a feed from minting
value. The recorded NAV only advances when the distribution lands.

Until 26 October the yield was delivered by `distribute-yield-loop.sh`, which
hands over a constant and says so in its own header. It proved the plumbing and
not this criterion, and it is kept for demos.

## Deliverable 3, Hardening and audit readiness

| Criterion | How to check it | Result |
|---|---|---|
| sustained multi-day testnet campaign without critical failures | `bash scripts/campaign-report.sh`, which needs no key and answers in seconds, or the reporter account on [stellar.expert](https://stellar.expert/explorer/testnet/account/GASAXCP2Z4BSK5RGPFU257FA57K47JSPD6BJYYKH3RDQ2CKYXIYQOM4H) | **more than 500 `submit_nav` transactions, none failed, on every calendar day since 9 October without exception**, longest gap between two submissions 11.5 hours. That account has never signed anything else, which is why it is the one to count: the other key in the quorum is the deployment admin, and `ALL=1` counts its submissions too (**1009 together**) by scanning the twelve thousand operations it has signed since the first deploy, which takes minutes rather than seconds. Our own logs add the passes that submitted nothing because every feed was still fresh: the keeper is scheduled every ten minutes and has recorded **more than 920 passes, 11 with a failed push**, every one of them the public RPC not answering with a ledger, so nothing was submitted and the next pass carried it; the sagUSD market maker, **more than 1770 quoting cycles, no error**. The counts differ because most passes have nothing to push, and because a timer on a laptop does not fire while the laptop sleeps, which is what the 11.5 hour gap is. A third job extends the contracts' TTL every 72 hours, which is why every address in this file still answers |
| agUSD/USDC swaps through the Stellar DEX | `bash scripts/e2e-generation3.sh`, section 6 | a Soroswap swap, executed in the run |
| and path payments | same run, section 7 | the order book quoted through Horizon's strict-send paths, then a `path-payment-strict-send`, with the run asserting the fill honoured the quote it was taken at |
| codebase frozen for the audit | `git diff --name-only aee6c61..HEAD -- contracts/ adapters/ crates/ Cargo.toml Cargo.lock` | **nothing**, which is the freeze. What landed after aee6c61 is this file, six new scripts under `scripts/` and fixes to five more, the deployment record and the README. The check is the command, so it stays honest as we go on working on everything around the contracts |
| the freeze is a frozen tree, not a frozen claim | `bash scripts/smoke-hardening.sh` | **64 passed, 0 failed** on 26 October, against the live addresses. The adversarial review ahead of the audit found three critical, two high and four medium, every one fixed, every fix with a test that fails without it. The hashes the README carries for each finding are from 9 September and point at the retired generation, which is why the suite was re-run rather than cited |
| handed over to OtterSec | the engagement | **in scheduling**. This is the one line in this file that is not a command, and it is not going to be written as though it were |

## A second review, on 27 October, and what it found

The review above is the one that ran before the audit was scheduled. This is a
second pass over the same code, run the day this submission was finalised,
reported here because a finding a reviewer discovers for themselves costs more
than one we hand them.

| Finding | Severity | Status |
|---|---|---|
| Generation 1 agUSD (`contracts/agusd`, superseded) has an `initialize` with no `require_auth` and no re-entry guard, so anyone can claim its admin role and sweep its reserve | critical, on a retired contract | **reserve swept to the treasury on 27 October**, `reserve()` reads 0, nothing in service points at it. The contract is immutable so the source fix cannot reach it; `SECURITY.md` now names it as the exception to the constructor rule |
| `staking::stake` has no minimum first stake and no virtual offset, so a one stroop stake held through a distribution raises the share price permanently: later stakers below the new price are refused, above it they lose the truncation to the incumbent | critical on a fresh deployment | **open, for the audit**. Not reachable on the live contract, which has 3.48e9 shares outstanding. The fix is a minimum first stake or an ERC-4626 virtual offset, and it is a redeployment |
| A round is keyed on `(feed, timestamp)` and a reporter cannot change its vote, while the tally is keyed on the value. Two reporters who disagree on one timestamp split the tally one and one and neither can revote: that round is dead, and a reporter that disagrees on every round stops the feed for good | critical, needs a reporter key | **open, for the audit**. Raised by an outside reader of the repository on 27 October and verified in `contracts/oracle-adapter/src/lib.rs:838-849` the same day. The fix is to let a reporter replace its vote, or to key the round on the value with a timeout, and either is a redeployment |
| `staking::distribute_yield` does not check that the share supply is non zero, so a distribution into an empty pool is taken whole by the next staker | high | **open, for the audit**, and pinned by `yield_with_no_shares_goes_to_whoever_stakes_next` |
| Nothing stops staking immediately before a distribution and requesting immediately after: the cooldown delays the cash, not the pricing | high | **open, for the audit** |
| `vault::set_agusd` gates on this vault having taken no deposit, which stopped being the same statement as the token having no supply when agUSD became a classic asset | high | **open, for the audit**. The deployment record carries the case that proves the gap, `retiredAgusdResidue` |
| The oracle's staleness window is measured against the timestamp the reporter attests to, and the keeper reposts the value already on the feed, so a feed expires when its reporters stop rather than when the number ages | high, as a control | **documented above**, in Deliverable 2. The fix is to re-source on every pass and to refuse a report already outside its own window on the way in |
| The quorum threshold is admin settable with no floor above one, and the admin is also the first reporter | high, as a control | **documented above**. The fix is a threshold that only ratchets upward |
| `cctp::set_destination` lets the admin point the burn at any EVM address while exposure is zero, and `write_down` zeroes exposure with no cash moving | high, admin only | **open, for the audit**. The separation of duties its doc relies on is not implemented |
| `settle_withdrawal` takes no signature and strips the head claim of its queue position irreversibly, and a third party can choose the moment | medium | **open, for the audit** |
| The withdrawal queue has no partial fill, so a claim larger than idle reserves blocks every claim behind it | medium | **open, for the audit** |
| `staking` never extends its instance TTL on any user path, unlike the Vault, which does it on all eighteen | medium | **open, for the audit** |
| Anyone can block `staking::set_agusd` for good by sending one stroop of the current agUSD to the contract, because the guard reads a raw balance | medium | **open, for the audit** |
| `smoke-hardening.sh` counts four skipped branches as passes, so its 64 is compatible with the interval guard never having been exercised on that run | medium, in the evidence rather than the code | **open**. The suite prints `SKIP` correctly elsewhere and should here |
| `e2e-oracle-quorum.sh` submits the value the feed already holds, so "one reporter moves nothing" cannot fail | medium, in the evidence | **open**. Submitting a different value and asserting `last_update` did not advance is the fix |
| `check-authorization.sh` does not scan `adapters/cctp`, which is live and registered | medium, in the evidence | **open**. The 69 is the count for the files it does scan |

One word about who ran these. The adversarial reviews this file and the
README refer to are ours, run internally, not a third party engagement, and
the only external audit is the OtterSec one in the row above, in scheduling.
A reader who takes "adversarial review" for an outside report would be reading
more into it than it says, so here it is said plainly.

Two things this pass fixed in place rather than listing: `campaign-report.sh`
now ends in a verdict and exits non zero when a day is missing or a submission
failed, and the three sentences elsewhere in this file that claimed more than
the code did are corrected above.

## What backs every number above

| Check | Command | Result |
|---|---|---|
| every contract we deploy is the source in this tree | `bash scripts/check-deployment-record.sh --wasm` | 77 passed, 0 failed. Seven addresses are compared byte for byte, which is every contract this repository builds: the Vault, staking, the Engine, the Oracle Adapter and the three pool adapters. The other eight the record names are declared in `notCompared` with a reason and the pass fails on any address in neither list, because a hand written list is how six credit vaults, generation 1 agUSD and the USDC contract sat outside the claim for weeks without anyone deciding they should. Circle's USDC and the Stellar Asset Contracts carry no uploaded WASM at all, so there is nothing to rebuild; the six credit vaults are one build of `staking.wasm` with its ledger hash recorded. From a bare clone it is 65: twelve of them compare the docs site and need the docs repo alongside, and the script prints the skip and both totals |
| every state-changing entry point authorizes | `bash scripts/check-authorization.sh` | 69 entry points, 5 deliberately permissionless and argued one by one, 0 failures |
| every documented signature matches the ledger | `bash scripts/check-doc-entry-points.sh` | 9 passed, 0 failed |
| the contracts have not archived themselves | `bash scripts/check-ttl.sh` | 10 passed, 0 failed |
| advisories against the deployed bytecode | `bash scripts/check-advisories.sh` | **2 passed, 0 failed**. There are two open Dependabot alerts on this repository and we would rather name them than let you find them: `stellar-xdr` (medium, `StringM::from_str` skipping its length check) and `soroban-env-host` (low, muxed address conversions). Both are in `Cargo.lock` because `soroban-sdk`'s testutils pull the host in for the unit tests, and neither appears in any of the 18 deployed modules, which the script checks by searching the bytecode rather than the dependency graph. Bumping them would rewrite the tree frozen at `aee6c61` and with it every wasm hash on the ledger, so they stay until after the audit |
| the unit suite | `cargo test --workspace` | 227 passed, 0 failed, 11 suites |

## The contracts this tranche is about

| Contract | Address | What it does here |
|---|---|---|
| Allocation Engine | [`CBDVZPMB...ZE6FFD`](https://stellar.expert/explorer/testnet/contract/CBDVZPMBUQQ6OML3WTT4TP6QIOJDRC4BWYXR7UZQAAZG2LETAVZE6FFD) | routes capital, enforces the four limits |
| Oracle Adapter | [`CAUOHPPN...TWIQUS`](https://stellar.expert/explorer/testnet/contract/CAUOHPPNHUIYQI3KIVPLP75CGWKFBGSXK3RW75UO52PKY3YKQRTWIQUS) | three feed types, staleness, deviation, quorum |
| Vault | [`CCVNCXPJ...PZTTJF`](https://stellar.expert/explorer/testnet/contract/CCVNCXPJXCA5GKJKNUNZRMJEEWYL74ASYYTL2DULPO5TZDGSHUPZTTJF) | prices its book from PC_NAV, keeps its own floor |
| sagUSD Staking | [`CBOHG5YG...4CACV3`](https://stellar.expert/explorer/testnet/contract/CBOHG5YGAE7ORFDE5GIUN6MYYSXMHYWGLZTH3Y563HZCBBWFVQ4CACV3) | where the yield lands, as a share price |
| private credit adapter | [`CDNWXGSS...WLP3VE`](https://stellar.expert/explorer/testnet/contract/CDNWXGSSP3BOAIKIYTGDHST2BBSZNWIW6RMDQERM3HOQ24EO43WLP3VE) | QIRO, LU |
| Etherfuse adapter | [`CCXO2ZIM...KM7BXN`](https://stellar.expert/explorer/testnet/contract/CCXO2ZIMK7KZMMUBE24KOLWDJHVXQKXDNEP4QH7N5ZK5U6ESCWKM7BXN) | ETHERFUS, MX |
| cross chain adapter | [`CDSO4GJR...WUWFML`](https://stellar.expert/explorer/testnet/contract/CDSO4GJRY7BFVMQ4PYP3ISVOFPQLPA3C7ZFT5HQOUDM3VXTGOUWUWFML) | ABF, JE, `pool_kind` crosschn, settling on a 1 to 14 day window |

## If you hold none of our keys

Start here. Neither needs anything: no key, no identity, no funding, no config.

```sh
bash scripts/verify-tranche2.sh            # 23, against the live ledger
bash scripts/campaign-report.sh            # the oracle campaign, counted off Horizon
```

The first makes its own account, funds it from friendbot, and checks this file
against the chain, including the deployment record's own pool list against the
Engine's. It also reproduces two refusals, because a contract error comes back
from simulation before a signature is involved: `#407` over the per-pool cap at
an account that is nobody, and `#411` for more than the Vault holds idle. The
second counts the campaign off Horizon, which is the one claim our own logs
cannot settle.

Six more need no key either, and they are where the rest of the numbers above
come from:

```sh
cargo test --workspace                           # 227, 11 suites
bash scripts/check-deployment-record.sh --wasm   # 65 from a clone, 77 with the docs repo
bash scripts/check-authorization.sh              # 69 entry points
bash scripts/check-doc-entry-points.sh           # 9
bash scripts/check-ttl.sh                        # 10
bash scripts/check-advisories.sh                 # 2
```

And then the eight runs that sign, which you cannot, and it is worth
being exact about why rather than letting you find out: `allocate` and
`set_caps` require the Engine's admin, `submit_nav` requires a registered
oracle reporter, and the user-path suite needs an account holding the USDC we
issue on testnet. A reviewer holds none of those, by design. That is the same
property the tranche is about.

```sh
bash scripts/e2e-allocation-guards.sh      # 10, #407 and #410
bash scripts/e2e-concentration-caps.sh     # 10, #408 and #409
bash scripts/e2e-oracle-quorum.sh          # 11, a NAV one reporter cannot move
bash scripts/e2e-oracle-staleness.sh       #  3, OracleStale on the peg feed
bash scripts/refusals-on-ledger.sh         #  6, the four refusals, submitted not simulated
bash scripts/smoke-hardening.sh            # 64, the security review on the live addresses
bash scripts/e2e-generation3.sh            # 21, deposit to redemption, and the SDEX
DRY=1 bash scripts/keeper-yield.sh         # what the feed says the book earned, unsent
```

Two things to know before running those, if you ever do. The feeds are live and
a keeper reports to them every ten minutes, so an unpaused keeper closes the
quorum round under the script; it is the one place in this repository that asks
you to stop something first. And the staleness suite is allowed to let a feed
expire only because that feed, the peg check, is read by nothing on chain.

Send us an address and we will fund it with testnet USDC within the day, if you
would rather run the write path yourself than watch it in the video.
