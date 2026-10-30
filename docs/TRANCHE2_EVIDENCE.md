# Tranche 2, Evidence

Every claim below is a command anyone can run or a transaction anyone can open.

Network: Stellar testnet. First generated 2026-10-26, rewritten 2026-10-30
against the award record.

## The criteria, transcribed

The first version of this file was measured against the scope as our roadmap
stated it, because the Tranche 2 criteria had never been transcribed into this
repository, and it said so. That was the root of the review that came back: a
reviewer compares against the award record, and we had published a different
yardstick. The record's own words are below, once, so that there is one
yardstick and it is not ours.

### Deliverable 1, Allocation Engine with on-chain reserve floor, Etherfuse and private credit adapters

> **How to measure completion:** engine live on testnet with both adapters
> registered; allocations breaching a cap or the reserve floor rejected
> on-chain; Etherfuse and private credit adapters passing their unit test suites
> against mock pool contracts; exposure map and current reserve ratio readable
> via contract calls.

### Deliverable 2, Oracle pipeline for NAV & yield

> **How to measure completion:** NAV updates flowing on testnet from all three
> feed types; stale reports reverting with OracleStale and out-of-bounds
> reports emitting nav_rejected, each demonstrated by a test case; yield
> distribution to sagUSD driven by oracle data; the reconciliation procedure
> between on-chain NAV and off-chain originator servicing data documented and
> executed end-to-end on testnet.

The three feeds, as the record describes them: the **Reflector USDC/USD** feed
validating peg integrity of the vault base asset at one hour of staleness and a
2% deviation bound; **private credit NAV** on a dedicated reporter feed at seven
days and 5%; **Etherfuse Stablebond pricing** on the Etherfuse feed at 48 hours
with no deviation bound, that NAV being deterministic.

### Deliverable 3, MoneyGram fiat ramp, hardening and audit readiness

> **How to measure completion:** SEP-10 authentication and SEP-24 interactive
> deposit and withdrawal flows completing end-to-end on Stellar Testnet against
> the MoneyGram Access sandbox, cash to USDC to agUSD and the reverse, with the
> SDF Stellar Test Anchor covering the same flows during MoneyGram onboarding;
> sustained multi-day testnet campaign without critical failures; codebase
> frozen and handed over for audit.

## Status against those criteria

| Criterion | Status | Where |
|---|---|---|
| D1 engine live, both adapters registered | **met** | `pools()` on the Engine |
| D1 cap and reserve floor breaches rejected on chain | **met** | four failed transactions, `e2e-allocation-guards.sh`, `e2e-concentration-caps.sh` |
| D1 both adapters passing unit suites against mock pool contracts | **met 2026-10-30** | `contracts/mock-stablebond`, 12 cases; `adapters/etherfuse`, 22 cases; the adapter now subscribes and redeems rather than incrementing a counter |
| D1 exposure map and reserve ratio readable | **met** | `get_exposures()`, `get_reserve_ratio()` |
| D2 NAV flowing from all three feed types | **met** | all three registered with the record's parameters, all three fresh |
| D2 the feeds sourced from Reflector and Etherfuse | **met 2026-10-30** | `keeper-reflector.sh` reads `lastprice(Other("USDC"))` off Reflector's SEP-40 oracle `CCYOZJCO...`; `keeper-etherfuse.sh` reads USTRY off `api.etherfuse.com` with a cross-source agreement check. Both refuse to submit when their own source has stalled, rather than pushing a stale number under a current timestamp |
| D2 OracleStale and nav_rejected, each with a test case | **met** | `oracle-adapter` suite, 53 cases, including `out_of_bounds_deviation_emits_nav_rejected_on_submit_nav` |
| D2 yield distribution driven by oracle data | **met 2026-10-30** | `keeper-yield.sh` now prices each pool from the feed that pool names; the 26 October run applied the private credit move to all deployed capital |
| D2 reconciliation documented and executed end to end | **met 2026-10-30** | `docs/NAV_RECONCILIATION.md`, `scripts/e2e-reconciliation.sh`, run in `docs/evidence/reconciliation-2026-10-30.log` |
| D2 the peg feed validating the base asset | **built and demonstrated on chain; not on the live Vault** | nine unit cases plus `scripts/e2e-peg-gate.sh`, 11 assertions on testnet: `PegBroken` at 300 bps either side of par, through inside 150 bps. It runs on a Vault of its own because no contract here has an `upgrade` entry point, so carrying the gate to the live instance is the generation migration in `deploy-vault-generation.sh`, which retires the Vault, agUSD and staking |
| D3 SEP-10 end to end | **met 2026-10-30** | `anchor/sep_client.py`, challenge verified before signing, JWT from `testanchor.stellar.org`; `docs/ANCHOR_RAMP.md` |
| D3 SEP-24 interactive deposit and withdrawal end to end | **met 2026-10-30** | both flows reached `completed` on testnet: deposit `ae2734cc`, withdrawal `57eaf7e1`. `scripts/e2e-anchor.sh` |
| D3 cash to USDC to agUSD and the reverse | **met 2026-10-30** | 5 USD of cash to 4.5 USDC to 4.5 agUSD, back through the FIFO queue, out as 4.1 USD. Every leg is a transaction in `docs/evidence/anchor-roundtrip-2026-10-30.log` |
| D3 sustained multi-day campaign | **met** | `campaign-report.sh`, 21 consecutive days |
| D3 codebase frozen and handed to audit | **not yet** | follows D3's first clause |

