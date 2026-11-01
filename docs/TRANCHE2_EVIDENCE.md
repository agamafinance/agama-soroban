# Tranche 2, Evidence

Every claim below is a command anyone can run or a transaction anyone can open.

Network: Stellar testnet. First generated 2026-10-26, rewritten 2026-10-30
against the award record, every figure re-measured 2026-10-31.

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

### Deliverable 3, MoneyGram fiat ramp and hardening

> **How to measure completion:** SEP-10 authentication and SEP-24 interactive
> deposit and withdrawal flows completing end-to-end on Stellar Testnet against
> the MoneyGram Access sandbox, cash to USDC to agUSD and the reverse, with the
> SDF Stellar Test Anchor covering the same flows during MoneyGram onboarding;
> sustained multi-day testnet campaign without critical failures; codebase
> frozen and handed over for audit.

That last clause is quoted whole, like the rest of it, and it is the one clause
on this page that asks for a decision rather than a measurement. The freeze was
lifted on 30 October to answer this review, because you cannot both hold a tree
still for an outside reader and fix what a reader found, and of the two the fix
is worth more. It re-establishes on whichever commit the reviewer accepts.
`decisions.codeFreeze` in the deployment record carries the date, the reason, the
baseline commit and what has moved since, so the state of it is readable next to
the addresses it governs rather than asserted here.

## Status against those criteria

| Criterion | Status | Where |
|---|---|---|
| D1 engine live, both adapters registered | **met** | `pools()` on the Engine |
| D1 cap and reserve floor breaches rejected on chain | **met** | four failed transactions, `e2e-allocation-guards.sh`, `e2e-concentration-caps.sh` |
| D1 both adapters passing unit suites against mock pool contracts | **met 2026-10-30** | `contracts/mock-stablebond`, 12 cases; `adapters/etherfuse`, 26 cases; the adapter now subscribes and redeems rather than incrementing a counter |
| D1 exposure map and reserve ratio readable | **met** | `get_exposures()`, `get_reserve_ratio()` |
| D2 NAV flowing from all three feed types | **met** | all three types registered with the record's parameters and all of them fresh. Four feeds, because private credit has two instances: `USDC_USD`, `PC_NAV`, `PC_NAV2`, `EF_BOND`, each at a quorum of two |
| D2 the feeds sourced from Reflector and Etherfuse | **met 2026-10-30** | `keeper-reflector.sh` reads `lastprice(Other("USDC"))` off Reflector's SEP-40 oracle `CCYOZJCO...`; `keeper-etherfuse.sh` reads USTRY off `api.etherfuse.com` with a cross-source agreement check. Both refuse to submit when their own source has stalled, rather than pushing a stale number under a current timestamp |
| D2 OracleStale and nav_rejected, each with a test case | **met** | `cargo test -p oracle-adapter`, 37 cases, including `out_of_bounds_deviation_emits_nav_rejected_on_submit_nav` and `stale_read_errors_with_oracle_stale` |
| D2 yield distribution driven by oracle data | **met 2026-10-30** | `keeper-yield.sh` now prices each pool from the feed that pool names; the 26 October run applied the private credit move to all deployed capital |
| D2 reconciliation documented and executed end to end | **met 2026-10-30** | `docs/NAV_RECONCILIATION.md`, `scripts/e2e-reconciliation.sh`, run in `docs/evidence/reconciliation-2026-10-30.log` |
| D2 the peg feed validating the base asset | **built and demonstrated on chain; not on the live Vault** | nine unit cases plus `scripts/e2e-peg-gate.sh`, 11 assertions on testnet: `PegBroken` at 300 bps either side of par, through inside 150 bps. It runs on a Vault of its own because no contract here has an `upgrade` entry point, so carrying the gate to the live instance is the generation migration in `deploy-vault-generation.sh`, which retires the Vault, agUSD and staking |
| D3 SEP-10 end to end | **met 2026-10-30** | `anchor/sep_client.py`, challenge verified before signing, JWT from `testanchor.stellar.org`; `docs/ANCHOR_RAMP.md` |
| D3 SEP-24 interactive deposit and withdrawal end to end | **met 2026-10-30** | both flows reached `completed` on testnet: deposit `ae2734cc`, withdrawal `57eaf7e1`. `scripts/e2e-anchor.sh` |
| D3 cash to USDC to agUSD and the reverse | **met 2026-10-30** | 5 USD of cash to 4.5 USDC to 4.5 agUSD, back through the FIFO queue, out as 4.1 USD. Every leg is a transaction in `docs/evidence/anchor-roundtrip-2026-10-30.log` |
| D3 sustained multi-day campaign | **met** | `campaign-report.sh`, **853 submissions, none failed, 23 consecutive calendar days** as of 2026-10-31, and the dedicated reporter key has signed nothing else |
| D3 the codebase frozen and handed over | **a decision, deliberately not met yet** | Lifted 2026-10-30 to answer this review and re-established on whichever commit the reviewer accepts. `decisions.codeFreeze` in `deployments/testnet.json`. `git diff --name-only bbeae11..HEAD -- contracts/ adapters/` is the command that says what moved since the baseline: **eight files today**, the Etherfuse adapter and its tests, the private credit adapter and its tests, the Engine's tests, and the Vault with its tests and its fuzzer. It is meant to report something until the baseline is moved deliberately |

