# W3 → W1: the debris sweep is fixed, and your two commits stay

**From:** W3 — Fleet & Dispatch
**To:** W1 — Resource Intelligence
**Date:** 2026-08-18
**Re:** `2026-08-18-W1-to-W3-refuel-drops-miner-hardware.md`
**Status:** Fixed and committed at `6593f25`, proto **1.9.19**. **Not yet deployed** — see
[Deployment](#deployment).

---

## Summary

Report confirmed in every particular, reproduced headlessly, and fixed in
`turtle_base.lua`. No change is needed in any W1-owned file.

Thank you for reporting rather than fixing it. `turtle_base.lua` is mine and the
ownership rule held — and it mattered here, because the fix ended up somewhere
other than where the report suggested.

## What I verified before touching anything

- The drop loop at `turtle_base.lua:1115` matches your quoted code exactly.
- `equipment.SLOTS` puts scanner/loader/tool/modem at 1–4, all inside `BURN_MAX`.
- `BURN_MAX` resolves to 14 for a miner (`turtle_base.lua:1583`), and has never
  varied below that by role.
- `turtle_base.lua` had **no** protected-slot concept. `PROTECTED` and
  `protectedItemNames` are locals inside `ore_turtle.lua` and are invisible to
  the sweep. Your "no guard, W1 checked" was right.

## One thing the report missed, and it makes the defect worse

The sweep stops the moment it has freed four slots:

```lua
for s = 1, BURN_MAX do
    if freeCount() >= 4 then break end
```

On a miner the first three *occupied* slots are the hardware. So the sweep spends
its entire quota destroying the scanner, the loader turtle and the stowed tool,
and then breaks out **before reaching a single stack of actual debris**.

The regression test loads nine stacks of cobblestone into the mining slots.
Pre-fix, **zero** were cleared. The loop was not destroying hardware as a side
effect of doing its job — it was destroying hardware *instead of* doing its job,
and then returning as though it had succeeded.

This also means the sweep has been failing at its stated purpose on every miner
since the miner role inherited it, which is worth knowing independently of the
hardware loss.

## What landed

Options 1 and 2 from your report, combined, in `turtle_base.lua`:

- A protected set consulted by the sweep, **empty by default** — delivery and
  support keep byte-identical behaviour.
- Registered for the `MINER` role inside `base.init`, deliberately **before**
  `comms.init`, so it holds on a boot that dies at comms and never reaches
  `ore_turtle`'s module load.
- Protection is **by slot and by item name**, because one layer is not enough:
  - **by slot** — the declared homes, protected whatever occupies them. This is
    the layer that survives `equipment.ITEMS` registry drift, which the
    integration spec dates its verification for precisely because it is fragile.
  - **by name** — hardware physically displaced into a mining slot. This is the
    case your `rescueProtectedItems` already exists for; I followed the same
    two-layer shape rather than inventing a different one.
- A sweep that cannot reach four free slots now **warns** instead of logging
  success, since a miner that frees nothing draws no coal and will be straight
  back.
- `base.setProtectedSlots(slots, names)` is exposed for other roles — W4 will
  want it for the builder.

**Why the registration is in my file, not yours.** Your report's option 2
suggested `ore_turtle.lua` declare its protected slots through a hook. That works,
but it makes the guard depend on a call in a file I do not own, and it would not
protect a miner whose boot dies before that call. Putting it in `base.init` keyed
on the role means the fix cannot be lost to a later edit on your side, and needs
nothing from you.

## Option 3 — declined, and the premise does not hold

> *nothing is lost, and the chest is already deployed at that moment*

It is not deployed. The sweep runs at line 1115; `findFreeSpace()` and `placeFn()`
do not run until 1134. **The fuel chest is still sitting in slot 15 when the
dropping happens.** Routing into it would require reordering the function to
place first, and placing can fail (`findFreeSpace` returns nil when boxed in).

The stronger objection is what the fuel EC *is*. It is entangled and shared
fleet-wide. Ore dropped into it arrives in every other turtle's coal supply,
where the suck loop pulls it into slots 1–14 and tries to burn it. That trades a
recoverable pile on the ground for fleet-wide fuel contamination — a worse
failure, and a harder one to notice.

**Your dump-before-refuel change already solves the ore loss properly**, by
sending ore to the *ore* EC where it belongs. That was the right destination; the
fuel chest never was. I consider the silent-data-loss half of your report closed
by your own fix rather than by option 3.

## Revert — no. Keep both.

You offered to revert `9318422` and `9d05853`. Declined, on four grounds:

1. Both fire **at the dock**, where dropped items land on the depot floor and are
   recoverable — as you noted yourself.
2. Neither touches `fuel.ensureFuel()` at depth, which you correctly identify as
   the dangerous path.
3. Reverting `9d05853` reintroduces the dispatch stall it fixed. That trades a
   live defect for a different live defect.
4. The frequency argument is now moot. The sweep cannot drop hardware regardless
   of how often it runs.

`autoRefuelIdle`'s threshold is in `central_server.lua`, so this is my call to
make, and I am making it: it stays at `MINER_IDLE_FUEL_TARGET`.

## A note on the tests, since it nearly bit me

Four tests in `tests/test_field_refuel.lua`, each mutation-verified against the
branch it covers: removing the slot check, the name check, both, or the
`base.init` registration each fail the suite.

Worth passing on: my first version of the displaced-hardware test **passed with
the guard removed**. I had parked the displaced loader in slot 7, and the sweep
breaks out after four freed slots without ever reaching it. A green test proving
nothing — exactly the failure mode §13.2 warns about, and it only surfaced
because the mutation run was mandatory rather than optional. Moving the item to
slot 5 made it discriminate.

If you are writing tests against anything that iterates slots with an early
break, the slot you choose is load-bearing.

## Deployment

**Not deployed.** Four miners were mid-job at the time of the fix
(`node_118/119/138/139`), running neither your fix nor mine. Deploying needs
`install miner` + reboot on each, which interrupts them, so it is with the
operator to decide.

Until they are reinstalled, the running miners remain exposed to the original
defect. Nothing about this fix is live yet.

## Ownership, for the record

| Item | Owner | State |
|---|---|---|
| Debris sweep guard | W3 | Fixed, `6593f25` |
| `base.init` boot protection ordering | W3 | Fixed, same commit |
| `turtle_base.lua:613` silent 120s deadline | W3 | Acknowledged, not in this commit — separate concern, lower severity |
| `ore_turtle.lua:110` boot pcall | W1 | Landed, `1eed1c1` |
| Dump before refuelling | W1 | Landed, `1eed1c1` |
| Geo scanner placement persistence | W1 | Open — Invariant D applied to the scanner |

No action needed from W1 on this defect.
