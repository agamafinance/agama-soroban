#!/usr/bin/env python3
"""SEP-1, SEP-10 and SEP-24 against a Stellar anchor.

Tranche 2, Deliverable 3 of the SCF #45 award asks for:

    SEP-10 authentication and SEP-24 interactive deposit and withdrawal flows
    completing end-to-end on Stellar Testnet against the MoneyGram Access
    sandbox, cash to USDC to agUSD and the reverse, with the SDF Stellar Test
    Anchor covering the same flows during MoneyGram onboarding

The second half of that sentence is why this points at `testanchor.stellar.org`
by default and not at MoneyGram. The record names the SDF Test Anchor as what
covers these flows while MoneyGram onboarding is in progress, and the two speak
the same protocol: the anchor is a `--home-domain` away. Nothing here is
specific to the SDF server.

The Stellar reviewer's finding was that "MoneyGram only appears in architecture
prose; there is no SEP-10/SEP-24 code in the repo". This is the code.

What is implemented, and what is deliberately not:

  SEP-1   read the anchor's stellar.toml, take WEB_AUTH_ENDPOINT,
          TRANSFER_SERVER_SEP0024, SIGNING_KEY and NETWORK_PASSPHRASE from it
          rather than from a constant here
  SEP-10  fetch the challenge, verify it before signing it, sign, exchange for
          a JWT, and read the JWT's claims back
  SEP-24  start an interactive deposit or withdrawal, and poll the transaction
          to a terminal state

  The interactive step itself is a webview the user completes. That is what the
  "interactive" in SEP-24 means and it is not a gap in this client: the anchor
  hands back a URL, a human or a browser driver completes the form, and this
  client polls. `--open` prints the URL; `--wait` polls until the anchor moves
  the transaction.

Verifying the challenge before signing is not optional and is the part a naive
client skips. A challenge transaction is a real transaction with a real
sequence number, and signing one that was not built by the anchor is signing
whatever the attacker put in it. Checked here: source is the anchor's
SIGNING_KEY, sequence is 0, the first operation is a ManageData naming our
account, the home domain matches, the anchor's signature is present and valid,
and the time bounds contain now.

Usage:
  python anchor/sep_client.py toml
  python anchor/sep_client.py auth   --secret-name agama-user
  python anchor/sep_client.py deposit  --secret-name agama-user --amount 25
  python anchor/sep_client.py withdraw --secret-name agama-user --amount 10
  python anchor/sep_client.py poll   --secret-name agama-user --id <tx id>
"""
import argparse
import base64
import json
import os
import subprocess
import sys
import time
import urllib.parse

import requests
from stellar_sdk import Keypair, Network, TransactionEnvelope
from stellar_sdk.sep.stellar_web_authentication import read_challenge_transaction

DEFAULT_HOME = "testanchor.stellar.org"
TIMEOUT = 30


def toml_of(home_domain):
    """SEP-1. Everything else in this module is read from here."""
    url = f"https://{home_domain}/.well-known/stellar.toml"
    r = requests.get(url, timeout=TIMEOUT)
    r.raise_for_status()
    out, currencies, current = {}, [], None
    for line in r.text.splitlines():
        line = line.strip()
        if line.startswith("[[CURRENCIES]]"):
            current = {}
            currencies.append(current)
            continue
        if line.startswith("[") or not line or line.startswith("#"):
            if line.startswith("[") and not line.startswith("[["):
                current = None
            continue
        if "=" not in line:
            continue
        k, _, v = line.partition("=")
        v = v.strip().strip('"')
        target = current if current is not None else out
        target[k.strip()] = v
    out["CURRENCIES"] = currencies
    out["_url"] = url
    return out


def secret_of(name):
    """The signing key, from the stellar CLI's keystore rather than from a file
    in the repository. A secret that lives next to the code it signs with is a
    secret that gets committed."""
    env = os.environ.get("SEP_SECRET")
    if env:
        return env
    r = subprocess.run(
        ["stellar", "keys", "show", name], capture_output=True, text=True
    )
    if r.returncode != 0:
        raise SystemExit(f"stellar keys show {name}: {r.stderr.strip()}")
    return r.stdout.strip()


