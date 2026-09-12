# The reserve floor's base is measured on accounted cash

Status: **taken.** Written as a proposal after an invariant fuzzer found the
defect below, deliberately not applied in the same change that fixed it, and
applied a day later once the thing that was missing had been built.

## What the fuzzer found

`Engine::book_recovery`, added for M1 of the third adversarial review, could
lower `floor_base`. The shrunk counterexample was four operations: a transfer
straight to the Vault, an allocation, a write-down, and a `book_recovery`.

The mechanism is a double count.

`Vault::idle_reserves` reads the real token balance. Cash that arrives without
the books being told, a misdirected repayment, an over-payment, an adapter admin
taking its own surplus sweep, an outright donation, raises that balance the
moment it lands, and `floor_base` counts it there and then.
`Vault::record_recovery` books the same cash later and lowers
`recognised_losses` when it does. Both terms are inside the base. So the dollar
is counted once on arrival and spent once on booking, and the base ends lower
than it stood in between.

`Engine::recover` does not have the problem, and the difference is *where the
cash sits when it is booked*. In an adapter it is outside the base until the
sweep brings it in, so the rise and the fall happen in the same call and cancel
exactly. `book_recovery` books cash that is already inside.

The comment written on `book_recovery` claimed the two were equivalent, because
an admin could send USDC to an adapter and sweep it through `recover` for the
same effect. The round trip is not equivalent. That sentence was wrong and the
counterexample is what says so.

## Why the third review's derivation did not catch it

The third review concluded the base can only be lowered by the two calls that
book returning cash, that both are bounded by the balance the Vault cannot
already account for, and that every unit of that cash had raised the base by the
same amount when it arrived.

All three statements are true. The conclusion drawn from them, that the base
therefore never falls, does not follow, because the rise and the fall can be in
different transactions and the base is higher in between. With `recover` alone
they never were, which is why the derivation held in practice right up until a
call existed that separated them.

## The proposal

Measure the cash term of the base on `booked_reserves` rather than on the raw
balance:

```
accounted_free_reserves = max(0, booked_reserves - outstanding_liabilities)
floor_base              = accounted_free_reserves + deployed_capital + recognised_losses
```

`booked_reserves` is already exactly "the balance the Vault can account for from
its own flows": deposits in, allocations out, repayments and recoveries in,
payouts out. Measured there, unannounced cash counts for nothing until something
books it, and booking it moves accounted free reserves up by precisely what it
moves recognised losses down. A sweep does not inflate the base and a booking
does not deflate it. Both are neutral, which is what they always should have
been.

## What it costs, which is why it is not taken here

It does not stop at `floor_base`. `settle_allocation` checks liquidity and the
floor against `free_reserves`, which reads the raw balance. Leave that alone and
the two measures disagree: an allocation funded partly by unannounced cash
lowers one term of the base without raising the other, and the base moves on an
operation that is supposed to be neutral. The fuzzer finds that in two
operations, a donation and an allocation.

Moving `settle_allocation` to the same basis fixes it and changes the Vault's
behaviour: **cash nobody deposited stops being deployable until it is booked.**
That is defensible and arguably right, since capital no agUSD claims arguably
should not be lent out, and it is a real semantic change to the most reviewed
contract here. An existing test,
`a_vault_that_has_not_been_given_an_engine_releases_nothing`, funds a Vault by
faucet and expects to allocate from it, and encodes the current rule.

So it is three coupled changes to the reserve floor's basis, and they were
reached by following a bug introduced the day before. Landing that on a
pre-audit codebase in one morning, with no second opinion, would be repeating
the mistake that produced the bug: a chain of individually plausible steps with
nothing checking the conclusion.

## What changed between proposing it and taking it

One thing, and it was the thing the deferral rested on. The stated reason for
not applying it was "three coupled changes to the most reviewed part of the
system, reached by following a bug from the day before, with nothing checking
the conclusion."

The fuzzer is that check, and by the time this was taken it was proven on
exactly this defect class: it had found the original `book_recovery` defect in
four operations, and the halfway state where only `floor_base` had moved in two.

It earned that reputation again during the implementation. At 1500 cases it
found a **one stroop** drift in `floor_base` on a `deallocate`, from the clamp.
`accounted_free_reserves` clamps at zero, because free cash cannot be negative,
and a withdrawal request raises liabilities without moving cash, so
`booked - liabilities` can be negative while capital is out. The clamp then
reports zero, and a `deallocate` raising booked by `amount` raises the clamped
term by less than `amount` while deployed falls by all of it. The base drifts
down by the difference, once per deallocation: precisely the slow leak the floor
exists to prevent, reintroduced by the fix for a different leak.

The base is therefore summed from unclamped terms and clamped once at the end:

```
base = booked_reserves + deployed_capital + recognised_losses - outstanding_liabilities
floor_base = max(0, base)
```

Which reads as what it is. Everything the Vault has accounted for, plus what is
out, plus what has been written off, less what the queue is owed. Every pairing
that should be neutral is, and only a withdrawal request lowers it, which it
should, because the protocol owes more than it did. The clamp at the end is for
the comparison rather than the arithmetic: a negative base satisfies any floor
trivially, and zero is the honest value for a number used as a denominator.

## What it did to M1, which is the reason it was worth doing

M1 stops being a finding rather than staying an open one.

The harm M1 described was that an adapter admin's surplus sweep raises the
floor's base while `recognised_losses` still carries the same amount, so the
base counts the dollar twice and freezes `floor_bps` of it as reserves that can
never be deployed. Measured on accounted cash the sweep does not touch
`booked_reserves`, so the base does not move, so nothing is frozen and there is
nothing to unfreeze.

`an_adapter_admins_sweep_no_longer_inflates_the_floors_base` is that, and it
fails on the old base with the inflation it describes, 12000000000 against
10000000000 on the fixture. The entry point written to release that inflation,
and which the fuzzer then showed could lower the base, turns out not to have
been needed for it at all.

The permanent residue on the deployment stops being an unexplainable gap and
becomes a conservative buffer that counts for nothing.

## What was done first, and kept


`Engine::book_recovery` is removed, and M1 of the third review is open again.
That is where the review left it, and the reason it gave was exactly this:

> The fix is a new entry point (an `Engine::book_recovery(admin, pool_id,
> amount)` that books against unaccounted Vault cash without going through the
> adapter). That is new authority over `recognised_losses` and a product
> decision, which is why it is recorded rather than written.

The review was right and its caution was overridden. The fuzzer found the reason
it was right, which is the best argument available for having written the fuzzer.

## If this is taken later

The three changes are small and they have to land together:

1. `floor_base` on `accounted_free_reserves`.
2. `settle_allocation` on the same, for both its liquidity check and its floor
   check.
3. The faucet-funded test rewritten to deposit, and a new test pinning that
   unannounced cash is not deployable until booked.

The fuzz suite in `contracts/vault/src/fuzz.rs` is the check: it found the
original defect and it found the halfway state where only the first change was
made. Both were two operations deep.
