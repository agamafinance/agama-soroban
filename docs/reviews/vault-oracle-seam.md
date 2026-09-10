# The Vault's oracle seam, findings written before any code changed

Severities fixed here, before the cost of fixing is known. Same discipline the
three adversarial reviews used, and for the same reason.

## V1. `set_oracle` interrogates nothing. MEDIUM.

Every other counterparty pointer on the Vault is interrogated before it is
accepted:

| Setter | What it proves about the incoming address |
|---|---|
| `set_agusd` | answers `minter()`, and answers with this Vault |
| `set_engine` | answers `vault()` with this Vault, and `total_allocated()` with 0 |
| `set_oracle` | **nothing at all** |

`set_oracle(admin, oracle, feed_id)` writes both `Cfg::Oracle` and
`Cfg::OracleFeed` after checking only that the caller is the admin. The address
need not be a contract. If it is a contract it need not be an oracle. If it is
an oracle it need not have heard of `feed_id`. Nothing notices until somebody
calls `get_nav()`, and the two failures do not look alike: a feed the oracle
does not know is a legible refusal, and an address that is not an oracle traps
the invocation.

Worse than either is the case that does not fail: a *valid* oracle with a
*registered* feed that is simply the wrong one. `set_oracle(admin, oracle,
EF_BOND)` on a Vault whose book is private credit is accepted, and from then on
the Vault reports the Etherfuse bond price as its NAV, correctly and quietly.

Medium rather than High because nothing on-chain consumes it: agUSD redeems one
for one, the withdrawal queue pays claim amounts, and the reserve floor is a
share of `floor_base`, which is built from the Vault's own books. `get_nav()` is
a reporting view. It is the view the application and any integrator read, which
is where the harm is.

## V2. Neither half of the pair can be read back. LOW, and it is what hid V1.

`admin()`, `usdc()`, `agusd()` and `allocation_engine()` are all public. `Cfg::Oracle`
and `Cfg::OracleFeed` have no getter, so the only way to find out what the Vault
is pointed at is to call `get_nav()` and infer it from the number, which is
exactly the inference V1 makes unreliable.

This is not theoretical. Repointing the Vault at the replacement Oracle Adapter
earlier today could not be verified by reading the pointer back, and the deploy
script had to say so in a comment instead.

## V3. `get_nav` propagates a raw sub-call error. WITHDRAWN.

Written up as a Low on the claim that the Vault "has `OracleStale` in its error
enum for this and never returns it". That claim is false: the Vault's enum has
`OracleNotConfigured` and nothing else about oracles. `OracleStale` is 511 on the
Oracle Adapter.

Following it through changed the conclusion rather than the wording. Calling
`get_nav` without `try_` is what lets the Oracle Adapter's own codes reach the
caller: 504 for a feed it does not know, 511 for one past its staleness window,
512 for one that has never reported. Translating those into a single Vault error
would replace three distinct facts with one, which is a loss and not a fix, and
the documentation already describes the propagated codes and gets them right.

So the behaviour stands, with the reasoning written into the call so the next
person does not re-derive it. What was genuinely wrong here is smaller: the API
page types `get_nav()` as returning a `VaultError` when the error it surfaces is
an `OracleError`. Corrected there.

Recorded rather than deleted, because a findings list that only contains the
findings that survived is a list you cannot check.

## Not findings

`set_oracle` has no state guard, unlike `set_agusd`, which closes once deposits
exist. That is correct and should stay: the pointer is display-only, an oracle
that has to be replaced during an incident is exactly when repointing matters,
and freezing it would be freezing the repair.