def authenticate(home_domain, secret, verbose=True, client_domain=None, client_domain_secret=None):
    """SEP-10, with the challenge verified before it is signed.

    `client_domain` is how an anchor learns which wallet provider is driving the
    session, and some of them need it. MoneyGram is one: without it their widget
    opens with `wallet_provider=` empty and fails with their error RMP-01,
    because there is no partner for it to resolve. The mechanism is attestation
    rather than a claim: the client names its domain, the anchor fetches
    `https://<domain>/.well-known/stellar.toml`, reads the `SIGNING_KEY` there,
    adds a second `ManageData` operation naming the domain, and requires the
    challenge to carry that key's signature as well as the account's. A client
    that merely asserts a domain it does not control cannot produce it.

    So two signatures go back: the account's, which says who is transacting, and
    the domain's, which says who is operating the client.
    """
    t = toml_of(home_domain)
    endpoint = t["WEB_AUTH_ENDPOINT"]
    kp = Keypair.from_secret(secret)

    params = {"account": kp.public_key, "home_domain": home_domain}
    if client_domain:
        params["client_domain"] = client_domain
    r = requests.get(endpoint, params=params, timeout=TIMEOUT)
    r.raise_for_status()
    body = r.json()
    challenge_xdr = body["transaction"]
    passphrase = body.get("network_passphrase", t["NETWORK_PASSPHRASE"])

    # The verification. read_challenge_transaction raises on a challenge that
    # is not well formed, not signed by the server key, outside its time
    # bounds, or not addressed to this account.
    parsed = read_challenge_transaction(
        challenge_transaction=challenge_xdr,
        server_account_id=t["SIGNING_KEY"],
        home_domains=[home_domain],
        web_auth_domain=urllib.parse.urlparse(endpoint).netloc,
        network_passphrase=passphrase,
    )
    env = TransactionEnvelope.from_xdr(challenge_xdr, passphrase)
    if env.transaction.sequence != 0:
        raise SystemExit("challenge sequence is not 0, refusing to sign")
    if parsed.client_account_id != kp.public_key:
        raise SystemExit("challenge names a different account, refusing to sign")

    # The client_domain operation, when one was asked for. Checked rather than
    # assumed: an anchor that quietly dropped it would leave us co-signing with
    # the domain key for a session that does not carry the domain, and the
    # signature would be spent proving nothing.
    domain_op = None
    for op in env.transaction.operations:
        name = getattr(op, "data_name", None)
        if name == "client_domain":
            domain_op = op
    if client_domain and domain_op is None:
        raise SystemExit(
            f"asked for client_domain={client_domain} and the challenge carries none, "
            "so the domain signature would prove nothing")
    if domain_op is not None:
        declared = bytes(domain_op.data_value).decode()
        if declared != client_domain:
            raise SystemExit(
                f"the challenge names client_domain={declared}, not {client_domain}")

    if verbose:
        print(f"  challenge from   {t['SIGNING_KEY']}")
        print(f"  for account      {parsed.client_account_id}")
        print(f"  home domain      {parsed.matched_home_domain}")
        print(f"  sequence         {env.transaction.sequence}  (0, so it can never be submitted)")
        print(f"  time bounds      {env.transaction.preconditions.time_bounds.min_time}"
              f" to {env.transaction.preconditions.time_bounds.max_time}")
        print(f"  server signature verified against SIGNING_KEY")
        if domain_op is not None:
            print(f"  client domain    {client_domain}, co-signed by its own SIGNING_KEY")

    env.sign(kp)
    if domain_op is not None:
        if not client_domain_secret:
            raise SystemExit(
                f"the challenge requires {client_domain}'s SIGNING_KEY and none was given")
        env.sign(Keypair.from_secret(client_domain_secret))
    r = requests.post(endpoint, json={"transaction": env.to_xdr()}, timeout=TIMEOUT)
    if r.status_code != 200:
        raise SystemExit(f"auth refused {r.status_code}: {r.text[:300]}")
    token = r.json()["token"]
    claims = json.loads(
        base64.urlsafe_b64decode(token.split(".")[1] + "==").decode()
    )
    return token, claims, t


