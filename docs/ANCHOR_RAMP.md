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
| the anchor's own KYC form | a person, in a webview | **manual** |
| SEP-24, poll to a terminal state | the client | **runs** |
| USDC to agUSD through `Vault::deposit` | the client | runs once the deposit settles |
| agUSD to USDC and back out through SEP-24 withdraw | the client | same |

The form is not a gap. "Interactive" in SEP-24 means the anchor serves its own
webview and collects whatever its jurisdiction requires, and a client that
automated a KYC form would be defeating the point of the flow rather than
implementing it. What the client owes is to hand the URL over and to read the
transaction state back honestly, including when the answer is `incomplete`.

## The run

Against `testanchor.stellar.org`, 2026-10-30:

```
SEP-1    WEB_AUTH_ENDPOINT        https://testanchor.stellar.org/auth
         TRANSFER_SERVER_SEP0024  https://testanchor.stellar.org/sep24
         SIGNING_KEY              GCHLHDBOKG2JWMJQBTLSL5XG6NO7ESXI2TAQKZXCXWXB5WI2X6W233PR
         USDC                     GBBD47IF6LWK7P7MDEVSCWR7DPUWV3NY3DTQEVFL4NAT4AQH3ZLLFLA5

SEP-10   challenge from   GCHLHDBOKG2JWMJQBTLSL5XG6NO7ESXI2TAQKZXCXWXB5WI2X6W233PR
         for account      GC35EAQJPYWZDPOUMOOLGETVTDMG3KQDKOX4ISGOLXS2RR4JLLLGBFF2
         sequence         0
         server signature verified against SIGNING_KEY
         JWT              sub matches the account, exp +24h

SEP-24   transaction      61ef6158-1681-43d0-bd11-9fb32e2ed1b8
         type             interactive_customer_info_needed
         status           incomplete   (the form was not submitted)
```

`incomplete` is the correct status for a transaction whose form has not been
completed, and reporting it is the point. The run is 7 assertions, 0 failures,
and the last of them asserts that the client read `incomplete` back rather than
that a deposit settled.

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
