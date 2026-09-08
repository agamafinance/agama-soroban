#!/usr/bin/env python3
"""Rewrite one field of an unsigned Soroban transaction envelope.

This exists to submit refusals rather than simulate them.

The Stellar CLI will not send a transaction whose simulation fails, and every
interesting refusal fails simulation: that is what a refusal is. Simulating one
proves the contract returns the error, which is worth something, but it is not
a ledger entry, and a reviewer cannot look it up. The four refusals the smoke
test claims are therefore built as real transactions, submitted, and left on
the ledger as failed transactions carrying the contract's own error code.

Two of them (a non-Vault minting, a non-Engine releasing the Vault's USDC) are
straightforward, because they fail on authorization and authorization is only
recorded during simulation, not enforced. They simulate cleanly and fail when
they apply.

The other two, a concentration cap breach and a reserve floor breach, fail in
simulation, so there is nothing to sign. What this script does is take a
transaction the CLI did prepare, for a smaller allocation that simulates
cleanly, and rewrite the amount. The footprint and the resource estimate stay
valid, because the refused call touches exactly the same ledger entries and
strictly fewer of them: it reverts before it writes anything. The result is a
transaction that is well formed, correctly authorized for the arguments it
actually carries, and refused by the Engine when the network applies it.

Modes:

  amount <old> <new>   Replace every big-endian i128 encoding of <old> with
                       <new>. There are two of them in a prepared invoke: the
                       operation's argument list, and the root invocation of
                       the authorization entry, which has to match the call or
                       the transaction fails on authorization instead of on the
                       limit being tested.

  seq <n>              Rewrite the sequence number. A harvested transaction is
                       prepared before the ledger reaches the state that makes
                       the call refusable, so by the time it is submitted its
                       sequence number is stale.

Reads base64 on stdin, writes base64 on stdout, and fails loudly if the field
it was asked to rewrite was not found.
"""
import base64
import struct
import sys

# TransactionV1Envelope, source account KEY_TYPE_ED25519:
#   0..4    envelope type discriminant, 2 = ENVELOPE_TYPE_TX
#   4..8    MuxedAccount discriminant, 0 = KEY_TYPE_ED25519
#   8..40   the 32 byte public key
#   40..44  fee
#   44..52  sequence number
ENVELOPE_TYPE_TX = 2
KEY_TYPE_ED25519 = 0
SEQ_OFFSET = 44


def i128_bytes(value: int) -> bytes:
    """The 16 byte Int128Parts body of an ScVal, hi then lo, big-endian."""
    if value < 0:
        raise SystemExit("tx-patch: only non-negative amounts are supported")
    return struct.pack(">q", value >> 64) + struct.pack(">Q", value & ((1 << 64) - 1))


# A prepared invoke carries the amount exactly twice: once in the operation's
# argument list and once in the root invocation of its authorization entry. Any
# other count means the rewrite is hitting something it was not aimed at, and a
# blind replace on a transaction that is about to be signed is not the place to
# be relaxed about that.
EXPECTED_OCCURRENCES = 2


def patch_amount(env: bytes, old: int, new: int) -> bytes:
    old_b, new_b = i128_bytes(old), i128_bytes(new)
    count = env.count(old_b)
    if count != EXPECTED_OCCURRENCES:
        raise SystemExit(
            f"tx-patch: expected {EXPECTED_OCCURRENCES} occurrences of {old} "
            f"in the envelope, found {count}; refusing to rewrite"
        )
    patched = env.replace(old_b, new_b)
    if len(patched) != len(env):
        raise SystemExit("tx-patch: rewriting the amount changed the envelope length")
    print(f"tx-patch: rewrote {count} occurrences of {old} to {new}", file=sys.stderr)
    return patched


def patch_seq(env: bytes, seq: int) -> bytes:
    kind, muxed = struct.unpack(">II", env[:8])
    if kind != ENVELOPE_TYPE_TX or muxed != KEY_TYPE_ED25519:
        raise SystemExit("tx-patch: not a v1 transaction envelope with an ed25519 source")
    was = struct.unpack(">q", env[SEQ_OFFSET : SEQ_OFFSET + 8])[0]
    print(f"tx-patch: rewrote sequence number {was} to {seq}", file=sys.stderr)
    return env[:SEQ_OFFSET] + struct.pack(">q", seq) + env[SEQ_OFFSET + 8 :]


def main() -> None:
    if len(sys.argv) < 3:
        raise SystemExit(__doc__)
    env = base64.b64decode(sys.stdin.read().strip())
    mode = sys.argv[1]
    if mode == "amount":
        out = patch_amount(env, int(sys.argv[2]), int(sys.argv[3]))
    elif mode == "seq":
        out = patch_seq(env, int(sys.argv[2]))
    else:
        raise SystemExit(f"tx-patch: unknown mode {mode}")
    sys.stdout.write(base64.b64encode(out).decode())


if __name__ == "__main__":
    main()