def interactive(home_domain, secret, kind, asset_code, amount, extra=None,
                client_domain=None, client_domain_secret=None):
    """SEP-24 /transactions/{deposit,withdraw}/interactive."""
    token, claims, t = authenticate(home_domain, secret, verbose=False,
                                    client_domain=client_domain,
                                    client_domain_secret=client_domain_secret)
    base = t["TRANSFER_SERVER_SEP0024"].rstrip("/")
    kp = Keypair.from_secret(secret)
    payload = {"asset_code": asset_code, "account": kp.public_key}
    if amount is not None:
        payload["amount"] = str(amount)
    payload.update(extra or {})
    r = requests.post(
        f"{base}/transactions/{kind}/interactive",
        json=payload,
        headers={"Authorization": f"Bearer {token}"},
        timeout=TIMEOUT,
    )
    if r.status_code not in (200, 201):
        raise SystemExit(f"{kind} refused {r.status_code}: {r.text[:400]}")
    return r.json(), token, base


def poll(base, token, tx_id, wait=0, every=5):
    """Poll one transaction. SEP-24's terminal states are completed, refunded,
    expired, error and no_market; everything else is in flight."""
    terminal = {"completed", "refunded", "expired", "error", "no_market"}
    deadline = time.time() + wait
    seen = None
    while True:
        r = requests.get(
            f"{base}/transaction",
            params={"id": tx_id},
            headers={"Authorization": f"Bearer {token}"},
            timeout=TIMEOUT,
        )
        r.raise_for_status()
        tx = r.json()["transaction"]
        if tx["status"] != seen:
            seen = tx["status"]
            print(f"  {time.strftime('%H:%M:%S')}  {seen}"
                  + (f"  {tx.get('message','')}" if tx.get("message") else ""))
        if tx["status"] in terminal or time.time() >= deadline:
            return tx
        time.sleep(every)


