# The request to send MoneyGram

Everything below is checkable by them in a minute, which is the point: it asks
for a whitelist entry rather than for an evaluation.

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
