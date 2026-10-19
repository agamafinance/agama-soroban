# Tranche 1, Evidence

Every claim below is a command anyone can run or a transaction anyone can open.

Generated 2026-10-19. Network: Stellar testnet.

Tranche 1 is three deliverables. Deliverable 1, the core Soroban contracts, is
proven in the three sections that follow. Deliverable 2, the dApp, and deliverable 3,
the indexer, each have their own section further down, under the same rule: a URL to
open or a command to run, not a description.

## Deliverable 1, the four completion criteria

| Criterion | How to check it | Result |
|---|---|---|
| contracts deployed on testnet, transactions publicly verifiable | `bash scripts/check-deployment-record.sh`, then open any address below | **45 passed, 0 failed**, and every address below answers on testnet. The stricter pass, `--wasm`, rebuilds and compares: see **Bytecode provenance** |
| the full deposit / mint / stake / unstake / redeem flow end to end | `bash scripts/e2e-generation3.sh` | **21 passed, 0 failed** |
| sagUSD exchange rate readable through DeFindex assets-per-share | asserted inside the same run, `get_asset_amounts_per_shares` against `exchange_rate` | **PASS**, both return the same figure |
| unit test suite passing on all core functions | `cargo test --workspace` | **227 passed, 0 failed**, 11 suites |

Four further checks the repository carries, all green:

| Check | Command | Result |
|---|---|---|
| contracts still live, not archived | `bash scripts/check-ttl.sh` | 10 passed, 31 days left |
| every state-changing entry point authorizes | `bash scripts/check-authorization.sh` | 69 entry points, 0 failures |
| advisories against the deployed bytecode | `bash scripts/check-advisories.sh` | 2 passed, 0 failed |
| every documented signature matches the ledger | `bash scripts/check-doc-entry-points.sh` | 9 passed, 0 failed |

## The live contracts

