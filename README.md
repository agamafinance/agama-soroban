# Agama Finance Soroban Contracts

Private Credit Yield Vaults on Stellar · **[Try the app](https://app.agama.finance/stellar)**

Users deposit USDC into curated vaults and receive **agUSD**, a composable synthetic dollar backed by diversified real-world credit pools. Staking agUSD produces **sagUSD**, a yield-bearing token that appreciates as private credit repayments and on-chain strategies generate returns.

All contracts are written in Rust for the Soroban smart contract platform.

## Architecture

![Agama on Stellar](docs/architecture.png)

Entry ramps, the dApp, the Soroban contract set, allocation targets, the oracle feeds and the off-chain indexer. Source: [`docs/architecture.svg`](docs/architecture.svg). The same diagram is a Mermaid flowchart in [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md), alongside the full technical architecture.

## Live on Testnet

Network: **Stellar Testnet** · RPC: `https://soroban-testnet.stellar.org`

**[Test the app at app.agama.finance/stellar](https://app.agama.finance/stellar)**

### Core Contracts

| Contract | Address |
|---|---|
| USDC (Circle) | [`CBIELTK6...XQDAMA`](https://stellar.expert/explorer/testnet/contract/CBIELTK6YBZJU5UP2WWQEUCYKLPU6AUNZ2BQ4WWFEIE3USCIHMXQDAMA) |
| agUSD | [`CCW763RT...U4ALZL`](https://stellar.expert/explorer/testnet/contract/CCW763RTVRDQTEEQ42XCAARSJ42AKWRB2DDM62QV4XVUJFCDAWU4ALZL) |
| sagUSD | [`CCBEDKRQ...L6HFO2`](https://stellar.expert/explorer/testnet/contract/CCBEDKRQHKAP2W3NC4UIYC4WZSMJVYRXN6EQERHFII45M3PD4JL6HFO2) |
| Vault Contract | [`CCGPF36P...F5KVRR`](https://stellar.expert/explorer/testnet/contract/CCGPF36PDG2WBBK6ZROLMNMHD67UV4MNG6PHQCN2PXWLLRBXCYF5KVRR) |
| Allocation Engine | [`CAFJKWLU...SZ5HUX`](https://stellar.expert/explorer/testnet/contract/CAFJKWLUGUSYEC7L5ZBNFIFEPSO5MLI7SKDMVVJCGC6Z2TGVP5SZ5HUX) |
| Oracle Adapter | [`CDV5BC4X...XCSV7G`](https://stellar.expert/explorer/testnet/contract/CDV5BC4XCNT5ASOZNFXBQXRGKVXGKHLRVK5EDX6XP5J6EBIZWSXCSV7G) |

### Pool Adapters

| Adapter | Originator | Jurisdiction | Address |
|---|---|---|---|
| Private Credit | QIRO | LU | [`CBAPY7KR...ZGFTOZ`](https://stellar.expert/explorer/testnet/contract/CBAPY7KRVIG3FPGSP3VKXXA6SCDKZUWBSFDWISRJXR5V7PYPVQZGFTOZ) |
| Etherfuse | ETHERFUS | MX | [`CBA3GQLH...AH7EWI`](https://stellar.expert/explorer/testnet/contract/CBA3GQLHCEOCCZIDVFZ74AG4FUCEO2SN7AMGY4RSAMN4DTHW2WAH7EWI) |

Both adapters are registered with the Allocation Engine. `originator` and
`jurisdiction` are the buckets the concentration caps aggregate over, so two
pools fronted by the same counterparty count as one position.

### Superseded Contracts

Every address that has ever been live stays in this table and in
[`deployments/testnet.json`](deployments/testnet.json), with the reason it was
replaced. None of them is deleted, and none of them is quietly reused.

| Contract | Address | Why it was replaced |
|---|---|---|
| agUSD (`contracts/agusd`), first deployment | [`CCXEP6QA...HNQ6H3`](https://stellar.expert/explorer/testnet/contract/CCXEP6QAAYEMFMV2JGBULD2NS6AQB6KQSBHLPPBJSDBCN6HOYIHNQ6H3) | A self contained vault rather than a plain token: it mints only inside its own `deposit()` and exposes no `mint`, so the Vault Contract could never mint against a deposit. Still deployed, still held, and left exactly as it is. |
| Vault Contract, first deployment | [`CAVKHGBQ...5OFJW3`](https://stellar.expert/explorer/testnet/contract/CAVKHGBQUEPVTWHFJGU42ZVZA6VZSM6RZXFHCUXTT72JFRWNPF5OFJW3) | Wired to that token at `initialize()` with no setter and no upgrade path, so its `deposit()` could never mint. |
| Vault Contract, second deployment | [`CDQP7L5R...TR3KS4`](https://stellar.expert/explorer/testnet/contract/CDQP7L5RZ6AM4J2PZETMG7TC4M3CDTVQ6QAMYPLG43Z6GAOCB4TR3KS4) | Initialized with the first Allocation Engine as its allocation counterparty, and `settle_allocation` authorizes that address and no other. That Engine governs a different Vault, so this one could take deposits and pay its queue and never release a dollar to a pool. It carries `set_agusd` but not `set_engine`, so the pointer that mattered could not be corrected. |
| agUSD (`contracts/agusd-core`), first deployment | [`CCFICOHA...6H54WV`](https://stellar.expert/explorer/testnet/contract/CCFICOHAC4V6M5CDI62O5SWCZR43XG6JXNYFBZ4HAVQJBUCR4V6H54WV) | Names the second Vault as its only minter and has no `set_minter`, so issuance could not follow the Vault to its replacement. Retired at a zero supply. |
| Allocation Engine, first deployment | [`CANDJEHB...SL2SGS`](https://stellar.expert/explorer/testnet/contract/CANDJEHBZUPGBWQMWM567Z3NQR4AHJKJSMWB4LTXPT6SC7GSRKSL2SGS) | Stores the Vault it governs at `initialize()` with no setter, and that Vault had been superseded, so every cap it enforced was measured against a balance sheet nobody was depositing into. |
| Private credit adapter, first deployment | [`CCDZRKZD...CXT3VZ`](https://stellar.expert/explorer/testnet/contract/CCDZRKZDCWJWTFMLVJFW4LRALZEWRDKWOOD727EDO3EFFKLNDKCXT3VZ) | Stores both the Engine and the Vault at `initialize()` with no setters, and both addresses had been superseded. |
| Etherfuse adapter, first deployment | [`CBS3OGCV...KFLYKK`](https://stellar.expert/explorer/testnet/contract/CBS3OGCVYMI3XQN2ORZZNE2WKGYK24VSTVDUB3QS5HCZHBQQFWKFLYKK) | Stores both the Engine and the Vault at `initialize()` with no setters, and both addresses had been superseded. |
| sagUSD staking, first deployment | [`CABPYD4U...2XTALX`](https://stellar.expert/explorer/testnet/contract/CABPYD4U5FAYLBEBMY2MVGVF7BILXTNPWGLOPIXCMUK3QQGIAE2XTALX) | Accepts the first generation agUSD, stores it at `initialize()` with no setter, and has no re-initialization guard. Anyone can call its `initialize` a second time and take it over, so the 49.19 agUSD it still custodies should be treated as at risk; that is one of the reasons it is superseded rather than a footnote to it. |
| Vault Contract, third deployment | [`CAU54R4P...A33AFY`](https://stellar.expert/explorer/testnet/contract/CAU54R4PIHZXGCRZMJJCCIOFNMVXZHZF6BBNNSGWJT6A4UZ32MA33AFY) | Replaced within the day, after review of this branch. Its `set_engine` accepted any address, including an ordinary account, which made the pointer that releases the Vault's reserves a one call instruction to hand them over. |
| agUSD (`contracts/agusd-core`), second deployment | [`CD6OX76F...2TGYSK`](https://stellar.expert/explorer/testnet/contract/CD6OX76FZ54SNOKNR4D3JLHTVS5IO3TNVBE4WSSLR4DIS5VW3O2TGYSK) | Replaced with the Vault that mints it, since a token freezes its minter and cannot follow one. Retired at a zero supply, redeemed through its own Vault first. |
| Allocation Engine, second deployment | [`CBCLMUK4...HEAMKE`](https://stellar.expert/explorer/testnet/contract/CBCLMUK4R2CW3YVCX3OQ3GMGAXUNKA6JQWXH2AG3JW7U35FBNFHEAMKE) | Replaced with the Vault it governs. Its own guards were sound; it is here because the stack moved. |
| Private credit adapter, second deployment | [`CDKLN4NB...2RSMEV`](https://stellar.expert/explorer/testnet/contract/CDKLN4NBLLHYUOQEDLSKWM6BI7HSN4NL3W5B2MB4DUAPJG4IKA2RSMEV) | Replaced within the day, after review. Its Engine and Vault pointers moved independently and the emptiness check was retrospective only, so a repointed Vault would have misdirected repayments one allocation later. |
| Etherfuse adapter, second deployment | [`CCFYYCIH...2H6KGO`](https://stellar.expert/explorer/testnet/contract/CCFYYCIHEKQLFN5TZKGFBW3GAH6SBXA7YEWMETTR62TWPEC43X2H6KGO) | Replaced within the day, after review. Its Engine and Vault pointers moved independently and the emptiness check was retrospective only, so a repointed Vault would have misdirected repayments one allocation later. |
| sagUSD staking, second deployment | [`CDY3ED6T...BTC345`](https://stellar.expert/explorer/testnet/contract/CDY3ED6T72VJDX5RCMQOZNCV5XKJBHQVAYPNOXTWB66RNBVOS5BTC345) | Replaced within the day, after review. Its `set_agusd` keyed off the stake counter alone, and `accrue_yield` takes custody without touching it. |
| sagUSD staking, third deployment | [`CBMEW3QA...WFTHZF`](https://stellar.expert/explorer/testnet/contract/CBMEW3QALCS6FFJMK5FR7LVKUWX3MPIP26LQQQAFYMQFYVG6VUWFTHZF) | Exposes `accrue_yield` and `share_price`, the names this contract shipped with, rather than `distribute_yield` and `exchange_rate`, the names Agama committed to in its answer to the SCF panel. A wallet looking for the committed convention did not find it here. Superseded holding nothing: NAV and share supply were both zero at handover, so it strands no staker. |

One missing setter cost six contracts. The Engine could not follow its Vault,
the Vault could not follow its Engine, the token could not follow the Vault
that mints it, the adapters could not follow either, and sagUSD could not
follow the token. Every replacement carries the setter it was missing, each of
them admin gated and each closed once the contract holds state the move would
invalidate. USDC, the Oracle Adapter and the six credit vaults were not
redeployed: the Oracle Adapter binds no Vault and no Engine, so it was never
part of the problem.

**One thing is left behind.** 1.2 USDC of working capital sits in the first
Vault Contract. It was never minted against, so no agUSD claims it, and the
only path out of that Vault is its withdrawal queue, which burns first
generation agUSD. Recovering it would mean reducing the supply of a token that
is deployed, held by other people and deliberately left untouched, for 1.2 USDC
of testnet float. It stays where it is, and it is recorded here rather than
netted out of a balance somewhere.

### Deployed Configuration

The Allocation Engine ships fail closed, every cap at zero and the reserve
floor at 100%, so these are the values it was opened up to. They are recorded
in [`deployments/testnet.json`](deployments/testnet.json) and are readable
on-chain through `caps()` and `reserve_floor_bps()`.

| Limit | Value | Previously |
|---|---|---|
| Per-pool cap | 4000 bps (40%) | 3000 bps |
| Per-originator cap | 4500 bps (45%) | 4000 bps |
| Per-jurisdiction cap | 5000 bps (50%) | unchanged |
| Idle USDC reserve floor | 2500 bps (25%) | 2000 bps |

The caps moved because the old set could not both matter. Two pools capped at
30% can deploy at most 60% of the book, so 40% stays idle whatever the operator
does and a 20% floor is arithmetically unreachable: the per-pool cap fires
first, every time, and the floor is a guard that passes its own unit test and
never refuses anything on-chain.

A floor binds only when the registered pool caps sum to more than it is willing
to release. Two pools at 40% can absorb 80% of the book; the floor releases
75%; the last 5% belongs to the floor alone. Filling private credit to its 40%
cap and Etherfuse to 35% lands idle reserves exactly on the floor, and 500 bps
more into Etherfuse is inside its own cap, inside the global pool cap, inside
the originator cap and inside the jurisdiction cap, and is still refused. That
state is reached by ordinary allocations, it is a unit test, and it was
executed and refused on testnet in the run below.

The caps stay nested, pool under originator under jurisdiction, so the per-pool
limit remains the tightest concentration constraint.

Which means, said plainly: with the two pools registered today the originator
and jurisdiction caps cannot bind either. Each pool has an originator and a
jurisdiction of its own, and the 40% per-pool cap is strictly tighter than both,
so neither aggregate limit can be the one that refuses an allocation until a
second Qiro pool or a second Luxembourg pool is registered. That is the same
critique that motivated moving the reserve floor, and it applies to two of the
four limits. It is left as it is rather than papered over, because the aggregate
caps exist for the book the protocol is being built towards rather than the two
pools it has today, and a cap that binds only when a third pool arrives is
honest as long as nobody claims otherwise.

The Oracle Adapter carries the three feeds documented below, each registered
with its own staleness window and deviation bound, and the admin address as the
sole authorized reporter. The Vault reads NAV from `PC_NAV`.

### The Whole Journey, On-Chain

`scripts/smoke-journey.sh` runs the complete user path against the live
deployment with real Circle USDC, in one reproducible script, with 54
assertions. From the run of 8 September 2026:

| Step | What it proves | Transaction |
|---|---|---|
| Deposit | 2 USDC in, 2 agUSD minted 1:1 | [`735c1403`](https://stellar.expert/explorer/testnet/tx/735c1403183abd120c301d3fce8a412ff9289787337f9aa257bbad0badd1f1e6) |
| Stake | 1 agUSD staked, sagUSD issued at a share price of 1.0 | [`e921a1bf`](https://stellar.expert/explorer/testnet/tx/e921a1bf984ed2cd1c626f9164bf5b42d8e9871d2f0ff509a5f1d62eeb7ddd66) |
| Allocate | 4000 bps into private credit, the Vault releases and the adapter books it | [`d0347f1f`](https://stellar.expert/explorer/testnet/tx/d0347f1f968e53f7639c8e92c115839e6c0428cb76987571581669745a193385) |
| NAV | A 1% revaluation pushed on `PC_NAV`, read back through the Vault | [`1f946a98`](https://stellar.expert/explorer/testnet/tx/1f946a98587c3099611c1e582b8de4cc8a67e47b876f82d3476b55bc5c01bf36) |
| Yield | Yield delivered, sagUSD share price rises to 1.1, no shares minted | [`609a6ffc`](https://stellar.expert/explorer/testnet/tx/609a6ffcc2925979672ade3d725b74189524f74528c0c10a0c6db025f30d6ed0) |
| Allocate | 3500 bps into Etherfuse, landing idle reserves exactly on the floor | [`36ce0dba`](https://stellar.expert/explorer/testnet/tx/36ce0dba3789ecca34a624f09c5ca476d3858cee88685ae26f97260608df0173) |
| Unstake | Shares burned at request, the appreciated position locked behind the cooldown | [`e2571d0b`](https://stellar.expert/explorer/testnet/tx/e2571d0bd62ed52fa3c78004554b760ebbaf066735182cba9d38ecbcd76b877e) |
| Unstake claim | 1.1 agUSD returned for 1.0 staked, after the cooldown | [`70678eb4`](https://stellar.expert/explorer/testnet/tx/70678eb46029a2d82ebc8d3e548c9e570b3ce060629e38740231ad71ae1daf13) |
| Withdrawal request | agUSD burned at request time, claim queued and not yet payable | [`7a2b6048`](https://stellar.expert/explorer/testnet/tx/7a2b6048eab3e99251de1072ed1e46c1920cd97dfec121edad64c3c456800f4f) |
| Deallocate | Capital returns from Etherfuse and the claim becomes payable | [`74488e22`](https://stellar.expert/explorer/testnet/tx/74488e2231ae647c7970f78491e73a78014d1be7e52eca9f25b3e2bbc1eb5253) |
| Withdrawal claim | Claim paid, USDC back to the holder, queue empty | [`6bf56410`](https://stellar.expert/explorer/testnet/tx/6bf56410af8e0ba513e0d2708620ad90b40d5fbaab548d93a48ca801520bdf85) |
| Unwind | Private credit repaid, the book back to 100% reserves | [`26016d59`](https://stellar.expert/explorer/testnet/tx/26016d596f766e1728a97f99dea7ae421f05f59849510bb3b9fca2c3dbdfd850) |

And the four refusals, each one a failed transaction on the ledger rather than a
claim in a log:

| Refusal | Ledger record | Transaction |
|---|---|---|
| A caller that is not the Vault cannot mint agUSD | authorization failure | [`6cd17ab3`](https://stellar.expert/explorer/testnet/tx/6cd17ab3982105278b25e05f60aa028e147c6243dfcee0a009e2d0b20fa7ea9c) |
| A caller that is not the Engine cannot release the Vault's USDC | authorization failure | [`f7cba464`](https://stellar.expert/explorer/testnet/tx/f7cba464fb723180a7fd0a7f1e37fb035161094c81ef45434367b259f575fd0e) |
| An allocation of 4250 bps into a pool capped at 4000 is refused | contract error 407, `PoolCapExceeded` | [`7861c0d8`](https://stellar.expert/explorer/testnet/tx/7861c0d87aff15e9aaeb7f73f8cf1d9ac23a5db1fb1789d2d415c8bd294f318c) |
| An allocation inside every cap that would breach the reserve floor is refused | contract error 410, `ReserveFloorBreached` | [`30c6bfa7`](https://stellar.expert/explorer/testnet/tx/30c6bfa747008f7c2662c047f1eaf3a925fabcdae24fac56389af96109b0cfbb) |

All four were submitted, not simulated, and the script reads the failure reason
back off the ledger before it calls any of them passed. Simulation records
authorization instead of enforcing it, so the first two only fail for real when
they apply. The last two fail during simulation, which is why the Stellar CLI
would never send them: [`scripts/tx-patch.py`](scripts/tx-patch.py) takes a
transaction the CLI did prepare, for a smaller allocation that simulates
cleanly, and rewrites the amount in the operation and in its matching
authorization entry. The footprint stays valid because a refused allocation
reads the same ledger entries and writes none of them.

### The DeFindex Naming, On-Chain

sagUSD was redeployed on 9 September 2026 so that the contract on the ledger
carries the names Agama committed to. `scripts/deploy-sagusd.sh` deploys and
wires it, checking the deployed WASM's own interface rather than the source
tree, because a wallet reads the former. `scripts/smoke-sagusd.sh` then proves
the yield path against it with 26 assertions, every state change submitted:

| Step | What it proves | Transaction |
|---|---|---|
| Deploy | sagUSD deployed and initialized on the live agUSD, at an exchange rate of 1.0 | [`d88f8144`](https://stellar.expert/explorer/testnet/tx/d88f8144f738e4c62829668367c55cd7160dbc824ed7b523517bc4ebf996a2de) |
| Stake | 1 agUSD staked, shares issued at the rate that was showing, custody moved | [`11844e00`](https://stellar.expert/explorer/testnet/tx/11844e006fd8cf70a971675f7c15cd060443b286d7e6d5b11c3c2f6c8ae9c7e3) |
| `distribute_yield` | 0.1 agUSD delivered under the committed name; NAV and `exchange_rate()` rise from 1.0 to 1.1, no share minted, no balance changed | [`3cf2744d`](https://stellar.expert/explorer/testnet/tx/3cf2744d641a3c0aa2277ac6a77d565833c6b411a0845bb7bde7a1df88796008) |
| Unstake request | Shares burned at request time and the appreciated 1.1 agUSD locked behind the 60s cooldown | [`955c4dd3`](https://stellar.expert/explorer/testnet/tx/955c4dd37454c2f69ae5e14de5e065b49d2399be134605cafa7b0a237ae4d66a) |
| Unstake claim | 1.1 agUSD returned for 1.0 staked, after the cooldown; the contract back to holding nothing | [`b6985d62`](https://stellar.expert/explorer/testnet/tx/b6985d626cf0b9337b8f63583c8bed8abf7b06f97698eadac2f3387eca9efde1) |

The smoke script also reads the deployed interface back off the network and
asserts that `distribute_yield` and `exchange_rate` are on it, that
`accrue_yield` is not, and that `share_price()` returns the same number as
`exchange_rate()` at every point where the two could differ. The claim being
checked is about what the contract publishes, so it is checked against what the
contract publishes.

Nothing else was redeployed. sagUSD is a leaf: no other contract in the stack
stores its address, so replacing it strands no pointer, which is why this was a
one contract deployment where the rewire below was a six contract one. The
`Stake`, `Yield` and `Unstake` rows in the journey table above were run against
the superseded sagUSD and remain on the ledger as a record of it.

### The Rewire Itself

Each contract was deliberately initialized against the superseded counterpart it
would have been stuck to, and then corrected. That is on purpose: it puts every
setter on the ledger, applied to the exact address that caused the incident, at
a moment when its guard still permitted the move. The recovery path is a
transaction hash rather than a paragraph.

| Setter | What it corrected | Transaction |
|---|---|---|
| `AgUsdCore::set_minter` | Issuance moved from the superseded Vault to the new one, at a zero supply | [`db46e40e`](https://stellar.expert/explorer/testnet/tx/db46e40e5083632c3a190c4745c196b5eefd1e29ce9cb00dab776c9589538288) |
| `AllocationEngine::set_vault` | The Engine repointed at the Vault it actually governs, with an empty book | [`7e0e51c2`](https://stellar.expert/explorer/testnet/tx/7e0e51c2584f0ff26e35092c1e89500c9126d054e20e4e35c05fb44d504180d9) |
| `Vault::set_agusd` | The Vault repointed at the new agUSD, before its first deposit | [`3f5bcd0e`](https://stellar.expert/explorer/testnet/tx/3f5bcd0eea01c39ab5524172921329ab7f5fc2041c72f2d31d7ea9a3d10a2346) |
| `Vault::set_engine` | The Vault repointed away from an Engine that governs a different Vault, onto one that names it back | [`111faa6d`](https://stellar.expert/explorer/testnet/tx/111faa6d95faed454a06d02931acc647fddb660e896b848e83e6811fd70d9673) |
| `PrivateCreditAdapter::set_counterparties` | Engine and Vault moved together, holding nothing | [`4ba96771`](https://stellar.expert/explorer/testnet/tx/4ba96771fb7006256d93fbfa7712648e7d0af55c1fc5b7664351f80c0ca4b84a) |
| `EtherfuseAdapter::set_counterparties` | Engine and Vault moved together, holding nothing | [`e014feb2`](https://stellar.expert/explorer/testnet/tx/e014feb2c271b2dc7dc36b908f9a0aa99316d3eb4814b1759be49a08409bd541) |
| `Staking::set_agusd` | sagUSD repointed at the agUSD the protocol issues, before its first stake | [`36ee7f08`](https://stellar.expert/explorer/testnet/tx/36ee7f080531d437f97b15c76f28d1cd47c8646114e8de48fdc134246b410986) |

`Vault::set_engine` is where the guards meet. It was applied while the Vault was
pointed at an Engine with a live, non-empty exposure book, every stroop of which
had been funded by a different Vault: a guard that only asked whether the Engine
had capital deployed would have refused it, and refused it in precisely the case
the setter exists for, so the guard asks whose capital it is. And it refuses any
address that does not answer that it governs this Vault, which is why the Engine
had to be configured first and which is what stops the pointer that releases the
reserves being aimed at an ordinary account.

Each superseded generation was wound down before it was replaced rather than
abandoned. Every agUSD it had issued was redeemed to a zero supply through the
Vault that minted it, so no token is retired holding somebody's claim
([`96a43e4b`](https://stellar.expert/explorer/testnet/tx/96a43e4ba6733107b1d35a37f323d17169294664f3a2652ca6646d4efc6ad7c6),
[`44d95d66`](https://stellar.expert/explorer/testnet/tx/44d95d662d26314ab6c5bf4d473e3486ea1d6ef979055171f1c58ff2bc2addc8)
for the first, and
[`355f3b49`](https://stellar.expert/explorer/testnet/tx/355f3b4975c4f20d5a598881daca64a3417bc075d9618282bfd673201ba053d4),
[`880d91da`](https://stellar.expert/explorer/testnet/tx/880d91da2605472a1f1f2eb71b72e58a6b51027a6aeba93d6d60b826e269c6ac)
for the second). The first Engine's book was unwound to zero
([`7390dc2e`](https://stellar.expert/explorer/testnet/tx/7390dc2e93b0d5e2fba93f7c39956e7d644cad777fbf483627e33b190f0440ac)),
so nothing reads as deployed on a stack nobody drives.

**Why there are two of them.** The first rewire was reviewed before this branch
was merged, and the review found that its `Vault::set_engine` would accept any
address at all. That made the pointer which releases the Vault's reserves a one
call instruction to hand them to an ordinary account, and the pool adapters had
the mirror image: two independently settable pointers behind an emptiness check
that only looked backwards. The contracts were tightened and the stack was
redeployed the same day, before it held anything but the deploying admin's own
working capital. The addresses are in the table above with that reason next to
them, because a deployment that quietly replaces itself is exactly the habit
this branch exists to break.

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
│   └── testnet.json        Live addresses, engine configuration, and every
│                           address that has been superseded and why
└── scripts/                Deploy and test scripts
```

## Contracts

### agUSD (`contracts/agusd-core`) (deployed on testnet)

Composable synthetic dollar minted 1:1 against USDC deposits. Full [SEP-41](https://github.com/stellar/stellar-protocol/blob/master/ecosystem/sep-0041.md) token interface: `transfer`, `approve`, `transfer_from`, `balance`, `allowance`.

`mint` checks the minter address recorded at initialization, which is the Vault Contract, and nothing else. There is no admin mint and no pause that could create supply, so one agUSD in circulation means one USDC was deposited into the Vault, and an auditor can check that rather than take it on trust.

`set_minter` exists and freezes at the first mint. The earlier version had no setter at all, on the argument that an admin who can rotate the minter can point it at itself and print. That is true of a token with a book and false of a token with no supply, and paying for it cost a token migration when the Vault named at initialization turned out to be unusable. So the guard is the mint counter: zero mints and the minter is configuration, one mint and it is frozen for the life of the contract, readable in one call as `mints()`. Burning the supply back to zero does not reopen it, because having issued is not the same as holding.

Be precise about what that rules out. It does not stop an admin naming itself minter and printing, because the two conditions are sequential and both hold at a zero supply. It stops doing that to a token anybody is holding, and it stops doing it quietly: every rotation emits `MinterSet`. And which token is the protocol's agUSD is decided by the Vault that names it and by the deployment record, both public, so a token whose `minter()` is not the Vault above is not this protocol's agUSD, and an admin who wanted one could always have deployed it.

`burn` and `burn_from` stay on the standard SEP-41 semantics, authorized by the holder. That is what the Vault's `request_withdrawal` calls, and restricting the burn path would buy nothing: destroying your own balance harms nobody else. Supply goes up only through the Vault and down only through the holder.

### agUSD generation 1 (`contracts/agusd`) (deployed on testnet, superseded)

The first agUSD is not a plain token, it is a self contained vault: it takes the USDC in, mints against it, keeps a `buffer_bps` liquidity buffer for instant redemption and pushes the excess into the credit vaults at the Allocation Engine's target weights, inside the same deposit call. Custody, routing and issuance all live in one contract, which is why it exposes no `mint` for the Vault Contract to call.

It is left exactly as it is rather than rewritten underneath the people holding it. It stays deployed and it keeps its holders. It was also, until the rewire, the only token the deployed sagUSD staking contract would accept, because that contract stored its token address at initialization and had no setter.

### sagUSD (`contracts/staking`) (deployed on testnet)

Yield-bearing staked agUSD. Share-based vault accounting: yield accrues by increasing the sagUSD/agUSD exchange rate through `distribute_yield()`, which moves real agUSD into the contract, so there is nothing to claim and no rebasing. Two-step unstake, `request_unstake()` then `claim()`, with a configurable cooldown; the shares are burned and priced at request time, so the cooldown is not a free option on the rate.

**The committed naming convention.** Agama's answer to the SCF panel says sagUSD adopts the `distribute_yield` / assets-per-share convention, and that this is an interface compatibility rather than a protocol-level integration. The contract now honours that: `distribute_yield()` is the entry point that raises assets-per-share, and `exchange_rate()` is the view that reports it. It previously exposed `accrue_yield()` and `share_price()` and so did not, which is why the deployed sagUSD was replaced rather than the sentence edited.

`share_price()` is kept as an alias of `exchange_rate()`, returning the same number from the same computation. It has a live on-chain caller: the generation 1 agUSD prices its positions in the six credit vaults through `share_price`, and those vaults are instances of this contract. Dropping the name would break a caller for no gain, since nothing looking for `exchange_rate` cares that a second name also answers. The yield entry point was a hard rename instead, because it has no on-chain caller anywhere in this workspace and two ways to move real money into a contract is one more than an auditor should have to check.

One correction, recorded because the claim is checkable and this repository is going to audit. DeFindex's own vault publishes neither of these names. Its interface is multi-asset (`fetch_total_managed_funds`, `get_asset_amounts_per_shares`, `distribute_fees`, and strategy-level `harvest`), it exposes no scalar price-per-share getter at all, and it has no vault-level yield distribution entry point. So this is a naming convention Agama has adopted on its own side, matching DeFindex's economics — shares are never rebased, nothing is pushed to holders, a position appreciates because the assets behind each share grow — and not call compatibility with a DeFindex vault. It should not be described as the latter.

`set_agusd` repoints the token this contract accepts and closes the moment it has taken custody of anything: a stake counter rather than the share supply, because a position that has been fully unstaked is not the same as one that never existed and the pending unstake queue can outlive the shares that created it, plus the NAV and the balance, because `distribute_yield` takes custody without going near the counter.

`initialize` now refuses a second call, which the deployed generation did not: a second call could name a new admin, repoint the staked asset and reset the NAV, which is the denominator every share is redeemed against. That guard stops a stranger. It does not stop the admin, who keeps `report_nav` and can still overwrite that denominator, and it is not offered as doing so; `report_nav` is there for demo and reconciliation, and `distribute_yield`, which moves real agUSD and cannot overstate the book, is the path that should be used.

### Vault Contract (`contracts/vault`) (deployed on testnet)

USDC entry point. Accepts deposits, mints agUSD 1:1, routes capital through the Allocation Engine, and manages a two-step FIFO withdrawal queue (`request_withdrawal` / `claim_withdrawal`). Queries Oracle Adapter for NAV. Includes a circuit-breaker (`set_paused`).

The queue is paid strictly in order and there is no admin path around it: `claim_withdrawal` refuses any claim that is not at the head. agUSD is burned when the withdrawal is requested, not when it is claimed, so a queued position cannot be sold or re-requested while it waits. A minimum withdrawal of 1 agUSD keeps dust requests from crowding the queue.

**Two pointers, two setters.** `initialize()` writes the agUSD address and the Allocation Engine address, the Vault is not upgradeable, and both of them used to be one way doors. Both have now been through one. The first Vault pointed at a token with no `mint` and could never issue agUSD. The second pointed at an Engine that governs a different Vault and could never release a dollar of capital, because `settle_allocation` authorizes the address `initialize()` wrote and nothing else. Each mistake cost a redeployment, and the second cost two contracts rather than one, because the token names the Vault as its only minter.

`set_agusd` and `set_engine` are that lesson. Both are admin gated and both close once the contract holds state the move would invalidate. For agUSD that line is the first deposit: repointing a Vault while agUSD is outstanding would leave holders backed by a token it no longer mints or burns. For the Engine it is an exposure book funded by this Vault, because the USDC behind it is out in the pool adapters and only the Engine that put it there can call it back. An Engine whose book belongs to a different Vault does not freeze the pointer, which matters, because that was exactly the state the live deployment was stuck in.

`set_engine` also refuses any address that does not answer that it governs this Vault. That check is not decoration. `settle_allocation` hands the reserves to whatever the pointer names and `require_auth` on an ordinary account is satisfied by that account's own signature, so without it the setter would be a one call instruction to release the Vault to the admin. With it, an account cannot be named at all, and neither can an Engine that governs somebody else. It does not make the admin harmless and it is not offered as doing so: see the Security section for what the admin can still do and what actually constrains it.

**Testnet status.** Deposit, mint, stake, allocate, NAV, yield, unstake, withdrawal request and claim all run on-chain against real Circle USDC, in one script with every transaction hash, listed under [The Whole Journey, On-Chain](#the-whole-journey-on-chain) above. The queue behaviour is worth singling out: the withdrawal claim is deliberately requested while capital is still deployed, so it sits at the head of the queue and reads `Pending` until a pool repays, then becomes `Ready` without anyone touching it.

### Allocation Engine (`contracts/allocation-engine`) (deployed on testnet)

Routes vault capital across registered pool adapters with on-chain concentration caps (per pool, per originator, per jurisdiction). All pool types implement a uniform adapter interface so the Engine stays agnostic to pool type. Admin-gated in V1, off-chain optimizer in V2.

A fourth guard, `set_reserve_floor`, holds a minimum share of total assets as idle USDC in the Vault. `allocate()` reverts if a call would push reserves below it, which is where fast-exit liquidity now lives. Caps and floor start fully closed at deployment, so an Engine that has not been configured cannot deploy capital.

Whether the floor can ever bind is a property of the configuration, not of the code, and the previous configuration got it wrong: two pools capped at 30% could deploy at most 60% of the book, so 40% stayed idle whatever the operator did and a 20% floor could never be the reason anything was refused. The deployed limits are now chosen so the registered pool caps sum to more than the floor will release, and the state where the floor is the only limit saying no is both a unit test and an on-chain transaction. See [Deployed Configuration](#deployed-configuration).

`set_vault` repoints the Engine and is refused while `total_allocated()` is non-zero. That is not ceremony: every cap and the floor are a ratio of booked exposure to total assets, and total assets are the Vault's idle USDC plus that exposure. Moving the Vault mid-book would put the numerator and the denominator on two different balance sheets, so the limits would still be computed and would no longer mean anything.

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

Only the Engine can move capital: there is no admin path that allocates or deallocates behind it, because that path would bypass every concentration cap and the reserve floor.

Both adapters carry `set_counterparties`, which moves the Engine and the Vault together in one call and refuses unless three things hold: the caller is the admin, the adapter is holding nothing (no booked exposure and no USDC), and the Engine offered says it governs the Vault offered. One call rather than two because the addresses are only meaningful as a pair, and an adapter halfway between two generations takes capital on one authority and returns it to another. The emptiness check alone would not be enough, because being empty today says nothing about tomorrow: repoint the Vault while empty, let the Engine allocate afterwards, and every repayment would go to the address that was written here while the Engine's book decremented all the same, with nothing reverting. The symmetry check is what closes that.

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

# Redeploy and rewire the whole stack: Vault, agUSD, Allocation Engine, both
# pool adapters and sagUSD, every one of them pointing at the others. Reuses
# the live USDC and Oracle Adapter, winds the superseded generation down to a
# zero supply and an empty book first, and writes the new addresses and the
# reason each old one was retired into deployments/testnet.json.
bash scripts/deploy-rewire.sh

# Run the complete user journey against that deployment with real Circle USDC:
# deposit, stake, allocate, NAV, yield, unstake, withdrawal request and claim,
# plus the four refusals, submitted rather than simulated
bash scripts/smoke-journey.sh

# Redeploy sagUSD alone, so the deployed contract carries the distribute_yield
# and exchange_rate names Agama committed to. Refuses to run if the contract it
# is retiring still owes a staker anything, and checks the names against the
# deployed WASM's interface rather than against the source tree.
bash scripts/deploy-sagusd.sh

# Prove the sagUSD yield path against that deployment: stake, distribute_yield
# raising the exchange rate, and the two step unstake through the cooldown
bash scripts/smoke-sagusd.sh

# Deploy the agUSD + sagUSD + credit vault set (already live on testnet)
cp .env.example .env
bash scripts/deploy.sh
```

`scripts/deploy-core.sh`, `scripts/deploy-agusd-core.sh`, `scripts/smoke-core.sh`
and `scripts/smoke-agusd-core.sh` are the earlier generation's scripts. They are
kept because the addresses and transactions they produced are still on the
ledger and still recorded, and each one now says so in its header.
`scripts/smoke-journey.sh` covers everything the two smoke scripts did, against
the current deployment.

## Roadmap

| Deliverable | Contracts | ETA | Status |
|---|---|---|---|
| Tranche 1, MVP | Vault, agUSD, sagUSD | November 2026 | Live on testnet, deposit, stake, yield and withdrawal all proven on-chain |
| Tranche 2, Testnet | Allocation Engine, Etherfuse and private credit adapters, Oracle Adapter | December 2026 | Live on testnet, delivered early, allocation and both guards proven on-chain |
| Tranche 3, Mainnet | All contracts, audit remediation | February 2027 | Pending |

## Ecosystem Integrations

From the [SCF Integration List](https://communityfund.stellar.org/integration-list):

| Protocol | Role |
|---|---|
| [DeFindex](https://defindex.io) | sagUSD assets-per-share accounting convention |
| [Soroswap](https://soroswap.finance) | agUSD/USDC and sagUSD/agUSD AMM pools |
| [Etherfuse](https://etherfuse.com) | Stellar-native government bond RWA collateral |
| [Reflector](https://reflector.network) | Decentralized XLM/USD and USDC/USD price feeds |

> **Revision, September 2026.** Blend v2 was previously an allocation target for idle capital and the instant-withdrawal liquidity buffer. It has been removed following the Comet BLND-USDC exploit and Blend's removal from the SCF Integration List. It is not replaced by another protocol: fast-exit liquidity is now a minimum idle USDC reserve floor enforced by the Allocation Engine, where `allocate()` reverts if a call would push vault reserves below the floor.

## Security

- `mint` restricted to the Vault Contract via `require_auth()`, with the minter frozen at the first mint: no admin mint, no rotation once supply exists, and burning left to the holder
- Every counterparty pointer that has caused an incident is now admin settable, and every one of those setters closes once the contract holds state the move would invalidate: the Vault's agUSD at its first deposit, the Vault's Engine once that Engine holds this Vault's capital, the Engine's Vault once its book is non-empty, an adapter's Engine and Vault once it holds exposure or USDC, sagUSD's agUSD once it has taken custody, and agUSD's minter at its first mint. Two stored addresses are not settable and are not claimed to be: the Vault's USDC, which has no setter at all, and the Vault's Oracle Adapter, whose setter never closes because a stale or wrong NAV feed is a reporting problem and not a custody one
- Every one of those setters emits an event, so a change to the highest-privilege state in the protocol is never a silent storage write
- The Vault's USDC leaves only through the Allocation Engine or a queued withdrawal claim
- **The admin is a trusted role in V1 and the contracts do not pretend otherwise.** The admin sets the Engine's caps and reserve floor and chooses which pools are registered, so an admin willing to register a pool it controls can move the Vault's capital to itself. No guard inside the Vault prevents that, by design: the Vault does not duplicate the Engine's limits, and duplicating them would mean two implementations that can disagree. What protects depositors from the admin is the 2-of-3 multi-signature admin in V1 and governance with a 48h timelock in V2, both below, not a check in a contract
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
- Technical Architecture: [Markdown](docs/ARCHITECTURE.md) · [PDF](docs/Agama_Technical_Architecture.pdf)