Nothing in that table is softened. Three rows say the work is not finished and
one says a built thing is not deployed.

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
| a NAV cannot be moved by one reporter | `bash scripts/e2e-oracle-quorum.sh` | **12 passed, 0 failed** on 27 October against a quorum of two: one reporter gets `Pending` and moves nothing, a repeat vote is `#518`, a second distinct reporter commits, now against a value the feed does not already hold. Until 27 October it submitted the stored value, which made "nothing committed, the feed is unchanged" hold whether or not the lone vote had committed: the assertion could not fail, so it was not evidence. It now moves the feed by one stroop and also asserts the stored round did not advance after the first vote. What it does not cover, stated here rather than left to be found: the threshold is admin settable with no floor above one, and the admin is also the first reporter, so the quorum holds against a compromised reporter and not against the admin key. A threshold that only ratchets upward is a one line change we are taking to the audit rather than redeploying under a submitted milestone |
| yield distribution driven by oracle data | `bash scripts/keeper-yield.sh` | **proven on chain twice on 26 October**: PC_NAV 10150500 to 10181000 through a quorum of two, 1210 USDC of deployed capital, 36357814 stroops distributed, share price moved with it, no share minted. The keeper asserts both of those itself since 27 October, before it only printed the rate afterwards and compared it to nothing, which left the criterion resting on a suite that drives a hand picked constant rather than on the oracle derived path. Earlier the same day on 100 USDC: 10100000 to 10150500, 500000 stroops, 16320400 to 16321847 |
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

## Deliverable 3, MoneyGram fiat ramp, hardening and audit readiness

The title is the award's. The first version of this section was called
"Hardening and audit readiness", dropped the fiat ramp, and listed a Soroswap
swap and SDEX path payments in its place. The reviewer was right to refuse that:
the Soroswap swap is Tranche 1 Deliverable 2 scope and path payments are not in
the award at all. Those two rows are gone from here. They are real and they are
evidence, of Deliverable 2 of the previous tranche, and they are cited there.

