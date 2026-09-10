# The pending unstake record, findings before any code changed

## S1. A pending unstake is given under six hours of life and nothing can extend it. HIGH.

`request_unstake` burns the shares, takes the assets out of `nav`, and writes a
`Pending` record. That record is the only thing that says the agUSD is owed to
anybody: the shares are gone and the assets are out of the share price, so if
the record goes, the money belongs to nobody and sits in the contract.

It is written with `set` and nothing else. Measured off the ledger entry in the
test harness, that gives it **4095 ledgers**, which at five seconds a ledger is
about five and three quarter hours.

The Vault carries the same kind of record and treats it completely differently:

| | Vault claim | Staking pending unstake |
|---|---|---|
| TTL on write | `CLAIM_BUMP`, 90 days | whatever `set` gives, 4095 ledgers |
| Extended when written | yes, `write_claim` | no |
| Permissionless keeper call | `bump_claim`, anyone can call | none |

That difference is not an accident of style. The second adversarial review found
that an archived claim record takes `claim_withdrawal` and `settle_withdrawal`
with it and stops the queue at the head until somebody pays for a
`RestoreFootprint`, and `bump_claim` exists because of it. The Vault's own module
doc states the behaviour in those words. Staking has the same shape of record,
holding the same kind of user money, and got neither half of the fix.

What makes it worse here rather than better is that a cooldown is a period the
user is *told to go away for*. A claim on the Vault is payable as soon as the
queue reaches it, so a user watching for it has a reason to come back. An
unstaker is told to come back later by construction.

**What is established and what is not.** The 4095 figure is measured. The
consequence is not demonstrated by a test in this repository, because
`Env::default()` does not evict entries as the sequence advances, so a test can
show the TTL running down but not the archival itself. The behaviour on archival
is Soroban's, and it is the behaviour this repository already documents in the
Vault for the identical case. Saying that plainly is better than dressing a
reasoned conclusion up as a measured one.

Recoverable rather than lost: a `RestoreFootprint` brings the entry back. The
finding is that the protocol closed exactly this gap once, deliberately, and left
the other instance of it open.

## S2. There is no keeper entry point at all on staking. Part of the same fix.

`bump_claim` is permissionless on the Vault, and the reason given is that a claim
waiting on liquidity is a claim nothing writes to, so nothing extends it. A
pending unstake waiting out a cooldown is in exactly that position. Without a
bump, the only way to refresh the record is to call `request_unstake` again,
which requires shares the user has already burned.