Nothing in that table is softened. Two rows are not "met": the peg feed is
built, unit tested and demonstrated on chain but not on the live Vault, and the
last clause of Deliverable 3 is a decision we have deliberately not taken yet
and say why.

## Deliverable 1, Allocation Engine with on-chain risk caps

| Criterion | How to check it | Result |
|---|---|---|
| engine live on testnet with whitelisted pools | `pools()` on the Engine | **four pools**, each with its own originator and jurisdiction: ETHERFUS/MX, QIRO/LU, ABF/JE, QIRO2/IE. The fourth is the private credit wasm deployed a second time against a second counterparty, which is what a configurable feed bought |
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
| a NAV cannot be moved by one reporter | `bash scripts/e2e-oracle-quorum.sh` | **12 passed, 0 failed** on 27 October against a quorum of two: one reporter gets `Pending` and moves nothing, a repeat vote is `#518`, a second distinct reporter commits, now against a value the feed does not already hold. Until 27 October it submitted the stored value, which made "nothing committed, the feed is unchanged" hold whether or not the lone vote had committed: the assertion could not fail, so it was not evidence. It now moves the feed by one stroop and also asserts the stored round did not advance after the first vote. What it does not cover, stated here rather than left to be found: `set_quorum_threshold` is admin settable with no floor above one, so the admin key can lower a quorum of two back to one and then post alone. The quorum holds against a compromised reporter key and not against a compromised admin key. What changed on 31 October is that those are now different keys: the admin was one of the two reporters until then, so a single key both wrote the rule and voted under it, and `is_reporter` on the admin reads `false` today. A threshold that only ratchets upward is the remaining one line change, and it is a redeployment of the Oracle Adapter under a submitted milestone, so it ships with the Tranche 3 mainnet deployment |
| yield distribution driven by oracle data | `bash scripts/e2e-reconciliation.sh` | **13 passed, 0 failed** on a run that can push, **10** on one inside `PC_NAV`'s hour, which the suite says rather than failing. The chain of custody is five links: a servicing tape, a pure function of it, one vote per reporter to quorum, the feed's own guards, and a keeper that prices each pool from the feed that pool names. The run that distributed is in `docs/evidence/reconciliation-2026-10-30.log`: tape to `10374235`, `NavQuorumReached` with two votes, **1897996** stroops delivered, `exchange_rate` 17138171 to 17143622, `total_shares` unmoved. **The two runs this row used to cite are the defect and not the proof**, and the reviewer was right about both. On 26 October it paid 36357814 stroops on 1210 USDC of deployed capital by applying the private credit move to every pool, including capital in a Stablebond that `PC_NAV` says nothing about; 700 USDC was at that feed and 21033446 was owed. The earlier run the same day, 500000 stroops, reconciles only at 10 USDC and was labelled 100. The keeper groups exposure by feed now, reads every feed through the Adapter so one stale feed stops the whole run, and clamps a falling feed to zero because a loss is a `write_down` |
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

## Deliverable 3, MoneyGram fiat ramp and hardening

