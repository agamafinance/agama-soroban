# The counterparty, replicated

Agama's yield does not come from Stellar. Deposits land on Stellar, cross to an EVM chain by CCTP, and buy
shares in an off chain credit book run by an ABF partner. This directory is that partner's side of the trade,
rebuilt so the whole route can be driven end to end on a testnet.

It exists because there is nothing else to point at. The partner runs no testnet. What they supply is a
Polygon staging deployment handed over explicitly for fork testing, which is enough to prove our calldata is
accepted and not enough to run a crossing that starts on Stellar and comes back.

## What is faithful, and what is not

Every struct, enum, error selector, event and function signature in `src/IAbf*.sol` is copied from the
partner's published integration interfaces. So is the EIP-712 order typehash, character for character:

```
Order(uint8 orderType,address instrument,uint256 trancheId,uint256 amount,uint256 price,
address payer,address receiver,uint256 expiry,bytes32 salt)
```

That constant is the whole compatibility story. A signature over any other type string recovers a different
address and is simply invalid, so an integration that works against this engine is sending bytes the real one
accepts. `test_orderTypehashMatchesThePartners` pins it and the live deployment returns the same 32 bytes.

Three deliberate divergences, each written down rather than hidden:

| Divergence | Why |
| --- | --- |
| The asset is USDC, not Agora AUSD | CCTP delivers USDC. With USDC as the asset the bridged amount is depositable exactly as it arrives. An AUSD vault would need a USDC to AUSD swap, and that swap is the only step in the route where a keeper would have to touch a price. |
| Base Sepolia, not Ethereum Sepolia | Creation fails on Ethereum Sepolia and burns the whole gas limit. See below. |
| One key holds both sides | On a testnet there is nobody else to be the counterparty. In production settlement is theirs alone. |

Fees are carried and reported but charged on nothing, because the only path Agama uses is primary issuance at
NAV and there is no spread at NAV to take a cut of. That is what the partner's staging deployment did when
measured, so inventing a fee model here would be a worse lie than carrying the fields unused.

## The four closed doors, which are the entire architecture

`mint` and `withdraw` always revert. `deposit` and `redeem` are callable by the Matching Engine alone. No
amount of allowance or approval lets anybody enter or leave except through an order the partner's operator
settled. That is what makes a share a claim on a diligenced book rather than on a pool, and it is why Agama's
withdrawal queue burns agUSD at request time and pays from a position in line: settlement is not ours to
trigger, so cash on demand is a promise we could only keep by holding capital idle.

## Run

```sh
forge soldeer install   # restores dependencies/ from soldeer.lock
forge build
forge test              # 22 tests, no network needed
```

The suite holds the replica to the partner's measured behaviour, not just their signatures. The tests worth
reading first are the ones that assert outcomes nobody wants:

| Test | What it pins |
| --- | --- |
| `test_bidAboveNavPaysThePremiumToThePartnerTreasury` | A bid at 11111 bps fills 900000 USDC and sends 99990 to their treasury for no extra shares. This is the measurement that justifies pinning the keeper's order price to 10000 on both sides. |
| `test_revert_redeemBeforeTheYieldIsFunded` | A NAV the administrator raised is a claim, not cash. The vault refuses a redemption it cannot fund rather than paying part of it. |
| `test_returnFromFundMakesTheYieldPayable` | Cash back in and the book written down are two steps, and in between the vault counts the same money twice. |
| `test_revert_ownerAloneCannotSettleOrWriteNav` | `owner()` is set on every contract and grants nothing. The partner's own deployer still shows up as owner with every operator role revoked, and a fork test that impersonates it fails for a reason no error message gives. |
| `test_navGoesStaleAfterMoreThanOnePeriod` | Staleness is counted in periods, not seconds, so an age check in seconds reads as fresh through a period that has already lapsed. |

## Deployed

Base Sepolia, chain 84532. Addresses and the transactions that prove it in
[`deployments/base-sepolia.json`](deployments/base-sepolia.json).

Run live on 12 October 2026: 2 USDC crossed into 2000000 abfUSD-T through a posted BID settled at NAV, then
1.8 USDC moved to the fund administrator and the book reported at 1.9. The same 2000000 shares went from
being worth 2000000 to 2100000 with nothing minted or burned, which is what yield looks like here: the share
count is fixed and the valuation moves.

### Ethereum Sepolia does not accept contract creation

It was the first choice. Creation from the deployer fails and consumes the entire gas limit whatever that
limit is. Measured with a five byte initcode, `0x60016000f3`, a contract whose runtime is a single STOP, at
limits of 100k, 120k and 3M: each burned in full with status 0, across three endpoints that accepted the
send. The identical five bytes deploy on Base Sepolia for 53279 gas with status 1. The fault is that chain.

Base Sepolia costs nothing here: CCTP has it as domain 6, the Stellar TokenMessengerMinter has domain 6
registered as a remote with the same TokenMessengerV2 address it has for domain 0, and the inbound leg has
already been run live on it.

### Reads straight after writes are not trustworthy

`sepolia.base.org` load balances over several nodes, so a read in the call that follows a send can hit one
that has not caught up. In one session it reported zero shares against a vault whose `totalAssets` had
already moved, and `PRE_WINDOW` immediately after a toggle whose transaction had succeeded. Nothing was wrong
except the read. Take any assertion from two endpoints or after a wait.
