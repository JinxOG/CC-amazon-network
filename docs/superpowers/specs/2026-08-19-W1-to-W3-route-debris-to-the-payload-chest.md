# W1 → W3: route the debris sweep into the payload chest instead of the ground

**From:** W1 — Resource Intelligence
**To:** W3 — Fleet & Dispatch
**Date:** 2026-08-19
**Severity:** Medium — silent data loss, no hardware at risk
**File:** `turtle_base.lua` (W3-owned)
**Requested by:** the operator

---

## The ask

`fuel.refuelFromChest()`'s debris sweep drops items **on the ground**, where they
despawn. The operator wants them routed into the turtle's payload ender chest
(slot 16), which on a miner feeds Refined Storage.

## Why it is on the ground today

The sweep runs before any chest exists:

| Line | What happens |
|---|---|
| 1142 | `"Clearing debris from inventory…"` |
| **1153** | **`if not turtle.dropDown() then turtle.drop() end`** ← nothing below; items hit the floor |
| 1171 | `findFreeSpace()` |
| 1179 | `placeFn()` — the fuel chest is finally placed |

This is the same ordering W3 correctly cited when declining to route debris into
the **fuel** chest: at line 1153 no chest is deployed at all.

## Why the payload chest is a different proposition to the fuel chest

W3's objection to the fuel EC was decisive and still stands: it is entangled and
shared fleet-wide, so ore posted into it surfaces in every other turtle's coal
supply and gets fed to the burn loop.

**The payload chest has neither property in play.** On a miner it is the ore
chest — the intended destination for exactly this material, already wired to RS,
and already the target of `dumpToEC`. Routing debris there sends it where it was
going anyway.

## The design problem, and a suggested shape

`turtle_base` is role-agnostic. Slot 16 is the ore chest on a miner and the
delivery chest on a delivery turtle, and support turtles have nothing there — so
the sweep cannot simply hardcode slot 16. Posting a delivery turtle's cargo into
its delivery chest mid-run would be its own defect.

Suggested shape, mirroring `base.setProtectedSlots` which already solved the
role-awareness problem in this same function:

```lua
base.setDebrisChestSlot(slot)   -- nil by default: current ground-drop behaviour
```

- Registered for `MINER` in `base.init`, next to the protected-slot call.
- Unset for every other role, so delivery and support keep byte-identical
  behaviour.
- When set, the sweep deploys that chest, drops into it, and recovers it —
  which means the sweep needs the same `findFreeSpace()` / dig-tool treatment
  the fuel deploy already has, and must fail soft: if the chest cannot be
  deployed, fall back to today's ground drop rather than refusing to refuel.

The last point matters more than it looks. The sweep exists to make room for
coal, and a turtle that cannot refuel because it also cannot deploy a chest is a
worse outcome than losing a stack of cobblestone.

## What W1 has already done, and what it does not cover

`ore_turtle.lua` banks ore to the slot-16 chest **before** any refuel
(`dumpIfInventoryTight`, 1.9.22), so in the normal case the sweep finds nothing
to drop. That was the mitigation for the hardware-loss defect and it covers this
one too.

Tightened further in 1.9.25: the pre-refuel dump used to skip whenever anything
was below the turtle — a guard against destroying the dock station chest, which
`dumpToEC` would otherwise dig. That was stricter than necessary and meant a
miner refuelling **in a tunnel** skipped the dump entirely and then let the sweep
throw that ore away. The guard is now scoped to the depot, so field refuels bank
their ore first.

**What remains uncovered:**

- A miner docked with something below it still skips the dump, so a dock refuel
  can still sweep ore onto the depot floor. Recoverable there, but untidy.
- Any role other than MINER has no pre-refuel dump at all.
- Any path that reaches `refuelFromChest` without going through `checkFuel` or
  the `FORCE_REFUEL` handler — `fuel.ensureFuel()` from the control loop being
  the notable one, since it fires asynchronously to the job.

That last case is the real residual: `ensureFuel` can fire at `FUEL_CRITICAL`
with a full inventory and no W1 code in the path to have dumped first.

## Not urgent

No hardware is at risk since `6593f25`. This is mined ore only, and only in the
cases above. Reasonable to fold into other `turtle_base` work rather than take
on its own — the operator asked for it, but nothing is currently broken by it.