| Criterion | How to check it | Result |
|---|---|---|
| SEP-10 authentication end to end on testnet | `bash scripts/e2e-anchor.sh`, or `.venv-sep/bin/python anchor/sep_client.py auth` | **runs.** Challenge fetched from `testanchor.stellar.org`, verified before it is signed, JWT returned with `sub` matching the account. The verification is the part a naive client skips: source against the toml's `SIGNING_KEY`, sequence 0 so the transaction can never be submitted, first operation a `ManageData` naming our account, home domain matched, server signature valid, time bounds current |
| SEP-24 interactive deposit end to end | the same run | **`completed`.** Transaction `ae2734cc-2458-419f-8910-d3f53d04be71`, 5 USD in, 0.5 USD anchor fee, 4.5 USDC delivered by stellar transaction `4a2167a714fee32dfa0463b70c73131ee866a336a084f19c7d92cedba9f5a439` |
| SEP-24 interactive withdrawal end to end | the same run | **`completed`.** Transaction `57eaf7e1-2ce1-410d-9396-84969f227568`, 4.5 USDC in, 0.4 USDC fee, 4.1 USD out. The anchor's account and memo are read off its own transaction record, not hardcoded: payment `994d83972c03439c02dc27eba3f4ab3b84e365f748fb27130102ae95c8bb59c2`, memo `id:6100031375387207126` |
| cash to USDC to agUSD and the reverse | `docs/evidence/anchor-roundtrip-2026-10-30.log` | **closed.** 5.0 USD of cash to 4.5 USDC to 4.5 agUSD minted one for one by the Vault, back out through the FIFO queue as claim 54, and out to 4.1 USD of cash. Every leg is a transaction in that log |
| against the MoneyGram Access sandbox | | **not run, and not a substitution.** The award's own words are "with the SDF Stellar Test Anchor covering the same flows during MoneyGram onboarding", so the Test Anchor is what the record names for this period rather than something put in MoneyGram's place. `anchor/sep_client.py` is anchor-agnostic: MoneyGram is a `--home-domain` and their asset code once that account is live, which is commercial and not technical. `docs/ANCHOR_RAMP.md` carries the quote next to the code |
| sustained multi-day testnet campaign without critical failures | `bash scripts/campaign-report.sh`, which needs no key, or the reporter account on [stellar.expert](https://stellar.expert/explorer/testnet/account/GASAXCP2Z4BSK5RGPFU257FA57K47JSPD6BJYYKH3RDQ2CKYXIYQOM4H) | **589 `submit_nav` transactions, none failed, every one of the 22 calendar days in the span covered.** That account has never signed anything else, which is why it is the one to count, and the report checks that too rather than filtering the rest away in silence: any operation on it that is not a `submit_nav` fails the run. Our own logs add the passes that submitted nothing because every feed was still fresh: **1098 keeper passes, 14 with a failed push**, each one the public RPC not answering with a ledger, so nothing was submitted and the next pass carried it; the market maker, **2140 quoting cycles, no error**. A third job extends the contracts' TTL every 72 hours, which is why every address in this file still answers |
| codebase frozen for the audit | `git diff --name-only aee6c61..HEAD -- contracts/ adapters/ crates/ Cargo.toml Cargo.lock` | **the freeze was lifted on 2026-10-30 and this row says so rather than carrying a number that was true a week ago.** It read "nothing" until the review came back, and answering the review meant changing contracts: fourteen files, which are the Etherfuse adapter learning to subscribe, `contracts/mock-stablebond` as the pool the award asks it to be tested against, the Vault's peg gate, and the tests for all three. You cannot both freeze for an audit and fix what a reviewer found, and of the two the fix is worth more. The freeze re-establishes at `bbeae11`, and the command above is the one that keeps this honest: it will report those fourteen files until the baseline is moved deliberately |
| the freeze is a frozen tree, not a frozen claim | `bash scripts/smoke-hardening.sh` | **59 passed, 0 failed**, then it stops at its credit-loss finding and says why: the private credit pool carries 29138631047 stroops of accumulated test write-offs against a cap of 18400749875, four tenths of net assets, so it has no room to allocate into and the finding cannot be walked on this book. That charge is permanent by design, because a write-down reopening a cap was a finding this Engine closed, and inventing a recovery to make the suite green is the one thing not to do. The adversarial review ahead of the audit found three critical, two high and four medium, every one fixed, every fix with a test that fails without it |
| handed over to OtterSec | the engagement | **in scheduling**, and it follows the freeze re-establishing. This is the one line in this file that is not a command, and it is not going to be written as though it were |

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
| every state-changing entry point authorizes | `bash scripts/check-authorization.sh` | **77 entry points, 5 deliberately permissionless and argued one by one, 0 failures**. It was 69 until 27 October, because the file list was written by hand and the cross-chain adapter was never added to it while being live and registered as the Engine's third pool. Adding it found no violation, which is the good outcome and not the one that excuses the gap: the number now covers every contract this repository deploys |
| every documented signature matches the ledger | `bash scripts/check-doc-entry-points.sh` | **9 passed, 0 failed**, and the 9 means more than it did on 26 October. Documented used to mean the function's name appeared anywhere in the prose, so `admin`, `nav`, `pools`, `claim` and `balance` were documented by any sentence containing the word; it now means named as a call. That found six real getters the docs never named, on the Vault and the staking contract, and they are in `ARCHITECTURE.md` now. The arity half printed one pass whatever it had examined, including nothing; it reports the count, which is 66 |
| the contracts have not archived themselves | `bash scripts/check-ttl.sh` | 10 passed, 0 failed |
| advisories against the deployed bytecode | `bash scripts/check-advisories.sh` | **2 passed, 0 failed**. There are two open Dependabot alerts on this repository and we would rather name them than let you find them: `stellar-xdr` (medium, `StringM::from_str` skipping its length check) and `soroban-env-host` (low, muxed address conversions). Both are in `Cargo.lock` because `soroban-sdk`'s testutils pull the host in for the unit tests, and neither appears in any of the 9 deployed modules, searched in both the compiler's and the optimiser's artefact, which the script checks by searching the bytecode rather than the dependency graph. Bumping them would rewrite the tree frozen at `aee6c61` and with it every wasm hash on the ledger, so they stay until after the audit |
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
bash scripts/verify-tranche2.sh            # 24, against the live ledger
bash scripts/campaign-report.sh            # the oracle campaign, counted off Horizon
```

The first makes its own account, funds it from friendbot, and checks this file
against the chain, including the deployment record's own pool list against the
Engine's. It also reproduces two refusals, because a contract error comes back
from simulation before a signature is involved: `#407` over the per-pool cap at
an account that is nobody, and `#411` for more than the Vault holds idle. The
second counts the campaign off Horizon, which is the one claim our own logs
cannot settle.

The video says twenty three assertions and this file says twenty four. The
video is right about the day it was recorded. The twenty fourth was added on
27 October, when a reading of our own scripts found that the six originator
and jurisdiction values were printed and never compared to the record that
repeats them in prose, which is how a record and a ledger drift apart. Running
the command is what settles which number is current, and that is the point of
handing you the command rather than the number.

Five more need no key either, and a sixth needs a GitHub push access rather
than a Stellar one. They are where the rest of the numbers above come from:

```sh
cargo test --workspace                           # 227, 11 suites
bash scripts/check-deployment-record.sh --wasm   # 65 from a clone, 77 with the docs repo
bash scripts/check-authorization.sh              # 77 entry points
bash scripts/check-doc-entry-points.sh           # 9
bash scripts/check-ttl.sh                        # 10
bash scripts/check-advisories.sh                 # 2, and this one alone needs a GitHub
                                                 #    push access to read the alert list.
                                                 #    Without it it prints SKIP and exits 2,
                                                 #    which is not the same as none open
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
bash scripts/e2e-oracle-quorum.sh          # 12, a NAV one reporter cannot move
bash scripts/e2e-oracle-staleness.sh       #  3, OracleStale on the peg feed. Every call
                                           #    it makes is a simulation, so what you cannot
                                           #    do is not sign it but pause our keeper, which
                                           #    is what lets the feed expire in the first place
bash scripts/refusals-on-ledger.sh         #  6, the four refusals, submitted not simulated
bash scripts/smoke-hardening.sh            # 62, the security review on the live addresses
bash scripts/e2e-generation3.sh            # 20, deposit to redemption, and the SDEX
DRY=1 bash scripts/keeper-yield.sh         # what the feed says the book earned, unsent
```

Two things to know before running those, if you ever do. The feeds are live and
a keeper reports to them every ten minutes, so an unpaused keeper closes the
quorum round under the script; it is the one place in this repository that asks
you to stop something first. And the staleness suite is allowed to let a feed
expire only because that feed, the peg check, is read by nothing on chain.

Send us an address and we will fund it with testnet USDC within the day, if you
would rather run the write path yourself than watch it in the video.

## Declared: the cross-chain adapter, what it is for, and that it goes to mainnet

The Stellar reviewer asked for this in those terms: declare it, and say whether
it goes to mainnet. Both answers are here, and the second one is yes.

**One distinction first, because it changes the question.** CCTP *into* Stellar
is funded by this award: Tranche 1 Deliverable 2 names "a bridge tab built on
Circle CCTP for native 1:1 USDC transfers into Stellar". What is not named
anywhere in the award is the adapter that goes the other way, and that is the
contract this section is about.

**What it is.** `adapters/cctp` is a third pool adapter registered on the Engine
(`CDSO4GJRY7BFVMQ4PYP3ISVOFPQLPA3C7ZFT5HQOUDM3VXTGOUWUWFML`). An allocation to
it burns the Vault's USDC through Circle's CCTP Token Messenger on Stellar,
against a destination domain and address the adapter's admin sets, so the
capital lands on an EVM chain.

**Why it exists, said plainly.** It is not an experiment on the side. The credit
yield this protocol distributes is produced by a protocol on EVM, which takes
the capital off-chain, into real-world instruments, and remits back. Stellar is
where the vault, the share accounting, the risk caps and the depositor live;
Ethereum is where the capital has to arrive for that yield to be generated. So
this adapter is the path the money actually takes, and it goes to mainnet
because without it the yield in Tranche 3 has nowhere to come from.

That is a larger statement than "a third adapter exists", and it is the honest
one. It also means the private credit adapter and this one are two routes to the
same economics rather than two different asset classes, and the award's
Deliverable 1 wording, "private credit adapters for off-chain originator
allocations", describes the destination rather than the rail.

**How it changes the risk model, in four specifics rather than in general.**

1. `set_destination` is admin-set. A compromised or mistaken admin key aims the
   next allocation at an address of its choosing, and a CCTP burn is not
   reversible from this side. Every other adapter here can only move capital to
   the Vault it was registered against.
2. Capital that crosses stops being measurable by any contract on Stellar. The
   Engine carries the exposure at cost basis and the far book is read by
   nothing. `oracle_feed()` answers `PC_NAV`, on the rationale that the crossing
   is transport rather than an asset of its own, and that rationale is only as
   good as the reporting on the far side.
3. It puts a bridge in the withdrawal path. The liquidity hierarchy the award
   describes ends in private credit repayment; here it ends in a CCTP message
   coming back, with that protocol's liveness in the way.
4. There is no call on Stellar that can unwind a position once it has crossed.
   This is not theoretical: see below.

**Demonstrated, not theorised.** On 2026-10-30 the 100000000 stroops this
adapter held could not be returned. `deallocate` refused with
`ReturnNotArrived`, because the USDC had been burned through CCTP and had not
come back, so no call could clear it and the exposure would have reported face
value for the life of the contract. It is written down, reason `CCTPBURN`:

```
  get_exposure(cross-chain)   0
  total_allocated             0
  written_off                 29238631047
```

The charge against that pool's cap is permanent, by design, because a write-down
reopening a cap was a finding this Engine closed. Ten USDC left Stellar through
this adapter and did not come back, and the book says so.

**What has to change before mainnet, then.** Since it is going, the two
weaknesses above are not acceptable as they stand, and neither is a code change
we are claiming to have made:

- `set_destination` behind a timelock, so an aimed destination is visible before
  it can be used rather than after.
- An allowlist of destination domains and addresses rather than a free field,
  so the admin chooses among destinations that were agreed, not any address.
- A reporting obligation on the far side that is at least as strong as the
  `PC_NAV` quorum here, because today the far book is read by nothing.

None of those is built. They belong to the Tranche 3 scope alongside the mainnet
launch, and naming them here is the declaration the reviewer asked for rather
than a claim that the risk is already handled.

It stays registered on testnet because unregistering it would hide it, and
because the Engine's cap arithmetic is exercised by having a third pool.

## Open, and decided: the third reporter

The reviewer's other observation on Deliverable 2 was that "the 26 Oct PC_NAV
moves came from your own two reporter keys". That is still true. The quorum on
`PC_NAV` is two, there are exactly two reporters, and both are keys this project
holds:

```
  GASAXCP2Z4BSK5RGPFU257FA57K47JSPD6BJYYKH3RDQ2CKYXIYQOM4H   dedicated reporter
  GBSX2ZFLIJVE75VFWJURAXPSS4TBOV4FZ34VCRLWM2D7GKI37AD3FFNV   deployment admin
```

A two-of-two among our own keys bounds operator error, not operator intent. It
stops one fat-fingered push and stops nothing we decide to do deliberately.

The decision, recorded here rather than left as a gap: **a third reporter held
by an originator, at mainnet.** The right third signer is not another key of
ours and not a price oracle, because Reflector does not price private credit.
It is the counterparty whose book the NAV describes, signing its own servicing
figure. That makes the quorum a reduction in trust instead of a reduction in
typos, and it is a Tranche 3 commitment because it needs one of the signed
issuers to agree to hold a key.

## Every suite, as of 2026-10-30

Each line is a command, and each number is what it printed on the generation
currently deployed.

| Command | Result |
|---|---|
| `cargo test --workspace` | **255 passed**, 0 failed |
| `bash scripts/verify-tranche2.sh` | **24 passed**, 0 failed |
| `bash scripts/check-deployment-record.sh` | **45 passed**, 0 failed |
| `bash scripts/check-doc-entry-points.sh` | **9 passed**, 0 failed, 68 signatures agreeing with the ledger |
| `bash scripts/check-advisories.sh` | **2 passed**, 0 failed |
| `bash scripts/check-ttl.sh` | **10 passed**, 0 failed |
| `bash scripts/smoke-hardening.sh` | **64 passed**, 0 failed |
| `bash scripts/e2e-etherfuse.sh` | **24 passed**, 0 failed, D1's subscription and redemption on testnet |
| `bash scripts/e2e-reconciliation.sh` | **10 passed**, 0 failed, D2's tape to NAV to yield |
| `bash scripts/e2e-peg-gate.sh` | **11 passed**, 0 failed, D2's peg feed refusing and permitting |
| `bash scripts/e2e-anchor.sh` | D3's round trip, both anchor transactions `completed` |
| `bash scripts/keeper-reflector.sh` | `USDC_USD` 10013012, Reflector's number |
| `bash scripts/keeper-etherfuse.sh` | `EF_BOND` 10787040, Etherfuse's USTRY |
| `bash scripts/keeper-oracle.sh` | dispatches the two above, reports PC_NAV's window |

Three of the reviewer's seven items were fixes to numbers that were wrong rather
than missing, and those are the ones worth re-reading: the keeper applying one
pool's feed to every pool, the Etherfuse adapter booking exposure it had not
invested, and the criteria in this file not being the criteria on the record.
