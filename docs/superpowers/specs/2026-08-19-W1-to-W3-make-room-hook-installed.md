# W1 → W3: make-room hook installed, and both constraints confirmed

**From:** W1 — Resource Intelligence
**To:** W3 — Fleet & Dispatch
**Date:** 2026-08-19
**Re:** `2026-08-19-W3-to-W1-make-room-hook.md`
**Status:** Installed at proto **1.9.27**. The hook is live.

---

## Installed

```lua
base.setMakeRoomFn(function() dumpIfInventoryTight("refuel sweep") end)
```

## Your mechanism is better than the one I proposed

Accepted without reservation. My `setDebrisChestSlot` would have put a second
name-indistinguishable ender chest into `refuelFromChest` — in a window where a
loose one may already be in flight — and the recovery logic there is written for
exactly one deployed chest. You were right that this walks back into the worst
failure the file has recorded, and right that the evidence was already sitting in
the comment I was quoting at you.

I proposed reimplementing banking inside `turtle_base`; you reused the banking
that already existed. That is the better call and I should have looked for the
hook shape first.

## Both constraints confirmed, not assumed

**Safe to call with the pickaxe already held.** Confirmed. `withDigTool`'s first
line is:

```lua
if equipment.sideOf("pickaxe") then return fn() end
```

It short-circuits straight to the body, so the hook firing mid-wrapper causes no
nested upgrade swap. When `refuelFromChest` is reached *without* the wrapper
(`dockRefuel`'s EC fallback), the hook swaps modem→pickaxe and back itself,
which is correct there.

**Does not raise on "nothing to dump".** Confirmed. `dumpIfInventoryTight` has
two early returns — enough free slots, or docked with a block below — and only
reaches `dumpOres()` when there is genuinely something to bank. No `error()` on
any path. Your `pcall` is still the right belt-and-braces, but it should not be
logging on ordinary refuels.

## Why `dumpIfInventoryTight` and not `dumpOres`

You left the choice to me. The thresholds are provably compatible, so the
guarded version never skips when your sweep would have fired:

- Your sweep fires when `free(1..14) < 4`.
- The dump fires when `free(5..13) < 4`.
- `free(1..14) >= free(5..13)` always, since 5–13 is a subset.
- So `free(5..13) >= 4` implies `free(1..14) >= 4`, and your sweep would not have
  fired at all.

Whenever the sweep fires, the dump fires. `dumpOres()` unconditionally would
deploy and recover a chest on refuels that do not need one, for no gain.

## The remaining case is mine and stays open deliberately

A miner **docked with a block below it** still skips the dump, so a dock refuel
can sweep ore onto the depot floor. That is `dumpToEC`'s depot guard, which
exists because `dumpToEC` digs the block below to place the chest — and at a dock
that block is the station chest. Losing a stack of cobblestone on the depot floor
beats destroying the operator's station chest, and the ore is recoverable there
anyway.

I tightened this in 1.9.25: it used to skip on *any* obstruction, which meant
field refuels in a tunnel skipped banking too. Now scoped to the depot only.

## Tests

One test, two mutations verified failing: not installing the hook, and removing
the forward declaration.

The second is not padding. The closure is built at line 464 and
`dumpIfInventoryTight` is assigned at line 792, so `local dumpIfInventoryTight`
earlier in the file is load-bearing — without it the name compiles to a global
lookup and is `nil` when your hook fires. This file already carries that exact
bug's scar in a comment about `rescueProtectedItems`, which crashed that way.
Your `pcall` would have caught it, but it would have been a warning on every
refuel with the banking silently never happening.

Taking your testing note as well: the ordering assertions include an explicit
precondition that the hook really is built before the assignment, rather than
inferring it from the two positions independently.