def send_withdrawal(home_domain, secret, tx_id, horizon="https://horizon-testnet.stellar.org"):
    """Pay the anchor the asset it is waiting for, to complete a withdrawal.

    A SEP-24 withdrawal reaches `pending_user_transfer_start` and then waits:
    the anchor has told us an account and a memo, and until the asset arrives
    there with that memo it has nothing to pay out. The destination and the
    memo are read off the anchor's own transaction record rather than typed in
    here, because a withdrawal paid to a hardcoded address is a withdrawal paid
    to whatever that address was last time.
    """
    from stellar_sdk import Asset, Server, TransactionBuilder

    token, _, t = authenticate(home_domain, secret, verbose=False)
    base = t["TRANSFER_SERVER_SEP0024"].rstrip("/")
    r = requests.get(f"{base}/transaction", params={"id": tx_id},
                     headers={"Authorization": f"Bearer {token}"}, timeout=TIMEOUT)
    r.raise_for_status()
    tx = r.json()["transaction"]
    if tx["status"] != "pending_user_transfer_start":
        raise SystemExit(f"status is {tx['status']}, not waiting on a transfer")

    dest = tx["withdraw_anchor_account"]
    memo = tx.get("withdraw_memo")
    memo_type = tx.get("withdraw_memo_type", "id")
    amount = tx["amount_in"]
    asset_code = tx.get("amount_in_asset", "").split(":")
    code = asset_code[1] if len(asset_code) > 2 else "USDC"
    issuer = asset_code[2] if len(asset_code) > 2 else None
    if issuer is None:
        for c in t["CURRENCIES"]:
            if c.get("code") == code:
                issuer = c["issuer"]

    kp = Keypair.from_secret(secret)
    server = Server(horizon_url=horizon)
    account = server.load_account(kp.public_key)
    builder = (
        TransactionBuilder(
            source_account=account,
            network_passphrase=t["NETWORK_PASSPHRASE"],
            base_fee=200,
        )
        .append_payment_op(
            destination=dest, asset=Asset(code, issuer), amount=str(amount)
        )
        .set_timeout(120)
    )
    if memo_type == "id":
        builder.add_id_memo(int(memo))
    elif memo_type == "text":
        builder.add_text_memo(memo)
    elif memo_type == "hash":
        builder.add_hash_memo(base64.b64decode(memo))
    envelope = builder.build()
    envelope.sign(kp)
    print(f"  paying           {amount} {code} to {dest}")
    print(f"  memo             {memo_type}:{memo}")
    resp = server.submit_transaction(envelope)
    print(f"  stellar tx       {resp['hash']}")
    return resp["hash"]


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("action", choices=["toml", "auth", "deposit", "withdraw", "poll", "pay"])
    ap.add_argument("--home-domain", default=DEFAULT_HOME)
    ap.add_argument("--secret-name", default="agama-user")
    ap.add_argument("--asset-code", default="USDC")
    ap.add_argument("--amount", default=None)
    ap.add_argument("--id", default=None)
    ap.add_argument("--wait", type=int, default=0, help="seconds to poll before giving up")
    ap.add_argument("--client-domain", default=None,
                    help="the wallet provider's domain, for anchors that need to know who is driving")
    ap.add_argument("--client-domain-key", default=None,
                    help="stellar CLI identity holding that domain's SIGNING_KEY")
    ap.add_argument("--json", action="store_true")
    a = ap.parse_args()

    cd_secret = secret_of(a.client_domain_key) if a.client_domain_key else None

    if a.action == "toml":
        t = toml_of(a.home_domain)
        if a.json:
            print(json.dumps(t, indent=1))
            return
        print(f"  {t['_url']}")
        for k in ("SIGNING_KEY", "NETWORK_PASSPHRASE", "WEB_AUTH_ENDPOINT",
                  "TRANSFER_SERVER_SEP0024", "KYC_SERVER"):
            print(f"  {k:<26}{t.get(k, '(absent)')}")
        for c in t["CURRENCIES"]:
            print(f"  currency {c.get('code'):<8}{c.get('issuer','')}")
        return

    secret = secret_of(a.secret_name)

    if a.action == "auth":
        token, claims, _ = authenticate(a.home_domain, secret,
                                        client_domain=a.client_domain,
                                        client_domain_secret=cd_secret)
        print()
        print(f"  JWT received, {len(token)} characters")
        for k in ("iss", "sub", "iat", "exp", "client_domain", "home_domain"):
            if k in claims:
                print(f"  {k:<16}{claims[k]}")
        if a.json:
            print(json.dumps({"token": token, "claims": claims}, indent=1))
        return

    if a.action == "pay":
        send_withdrawal(a.home_domain, secret, a.id)
        token, _, t = authenticate(a.home_domain, secret, verbose=False)
        base = t["TRANSFER_SERVER_SEP0024"].rstrip("/")
        tx = poll(base, token, a.id, wait=a.wait or 120)
        print(f"  final status {tx['status']}")
        return

    if a.action == "poll":
        token, _, t = authenticate(a.home_domain, secret, verbose=False)
        base = t["TRANSFER_SERVER_SEP0024"].rstrip("/")
        tx = poll(base, token, a.id, wait=a.wait)
        print(json.dumps(tx, indent=1) if a.json else f"  final status {tx['status']}")
        return

    res, token, base = interactive(a.home_domain, secret, a.action, a.asset_code, a.amount,
                                   client_domain=a.client_domain,
                                   client_domain_secret=cd_secret)
    print(f"  type             {res.get('type')}")
    print(f"  transaction id   {res.get('id')}")
    print(f"  interactive url  {res.get('url')}")
    print()
    print("  The form is the webview a user completes. SEP-24 is interactive by")
    print("  definition: the anchor collects whatever its jurisdiction requires")
    print("  and this client polls the transaction it handed back.")
    if a.wait:
        print()
        tx = poll(base, token, res["id"], wait=a.wait)
        print(f"  final status {tx['status']}")
    if a.json:
        print(json.dumps(res, indent=1))


if __name__ == "__main__":
    sys.exit(main())
