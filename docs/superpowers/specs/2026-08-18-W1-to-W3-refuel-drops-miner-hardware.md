# W1 → W3: `refuelFromChest` drops the miner's own hardware on the ground

**From:** W1 — Resource Intelligence
**To:** W3 — Fleet & Dispatch
**Date:** 2026-08-18
**Severity:** Critical — actively destroying hardware in the field
**File:** `turtle_base.lua` (W3-owned; W1 has not touched it)
**Found at:** proto 1.9.17

---

## Summary

`fuel.refuelFromChest()` clears "debris" from slots 1–14 by **dropping it on the
ground** whenever fewer than 4 slots are free. On a miner, slots 1–4 are not
debris — they are the geo scanner, the carried chunk-loader turtle, the stowed
pickaxe/chunky, and the modem.

The result is a miner that throws away its own identity mid-job, then goes
permanently silent because it can no longer recover a modem it no longer has.

This is reported rather than fixed: `turtle_base.lua` is W3's under §13, and the
ownership rule now binds.

## The code

```lua
if freeCount() < 4 then
    logInfo("Clearing debris from inventory to make room for coal...")
    for s = 1, BURN_MAX do              -- BURN_MAX = 14
        if freeCount() >= 4 then break end
        local item = turtle.getItemDetail(s)
        if item then
            local n = item.name
            local isFuel = (n == "minecraft:coal" or n == "minecraft:charcoal"
                            or n == "minecraft:coal_block" or n == CHEST_ITEM)
            if not isFuel then
                turtle.select(s)
                if not turtle.dropDown() then turtle.drop() end
            end
        end
    end
```

The whitelist is coal, charcoal, coal blocks, and ender chests. Everything else
in slots 1–14 is dropped.

## Why it hits miners specifically

`equipment.SLOTS` puts the miner's entire kit inside that range:

| Slot | Contents | In whitelist? |
|---|---|---|
| 1 | `advancedperipherals:geo_scanner` | **no — dropped** |
| 2 | carried chunk-loader turtle | **no — dropped** |
| 3 | stowed pickaxe / chunky | **no — dropped** |
| 4 | modem (during the retrieval window) | **no — dropped** |
| 5–13 | ore | dropped (correct — this is the intent) |
| 14 | coal | kept |
| 15/16 | fuel EC / ore EC | outside `BURN_MAX`, safe |

The comment above the loop explains the original intent: *"support turtles
accumulate road debris while following delivery."* Support turtles have nothing
in slots 1–4. Miners have everything there. The loop was correct for the role it
was written for and is catastrophic for the role that inherited it.

**There is no guard.** No protected-slot hook, no per-role exemption, nothing
registered by `ore_turtle.lua` that shields those slots. W1 checked.

## Observed in-world

Reported by the operator after a session, all four consistent with one pass of
this loop:

- chunk-loader turtles missing from the world
- a geo scanner missing
- inventories "completely jumbled up"
- **a turtle holding pickaxe + chunky and no modem**, found only because it
  happened to make it back to the warehouse

## Why the turtle then goes silent — the cascade

Losing the modem is survivable by design. It isn't, because the recovery path
depends on the modem being in the inventory it was just dropped from:

1. `equipment.reconcile()` → `findSlot(I.MODEM)` → **nil** (it's on the ground)
   → returns `false, "modem_unrecoverable"`
2. `comms.init()` → `error("No modem found. Attach a wireless or ender modem.")`
3. That error propagates out of `base.init(proto.ROLE.MINER)` at
   **`ore_turtle.lua:110` — module load, not `pcall`-protected**

Everything below line 110 never runs, including:

- `initProtectedSlots()`
- **`recoverPlacedLoader()`** ← this is why loaders are also abandoned
- `pcall(base.run, mineJob)`
- the final `os.reboot()`

The turtle stops at line 110 with an error on screen: deaf, motionless, and
holding a loader record it will never act on. Rebooting re-runs the same crash.

**Invariant B ("a worker must be able to recover a missing modem on boot from
its own inventory") cannot hold when the modem has been thrown on the ground.**

W1 is fixing the line 110 half — see *What W1 is changing* below — but that only
converts a silent brick into a loud one. It does not stop the drop.

## Trigger conditions

`freeCount() < 4` counts empty slots in 1–14. On a miner, slots 1–3 are
permanently occupied, so the margin is thin by construction:

| State | Free in 1–14 | Drops? |
|---|---|---|
| Empty mining slots, coal in 14 | ~10 | no |
| 8 of 9 mining slots full | 2 | **yes** |
| 9 of 9 full, retrieval modem in slot 4 | 0 | **yes** |

`inventoryFull()` in `ore_turtle.lua` triggers a dump at fewer than 2 free
*mining* slots, so the miner does keep itself trimmed — but `fuel.ensureFuel()`
fires from the control loop at `FUEL_CRITICAL = 200` **asynchronously to the job
loop**, so it can land while the inventory is at 2 or 3 free. That is the window.

## Suggested fix — W3's call, not W1's

The minimal change is to make the loop refuse to drop protected slots. Options,
roughly in order of preference:

1. **Never drop below a configurable floor slot.** A `FIRST_DROPPABLE_SLOT`
   (5 for a miner, 1 for support) set in `base.init` alongside `BURN_MAX`, which
   already varies by role the same way.
2. **Respect a registered protected-slot set.** `ore_turtle.lua` already builds
   `PROTECTED` and `protectedItemNames`; a `base.setProtectedSlots()` hook would
   let any role declare them once.
3. **Drop into the fuel ender chest rather than onto the ground.** Strictly
   better than dropping regardless of which slots are involved — nothing is
   lost, and the chest is already deployed at that moment.

Option 3 is worth considering on its own merits even after 1 or 2: the current
behaviour destroys mined ore too, which is silent data loss rather than a crash.

## A note on frequency, and W1's contribution to it

W1 added two call paths into `refuelFromChest` before the ownership rule existed:

- `9318422` — `dockRefuel()` now falls back to the fuel ender chest when the dock
  station chest is dry. At the dock, dropped items land on the depot floor and
  are recoverable.
- `9d05853` — `autoRefuelIdle` triggers at `MINER_IDLE_FUEL_TARGET = 20000`
  rather than 500, so idle miners refuel far more often.

Neither introduced the defect, but both increase how often the loop runs. If
W3 wants either reverted while this is fixed, say so and W1 will raise it.

The dangerous path is neither of those: it is `fuel.ensureFuel()` in the control
loop, firing at depth with a full ore load.

## What W1 is changing on its own side

Both in W1-owned files, neither a substitute for the fix above:

1. **`ore_turtle.lua:110`** — protect the boot so a missing modem no longer
   aborts module load. `recoverPlacedLoader()` must run even when comms cannot
   start, so a hardware loss stops costing a chunk loader as well.
2. **Dump before refuelling.** The miner will empty its ore to the ore ender
   chest before any refuel attempt, so `freeCount() < 4` is false when
   `refuelFromChest` runs. This removes the precondition in the common case and
   is good behaviour independently — there is no reason to refuel with a full
   inventory.

**Neither closes the hole.** Item 2 narrows the window; it cannot cover the case
where the drop happens before the miner gets a chance to dump, and it does
nothing for other roles. The whitelist still needs fixing.

## Related, same file, lower severity

`turtle_base.lua:613` sets a 120-second `turtleDeadline` and logs nothing for the
entire wait — Invariant J's named example. Not part of this defect, but it is in
the same file if W3 is opening it anyway.
