# Running every suite in the repository, and what that found

Asked for a complete verification, so: every script that verifies something was
run, 74 scripts inventoried, the deployment and migration ones excluded with
their reasons, and the rest run. This is what came back, including the parts
that came back red.

## Where every suite ended up

Nothing is red. Three suites refuse to run and say why, which is not the same
thing and is called out as such.

| Command | Result |
|---|---|
| `cargo test --workspace` | **255 / 0**, twelve crates |
| `check-deployment-record.sh --wasm` | **77 / 0**, every deployed contract rebuilds byte for byte |
| `check-deployment-record.sh` | **45 / 0** |
| `check-authorization.sh` | **0 failures**, 80 state-changing entry points, 5 deliberately permissionless |
| `check-doc-entry-points.sh` | **9 / 0**, 68 signatures agreeing with the ledger |
| `check-advisories.sh` / `check-refusals.sh` / `check-ttl.sh` | **2 / 0**, **4 / 0**, **10 / 0** |
| `verify-tranche2.sh` | **24 / 0** |
| `smoke-agusd-core.sh` | **32 / 0** |
| `smoke-core.sh` | **11 / 0** |
| `smoke-mediums.sh` | **60 / 0** |
| `smoke-review2.sh` | **45 / 0** |
| `smoke-review3.sh` | **38 / 0** |
| `e2e-test.sh` | **24 / 0** |
| `e2e-generation3.sh` | **20 / 0** |
| `e2e-etherfuse.sh` | **24 / 0** |
| `e2e-reconciliation.sh` | **13 / 0** |
| `e2e-peg-gate.sh` | **11 / 0** |
| `e2e-oracle-quorum.sh` | **12 / 0** |
| `e2e-allocation-guards.sh` / `e2e-concentration-caps.sh` | **10 / 0** each |
| `e2e-cctp-wiring.sh` | **10 / 0** |
| `e2e-anchor.sh` | the round trip, both anchor transactions `completed` |
| `campaign-report.sh` | **PASS**, 589 submissions across 22 consecutive calendar days |

### The three that refuse, and why that is right

`smoke-journey.sh` and `smoke-sagusd.sh` exit 2 because they will not unwind
sagUSD that belongs to other holders: this account holds 313 of a 349 supply,
and the remainder is somebody else's position. Both print the manual steps. A
suite that declined to touch a stranger's money is working.

`smoke-hardening.sh` exits 2 at its credit-loss finding, and the reason is the
most interesting number on this deployment. The three concentration caps are
measured on **charged exposure**, which is live exposure plus everything ever
written off against that pool and not recovered, and that charge is permanent
on purpose, because a write-down reopening a cap was a finding this Engine
closed. The private credit pool now carries **29138631047** stroops of
accumulated test write-offs against a cap of **18400749875**, four tenths of
net assets, so it has zero live exposure and no room at all:

```
  private-credit   live 0   charged 29138631047   cap 18400749875   room none
  etherfuse        live 0   charged 0              cap 18400749875   room full
  cross-chain      live 0   charged 100000000
```

That is not a defect to clear. It can only come back by the book growing past
about 7285 USDC of net assets, or by recoveries that would have to be real.
Inventing them to make a suite green is the one thing not to do here, so the
suite says it cannot walk the finding on this book, and `smoke-review3` now
checks the headroom before allocating rather than asserting through a `#407`.

## What the sweep broke, and why that is the finding

Five suites bugs and one structural problem, all of them invisible to a suite
run on its own.

### 1. A suite that left a lock nobody held

`smoke-hardening.sh` set `trap restore_engine EXIT`, which silently replaced
lib-baseline's own EXIT trap, the one that releases the suite lock. bash keeps
one trap per signal. lib-baseline warns about exactly this in a comment, and
this file was the thing it was warning about. Every run of it left a stale lock,
and the eight smoke suites after it refused to start, naming a dead pid.
**Fixed:** both exits from `restore_engine` release the lock.

### 2. A helper that measured held rather than spendable

`lib-ensure-usdc.sh` asked the SAC for `balance`. For a classic asset that is
the trustline's balance, and a trustline's balance includes whatever the
account's own open SDEX offers have locked as selling liabilities. The sagUSD
market maker posts USDC-side offers from the operator account, so `balance` read
1013.85 USDC while 1013.59 was committed and **0.26 was spendable**. Every suite
that asked for working capital was told it had plenty, then every transfer
failed with `BalanceError`, 10, reported as "got 0" and looking exactly like a
protocol failure. **Fixed:** it reads Horizon, subtracts selling liabilities,
and when short says how much is locked and where to look instead of pointing at
a faucet. `keeper-sagusd-book.sh` now keeps a reserve spendable and trims its
bid to fit.

### 3. Two assertions asking agUSD for entry points a SAC does not have

agUSD is a Stellar Asset Contract. Its entry points are `admin`, `set_admin`,
`authorized`, `set_authorized`, `clawback`, `trust`, `mint`, `burn` and the token
interface. There is no `minter` and no `total_supply`.

`smoke-agusd-core.sh` asked for both, got nothing, and reported that the Vault
was not the minter and that supply had not moved. Neither was true: `admin()` on
agUSD is the Vault, and the supply is on Horizon. **Fixed:** the mint authority
is asked by the name the contract answers to, and `agusd_supply()` sums all six
Horizon buckets, which today is 68425577618 stroops.

The same suite compared `idle_reserves` against the whole supply, which called
the Vault insolvent the moment the Engine deployed a dollar. **Fixed:** it counts
`deployed_capital` too, and the Vault is solvent on the real numbers, 68452577617
held against 68425577618 owed.

### 4. An assertion on a transaction nobody checked had landed

