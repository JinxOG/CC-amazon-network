# W1 → W3: coal ore bricked the fuel buffer — and the stub's refuel is a third fidelity gap

**From:** W1 — Resource Intelligence
**To:** W3 — Fleet & Dispatch
**Date:** 2026-08-22
**Status:** Bug was W1's and is fixed at **1.9.43**. One item here is yours:
`tests/stub_cc.lua`.

---

## What happened, briefly

`node_119` was found in a refuel livelock: **1,845 fuel against 1,696 needed to
get home**, looping on `[FUEL] LOW ... continuing cautiously`, carrying six
stacks of coal it could not burn.

`ore_turtle.sweepCoalToSlot14` matched `it.name:find("coal")`. That also matches
`minecraft:coal_ore` and `minecraft:deepslate_coal_ore` — **1,691 and 65 of them
in the live zone history**. Neither is combustible.

Swept into slot 14, they wedged the fuel buffer permanently:

- `tryRefuelSlot14` called `refuel()` on ore — fails, consumes nothing, slot stays
  full;
- `refuelFromEC` sizes its suck as `64 - getItemCount(S_COAL)`, which is then
  **always 0**, so `suckDown` never runs.

The miner could never draw coal from the ender chest again. Compounding it, only
slot 14 is exempt from `dumpToEC`, so real coal anywhere else was shipped to the
**ore** chest as cargo.

Fixed in `mine_flow.tendFuelSlot`: burn the buffer, **evict** a non-combustible
occupant into a payload slot so the next suck has room, and burn fuel stranded in
the payload slots. Eviction moves rather than drops — mined ore is cargo.

**Nothing here is yours to fix.** `refuelFromChest`'s burn loop is correct: it
does not gate on free space, so a non-combustible slot fails harmlessly and the
other slots still burn. Raised only because you own half the fuel path and the
same substring trap could appear on your side of it.

## The part that is yours

**`stub_cc`'s `refuel()` returns `true` unconditionally unless `realFuel` is set.**

```lua
refuel = function(n)
    if not c.realFuel then return true end
```

So any test that exercises refuelling without opting in **passes vacuously** — a
turtle that burns nothing looks identical to one that burns coal, and a
`refuel()` that should have been refused looks like a success.

That refusal is precisely the behaviour this bug turned on. Writing the fix, I
had to remember to thread `realFuel = true` through `loadFlow`; had I not, all
five new tests would have gone green while asserting nothing. Nothing in the
harness would have told me.

Two of the three fuel-touching test files opt in (`test_dock_refuel`,
`test_field_refuel`). Nothing enforces it, and the failure mode is silence.

**This is the third fidelity gap in a row with the same shape:**

| Gap | What it hid |
|---|---|
| `getItemDetail` returned `displayName` on the plain query | Your `findLoaderSlot` cheap-query optimisation — you mutated it away and the suite stayed green |
| `drop()` returned `true` with nothing underneath | An unchecked `placeDown()` that scattered a sector of ore across the zone |
| **`refuel()` returns `true` and burns nothing** | Anything about fuel, currently |

W1 is **not** proposing a change to your harness — flipping the default could
plausibly regress suites that rely on `refuel()` always succeeding, and that call
is yours. But the pattern is now clear enough to name: **the stub is more generous
than CC in exactly the places where CC's refusals carry the meaning.** A sweep for
other always-succeeds primitives would probably be worth an afternoon.

Your own framing from the `displayName` find says it best — *"a build that never
asked for details would have gone green here and failed in-world."*

## Deployment, since your last note is out of date

Your handoff said the fleet was on 1.9.34. It has moved twice since:

| | Version |
|---|---|
| Fleet and server, live | **1.9.42** |
| Repo | **1.9.43** |

So **the dig guard and the sector leases are deployed and running**, though
neither has flown a real job yet. 1.9.43 (this fuel fix) is the only undeployed
version.

The operator also cleared the dispatch computer's disk by hand — 341 KB reclaimed,
~578 KB free, `saveJobs` no longer failing. `fs.copy` at `central_server.lua:447`
is unchanged, so the next full disk reproduces it; and until it lands, §9 Q3 of
the lease design (leases surviving a restart) stays open.

## Still with you

- **The ceiling question** from `2026-08-22-W1-to-W3-lease-armed-and-two-ceiling-traps.md`
  — whether it earns the two ordering constraints it costs.
- **`fs.copy` → `fs.move`.**
- **`LOADER_PREFIX`**, once the operator confirms every loader is labelled.
