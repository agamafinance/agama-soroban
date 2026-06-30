# Agama Finance — Soroban Contracts

**Private Credit Yield Vaults on Stellar**

Agama brings tokenized private-credit yield to Stellar. Users deposit USDC into curated vaults and receive **agUSD**, a composable synthetic dollar backed by diversified real-world credit pools. Staking agUSD produces **sagUSD**, a yield-bearing token whose value appreciates as private credit repayments and on-chain strategies generate returns.

All contracts are written in Rust for the [Soroban](https://soroban.stellar.org) smart contract platform.

---

## Testnet Deployments

Network: **Stellar Testnet** (`Test SDF Network ; September 2015`)
RPC: `https://soroban-testnet.stellar.org`

| Contract | Address |
|---|---|
| USDC (mock) | `CBIELTK6YBZJU5UP2WWQEUCYKLPU6AUNZ2BQ4WWFEIE3USCIHMXQDAMA` |
| agUSD | `CCXEP6QAAYEMFMV2JGBULD2NS6AQB6KQSBHLPPBJSDBCN6HOYIHNQ6H3` |
| sagUSD (Staking) | `CABPYD4U5FAYLBEBMY2MVGVF7BILXTNPWGLOPIXCMUK3QQGIAE2XTALX` |

Verify on [Stellar Expert (Testnet)](https://testnet.stellar.expert).

---

## Repository Structure

```
agama-soroban/
├── contracts/
│   ├── agusd/              ✅ agUSD SEP-41 token — deployed testnet
│   ├── staking/            ✅ sagUSD staking vault — deployed testnet
│   ├── mock_usdc/          ✅ Mock USDC for testing
│   ├── vault/              🔧 Vault Contract (T1.1 — Aug 2026)
│   ├── allocation-engine/  🔧 Allocation Engine (T2.1 — Sep 2026)
│   └── oracle-adapter/     🔧 Oracle Adapter (T2.2 — Oct 2026)
├── adapters/
│   ├── blend-v2/           🔧 Blend v2 pool adapter (T2.1 — Sep 2026)
│   ├── etherfuse/          🔧 Etherfuse Stablebond adapter (T2.2 — Oct 2026)
│   └── private-credit/     🔧 Private credit pool adapter (T2.1 — Sep 2026)
├── crates/
│   └── token/              Shared SEP-41 token utilities
├── deployments/
│   └── testnet.json        Deployed contract addresses
└── scripts/                Deploy and test scripts
```

---

## Contract Overview

### agUSD (`contracts/agusd`)

Composable synthetic dollar minted 1:1 against USDC deposits. Implements the full [SEP-41](https://github.com/stellar/stellar-protocol/blob/master/ecosystem/sep-0041.md) token interface (`transfer`, `approve`, `transfer_from`, `balance`, `allowance`). Mint and burn are restricted to the Vault Contract address.

### sagUSD Staking (`contracts/staking`)

Yield-bearing staked agUSD. Uses DeFindex-compatible share-based vault accounting: yield accrues by increasing the sagUSD/agUSD exchange rate via `distribute_yield()` — no claiming, no rebasing. Two-step unstake with configurable cooldown.

> **DeFindex compatibility**: sagUSD adopts the DeFindex `distribute_yield()` / assets-per-share accounting convention, making sagUSD positions natively readable by any DeFindex-integrated wallet or protocol without additional integration work.

### Vault Contract (`contracts/vault`) — *T1.1, ETA August 2026*

USDC entry point. Accepts deposits, mints agUSD 1:1, routes capital via the Allocation Engine, and manages a two-step FIFO withdrawal queue (`request_withdrawal` → `claim_withdrawal`). Queries Oracle Adapter for NAV. Circuit-breaker via `set_paused`.

### Allocation Engine (`contracts/allocation-engine`) — *T2.1, ETA September 2026*

Routes vault capital across registered pool adapters while enforcing on-chain concentration caps (per pool, per originator, per jurisdiction). All pool types implement a uniform adapter interface — the Engine is agnostic to pool type. Admin-gated in V1; off-chain optimizer in V2.

### Oracle Adapter (`contracts/oracle-adapter`) — *T2.2, ETA October 2026*

Multi-source NAV pipeline with unified validation:

| Feed | Source | Staleness | Deviation Bound |
|---|---|---|---|
| Asset prices (XLM/USD, USDC/USD) | [Reflector](https://reflector.network) | 1 hour | 2% |
| Private credit NAV | Off-chain reporter → Backend | 7 days | 5% |
| Etherfuse bond price | Etherfuse API / on-chain | 48 hours | Deterministic |

Validates caller authorization, timestamp freshness, and deviation bounds on every update. Vault reverts with `OracleStale` if the feed is expired.

---

## Adapter Interface

All pool types implement a uniform adapter interface, making the Allocation Engine pool-agnostic:

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

---

## Build & Test

Requirements: [Rust](https://rustup.rs) + [Stellar CLI](https://developers.stellar.org/docs/tools/developer-tools/stellar-cli)

```bash
# Install Stellar CLI
cargo install --locked stellar-cli --features opt

# Build all contracts
cd contracts/agusd && cargo build --target wasm32-unknown-unknown --release
cd contracts/staking && cargo build --target wasm32-unknown-unknown --release

# Run tests
cargo test --workspace

# Deploy to testnet (requires funded account in .env)
cp .env.example .env  # fill in your secret key
bash scripts/deploy.sh
```

---

## Development Roadmap

| Deliverable | Contracts | ETA | Status |
|---|---|---|---|
| T1.1 — Core Contracts | Vault, agUSD, sagUSD | August 2026 | agUSD + sagUSD live on testnet |
| T2.1 — Allocation Engine | Allocation Engine, Blend v2 adapter, Private credit adapter | September 2026 | In development |
| T2.2 — RWA + Oracle | Oracle Adapter, Etherfuse adapter | October 2026 | In development |
| T2.3 — Stress Testing | All contracts | October 2026 | Pending |
| T3.1 — Mainnet + Audit | All contracts | November 2026 | Pending |

---

## Ecosystem Integrations

All integrations are drawn from the [SCF Integration List](https://communityfund.stellar.org/integration-list):

| Protocol | Role |
|---|---|
| [Blend v2](https://blend.capital) | On-chain yield + instant withdrawal liquidity buffer |
| [DeFindex](https://defindex.io) | sagUSD share-price accounting convention |
| [Soroswap](https://soroswap.finance) | agUSD/USDC and sagUSD/agUSD AMM pools |
| [Etherfuse](https://etherfuse.com) | Stellar-native government bond RWA collateral |
| [Reflector](https://reflector.network) | Decentralized XLM/USD and USDC/USD price feeds |

---

## Security

- `mint` / `burn` restricted to Vault Contract via `require_auth()`
- Oracle reporter set — `push_nav()` validates caller; rotation requires admin + event
- NAV deviation bounds: >5% rejected for private credit; >2% for Reflector asset prices
- On-chain concentration caps: `allocate()` reverts if any cap exceeded
- Pause circuit breaker: deposits and withdrawals blocked, staking continues
- Admin: 2-of-3 multi-sig (V1), governance + 48h timelock (V2)
- V1 contracts are immutable. Upgrades require redeployment + migration

---

## License

Apache 2.0 — see [LICENSE](./LICENSE)

All Soroban contracts are open-sourced under Apache 2.0 from day one. Contracts currently deployed on Stellar Testnet are available for public review now.

---

## Links

- App: [app.agama.finance/stellar](https://app.agama.finance/stellar)
- X: [@agamafinance](https://x.com/agamafinance)
- Technical Architecture: [PDF](https://docs.google.com/document/d/1E69_kfNsJBzwBaydMRedyGqN1AGm4elk-xlMbhsQQUM)