The reserve floor guard raised the floor to 9500 bps and asserted that an
allocation inside it was refused. testnet dropped that submission with a
timeout, so the floor never moved, the allocation was correctly accepted, and
the suite reported the Engine accepting something it should have refused.
**Fixed:** it reads the floor back and skips loudly when the raise did not take.
A step that did not happen is a skip, not a failure.

### 5. The structural one: the smoke chain is not independent

This is the finding worth keeping. Run one at a time around a deployment, the
smoke suites pass. Run back to back on one account, they fail in ways that have
nothing to do with the protocol:

- they share one operator key, so they compete for its sequence number and its
  spendable USDC, and each leaves less behind than it found
- they assume a book shape. `normalise_book` restores part of it and not all
- their write-downs are charged against the pools' caps for good, by design,
  because a write-down reopening a cap was a finding this Engine fixed. After
  the chain, `private-credit` carries **28950231047** stroops of recognised loss
  against a cap of about 17378138628, so `e2e-allocation-guards` and
  `e2e-concentration-caps` allocate into a pool with no headroom and get `#407`.
  Both pass on a normalised book and fail on that one. The Engine is right and
  the suites are reading a book the chain left behind.

So the honest statement about this repository's suites is: **they verify a
deployment, not each other.** Chaining them is a thing the operator can do and
the results of the chain are not evidence of anything. That is now written down
rather than discovered again.

## Not run, with reasons

| Excluded | Why |
|---|---|
| `deploy-*`, `rewire-*`, `redeploy-*` | one-off migrations, already applied |
| `keeper-*-run`, `distribute-yield-loop` | loops, not suites |
| `lib-*` | sourced helpers, no main |
| `e2e-cctp-transfer`, `e2e-stellar-to-evm`, `e2e-evm-to-stellar` | each burns the Vault's USDC through CCTP and cannot be undone from Stellar. That adapter is declared out of scope and already holds a position that `deallocate` refuses with `ReturnNotArrived`. Running them adds to it. |
| `e2e-oracle-staleness` | correct by design and it says so: it waits 61 minutes for the USDC_USD window to close, because the honest version of that test is to wait |

## The one that looked open, and was me reading the wrong file

This section replaces what stood here first, which said that six of the seven
deployed contracts did not reproduce from this tree. They all do. The
correction is kept visible rather than quietly swapped, because the way I got
it wrong is the useful part.

There are two artefacts per contract. The compiler writes
`target/wasm32v1-none/release/deps/<name>.wasm`, and the CLI post-processes
that into `target/wasm32v1-none/release/<name>.wasm`, stamped with `cliver`.
The CLI did not always do the second step, so everything deployed before it is
the raw artefact and everything deployed since is the optimised one:

```
engine, private-credit, staking, oracleAdapter, cctpAdapter   deps/     raw
etherfuse, deployed 2026-10-30 with CLI 28.1.0                release/  optimised
vault                                                         neither
```

I compared against the optimised path only, found five contracts that did not
match, and went through four wrong explanations before stopping: a dirty
incremental build (no, `cargo clean` reproduces byte-identically), a toolchain
drift (no, 1.98.1 and SDK 23.5.3#d3e1ab24 on both sides), a host interface
change (no, `contractenvmetav0` is byte-identical), and the old
`wasm32-unknown-unknown` target (no, that does not reproduce either). Then I
wrote five `pendingRedeployment` declarations asserting something untrue.

`check-deployment-record.sh` had already found this and says so in a comment
that ends: *"Checking only one of the two is how seven live contracts came to
look as though they no longer rebuilt, for weeks, with no source change behind
it."* Running `--wasm`, the mode the claim is actually attached to, reads **77
passed, 0 failed**, which is the number the Tranche 1 evidence has always
claimed. The claim was right; the check I invented was not.

What is true is one line. **Every deployed contract rebuilds from this tree
byte for byte except the Vault, where the tree is ahead by four entry points**,
`set_peg_feed`, `peg_feed`, `peg_tolerance_bps` and `peg`. That is declared
under `treeAheadOfLedger` and verified as an interface delta both ways: the
tree's extra entry points must be exactly the declared list, and the ledger
must hold nothing the tree has dropped.

Two things came out of the detour that are worth keeping. `smoke-mediums` was
comparing against one artefact and now tries both and names which matched, so
it no longer disagrees with `check-deployment-record` about whether the ledger
matches the source. And a failed `contract fetch` used to leave the previous
contract's wasm in `/tmp`, so agUSD was compared against the Vault's bytecode
and reported as diverging; it is cleared first now, and a Stellar Asset
Contract is skipped with its reason, because the host supplies that code and
there is nothing of ours to compare.

## What the capital constraint still costs

The suites that remain red on a chained run are red for one reason, and it is
the operator's balance sheet rather than the protocol.

`GBSX2ZFL` is both the sagUSD market maker and the account every suite spends
from. Its USDC-side offers commit most of the balance as selling liabilities,
and a trustline's balance counts what its own offers have locked, so the
account reads funded and can transfer almost nothing. With about 167 USDC
spendable, `smoke-hardening` deposits all of it and the three assertions that
follow the deposit fail when an offer re-locks part of it mid-run, and
`e2e-generation3` stops at its 20 USDC precondition.

Freeing it by hand works and is what made the rest of this sweep possible, but
the real fix is structural and is not a code change: **the market maker and the
suite runner should not be the same key.** `lib-ensure-usdc` now measures
spendable rather than held and says how much is locked and where, which turns
this from a cascade of false protocol failures into one legible message, and
`keeper-sagusd-book` keeps a reserve. Neither makes one key enough for both
jobs.
