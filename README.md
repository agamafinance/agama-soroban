# Agama Finance Soroban Contracts

Private Credit Yield Vaults on Stellar · **[Try the app](https://app.agama.finance/stellar)**

Users deposit USDC into curated vaults and receive **agUSD**, a composable synthetic dollar backed by diversified real-world credit pools. Staking agUSD produces **sagUSD**, a yield-bearing token that appreciates as private credit repayments and on-chain strategies generate returns.

All contracts are written in Rust for the Soroban smart contract platform.

## Live on Testnet

Network: **Stellar Testnet** · RPC: `https://soroban-testnet.stellar.org`

**[Test the app at app.agama.finance/stellar](https://app.agama.finance/stellar)**

### Core Contracts

| Contract | Address |
|---|---|
| USDC (Circle) | [`CBIELTK6...XQDAMA`](https://stellar.expert/explorer/testnet/contract/CBIELTK6YBZJU5UP2WWQEUCYKLPU6AUNZ2BQ4WWFEIE3USCIHMXQDAMA) |
| agUSD | [`CCXEP6QA...NQ6H3`](https://stellar.expert/explorer/testnet/contract/CCXEP6QAAYEMFMV2JGBULD2NS6AQB6KQSBHLPPBJSDBCN6HOYIHNQ6H3) |
| sagUSD | [`CABPYD4U...XTALX`](https://stellar.expert/explorer/testnet/contract/CABPYD4U5FAYLBEBMY2MVGVF7BILXTNPWGLOPIXCMUK3QQGIAE2XTALX) |

### Credit Vaults (Allocation Pools)

6 credit vaults live on testnet, curated by [Qiro](https://www.qiro.fi/) and [Tenka](https://tenka.fi/):

| Vault | Curator | Strategy | Address |
|---|---|---|---|
| Payment Financing | [Qiro](https://www.qiro.fi/) | Short Term Payment Receivables · 14% APY | [`CAUFXVGK...YQEF4`](https://stellar.expert/explorer/testnet/contract/CAUFXVGKB2OKEDDO6SDWH4ZSWXJ37T2WYKEVUTBOCWZAFEUTGCFYQEF4) |
| Private Credit | [Qiro](https://www.qiro.fi/) | Diversified Credit Fund · 13% APY | [`CADVWAZ3...VECN3`](https://stellar.expert/explorer/testnet/contract/CADVWAZ324KZYLDGYJVHPLQ5BXSQWTWZLH64OHIHIDYPX76BRL7VECN3) |
| Institutional Credit | [Qiro](https://www.qiro.fi/) | Institutional Lender Financing · 12% APY | [`CC3MOBKH...MJBK2`](https://stellar.expert/explorer/testnet/contract/CC3MOBKHGNTHGALTQKZHICW5MYD4VYPGZEA3UC7GFYRK3VYK47EMJBK2) |
| Flagship | [Tenka](https://tenka.fi/) | ABF Senior · 8-9% APY | [`CBOF52TX...ULKKS`](https://stellar.expert/explorer/testnet/contract/CBOF52TX36HR62LX7HVMWMYVPUDBZXTRD74H2Q7NZKLUGAVBNBJULKKS) |
| High Yield | [Tenka](https://tenka.fi/) | ABF Mezzanine · 15-20% APY | [`CCWXOUPQ...NHOPG`](https://stellar.expert/explorer/testnet/contract/CCWXOUPQFZLGENWWT3JLMXOBDE6N6EE5STS7IHESCADX72DDFUSNHOPG) |
| Deal Vaults | [Tenka](https://tenka.fi/) | Deal-by-Deal · 7-15% APY | [`CBXKGXB4...2IDO5G`](https://stellar.expert/explorer/testnet/contract/CBXKGXB46PD2NDGPS6YRIWJ33A5YEJP5YPYGRBJZTTGWBQ7ASY2IDO5G) |

The protocol uses native Circle USDC on Stellar (issuer `GBBD47IF6LWK7P7MDEVSCWR7DPUWV3NY3DTQEVFL4NAT4AQH3ZLLFLA5`), not a wrapped or synthetic asset. All contracts are verifiable on [Stellar Expert](https://stellar.expert/explorer/testnet).

## Repository Structure

```
agama-soroban/
├── contracts/
│   ├── agusd/              ✅ agUSD SEP-41 token (deployed testnet)
│   ├── staking/            ✅ sagUSD (deployed testnet)
│   ├── vault/              🔧 Vault Contract (T1.1, Aug 2026)
│   ├── allocation-engine/  🔧 Allocation Engine (T2.1, Sep 2026)
│   └── oracle-adapter/     🔧 Oracle Adapter (T2.2, Oct 2026)
├── adapters/
│   ├── blend-v2/           🔧 Blend v2 adapter (T2.1, Sep 2026)
│   ├── etherfuse/          🔧 Etherfuse adapter (T2.2, Oct 2026)
│   └── private-credit/     🔧 Private credit adapter (T2.1, Sep 2026)
├── crates/
│   └── token/              Shared SEP-41 token utilities
├── deployments/
│   └── testnet.json        Deployed contract addresses
└── scripts/                Deploy and test scripts
```

## Contracts

### agUSD (`contracts/agusd`)

Composable synthetic dollar minted 1:1 against USDC deposits. Full [SEP-41](https://github.com/stellar/stellar-protocol/blob/master/ecosystem/sep-0041.md) token interface: `transfer`, `approve`, `transfer_from`, `balance`, `allowance`. Mint and burn are restricted to the Vault Contract address.

### sagUSD (`contracts/staking`)

Yield-bearing staked agUSD. Share-based vault accounting compatible with the DeFindex standard: yield accrues by increasing the sagUSD/agUSD exchange rate via `distribute_yield()`, no claiming or rebasing needed. Two-step unstake with configurable cooldown.

**DeFindex compatibility:** sagUSD adopts the DeFindex `distribute_yield()` / assets-per-share model, making sagUSD positions natively readable by any DeFindex-integrated wallet or protocol without additional integration work.

### Vault Contract (`contracts/vault`) (T1.1, August 2026)

USDC entry point. Accepts deposits, mints agUSD 1:1, routes capital through the Allocation Engine, and manages a two-step FIFO withdrawal queue (`request_withdrawal` / `claim_withdrawal`). Queries Oracle Adapter for NAV. Includes a circuit-breaker (`set_paused`).

### Allocation Engine (`contracts/allocation-engine`) (T2.1, September 2026)

Routes vault capital across registered pool adapters with on-chain concentration caps (per pool, per originator, per jurisdiction). All pool types implement a uniform adapter interface so the Engine stays agnostic to pool type. Admin-gated in V1, off-chain optimizer in V2.

### Oracle Adapter (`contracts/oracle-adapter`) (T2.2, October 2026)

Multi-source NAV pipeline:

| Feed | Source | Staleness | Deviation Bound |
|---|---|---|---|
| XLM/USD, USDC/USD | [Reflector](https://reflector.network) | 1 hour | 2% |
| Private credit NAV | Off-chain reporter via Backend | 7 days | 5% |
| Etherfuse bond price | Etherfuse API / on-chain | 48 hours | Deterministic |

Validates caller authorization, timestamp freshness, and deviation bounds on every update. Vault reverts with `OracleStale` if a feed is expired.

## Adapter Interface

All pool types share the same interface, keeping the Allocation Engine pool-agnostic:

```rust
fn allocate(amount: i128)     // Deploy capital into the pool
fn deallocate(amount: i128)   // Withdraw capital from the pool
fn get_exposure() -> i128     // Current allocated amount
```

| Adapter | Underlying | Settlement | Oracle |
|---|---|---|---|
| Blend v2 | Blend lending pool | Instant (on-chain) | Not needed (on-chain accrual) |
| Etherfuse | Stablebond contracts | Instant (on-chain) | Etherfuse feed (48h) |
| Private Credit | Off-chain originator | D+15 to D+90 | Custom reporter (7d) |

## Build and Test

Requirements: [Rust](https://rustup.rs) + [Stellar CLI](https://developers.stellar.org/docs/tools/developer-tools/stellar-cli)

```bash
# Install Stellar CLI
cargo install --locked stellar-cli --features opt

# Build contracts
cd contracts/agusd && cargo build --target wasm32-unknown-unknown --release
cd contracts/staking && cargo build --target wasm32-unknown-unknown --release

# Run tests
cargo test --workspace

# Deploy to testnet
cp .env.example .env
bash scripts/deploy.sh
```

## Roadmap

| Deliverable | Contracts | ETA | Status |
|---|---|---|---|
| T1.1 Core Contracts | Vault, agUSD, sagUSD | August 2026 | agUSD + sagUSD live on testnet |
| T2.1 Allocation Engine | Allocation Engine, Blend v2, Private credit adapters | September 2026 | In development |
| T2.2 RWA and Oracle | Oracle Adapter, Etherfuse adapter | October 2026 | In development |
| T2.3 Stress Testing | All contracts | October 2026 | Pending |
| T3.1 Mainnet and Audit | All contracts | November 2026 | Pending |

## Ecosystem Integrations

From the [SCF Integration List](https://communityfund.stellar.org/integration-list):

| Protocol | Role |
|---|---|
| [Blend v2](https://blend.capital) | On-chain yield and instant withdrawal liquidity buffer |
| [DeFindex](https://defindex.io) | sagUSD share-price accounting convention |
| [Soroswap](https://soroswap.finance) | agUSD/USDC and sagUSD/agUSD AMM pools |
| [Etherfuse](https://etherfuse.com) | Stellar-native government bond RWA collateral |
| [Reflector](https://reflector.network) | Decentralized XLM/USD and USDC/USD price feeds |

## Security

- `mint` / `burn` restricted to Vault Contract via `require_auth()`
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
- Technical Architecture: [PDF](https://docs.google.com/document/d/1E69_kfNsJBzwBaydMRedyGqN1AGm4elk-xlMbhsQQUM)
