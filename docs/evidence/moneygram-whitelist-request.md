# Getting on MoneyGram's Stellar whitelist

Their own guide, `xramps.moneygram.com/ops/developer/guides/stellar`, sets out
six steps. This file records where we are against them, because five of the six
are ours and one is theirs.

| | Step, in their words | Where it stands |
|---|---|---|
| 1 | Get allowlisted (sandbox / Stellar testnet) | **theirs.** Submitted from the partner portal, Developers section, under "Whitelist in TestNet". Not an email: the form is in the portal |
| 2 | Install the Stellar SDK | **not needed.** `anchor/sep_client.py` speaks the protocol directly, and their SDK is a convenience over the same endpoints |
| 3 | Implement SEP-10, SEP-24 and the status page | **done.** SEP-10 with client domain attestation, SEP-24 both directions, status polling to a terminal state, and `more_info_url` read off the transaction |
| 4 | Test and certify in sandbox | **blocked on 1.** Three flows: cash-out, cash-out refund via the Cancel transfer button on `more_info_url`, and a staged cash-in. Transaction IDs then go in the portal under "Playground test transactions" |
| 5 | KYB and legal agreements | **theirs, in the portal.** Entity is Agama Labs Inc. |
| 6 | Production domain and keys | after 4 and 5 |

## What step 1 asks for, for a non-custodial wallet

Two things, and both are ready:

| They ask for | We have |
|---|---|
| the domain where your `stellar.toml` is hosted, including a signing key for Stellar testnet | `agama.finance`, serving `https://agama.finance/.well-known/stellar.toml`, `NETWORK_PASSPHRASE` testnet, `SIGNING_KEY` `GCGRQ2LCB4RJ65XNKKIWGHLK3TDHPM7LNKX5DN4SRJH6K5NGQTS6YOSG` |
| wallet name and intended use case | Agama. A Soroban vault that takes USDC and issues agUSD, a synthetic dollar backed by private credit. The ramp lets a user go from cash to a yield-bearing position without a centralised exchange |

Their tip is to run the Stellar TOML Checker first. The file answers 200 and
their own SEP-10 reads the key off it, which is the same check done the hard
way.

## Where their sandbox currently stops

Their anchor already works for us. What fails is two of their own calls, for a
partner they have not allowlisted yet:

```
POST  /rampsservice/v3/transactions/prepare       500
GET   /rampsservice/v3/reference-data/countries   500
```

Everything else on that page is 200. The widget shows RMP-01, RMP-02.

## Useful details from their guide, recorded so they are not rediscovered

- **Non-custodial requires `client_domain` in SEP-10.** Their table is explicit:
  home domain required, client domain required, user identified by public key
  plus our toml's `SIGNING_KEY`. That is what we built.
- **A trustline is required before an account can receive USDC.** We hit this
  the hard way on the agUSD mint and it is the same property.
- **Cash-out has a 30 minute clock**: once a withdrawal reaches
  `pending_user_transfer_start`, the USDC must be sent inside 30 minutes.
- **Sandbox cash-in only works at specific test locations**, eight of them,
  listed in their reference section. The widget highlights them at the top of
  the picker.
- **Limits**: 15 to 950 USDC on-ramp, 15 to 2500 USDC off-ramp. Our 5 USDC
  attempt was correctly refused.
- **Partner support**: MGramps@moneygram.com

## If the portal form is not enough

The message below asks for the same thing in prose. Everything in it is
checkable by them in a minute.

---

**Subject:** Stellar SEP whitelist request, agama.finance (wallet provider, non-custodial)

Hello,

We have a partner account on the Ramps portal under **Agama Labs Inc.** (DBA
Agama Finance), registered non-custodial on Stellar. We are asking to be
whitelisted as a wallet provider on the **Stellar SEP path**, SEP-10 and
SEP-24, rather than the widget path.

The integration is already built and already drives your sandbox at
`extmgxanchor.moneygram.com`:

- **SEP-1** reads your toml.
- **SEP-10** returns a JWT. We send `client_domain=agama.finance`, you fetch
  `https://agama.finance/.well-known/stellar.toml`, and the challenge is
  co-signed by the `SIGNING_KEY` published there,
  `GCGRQ2LCB4RJ65XNKKIWGHLK3TDHPM7LNKX5DN4SRJH6K5NGQTS6YOSG`. The JWT comes
  back carrying `client_domain: agama.finance`.
- **SEP-24** enforces your limits correctly: a 5 USDC deposit is refused for
  being under your 15 minimum, and at 20 USDC a transaction opens. The most
  recent is `4ddb0b16-b40a-41f7-8ce6-6698f7c0dead`.

Where it stops is on your side, and we think it is the missing whitelist entry:
the Ramps widget opens with `wallet_provider=` empty and two of your backend
calls return **HTTP 500** rather than a 401 or 403.

```
POST  /rampsservice/v3/transactions/prepare       500
GET   /rampsservice/v3/reference-data/countries   500
```

The widget then shows **RMP-01, RMP-02**. Every other request on that page
returns 200.

What we need from you is the whitelist entry for `agama.finance`. What you may
want to know about us:

- **Who:** Agama Labs Inc., Panama. Yield infrastructure for tokenised
  real-world assets, focused on private credit, built on Stellar Soroban.
- **Model:** non-custodial. End users sign their own Stellar USDC payments,
  including the memo your widget provides. We never hold user funds between
  your anchor and their wallet.
- **Asset:** USDC. Your sandbox quotes
  `USDC:GBBD47IF6LWK7P7MDEVSCWR7DPUWV3NY3DTQEVFL4NAT4AQH3ZLLFLA5`, which is
  the same asset our vault accepts, so a deposit lands with no conversion.
- **Context:** this is a funded Stellar Community Fund Build Award, #45, and
  the fiat ramp is a named deliverable of its second tranche.

Happy to send the client source, a transcript of a full round trip against the
SDF Stellar Test Anchor, or anything else useful.

---

## Where the facts above come from

| Claim | Evidence |
|---|---|
| SEP-10 with client domain works | `docs/evidence/moneygram-sandbox-2026-10-30.log` |
| the two 500s and RMP-01, RMP-02 | same file, addendum 2, read off the widget's own session |
| the toml is served | `curl https://agama.finance/.well-known/stellar.toml` |
| the round trip works against another anchor | `docs/evidence/anchor-roundtrip-2026-10-30.log` |

## The day the whitelist lands

One command, and the same suite that proved the Test Anchor proves MoneyGram:

```
HOME_DOMAIN=extmgxanchor.moneygram.com CLIENT_DOMAIN=agama.finance AMOUNT=20 \
  bash scripts/e2e-anchor.sh
```