| Contract | Address | What it does |
|---|---|---|
| Vault Contract | [`CCVNCXPJ...PZTTJF`](https://stellar.expert/explorer/testnet/contract/CCVNCXPJXCA5GKJKNUNZRMJEEWYL74ASYYTL2DULPO5TZDGSHUPZTTJF) | USDC deposits, reserve floor, FIFO withdrawal queue |
| sagUSD Staking | [`CBOHG5YG...4CACV3`](https://stellar.expert/explorer/testnet/contract/CBOHG5YGAE7ORFDE5GIUN6MYYSXMHYWGLZTH3Y563HZCBBWFVQ4CACV3) | share price, yield, unstake cooldown |
| agUSD (SAC) | [`CADD22PH...AHH33R`](https://stellar.expert/explorer/testnet/contract/CADD22PHOXWHYVCQ3K5DWIHPUNA5USTHBPOCBE2KDCYNUEBUGFAHH33R) | the dollar, as a classic Stellar asset |
| sagUSD (SAC) | [`CCQG6FDE...M7NBD5`](https://stellar.expert/explorer/testnet/contract/CCQG6FDEYA52IVWLXQ2IFZ56UTNKKBLOADGG5BASXNLTX53SBSM7NBD5) | the share, as a classic Stellar asset, quotable on the SDEX |
| Allocation Engine | [`CBDVZPMB...ZE6FFD`](https://stellar.expert/explorer/testnet/contract/CBDVZPMBUQQ6OML3WTT4TP6QIOJDRC4BWYXR7UZQAAZG2LETAVZE6FFD) | pool routing and caps |
| Oracle Adapter | [`CAUOHPPN...TWIQUS`](https://stellar.expert/explorer/testnet/contract/CAUOHPPNHUIYQI3KIVPLP75CGWKFBGSXK3RW75UO52PKY3YKQRTWIQUS) | multi source NAV, staleness and deviation guards |
| CCTP Adapter | [`CDSO4GJR...WUWFML`](https://stellar.expert/explorer/testnet/contract/CDSO4GJRY7BFVMQ4PYP3ISVOFPQLPA3C7ZFT5HQOUDM3VXTGOUWUWFML) | cross chain USDC leg |
| Private credit adapter | [`CDNWXGSS...WLP3VE`](https://stellar.expert/explorer/testnet/contract/CDNWXGSSP3BOAIKIYTGDHST2BBSZNWIW6RMDQERM3HOQ24EO43WLP3VE) | an off-chain originator behind allocate, deallocate, get_exposure |
| Etherfuse adapter | [`CCXO2ZIM...KM7BXN`](https://stellar.expert/explorer/testnet/contract/CCXO2ZIMK7KZMMUBE24KOLWDJHVXQKXDNEP4QH7N5ZK5U6ESCWKM7BXN) | a tokenized government bond behind the same three calls |
| USDC (Circle SAC) | [`CBIELTK6...XQDAMA`](https://stellar.expert/explorer/testnet/contract/CBIELTK6YBZJU5UP2WWQEUCYKLPU6AUNZ2BQ4WWFEIE3USCIHMXQDAMA) | the real testnet USDC |

## One run, one account, the whole journey

A fresh account is created for every run, so nothing below is carried over from an earlier one.
Account [`GAWTA6O5...L5QGSTN5G`](https://stellar.expert/explorer/testnet/account/GAWTA6O5BBF3YFPOEX6YLLMYWG57CVCJFVPUOQT7S5LS7JCL5QGSTN5G), 19 October 2026, every transaction successful.

| # | Step | Operation | Transaction |
|---|---|---|---|
| 1 | account created and funded | `create_account` | [`faaf32dec356`](https://stellar.expert/explorer/testnet/tx/faaf32dec356df6be7d73cc353c3343689cb97ad6ee4a7073f81048c481415e5) |
| 2 | trustline, USDC | `change_trust` | [`fe689d423283`](https://stellar.expert/explorer/testnet/tx/fe689d4232834a0e54897dcc3b1f2c8b96fdaaeaa5e791a3a3e192d82eff9a30) |
| 3 | trustline, agUSD | `change_trust` | [`79efbe6ff863`](https://stellar.expert/explorer/testnet/tx/79efbe6ff863939e7811314c207d056e905713778b878d43f49ef93b2023c5c6) |
| 4 | trustline, sagUSD | `change_trust` | [`8c262b76d677`](https://stellar.expert/explorer/testnet/tx/8c262b76d67742cbffe9fe98eb2913649d012c333d7d616e18dae71730e5680a) |
| 5 | 20 USDC sent to the test account | `transfer` | [`ee6a77d9d0be`](https://stellar.expert/explorer/testnet/tx/ee6a77d9d0bea369777a3dcecd62a4e052d5fb5ca57b494744183d81e5d82fcf) |
| 6 | deposit, agUSD minted at par | `deposit` | [`d9424f49de21`](https://stellar.expert/explorer/testnet/tx/d9424f49de21eac327ad1ef7dfbbf93b8d1e6605f212c17ec0a65ba0f3d404a2) |
| 7 | stake, sagUSD shares minted through the SAC | `stake` | [`eb6e524949da`](https://stellar.expert/explorer/testnet/tx/eb6e524949daaeb8c45e396db122d9b8cca127bc413a05162f687772c0fa0d79) |
| 8 | yield distributed, the rate moves and no share is minted | `distribute_yield` | [`a4d9ccdaab7b`](https://stellar.expert/explorer/testnet/tx/a4d9ccdaab7b4fc3c484441471568cc828e020ebddafc98a7d328ddeb830c11c) |
| 9 | unstake requested | `request_unstake` | [`7bb79f9605bb`](https://stellar.expert/explorer/testnet/tx/7bb79f9605bb641d6ba683ea1ceb4d3ff360c5f929e9155277ed793c684d01d3) |
| 10 | claimed after the cooldown, agUSD back with the yield | `claim` | [`2c557e402c44`](https://stellar.expert/explorer/testnet/tx/2c557e402c440932f05824f3c50cea0a989762bc1275db9519ffb1cb961ada93) |
| 11 | Soroswap, agUSD swapped for USDC on the AMM | `swap_exact_tokens_for_tokens` | [`67d7b8369e67`](https://stellar.expert/explorer/testnet/tx/67d7b8369e67c6740a01e4ebfeb7b67ebf3f28486ebf7d9933622e1ffd828e8c) |
| 12 | SDEX, the same pair filled on the orderbook | `path_payment_strict_send` | [`4f5cd34744fc`](https://stellar.expert/explorer/testnet/tx/4f5cd34744fc2792dc589a0d54ded6385667ee685abc751eb565fbc21c5e1fb2) |
| 13 | withdrawal requested, the Vault queue | `request_withdrawal` | [`71adcef54e73`](https://stellar.expert/explorer/testnet/tx/71adcef54e73bffa5df343b7cbb3d90979c1b709f819b7b0338873875d197c51) |
| 14 | withdrawal claimed, USDC paid out | `claim_withdrawal` | [`40bfe3fe5bb5`](https://stellar.expert/explorer/testnet/tx/40bfe3fe5bb5102475fc004a9765927f294442870dd082067d2c643bfbf2ba96) |

The account deposited 20 USDC and ended holding more than it started with, the difference being the yield the share price delivered. The run also reconciles what exists of each token against what backs it, through Horizon rather than through the contracts' own counters.

One run proves the path works once. The same script was run again the same day,
at 14:00 UTC, on an account it created for itself and which had never touched
the protocol: [`GA7PSQMB...LZFZTG`](https://stellar.expert/explorer/testnet/account/GA7PSQMBN65WOJAA74ZPJYWXCDKRQVXQC7NBJHCCKSWUGSUDE7LZFZTG),
same twenty one assertions, none failed, every transaction on the account
successful. Nothing is carried between the two: a reviewer running
`bash scripts/e2e-generation3.sh` gets a third account and a third set of
transactions, which is the point of the script creating its own.


## Deliverable 2, the dApp

Live on testnet at [app.agama.finance/stellar](https://app.agama.finance/stellar).
Nothing has to be requested to try it. The faucet page brings the account into
existence through friendbot, opens the USDC, agUSD and sagUSD trustlines in a single
signature, and points at Circle's own public faucet for the USDC itself, so a visitor
with a Stellar wallet goes from an empty address to a staked position without talking
to us. The USDC is Circle's real testnet issue, not a mock token.

| Page | What can be done there |
|---|---|
| `/stellar` | the vaults, their caps and what each one holds |
| `/stellar/faucet` | friendbot for the reserve, the three trustlines in one signature, Circle's faucet for the USDC |
| `/stellar/agUSD` | deposit USDC, mint agUSD, queue a withdrawal |
| `/stellar/sagUSD` | stake, the share price and its history, request an unstake |
| `/stellar/swap` | agUSD against USDC through Soroswap or the SDEX |
| `/stellar/portfolio` | holdings plus the two forms a position takes while it is leaving |
| `/stellar/bridge` | the USDC leg across chains, through the CCTP adapter |

Every write is a transaction signed in the visitor's own wallet. There is no
custodial step and no server side key: the pages build the invocation, the wallet
signs it, and the result is a transaction on testnet under the visitor's account,
not ours. The portfolio page counts a queued withdrawal and a pending unstake as
holdings, because the agUSD is burned the moment either is requested and the claim
on it lives in the contract until it is collected.

## Deliverable 3, the indexer

The indexer follows the contract events on the ledger and serves them. Two public
endpoints, no key:

| Endpoint | What it serves |
|---|---|
| [`/api/events`](https://app.agama.finance/api/events) | the event stream, per contract, with the ledger cursor it has reached |
| [`/api/nav`](https://app.agama.finance/api/nav) | the sagUSD share price history that feeds the chart, and the live figures |

What makes it evidence rather than a feature is that its numbers can be contradicted
by the chain, and are not. Four reads taken together on 19 October 2026, three of them
straight off the ledger:

```
curl -s https://app.agama.finance/api/nav
  live.sharePrice  16038750
  live.nav       5451280353

stellar contract invoke --id CBOHG5YG... --network testnet -- exchange_rate
  "16038750"

stellar contract invoke --id CBOHG5YG... --network testnet \
  -- get_asset_amounts_per_shares --vault_shares 10000000
  ["16038750"]

stellar contract invoke --id CBOHG5YG... --network testnet -- fetch_total_managed_funds
  total_amount "5451280353"
```

The share price the indexer serves, the scalar `exchange_rate` returns, and the figure
DeFindex's own entry point returns for one share are one number. The NAV the indexer
serves and the total `fetch_total_managed_funds` reports are one number. The dApp
prints the first of them as `1.6038750` at the top of
[app.agama.finance/stellar](https://app.agama.finance/stellar), which is where
deliverables 2 and 3 meet: the page is showing the ledger, through the indexer, and
either of the other two reads would contradict it if it were not.

These figures move. A reader running the same four commands later gets a different
number four times rather than this one four times, which is the point: none of it is
typed in by hand.


## Bytecode provenance

The repository compares every deployed contract against a rebuild of this tree,
with `bash scripts/check-deployment-record.sh --wasm`. 70 of its 77 assertions pass.
Seven do not. What follows is what the deployed objects say about themselves, read
off the ledger, rather than an inference about them.

Every Soroban contract carries a build stamp in a `contractmetav0` section, and
`stellar contract fetch --id <address> --network testnet` brings it back, so none
of this has to be taken on trust.

| | On the ledger | This tree today |
|---|---|---|
| rustc | 1.98.1 | 1.98.1, pinned in `rust-toolchain.toml` |
| soroban-sdk | 23.5.3, commit `d3e1ab24` | 23.5.3, commit `d3e1ab24` |
| Stellar CLI | no stamp at all | 28.1.0 |

The compiler matches, and the SDK matches down to its commit hash. The source
matches too: the only commit to touch `contracts/`, `adapters/` or `crates/` since
the oldest of these deployments is `c15cfa3`, which added the CCTP adapter as a
new crate and modified no existing one.

What does not match is the Stellar CLI that drove the build. Every object this
tree builds today carries a second `contractmetav0` section stamped
`cliver 28.1.0`. The deployed objects carry no such section, which is what a build
driven by an earlier CLI looks like. The CLI on the build machine was upgraded
after these deployments, and the code sections moved with it.

| Contract | Deployed | On the ledger | Rebuilt today |
|---|---|---|---|
| `vault` | 2026-10-05 | `916a02bcfc9946a8` | `7ed4b8796968bffd` |
| `staking` | 2026-10-06 | `b9e393a95b93ad9b` | `e6ec1aa15c2796ae` |
| `allocationEngine` | 2026-10-05 | `d22be492107c0dfd` | `95cd40c5b2abc8b0` |
| `oracleAdapter` | 2026-09-14 | `99fb5d13e208e8fd` | `dc8de91b20a784d4` |
| `cctpAdapter` | 2026-10-12 | `b2c24917a7cd6a18` | `8871af05110814bd` |
| `private-credit` | 2026-10-05 | `d41e8b8fb6dc1ed3` | `729f5ed25232ad65` |
| `etherfuse` | 2026-10-09 | `0797838a5e71934b` | `26afa013412cddd1` |

A correction worth making in the open: an earlier version of this section blamed
an unpinned rustc that had drifted to 1.99.1 after the deployments. That was a
guess, and the ledger contradicts it. Pinning 1.99.1 had in fact moved the rebuild
further from what is deployed, and the pin is now 1.98.1, which is what the stamps
say. Anyone can check the claim in one command, which is why it had to be right
rather than plausible.

The gap cannot be closed by redeploying, and that is a consequence of guarantees
made on purpose. No contract in this repository exposes an upgrade entry point, so
the bytecode at an address is final. agUSD and sagUSD are classic Stellar assets
whose Stellar Asset Contract admin was handed to the Vault and to the staking
contract, and whose issuer accounts were then locked by setting the master key
weight to zero. Neither contract can hand that admin on, which is what guarantees
the supply has exactly one minter. A replacement Vault would therefore be a
replacement agUSD, abandoning the asset that is in circulation, quoted on the SDEX
and held in a Soroswap pool. Keeping the asset and recording the provenance is the
better trade, and it is what this section does.

What remains verifiable without the rebuild: the recorded wasm hash of every
superseded generation is what the ledger holds, which the same script checks and
passes, 18 for 18.
