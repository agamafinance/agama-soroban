# The fiat ramp: SEP-10 and SEP-24 on testnet

Tranche 2, Deliverable 3 of the SCF #45 award, in its own words:

> SEP-10 authentication and SEP-24 interactive deposit and withdrawal flows
> completing end-to-end on Stellar Testnet against the MoneyGram Access
> sandbox, cash to USDC to agUSD and the reverse, **with the SDF Stellar Test
> Anchor covering the same flows during MoneyGram onboarding**

The emphasis is ours and it is the reason this points at
`testanchor.stellar.org`. The Stellar reviewer read the deliverable as
MoneyGram-only and said that substituting it needs a deliverable modification
first. That is the right rule, and it does not apply here: the record itself
names the SDF Test Anchor as what covers these flows while MoneyGram onboarding
is in progress. No substitution is being proposed. The anchor is one
`--home-domain` away, and nothing in `anchor/sep_client.py` is specific to the
SDF server.

The reviewer's other finding was exact: *"MoneyGram only appears in
architecture prose; there is no SEP-10/SEP-24 code in the repo."* There is now.

## What runs

```
bash scripts/e2e-anchor.sh
```

| Link | Who does it | State |
|---|---|---|
| SEP-1, read the anchor's `stellar.toml` | the client | **runs** |
| SEP-10, challenge, verify, sign, JWT | the client | **runs** |
| SEP-24, open an interactive deposit | the client | **runs** |
| the anchor's own KYC form | a person, in a webview | **done, in a browser** |
| SEP-24, poll to a terminal state | the client | **runs** |
| USDC to agUSD through `Vault::deposit` | the client | **runs** |
| agUSD to USDC through the withdrawal queue | the client | **runs** |
| USDC back out through SEP-24 withdraw, with the anchor's own account and memo | the client | **runs** |

The form is not a gap. "Interactive" in SEP-24 means the anchor serves its own
webview and collects whatever its jurisdiction requires, and a client that
automated a KYC form would be defeating the point of the flow rather than
implementing it. What the client owes is to hand the URL over and to read the
transaction state back honestly, including when the answer is `incomplete`.

## The run

Closed end to end on 2026-10-30, against `testanchor.stellar.org`. In full in
`docs/evidence/anchor-roundtrip-2026-10-30.log`; the shape of it:

```
  5.0 USD  cash          SEP-24 deposit    ae2734cc  completed
  4.5 USDC on Stellar    tx 4a2167a7...    (0.5 USD anchor fee)
  4.5 agUSD              Vault::deposit    minted one for one
  4.5 USDC               claim 54          FIFO queue, Ready, claimed
  4.1 USD  cash          SEP-24 withdraw   57eaf7e1  completed
                         payment 994d8397...  memo id:6100031375387207126
```

The 0.9 USD of difference is the test anchor's two fees. The Vault minted and
redeemed one for one in both directions.

Two things that are worth knowing before anyone repeats it:

**agUSD needs a trustline before the Vault can mint.** agUSD is a classic
Stellar asset and the contract address is its SAC, so an account that has never
held it has no trustline and the mint fails with *"trustline entry is missing
for account"*. That is the SAC refusing, not the Vault, and it is the one extra
operation a wallet has to do that a Soroban-only token would not need. It is
also the same property that puts agUSD on the SDEX.

**The anchor's USDC is the Vault's USDC.** On this testnet the SDF anchor issues
`USDC:GBBD47IF...`, and the SAC of that asset is `CBIELTK6...`, which is this
deployment's `contracts.usdc`. Checked with `stellar contract id asset` rather
than assumed, because if the two had differed the chain would have needed a swap
in the middle and the deliverable would have read very differently.

## Verifying the challenge before signing it

The part a naive SEP-10 client skips. A challenge is a real transaction with a
real signature request, and signing one that the anchor did not build is
signing whatever the attacker put in it. Checked, in `authenticate()`:

- the source account is the `SIGNING_KEY` from the anchor's own toml
- the sequence number is 0, so the transaction can never be submitted
- the first operation is a `ManageData` naming our account
- the `home_domain` in the operation matches the domain we asked
- the anchor's signature is present and valid for that key
- the time bounds contain now

Five of those are `read_challenge_transaction` from the Stellar SDK; the
sequence and the account are asserted again on our side, because a library
check that silently changes is a check nobody notices has gone.

## The secret

`secret_of()` reads the signing key from the `stellar` CLI keystore, or from
`SEP_SECRET` in the environment. There is no key material in this repository
and no path in this client that writes any.

## MoneyGram

The onboarding is commercial, not technical: the same two SEPs, against
`extstellar.moneygram.com` once the account is live, with a `--home-domain`
change and their asset code. That is the state of it, and it is why the award
names the Test Anchor as the cover.