The title is the award's, shortened: the record calls this deliverable
"MoneyGram fiat ramp, hardening and audit readiness" and the criterion itself is
quoted whole in the section above. The first version of this section was called
"Hardening", dropped the fiat ramp, and listed a Soroswap
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
| against the MoneyGram Access sandbox | `docs/evidence/moneygram-sandbox-2026-10-30.log` | **not run, and not a substitution.** Two facts, both checkable. First, the award names the cover itself: "with the SDF Stellar Test Anchor covering the same flows during MoneyGram onboarding", and that onboarding began on 2026-10-30, partner account under Agama Labs Inc., non-custodial on Stellar. Second, and found by trying rather than assumed: MoneyGram has moved new partners off this path. Their Stellar hub reads "Partners already on the Stellar whitelist integrate via SEP-10 and SEP-24, not the widget SDK", their legacy guide opens "New partners: use the Stellar widget hub instead", and the partner portal has no "Whitelist in TestNet" section at all, only the widget track. So the SEP path the award names is one the vendor has closed to new entrants since the award was written. The client is nonetheless complete against their anchor: SEP-1, SEP-10 with client domain attestation returning a JWT that carries `client_domain: agama.finance`, SEP-24 with their limits enforced and transaction `4ddb0b16-b40a-41f7-8ce6-6698f7c0dead` opened. Their widget then fails on two of their own calls, `transactions/prepare` and `reference-data/countries`, both HTTP 500, for a partner they have not allowlisted |
| sustained multi-day testnet campaign without critical failures | `bash scripts/campaign-report.sh`, which needs no key, or the reporter account on [stellar.expert](https://stellar.expert/explorer/testnet/account/GASAXCP2Z4BSK5RGPFU257FA57K47JSPD6BJYYKH3RDQ2CKYXIYQOM4H) | **853 `submit_nav` transactions, none failed, every one of the 23 calendar days in the span covered**, read on 2026-10-31. That account has never signed anything else, which is why it is the one to count, and the report checks that too rather than filtering the rest away in silence: any operation on it that is not a `submit_nav` fails the run. Our own logs add the passes that submitted nothing because every feed was still fresh: **1098 keeper passes, 14 with a failed push**, each one the public RPC not answering with a ledger, so nothing was submitted and the next pass carried it; the market maker, **2371 quoting cycles, no error**. A third job extends the contracts' TTL every 72 hours, which is why every address in this file still answers |
| the codebase frozen and handed over | `git diff --name-only bbeae11..HEAD -- contracts/ adapters/` | **a decision, and deliberately not met yet.** The freeze was lifted on 30 October to answer this review, because you cannot both hold a tree still for an outside reader and fix what a reader found, and of the two the fix is worth more. It re-establishes on whichever commit the reviewer accepts. The command above reports **eight files** today, the Etherfuse adapter and the private credit adapter with their tests, the Engine's tests, and the Vault with its tests and its fuzzer, and it is meant to keep reporting them until the baseline is moved deliberately. Recorded under `decisions.codeFreeze` |

## A second review, on 27 October, and what it found

The review above is the earlier one. This is a
second pass over the same code, run the day this submission was finalised,
reported here because a finding a reviewer discovers for themselves costs more
than one we hand them.

**Nothing in this table reads "open" any more, and that sentence needs its
qualification stated before the table rather than after it.** Eleven of these
stood open until 2026-11-01, including two criticals. **Eleven are now fixed in
source with a test each**, one was already mitigated on chain and cannot be fixed
in source because the contract is immutable, and one is marked verified bounded
with the reasoning for why nothing was changed. **Three of the eleven are on the
ledger** and eight are not. The three went live on 2026-11-01 with a new Oracle
Adapter, `CBJ3OZ4W...`, replacing `CAUOHPPN...`: the round deadlock, the quorum
floor and the staleness check. The remaining eight are declared under
`treeAheadOfLedger` with what each changes and why it is not deployed. The reason
is the same in every case and it is not a scheduling excuse: no contract in this
repository has an `upgrade` entry point, by design, so a fix means a
redeployment, which is exactly what the Oracle Adapter just had and why its three
are live; `agusd-core::set_minter` freezes after the first mint, so staking
and the Vault move together as a generation migration that retires the
deployment Tranche 2 is proven on; and `unregister_pool` refuses to remove a pool
carrying a write-off charge, which the cross chain pool carries, so replacing
that adapter moves the Engine too. They ship with the mainnet deployment. What
is true today is that the source is right, the tests say so, and the ledger is
behind it by exactly what the record declares.

| Finding | Severity | Status |
|---|---|---|
| Generation 1 agUSD (`contracts/agusd`, superseded) has an `initialize` with no `require_auth` and no re-entry guard, so anyone can claim its admin role and sweep its reserve | critical, on a retired contract | **reserve swept to the treasury on 27 October**, `reserve()` reads 0, nothing in service points at it. The contract is immutable so the source fix cannot reach it; `SECURITY.md` now names it as the exception to the constructor rule |
| `staking::stake` has no minimum first stake and no virtual offset, so a one stroop stake held through a distribution raises the share price permanently: later stakers below the new price are refused, above it they lose the truncation to the incumbent | critical on a fresh deployment | **fixed in source 2026-11-01, not deployed**. `stake` refuses a first stake under `MIN_FIRST_STAKE`, one agUSD, before it takes the money, and the guard is on the supply rather than on whether the contract has ever been used, so an empty supply is a fresh opening price. A minimum and not a virtual offset, because `exchange_rate` is `nav * ONE / supply` and the Vault, `get_asset_amounts_per_shares` and three on-chain suites compare against exactly that ratio. Three new cases, `the_first_stake_cannot_be_one_stroop`, `the_minimum_applies_again_if_everybody_leaves` and the rewritten `yield_into_an_empty_pool_is_refused_rather_than_held_for_whoever_arrives`. Declared under `treeAheadOfLedger`: staking cannot be replaced alone, `agusd-core::set_minter` freezes after the first mint |
| A round is keyed on `(feed, timestamp)` and a reporter cannot change its vote, while the tally is keyed on the value. Two reporters who disagree on one timestamp split the tally one and one and neither can revote: that round is dead, and a reporter that disagrees on every round stops the feed for good | critical, needs a reporter key | **fixed and deployed 2026-11-01**, live on `CBJ3OZ4W...`. Raised by an outside reader of the repository on 27 October. `RoundVoters` stores the value each reporter voted for instead of a flag, so a reporter may move its vote and not add one: the value it leaves is decremented in the call that increments the one it joins, and the sum of a round's tallies never counts a reporter twice. `two_reporters_who_disagree_can_still_resolve_the_round` is the deadlock itself, `a_reporter_gets_one_vote_per_round_and_may_move_it` is the rule, and the fuzz invariant that pinned the old behaviour is rewritten as `a_reporter_cannot_carry_a_round_alone_however_often_it_changes_its_mind`, which casts five submissions from one key and asserts the round holds one vote |
| `staking::distribute_yield` does not check that the share supply is non zero, so a distribution into an empty pool is taken whole by the next staker | high | **fixed in source 2026-11-01, not deployed**. Refused with `NoSupply`, before the transfer, so a refused distribution has not moved the admin's money. The test that pinned the old behaviour asserted where the thousand agUSD went; it now asserts the refusal and then that the same distribution lands once a share exists |
| Nothing stops staking immediately before a distribution and requesting immediately after: the cooldown delays the cash, not the pricing | high | **fixed in source 2026-11-01, not deployed**. An exit inside the cooldown is priced at no better than the rate it entered at, and the difference stays in `nav`, so it stays with the holders who were there rather than being burned or skimmed. `EarlyExitPricedAtEntry` carries both numbers. Measured against the deployment's own cooldown and not a new constant: if the protocol's answer to how long is too short to be paid is the cooldown, it is the same number here. Three cases: the sniping flow itself, where the sniper gets back exactly what went in and the whole distribution reaches the holder who stayed; the cap being one sided, so a fall inside the window is still taken at the current rate, because protecting it would be the same unfairness reversed; and a position with no recorded entry being read as staked long ago, so the rule cannot reach back into one that predates it. A top-up re-arms the window for the whole position, which is the conservative direction and is written down rather than discovered |
| `vault::set_agusd` gates on this vault having taken no deposit, which stopped being the same statement as the token having no supply when agUSD became a classic asset | high | **fixed in source 2026-11-01, not deployed**. It now also refuses to point away from a token that still has supply. One that publishes a supply is judged on it, which covers `agusd-core` and the case in `retiredAgusdResidue`, 38000000 stroops outstanding on a contract whose Vault had taken no deposit. A Stellar Asset Contract publishes none that a contract can read, so for one of those the question becomes whether this Vault is its mint authority: if it is, this Vault is what stands behind that token and will not abandon it unable to show nobody is holding it. Handing the mint authority away first is the deliberate route through, and it takes a transaction on the token rather than an assumption in here. Two cases, one per branch. Last of the four checks deliberately, so a call that is also wrong about the incoming token still reports that first |
| The oracle's staleness window is measured against the timestamp the reporter attests to, and the keeper reposts the value already on the feed, so a feed expires when its reporters stop rather than when the number ages | high, as a control | **closed and deployed 2026-11-01, in both halves**. The on-chain half: `process` refuses a report whose own timestamp is already outside the feed's staleness window, `ReportAlreadyStale` 520, so a reading cannot be stored already expired. The guard was one sided before, refusing a timestamp in the future and accepting one from arbitrarily far in the past. The other half cannot live in the contract, and that is stated rather than worked around: the contract cannot tell a value the reporter re-read from one it reposted unchanged, because an unchanged number is legitimate and common, a peg sitting at par or a deterministic bond price that did not move. So it is the keeper's, and `keeper-reflector.sh` and `keeper-etherfuse.sh` both refuse to submit when their own upstream has stalled. `a_reading_already_outside_its_window_is_refused_on_arrival`. The on-chain half is declared under `treeAheadOfLedger` |
| The quorum threshold is admin settable with no floor above one, and the admin was also one of the two reporters | high, as a control | **closed and deployed 2026-11-01**, both halves on the ledger. The admin is out of the reporter set on the live instance, verifiable with `is_reporter` on it, which reads `false`, and the deployment scripts seed reporters from `oracleReporters.addresses` and refuse the admin outright, so a redeployment cannot undo it. The floor is fixed in source rather than by a ratchet: raising a threshold is immediate, lowering one is announced, waits `QUORUM_REDUCTION_DELAY_SECS` of 72 hours and is applied by a second call with the same value. A pure upward ratchet was what the finding suggested and it is worse, because a threshold that can only rise turns one lost reporter key into a feed that can never be priced again. Three cases: the delay, a raise cancelling an announced reduction, and a different reduction restarting its own wait rather than inheriting one. Declared under `treeAheadOfLedger` |
| `cctp::set_destination` lets the admin point the burn at any EVM address while exposure is zero, and `write_down` zeroes exposure with no cash moving | high, admin only | **fixed in source 2026-11-01, not deployed**. A repoint is announced by one call and applied by a second with the same domain and recipient after `DESTINATION_DELAY_SECS` of 72 hours, readable through `pending_destination` and announced in `DestinationAnnounced`. A delay rather than the second role the old comment implied, because a second role on a one-operator deployment is two keys in the same hand and reads as a control without being one; 72 hours in which a depositor can see the address their capital is about to be sent to is not. The exposure lock stays as well, so there are two guards. `writing_the_position_off_opens_the_lock_and_still_does_not_open_the_pointer` walks the exact sequence the finding describes. The allowlist is the other half and is listed under `decisions.crossChainToMainnet` |
| `settle_withdrawal` takes no signature and strips the head claim of its queue position irreversibly, and a third party can choose the moment | medium | **verified bounded 2026-11-01, no change made, and here is why**. What a stranger can do is step the queue past a claim whose payment the token refused, and they cannot cause that refusal: it depends on the owner's own trustline. What the owner loses is the FIFO position; what they keep is the money and the liability, and a deferred claim is collectable by its owner at any time **without** being at the head, which is a weaker constraint than the one it replaced. `a_deferred_claim_is_still_owed_and_collectable_out_of_order` and `only_the_owner_can_collect_a_deferred_claim` pin both halves. The alternative, not advancing the head on a failed delivery, is the finding this deferral was introduced to fix: one undeliverable claim blocking everybody behind it for good. Recording who triggered it was considered and rejected: a top-level Soroban call has no caller address, so the only way to put one in the event is an unauthenticated parameter, and a self-reported identity in an event stream is worse than none |
| The withdrawal queue has no partial fill, so a claim larger than idle reserves blocks every claim behind it | medium | **fixed in source 2026-11-01, not deployed**. `deliver` pays what the Vault holds, reduces the claim by exactly that and leaves it at the head with the rest owed, so the order of the queue is untouched and the Vault has simply paid down as far as it can. All-or-nothing on a queue is a deadlock with a good explanation: a 500 USDC claim at the head with 100 USDC in the Vault paid nobody, released nothing, and left a 10 USDC claim behind it waiting on capital returning from a pool that owed the 500. `InsufficientLiquidity` is now the answer only when there is nothing at all to pay with. The anti-dust floor is deliberately not applied to a remainder: it gates `request_withdrawal`, where its job is to stop a queue being stuffed with crumbs, and a residue the Vault itself left is the rest of what somebody is owed. Three cases, and the accounting fuzzer is clean at 1500 cases through partial payments, which is the assertion that matters: both counters move by what was paid, so a partial fill is neutral in `floor_base` |
| `staking` never extends its instance TTL on any user path, unlike the Vault, which does it on all eighteen | medium | **fixed in source 2026-11-01, not deployed**. `stake`, `request_unstake`, `claim` and `distribute_yield` all bump it. `every_path_that_moves_value_extends_the_instance_ttl` burns two days of ledgers between calls, because `extend_ttl` is a no-op above the lifetime threshold and a shorter burn proves nothing |
| Anyone can block `staking::set_agusd` for good by sending one stroop of the current agUSD to the contract, because the guard reads a raw balance | medium | **fixed in source 2026-11-01, not deployed**. With no stake and no distribution nothing is owed, so a balance here has no claimant: it is swept to the admin, who is authorizing the repoint, with a `StrayBalanceSwept` event, and `StrayBalanceStuck` if it cannot be moved. `a_stranger_cannot_wedge_the_repoint_with_one_stroop` |
| `smoke-hardening.sh` counts four skipped branches as passes, so its 64 is compatible with the interval guard never having been exercised on that run | medium, in the evidence rather than the code | **closed**. Every conditional branch prints `SKIP` with its reason and increments nothing; the run that reads 62 passed names its 2 skips. The guard the finding was about is exercised by committing a round with both reporters and then submitting inside the interval |
| `e2e-oracle-quorum.sh` submits the value the feed already holds, so "one reporter moves nothing" cannot fail | medium, in the evidence | **closed**. It submits `BEFORE + 1` and asserts the stored round did not advance after the first vote, so the assertion can now fail |
| `check-authorization.sh` does not scan `adapters/cctp`, which is live and registered | medium, in the evidence | **closed**. `adapters/cctp/src/lib.rs` is in the scanned set and the count is 81 state-changing entry points, 5 deliberately permissionless, 0 failures |

## What runs automatically, and what cannot

`.github/workflows/checks.yml` runs the unit suites and
`check-source-invariants.sh` on every push, on the compiler
`rust-toolchain.toml` pins, which is the one the deployed bytecode was built
with. There was no CI at all until 2026-11-01, so a reviewer looking for a green
tick found nothing to look at.

What cannot run there is most of the verification in this file, and the reason is
worth stating rather than leaving as an omission. These suites read the live
testnet deployment, and the ones that matter most sign as the protocol's admin or
as an oracle reporter: a job that cannot allocate, write down a position or push
a NAV cannot assert anything about the guards that refuse those calls. Putting
the keys in CI to get a green tick would be trading the thing the keys protect
for the appearance of rigour. So those are run by hand, serially, and every
number in this file has the command next to it.

## Two things a reviewer will run that come back noisy, and why they stay that way

`cargo fmt --all -- --check` reports **138 diffs across 22 files**, and the tree
is deliberately left that way. rustfmt touches whitespace and import order,
Soroban embeds doc comments in `contractspecv0`, and the `.wasm` of every
contract is a hash this submission has published and
`check-deployment-record.sh --wasm` compares against the ledger. Running it would
move all eight of those hashes, and the ones currently reading "byte for byte
what this tree builds" would become declared divergences. That is trading a real
piece of evidence for whitespace. It goes with the mainnet deployment, where
every contract is built fresh and there is no hash to protect. Note the direction
of the trade rather than the state of it: the tree is not rustfmt clean and
nothing here pretends otherwise.

`cargo clippy --workspace --all-targets` reports **no errors** and 65 distinct
warnings, which clippy totals as 96 across eighteen crate and target
combinations because a warning in a library is counted again in its test build.
The number is given three ways because a reviewer counting it a fourth way
should not think anything is being hidden: zero errors is the part that matters.
Five of them are the ones worth knowing about, all in `crates/token`, all
`Events::publish` deprecated in favour of `#[contractevent]`. Taking that
suggestion would be a compatibility break and the crate header now says so at
length: SEP-41 fixes the topic shape of a token's events, every wallet and
indexer reads that exact shape, and `#[contractevent]` derives one of its own. A
token whose `transfer` event has a shape of our choosing is a token whose
transfers are invisible to everything built against the standard. The protocol's
own events, which nothing outside reads by a fixed shape, all use
`#[contractevent]`.

Two of them were real and are gone: an unused `ready_at` in the quorum
reduction path, and an unused depositor in a peg test, which was the test taking
a funded account from a helper when all it needed was the peg being configured.

One word about who ran these. The adversarial reviews this file and the
README refer to are ours, run internally, not a third party engagement, and
no outside party has reviewed this repository. Which is also why Deliverable 3's
last clause is quoted and then answered rather than claimed: the audit it names
is not ours to schedule or to name a firm for, and what we control is the freeze
and we say where that stands. Counted, because a claim about a word should be. In
this file the word is the criterion quoted above, the record's own name for that
deliverable, and this paragraph. In the code it is **six comments across five
files**, "auditable" three times, "auditor" twice and "audit" once, every one of
them meaning checkable by a reader and nothing more:

```
contracts/oracle-adapter/src/lib.rs      auditable, twice
adapters/etherfuse/src/lib.rs            auditable
contracts/agusd-core/src/lib.rs          auditor
contracts/allocation-engine/src/test.rs  auditor
contracts/vault/src/lib.rs               audit
```

The three in `oracle-adapter` and `etherfuse` are `///` doc comments, which
`contractspecv0` embeds, so editing them would move a deployed bytecode hash for
a word. Nowhere in this repository does it refer to an engagement.
A reader who takes "adversarial review" for an outside report would be reading
more into it than it says, so here it is said plainly.

Two things this pass fixed in place rather than listing: `campaign-report.sh`
now ends in a verdict and exits non zero when a day is missing or a submission
failed, and the three sentences elsewhere in this file that claimed more than
the code did are corrected above.

## What backs every number above

| Command | Result |
|---|---|
| `cargo test --workspace` | **279 passed**, 0 failed, 12 suites. 263 until 2026-11-01; the sixteen new cases are the nine source fixes above, one test per finding at least |
| `bash scripts/verify-tranche2.sh` | **27 passed**, 0 failed, run by an account it makes itself |
| `bash scripts/check-deployment-record.sh --wasm` | **91 passed**, 0 failed, deployed bytecode compared against the tree, and every contract's **live admin** compared against the key the record names. That last one was added 2026-11-01 after a suite left the Engine administered by a local throwaway identity for an hour and nothing was asking the question: the record named an admin and nothing compared it to the ledger, so the deployment could have been administered by a key the record has never heard of and every other check here would still have passed. agUSD is expected to answer with the Vault, which is its mint authority and the design rather than a drift |
| `bash scripts/check-doc-entry-points.sh` | **10 passed**, 0 failed. Across nine contracts, all **187** live entry points that are this repository's own are named in `docs/ARCHITECTURE.md`, the SEP-41 token interface the host supplies being described once as a standard rather than re-listed per token, and all **69** signatures that document declares agree with the ledger on arity |
| `bash scripts/check-authorization.sh` | **0 failures** over **81** state-changing entry points, 5 of them deliberately permissionless and each with its reason printed |
| `bash scripts/check-refusals.sh` | **4 passed**, 0 failed, four permanent refusals read back off the ledger |
| `bash scripts/check-advisories.sh` | **2 passed**, 0 failed |
| `bash scripts/check-doc-figures.sh` | **50 figures checked across 6 documents and 23 scripts**, 0 failed, and no network either. The claim this file makes is that every number has a command beside it, which is worth nothing while the number is not what the command prints. On 2026-11-01 **eleven had drifted**, three of them presented as current, and the scratch check meant to catch them stopped at the first mention of each script and reported nothing. The envelope now lives in one table in that script, so a deliberate change to a suite's assertion count is one number and the check says which documents disagree. The ranges are envelopes rather than values because five suites legitimately print different totals depending on whether a feed's minimum interval let them push |
| `bash scripts/check-source-invariants.sh` | **14 passed**, 0 failed, and it needs no network, no keys and no build. Three of the controls here are not entry points and not state, they are shapes the source has to keep, and the only thing holding them was a comment: the oracle admin sat in the reporter set for weeks under a comment explaining why it should not. It checks that no current deployment script passes `$ADMIN` to `add_reporter` and that the ones seeding a reporter set read it from the record or carry it from the contract they replace; that `oracleReporters.admin` is not one of the addresses; that every keeper stands aside for a suite holding its account; that nothing claims the loss counters never fall; and that no Stellar secret seed is in the tree or in the last five hundred commits of history, because a key removed in a later commit is still a key anybody can `git log -p` for, and the admin key here can allocate, write down a position and repoint counterparties. **The loss-counter check found three more places on its first run**, after I had corrected two and believed I was done |
| `bash scripts/check-ttl.sh` | **11 passed**, 0 failed |
| `bash scripts/e2e-etherfuse.sh` | **25 to 27 passed**, 0 failed, D1's subscription and redemption on testnet. `EF_BOND` takes one point an hour: inside that hour the accrual step asserts that the feed refuses a second point and skips the three assertions about the move, outside it the three run. 25 or 27, nothing fails either way |
| `bash scripts/e2e-allocation-guards.sh` | **10 passed**, 0 failed, D1's caps and reserve floor |
| `bash scripts/e2e-concentration-caps.sh` | **10 passed**, 0 failed, D1's originator and jurisdiction caps |
| `bash scripts/e2e-reconciliation.sh` | **11 to 13 passed**, 0 failed, D2's tape to NAV to yield. `PC_NAV` takes one point an hour, so a run inside that hour cannot push and the five assertions about the vote mechanics are replaced by two weaker ones on the stored value, with the reason printed. 13 on a run that can push, 10 on one that cannot, and nothing fails either way |
| `bash scripts/e2e-two-originators.sh` | **13 passed**, 0 failed, one wasm at two feeds with two caps |
| `bash scripts/e2e-oracle-quorum.sh` | **12 passed**, 0 failed, one reporter moves nothing |
| `bash scripts/e2e-round-deadlock.sh` | the critical an outside reader of this repository raised on 2026-10-27, walked on chain against the contract that now has the fix. Two reporters disagree at one timestamp, the tally splits one and one, nothing commits, and then one of them gives way and the round resolves **at the same timestamp** rather than waiting an hour for a new one. On the retired instance that round was dead and a reporter that disagreed on every round stopped the feed for good: a feed any single reporter can switch off does not have a quorum of two, it has a veto. Run on `USDC_USD`, the same choice `e2e-oracle-quorum` makes, because the peg gate is not on the live Vault and nothing on chain prices anything from that feed |
| `bash scripts/e2e-peg-gate.sh` | **11 passed**, 0 failed, D2's peg feed refusing and permitting |
| `bash scripts/e2e-cctp-wiring.sh` | **10 passed**, 0 failed |
| `bash scripts/e2e-generation3.sh` | **20 passed**, 0 failed |
| `bash scripts/e2e-test.sh` | **23 to 24 passed**, 0 failed, both ends observed on 2026-10-31. The variance is one of the six generation 1 credit vaults, `flagship`, whose yield distribution does not always land; the suite reports that as a `SKIP` with the error rather than counting it, so the total moves by one and nothing fails. Its deposit and its exit are asserted on every run, and on the run that read 24 the distribution landed and the share price rose 11564789 to 11637102 |
| `bash scripts/e2e-anchor.sh` | D3's round trip, both anchor transactions `completed` |
| `bash scripts/smoke-core.sh` | **11 to 14 passed**, 0 failed, one assertion per feed that can actually take a value. `USDC_USD` takes one point per 300s and the two NAV feeds one per 3600s, so a run inside those windows skips the read-back with its reason instead of comparing against the value the guard correctly refused to replace |
| `bash scripts/smoke-agusd-core.sh` | **32 passed**, 0 failed |
| `bash scripts/smoke-review2.sh` | **45 passed**, 0 failed |
| `bash scripts/smoke-review3.sh` | **38 passed**, 0 failed |
| `bash scripts/smoke-mediums.sh` | **64 passed**, 0 failed, 61 until 2026-11-01 when the admin rotation stopped being skipped by a comparison that could not be true, and it is the check that makes a `treeAheadOfLedger` declaration mean something: for every deployed contract it compares the ledger's interface against this tree's, both ways, and the declared list has to be exactly the difference. It covered five of the eight until 2026-11-01, so the declarations for `staking`, `oracleAdapter` and `cctpAdapter` were asserted by nobody. `check-deployment-record` only establishes that a declaration exists |
| `bash scripts/smoke-hardening.sh` | **62 to 64 passed**, 0 failed. The interval guard needs a round to commit first, and a round cannot commit inside `PC_NAV`'s hour, so the two assertions behind it run on a run that can push and are skipped with the reason on one that cannot. Its deposit is sized at the whole spendable balance, and the sagUSD market maker quotes on SDEX from the same account, so the amount is re-read immediately before the submit and the three assertions about the deposit are skipped, not failed, if it still does not land |
| `bash scripts/keeper-reflector.sh` | `USDC_USD` from Reflector, checked against its own clock |
| `bash scripts/keeper-etherfuse.sh` | `EF_BOND` from Etherfuse's USTRY, five sources agreeing around their median |
| `bash scripts/keeper-oracle.sh` | dispatches the two above, reports PC_NAV's window |
| `DRY=1 bash scripts/keeper-yield.sh` | the plan, per feed, and the guard that refuses a shape the grouping cannot fix: **`PC_NAV` is read by ABF and QIRO**, because the cross chain adapter is registered under ABF/JE with a compiled `PC_NAV`. Its exposure is zero, so the run reports the shape and continues; with capital behind that feed it exits rather than pricing one originator's capital off another's book, which is the defect of 26 October. The fix is the feed as a constructor parameter, a redeployment that `unregister_pool` blocks while the pool carries a write-off charge, so it ships with mainnet |

Every figure above was measured in one serial pass, the last of them on
2026-10-31. Serially and not in parallel, because the suites take an exclusive
lock on the deployment and two at once collide on the account's sequence number:
run together they reported smoke-review2 at 35 passed 10 failed and smoke-mediums
at 40 passed 6 failed, and the same two alone reported 45 and 61 with nothing
failing. The repository documents that trap and it still caught us, so it is
written here beside the numbers rather than left for the next reader to
rediscover.

Five of the totals above are ranges and not numbers, and the reason is a guard
rather than a flake. Every feed has a minimum interval in ledger time, 300
seconds on `USDC_USD` and an hour on the NAV feeds, and a suite that runs inside
one cannot push a value. Where that happens the suite says so and skips the
assertions that needed the push, rather than comparing against a value the guard
correctly refused to replace. So `e2e-test` reads 23 or 24, `e2e-reconciliation`
10 or 13, `e2e-etherfuse` 25 or 27, `smoke-core` 11 to 14 and `smoke-hardening`
62 or 64, with nothing failing at either end. A single number in this column
would have been a number that is right about half the time, which is the thing
this file is for.

**The trap is closed rather than documented, as of 2026-11-01.** The suites take
that lock and the keepers never did, which left the collision it was built for
open in the one direction nobody had closed: the keepers sign as the same
operator key and run under launchd every ten minutes. On 1 November
`smoke-mediums` asked the Engine to propose a new admin, a keeper reached for the
same sequence number in the same second, the proposal came back `TxBadSeq`, and
five assertions then compared the Engine against an admin it had never been
given. Nothing was wrong with the protocol and nothing was wrong with the keeper.
All five keepers now stand aside while a suite holds the account,
`lib-keeper-lock.sh`, and a lock older than half an hour is treated as abandoned
so that a suite killed rather than finished cannot stop the keepers for good,
which would be the worse failure of the two. And the admin rotation in
`smoke-mediums` checks that each of its two steps landed before asserting on the
state they were meant to produce, because a step that did not happen is a skip.

The same trap has a smaller version that is worth naming, because it produced a
red line during this pass. `verify-tranche2` read `nav`, `total_shares` and
`exchange_rate` as three separate calls and compared the ratio, and a yield
distribution landing between the second and the third reported a 0.47% mismatch
on an invariant that is exact. It re-reads once before calling that a failure
now: a ratio that disagrees twice is a broken invariant, one that disagrees once
is a transaction that landed mid read. The numbers agreed to the stroop a minute
later.

Three of the reviewer's seven items were fixes to numbers that were wrong rather
than missing, and those are the ones worth re-reading: the keeper applying one
pool's feed to every pool, the Etherfuse adapter booking exposure it had not
invested, and the criteria in this file not being the criteria on the record.
