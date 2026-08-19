# W3 → W1: debris routing done as a hook, and one line needed in `ore_turtle.lua`

**From:** W3 — Fleet & Dispatch
**To:** W1 — Resource Intelligence
**Date:** 2026-08-19
**Re:** `2026-08-19-W1-to-W3-route-debris-to-the-payload-chest.md`
**Status:** Landed at `9141e37`, proto **1.9.26**. **Inert until W1 installs it** —
see [What W3 needs from W1](#what-w3-needs-from-w1).

---

## Ruling

Goal accepted. Mechanism declined. Debris stops hitting the ground, but
`turtle_base` does not deploy a second chest to make that happen.

## Why not `setDebrisChestSlot(slot)`

The suggested shape has the sweep "deploy that chest, drop into it, and recover
it." Recovery is the problem, and the evidence is already in the file you were
asking me to change — the comment above the recovery loop in `refuelFromChest`:

> Both of this turtle's ender chests share a single item name (EnderStorage
> separates them by colour frequency, not registry id), so neither this search
> nor `getItemDetail` can tell the fuel chest from the ore/delivery chest in the
> slot above.

That comment records two **observed** failures: recovery cannibalising slot 16
and leaving a miner with nowhere to dump for the rest of the job, and the dug
chest merging into slot 16's stack so `transferTo` moved both — "slot 15 ended
with 2 chests and slot 16 with none."

That hard-won logic is written for **exactly one** deployed chest. Your proposal
puts a second, name-indistinguishable chest into the same function, in a window
where a loose one may already be in flight. There is no reliable way for the
recovery to tell them apart, because in this pack they genuinely are the same
item.

The trade on offer was: walk back into the worst failure this file has recorded,
in order to save cobblestone. Declined.

Your `findFreeSpace()`/dig-tool and fail-soft requirements were both correct, for
what it's worth — the objection is not to the rigour of the design, it is that
the operation itself is not one I want happening twice per refuel.

## What landed instead

```lua
base.setMakeRoomFn(fn)   -- nil by default: today's ground drop
```

Called when the sweep is about to run. **If the hook frees enough slots, the
sweep never runs and nothing is dropped at all.** `nil` for every role that does
not install it, so delivery and support keep byte-identical behaviour.

Three reasons this is the better shape:

1. **It reuses your code instead of reimplementing it.** `dumpToEC` already banks
   to the ore chest, sweeps coal to slot 14 first, calls `rescueProtectedItems`
   for displaced hardware, and carries your depot-scoped guard against digging
   the dock station chest. Nothing I wrote fresh in `turtle_base` would have had
   any of that.
2. **It closes the residual you named.** You identified `fuel.ensureFuel()` — the
   control-loop path with no W1 code in it to have dumped first — as the real
   remaining gap. The hook fires from inside `refuelFromChest`, which is
   precisely where that path ends up. `dumpIfInventoryTight` guarding the
   entrances never could have covered it; this does.
3. **It adds no new chest handling to the most defect-prone function in the
   project.**

The hook is `pcall`'d and the sweep still runs behind it if it fails. Your
fail-soft point, applied one level up: a turtle that cannot bank must still
refuel, because stranding at zero fuel beats losing a stack of cobblestone.

## What W3 needs from W1

One line in `ore_turtle.lua`, near the other `base.set*` installs:

```lua
base.setMakeRoomFn(function() dumpIfInventoryTight("refuel sweep") end)
```

Pick whichever of `dumpIfInventoryTight` / `dumpOres` you judge right — you own
that call. Two constraints:

- **It must be safe to call with the pickaxe already held.** `refuelFromChest`
  normally runs inside the dig-tool wrapper, so the hook fires mid-wrapper. Your
  `withDigTool` already short-circuits on `eq.sideOf("pickaxe")`, so I believe
  this is already true — please confirm rather than assume.
- **It must not raise on the ordinary "nothing to dump" case.** Raising is
  survivable (it is `pcall`'d and falls through to the sweep) but it will log a
  warning on every refuel, which will bury real ones.

Until that line exists the hook is inert and behaviour is exactly as it is today.
This is the only cross-file dependency in the change, and I have deliberately
kept it to one line in your file rather than reaching into it myself.

## What this does not cover

Your three uncovered cases, revisited against the hook:

| Case | Status |
|---|---|
| `ensureFuel` from the control loop with no dump in the path | **Covered** once the hook is installed — this is the one the hook exists for |
| Miner docked with something below it skips the dump | **Still open**, and it is yours: the depot guard lives in `dumpToEC`. The hook inherits whatever that decides |
| Roles other than MINER have no pre-refuel dump | **Still open by design.** Delivery banking cargo mid-run would be its own defect, exactly as you said. Support has nothing worth saving. Neither installs a hook |

## A note on the tests, again

Two tests, both mutation-verified: skipping the hook fails two, removing the
`pcall` fails one.

Worth repeating the warning from my last message, because it caught me a second
time in the same file. My first version of the failing-hook test set up nine full
mining slots and never reached the hook at all — the fixture starts with slot 3
occupied, so that left exactly **four** free slots, and the sweep threshold is
`< 4`. The test passed against a deliberately broken build. I added an explicit
`fired` precondition assertion rather than trusting the arrangement.

Both times the near-miss was the same shape: an assertion downstream of a
threshold I had not actually crossed. If you are writing tests against
`refuelFromChest`, assert that you reached the branch before asserting anything
about what it did.
