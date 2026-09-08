# Agama Finance Soroban Contracts

Private Credit Yield Vaults on Stellar · **[Try the app](https://app.agama.finance/stellar)**

Users deposit USDC into curated vaults and receive **agUSD**, a composable synthetic dollar backed by diversified real-world credit pools. Staking agUSD produces **sagUSD**, a yield-bearing token that appreciates as private credit repayments and on-chain strategies generate returns.

All contracts are written in Rust for the Soroban smart contract platform.

## Architecture

![Agama on Stellar](docs/architecture.png)

Entry ramps, the dApp, the Soroban contract set, allocation targets and the off-chain indexer, with the parameters each component enforces. Source: [`docs/architecture.svg`](docs/architecture.svg).

## Live on Testnet

Network: **Stellar Testnet** · RPC: `https://soroban-testnet.stellar.org`

**[Test the app at app.agama.finance/stellar](https://app.agama.finance/stellar)**

### Core Contracts

| Contract | Address |
|---|---|
| USDC (Circle) | [`CBIELTK6...XQDAMA`](https://stellar.expert/explorer/testnet/contract/CBIELTK6YBZJU5UP2WWQEUCYKLPU6AUNZ2BQ4WWFEIE3USCIHMXQDAMA) |
| agUSD | [`CCFICOHA...6H54WV`](https://stellar.expert/explorer/testnet/contract/CCFICOHAC4V6M5CDI62O5SWCZR43XG6JXNYFBZ4HAVQJBUCR4V6H54WV) |
| agUSD, generation 1 (superseded) | [`CCXEP6QA...NQ6H3`](https://stellar.expert/explorer/testnet/contract/CCXEP6QAAYEMFMV2JGBULD2NS6AQB6KQSBHLPPBJSDBCN6HOYIHNQ6H3) |
| sagUSD | [`CABPYD4U...XTALX`](https://stellar.expert/explorer/testnet/contract/CABPYD4U5FAYLBEBMY2MVGVF7BILXTNPWGLOPIXCMUK3QQGIAE2XTALX) |
| Vault Contract | [`CDQP7L5R...TR3KS4`](https://stellar.expert/explorer/testnet/contract/CDQP7L5RZ6AM4J2PZETMG7TC4M3CDTVQ6QAMYPLG43Z6GAOCB4TR3KS4) |
| Vault Contract, generation 1 (superseded) | [`CAVKHGBQ...5OFJW3`](https://stellar.expert/explorer/testnet/contract/CAVKHGBQUEPVTWHFJGU42ZVZA6VZSM6RZXFHCUXTT72JFRWNPF5OFJW3) |
| Allocation Engine | [`CANDJEHB...SL2SGS`](https://stellar.expert/explorer/testnet/contract/CANDJEHBZUPGBWQMWM567Z3NQR4AHJKJSMWB4LTXPT6SC7GSRKSL2SGS) |
| Oracle Adapter | [`CDV5BC4X...XCSV7G`](https://stellar.expert/explorer/testnet/contract/CDV5BC4XCNT5ASOZNFXBQXRGKVXGKHLRVK5EDX6XP5J6EBIZWSXCSV7G) |

Two addresses were superseded on 8 September 2026 and are kept in the table,
and in [`deployments/testnet.json`](deployments/testnet.json), rather than
quietly replaced. The generation 1 agUSD is a self contained vault with no
`mint` entry point, so the Vault Contract could never mint against a deposit;
it is still deployed, still held, and still the token the sagUSD staking
contract accepts. The generation 1 Vault was wired to it at initialization with
no setter and no upgrade path, so replacing the token meant replacing the
Vault. The Allocation Engine, the Oracle Adapter, both pool adapters, USDC,
sagUSD and the six credit vaults were not redeployed.

### Pool Adapters

| Adapter | Originator | Jurisdiction | Address |
|---|---|---|---|
| Private Credit | QIRO | LU | [`CCDZRKZD...CXT3VZ`](https://stellar.expert/explorer/testnet/contract/CCDZRKZDCWJWTFMLVJFW4LRALZEWRDKWOOD727EDO3EFFKLNDKCXT3VZ) |
| Etherfuse | ETHERFUS | MX | [`CBS3OGCV...KFLYKK`](https://stellar.expert/explorer/testnet/contract/CBS3OGCVYMI3XQN2ORZZNE2WKGYK24VSTVDUB3QS5HCZHBQQFWKFLYKK) |

Both adapters are registered with the Allocation Engine. `originator` and
`jurisdiction` are the buckets the concentration caps aggregate over, so two
pools fronted by the same counterparty count as one position.

### Deployed Configuration

The Allocation Engine ships fail closed, every cap at zero and the reserve
floor at 100%, so these are the values it was opened up to. They are recorded
in [`deployments/testnet.json`](deployments/testnet.json) and are readable
on-chain through `caps()` and `reserve_floor_bps()`.

| Limit | Value |
|---|---|
| Per-pool cap | 3000 bps (30%) |
| Per-originator cap | 4000 bps (40%) |
| Per-jurisdiction cap | 5000 bps (50%) |
| Idle USDC reserve floor | 2000 bps (20%) |

The Oracle Adapter carries the three feeds documented below, each registered
with its own staleness window and deviation bound, and the admin address as the
sole authorized reporter. The Vault reads NAV from `PC_NAV`.

### Credit Vaults (Allocation Pools)

6 credit vaults live on testnet, curated by [Qiro](https://www.qiro.fi/investor) and [Tenka](https://tenka.fi/):

| Vault | Curator | Strategy | Share Token | Address |
|---|---|---|---|---|
| Payment Financing | [Qiro](https://www.qiro.fi/investor) | Short Term Payment Receivables · 14% APY | qPAY | [`CAUFXVGK...YQEF4`](https://stellar.expert/explorer/testnet/contract/CAUFXVGKB2OKEDDO6SDWH4ZSWXJ37T2WYKEVUTBOCWZAFEUTGCFYQEF4) |
| Private Credit | [Qiro](https://www.qiro.fi/investor) | Diversified Credit Fund · 13% APY | qPCV | [`CADVWAZ3...VECN3`](https://stellar.expert/explorer/testnet/contract/CADVWAZ324KZYLDGYJVHPLQ5BXSQWTWZLH64OHIHIDYPX76BRL7VECN3) |
| Institutional Credit | [Qiro](https://www.qiro.fi/investor) | Institutional Lender Financing · 12% APY | qICV | [`CC3MOBKH...MJBK2`](https://stellar.expert/explorer/testnet/contract/CC3MOBKHGNTHGALTQKZHICW5MYD4VYPGZEA3UC7GFYRK3VYK47EMJBK2) |
| Flagship | [Tenka](https://tenka.fi/) | ABF Senior · 8-9% APY | tFLAG | [`CBOF52TX...ULKKS`](https://stellar.expert/explorer/testnet/contract/CBOF52TX36HR62LX7HVMWMYVPUDBZXTRD74H2Q7NZKLUGAVBNBJULKKS) |
| High Yield | [Tenka](https://tenka.fi/) | ABF Mezzanine · 15-20% APY | tHY | [`CCWXOUPQ...NHOPG`](https://stellar.expert/explorer/testnet/contract/CCWXOUPQFZLGENWWT3JLMXOBDE6N6EE5STS7IHESCADX72DDFUSNHOPG) |
| Deal Vaults | [Tenka](https://tenka.fi/) | Deal-by-Deal · 7-15% APY | tDEAL | [`CBXKGXB4...2IDO5G`](https://stellar.expert/explorer/testnet/contract/CBXKGXB46PD2NDGPS6YRIWJ33A5YEJP5YPYGRBJZTTGWBQ7ASY2IDO5G) |

Each credit vault is an independent Soroban contract with its own share token. The on-chain Allocation Engine, with concentration caps and a minimum idle USDC reserve floor, is deployed on testnet at the address in the Core Contracts table above and configured with the limits listed there.

The protocol uses native Circle USDC on Stellar (issuer `GBBD47IF6LWK7P7MDEVSCWR7DPUWV3NY3DTQEVFL4NAT4AQH3ZLLFLA5`), not a wrapped or synthetic asset. All contracts are verifiable on [Stellar Expert](https://stellar.expert/explorer/testnet).

## Repository Structure

```
agama-soroban/
├── contracts/
│   ├── agusd-core/         ✅ agUSD SEP-41 token, minted by the Vault (deployed testnet)
│   ├── agusd/              ✅ agUSD generation 1, superseded (deployed testnet)
│   ├── staking/            ✅ sagUSD (deployed testnet)
│   ├── vault/              ✅ Vault Contract (deployed testnet)
│   ├── allocation-engine/  ✅ Allocation Engine (deployed testnet)
│   ├── oracle-adapter/     ✅ Oracle Adapter (deployed testnet)
│   └── mock_usdc/          Test USDC faucet, used by the test suites
├── adapters/
│   ├── etherfuse/          ✅ Etherfuse adapter (deployed testnet)
│   └── private-credit/     ✅ Private credit adapter (deployed testnet)
├── crates/
│   └── token/              Shared SEP-41 token utilities
├── deployments/
│   └── testnet.json        Deployed contract addresses
└── scripts/                Deploy and test scripts
```

## Contracts

### agUSD (`contracts/agusd-core`) (deployed on testnet)

Composable synthetic dollar minted 1:1 against USDC deposits. Full [SEP-41](https://github.com/stellar/stellar-protocol/blob/master/ecosystem/sep-0041.md) token interface: `transfer`, `approve`, `transfer_from`, `balance`, `allowance`.

`mint` checks the minter address recorded at initialization, which is the Vault Contract, and nothing else. There is no admin mint, no minter rotation and no pause that could create supply, so one agUSD in circulation means one USDC was deposited into the Vault, and an auditor can check that rather than take it on trust. Moving issuance to a different Vault costs a new token deployment, which is the price of that guarantee.

`burn` and `burn_from` stay on the standard SEP-41 semantics, authorized by the holder. That is what the Vault's `request_withdrawal` calls, and restricting the burn path would buy nothing: destroying your own balance harms nobody else. Supply goes up only through the Vault and down only through the holder.

### agUSD generation 1 (`contracts/agusd`) (deployed on testnet, superseded)

The first agUSD is not a plain token, it is a self contained vault: it takes the USDC in, mints against it, keeps a `buffer_bps` liquidity buffer for instant redemption and pushes the excess into the credit vaults at the Allocation Engine's target weights, inside the same deposit call. Custody, routing and issuance all live in one contract, which is why it exposes no `mint` for the Vault Contract to call.

It is left exactly as it is rather than rewritten underneath the people holding it. It stays deployed, it keeps its holders, and it is still the token the deployed sagUSD staking contract accepts, because that contract stores the token address at initialization and has no setter either.

### sagUSD (`contracts/staking`)

Yield-bearing staked agUSD. Share-based vault accounting compatible with the DeFindex standard: yield accrues by increasing the sagUSD/agUSD exchange rate via `distribute_yield()`, no claiming or rebasing needed. Two-step unstake with configurable cooldown.

**DeFindex compatibility:** sagUSD adopts the DeFindex `distribute_yield()` / assets-per-share model, making sagUSD positions natively readable by any DeFindex-integrated wallet or protocol without additional integration work.

### Vault Contract (`contracts/vault`) (deployed on testnet)

USDC entry point. Accepts deposits, mints agUSD 1:1, routes capital through the Allocation Engine, and manages a two-step FIFO withdrawal queue (`request_withdrawal` / `claim_withdrawal`). Queries Oracle Adapter for NAV. Includes a circuit-breaker (`set_paused`).

The queue is paid strictly in order and there is no admin path around it: `claim_withdrawal` refuses any claim that is not at the head. agUSD is burned when the withdrawal is requested, not when it is claimed, so a queued position cannot be sold or re-requested while it waits. A minimum withdrawal of 1 agUSD keeps dust requests from crowding the queue.

**Testnet status.** The Vault is deployed, wired to the live USDC and to the agUSD above, and the whole deposit path runs on-chain against real Circle USDC. `scripts/smoke-agusd-core.sh` reproduces it with thirty assertions; `scripts/smoke-core.sh` still covers the allocation and NAV paths. From the run of 8 September 2026:

| What it proves | Transaction |
|---|---|
| A caller that is not the Vault cannot mint agUSD | [`3148ac62`](https://stellar.expert/explorer/testnet/tx/3148ac621c2a5343d2b6f60e0bec5dbaa3586cfdd906c23081b4248134ff9f6f) |
| 3 USDC deposited, 3 agUSD minted 1:1 | [`8923ea7d`](https://stellar.expert/explorer/testnet/tx/8923ea7d39cd9022fecac40cb11b3c06052851e1ecdd9e56c99ab5e3528e7c43) |
| 1 agUSD burned at request time, claim 1 queued | [`9f243cdb`](https://stellar.expert/explorer/testnet/tx/9f243cdb30e97743902a6751989ac9f4faf79c2efbd7b24e3ddace702069d634) |
| Claim 1 paid, 1 USDC back to the holder | [`3b1b7906`](https://stellar.expert/explorer/testnet/tx/3b1b7906da4a362dfcd4a2e556cd3710e81b727dbebec7b4dc7c8a01cebae918) |
| Only the Allocation Engine can release the Vault's USDC | [`3b406ba2`](https://stellar.expert/explorer/testnet/tx/3b406ba2bc705f5b6454eb6540229f05d378b17eba12d3093cb6117ce735b8be) |

The two refusals were submitted rather than simulated, and failed when they applied. Simulation records authorization instead of enforcing it, so a simulated refusal would have proved nothing.

The Vault's own address moved in that deployment. The generation 1 Vault stored the agUSD address at `initialize()` and had no setter and no upgrade entry point, so it was wired to a token with no `mint` for as long as it exists. The replacement carries `set_agusd`, which is admin gated and refuses once the Vault has taken a deposit: repointing a Vault while agUSD is outstanding would leave holders backed by a token it no longer mints or burns.

**Known gap.** The Allocation Engine stores the Vault address at `initialize()` and has no setter either, so it still points at the generation 1 Vault and its concentration caps and reserve floor still guard that book. The new Vault is initialized with the live Engine as its only allocation counterparty, and refuses `settle_allocation` from anyone else, so custody is wired the right way round; but until the Engine and the two pool adapters are redeployed it holds 100% of its assets as idle reserves and deploys no capital.

### Allocation Engine (`contracts/allocation-engine`) (deployed on testnet)

Routes vault capital across registered pool adapters with on-chain concentration caps (per pool, per originator, per jurisdiction). All pool types implement a uniform adapter interface so the Engine stays agnostic to pool type. Admin-gated in V1, off-chain optimizer in V2.

A fourth guard, `set_reserve_floor`, holds a minimum share of total assets as idle USDC in the Vault. `allocate()` reverts if a call would push reserves below it, which is where fast-exit liquidity now lives. Caps and floor start fully closed at deployment, so an Engine that has not been configured cannot deploy capital.

With the two pools registered today, each capped at 30%, at most 60% of the book can ever be deployed, so the 20% reserve floor is not the binding constraint: the per-pool cap always fires first. It becomes the binding one as soon as a third pool is registered or the caps are widened. `scripts/smoke-agusd-core.sh` raises the floor above the current reserve ratio to show it refusing a release that every cap allows, then puts it straight back.

### Oracle Adapter (`contracts/oracle-adapter`) (deployed on testnet)

Multi-source NAV pipeline:

| Feed | Source | Staleness | Deviation Bound |
|---|---|---|---|
| XLM/USD, USDC/USD | [Reflector](https://reflector.network) | 1 hour | 2% |
| Private credit NAV | Off-chain reporter via Backend | 7 days | 5% |
| Etherfuse bond price | Etherfuse API / on-chain | 48 hours | Deterministic |

Validates caller authorization, timestamp freshness, and deviation bounds on every update. Vault reverts with `OracleStale` if a feed is expired. Timestamps must be strictly increasing per feed and never ahead of ledger time, so a stale feed cannot be made to look fresh.

Two report paths share one validation. `push_nav()` fails the transaction on a deviation breach; `submit_nav()` returns a rejection outcome and emits `nav_rejected` instead. The split exists because Soroban discards the events of an invocation that errors, so a single entry point cannot both fail the caller and leave the refusal in the ledger event stream.

## Adapter Interface

All pool types share the same interface, keeping the Allocation Engine pool-agnostic:

```rust
fn allocate(amount: i128)     // Deploy capital into the pool
fn deallocate(amount: i128)   // Withdraw capital from the pool
fn get_exposure() -> i128     // Current allocated amount
```

| Adapter | Underlying | Settlement | Oracle |
|---|---|---|---|
| Etherfuse | Stablebond contracts | Instant (on-chain) | Etherfuse feed (48h) |
| Private Credit | Off-chain originator | D+15 to D+90 | Custom reporter (7d) |

## Build and Test

Requirements: [Rust](https://rustup.rs) + [Stellar CLI](https://developers.stellar.org/docs/tools/developer-tools/stellar-cli)

```bash
# Install Stellar CLI
cargo install --locked stellar-cli --features opt

# Build every contract to wasm
cargo build --target wasm32-unknown-unknown --release --workspace

# Or a single one
cargo build --target wasm32-unknown-unknown --release -p vault

# Run tests
cargo test --workspace

# Deploy the Vault, Allocation Engine, Oracle Adapter and the two pool
# adapters to testnet, then initialize and configure them. Reuses the live
# USDC and agUSD addresses from deployments/testnet.json.
bash scripts/deploy-core.sh

# Smoke test that deployment on-chain: NAV push and read back, reserves and
# total assets, an allocation and its unwind, and the concentration caps
bash scripts/smoke-core.sh

# Deploy the generation 2 agUSD and the Vault that mints it. Reuses the live
# USDC, Allocation Engine and Oracle Adapter, and leaves the generation 1
# agUSD, sagUSD and the six credit vaults alone.
bash scripts/deploy-agusd-core.sh

# Smoke test the deposit path on-chain: mint authority, a deposit minting 1:1,
# the withdrawal queue, the Engine's cap and reserve floor, and staking
bash scripts/smoke-agusd-core.sh

# Deploy the agUSD + sagUSD + credit vault set (already live on testnet)
cp .env.example .env
bash scripts/deploy.sh
```

## Roadmap

| Deliverable | Contracts | ETA | Status |
|---|---|---|---|
| Tranche 1, MVP | Vault, agUSD, sagUSD | November 2026 | agUSD + sagUSD + Vault live on testnet, deposit and withdrawal proven on-chain |
| Tranche 2, Testnet | Allocation Engine, Etherfuse and private credit adapters, Oracle Adapter | December 2026 | Live on testnet, delivered early |
| Tranche 3, Mainnet | All contracts, audit remediation | February 2027 | Pending |

## Ecosystem Integrations

From the [SCF Integration List](https://communityfund.stellar.org/integration-list):

| Protocol | Role |
|---|---|
| [DeFindex](https://defindex.io) | sagUSD share-price accounting convention |
| [Soroswap](https://soroswap.finance) | agUSD/USDC and sagUSD/agUSD AMM pools |
| [Etherfuse](https://etherfuse.com) | Stellar-native government bond RWA collateral |
| [Reflector](https://reflector.network) | Decentralized XLM/USD and USDC/USD price feeds |

> **Revision, September 2026.** Blend v2 was previously an allocation target for idle capital and the instant-withdrawal liquidity buffer. It has been removed following the Comet BLND-USDC exploit and Blend's removal from the SCF Integration List. It is not replaced by another protocol: fast-exit liquidity is now a minimum idle USDC reserve floor enforced by the Allocation Engine, where `allocate()` reverts if a call would push vault reserves below the floor.

## Security

- `mint` restricted to the Vault Contract via `require_auth()`, with the minter fixed at initialization: no admin mint, no rotation, and burning left to the holder
- The Vault's agUSD address is admin settable only before its first deposit, and its USDC leaves only through the Allocation Engine
- Oracle reporter set: `push_nav()` validates caller, rotation requires admin + event
- NAV deviation bounds: >2% for Reflector asset prices, >5% for private credit NAV
- On-chain concentration caps: `allocate()` reverts if any cap exceeded
- Pause circuit breaker: deposits and withdrawals blocked, staking continues
- Admin: 2-of-3 multi-sig in V1, governance + 48h timelock in V2
- V1 contracts are immutable, upgrades require redeployment + migration

## License

Apache 2.0 ([LICENSE](./LICENSE))

All Soroban contracts are open-sourced from day one. Contracts deployed on Stellar Testnet are available for public review now.

## Links

- App: [app.agama.finance/stellar](https://app.agama.finance/stellar)
- X: [@agamafinance](https://x.com/agamafinance)
- Technical Architecture: [PDF](https://drive.google.com/file/d/1l1FOhHtyuvJPQ-92_lvItzCFAFBeBA--/view?usp=sharing)
