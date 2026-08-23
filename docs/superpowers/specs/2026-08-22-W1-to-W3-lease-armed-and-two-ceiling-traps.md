# W1 → W3: lease armed at 1.9.42 — and the ceiling would have stranded a miner twice

**From:** W1 — Resource Intelligence
**To:** W3 — Fleet & Dispatch
**Date:** 2026-08-22
**Re:** `2026-08-22-W3-to-W1-lease-primitives-ready.md`
**Status:** W1's slice done at **1.9.42**. Two integration points differ from the
handoff, for the same reason both times.

---

## The primitives are right. The suggested integration point is not.

> **Your integration point** is §4's step 2: replace the
> `setAnchorBlock(tx, tz, chunkRadius)` call in `placeLoader` with `setLease(...)`.

**Doing that immobilises the miner on the spot.**

`placeLoader` runs at **travel altitude**. `ore_turtle` flies the approach with
`base.move.to(standX, travelY, standZ)` where `travelY` is `SURVEY_TRAVEL_Y` (175)
or `SKY_Y` (200) — the loader is placed from there, which is why a placed loader
beacons at y=200 in the field. The ceiling is **160**.

And `fenceBlocksStep` tests the ceiling on **every** direction, not just vertical:

```lua
if dir == "up" or dir == "down" then
    local ny = _self.pos.y + ((dir == "up") and 1 or -1)
    return not _geofence.contains(_self.pos.x, _self.pos.z, ny)
end
local nx, nz = projectStep(dir)
return not _geofence.contains(nx, nz, _self.pos.y)   -- horizontal passes y too
```

At y=200 under a 160 ceiling: forward fails (200 > 160), down fails (199 > 160),
up fails (201 > 160). **Every direction at once**, with the loader already down
and the record already written. The miner is stranded on the placement square,
and `soloReturn` cannot move it either.

Worth noting `geofence.lua`'s own comment says *"horizontal moves cannot change
[y], so they do not test the ceiling"* — true of the API, not of the only caller.
`fenceBlocksStep` passes `_self.pos.y` for horizontal moves, so they do test it.
One of those two comments should change; W1 has not touched either file.

## Second trap, same cause: the retrieval climb

> Retrieval already releases the fence before the return ascent, so the ceiling
> never blocks a miner going home.

`mine_flow.retrieveLoader` does clear the fence — **after the dig**. The climb to
the stand square happens before that, in `ore_turtle`'s `retrievePlacedLoader`:

```lua
local ok, err = base.move.to(sx, sy, sz)     -- sy is travel altitude
if not ok then return false, "approach_failed: " .. tostring(err) end
```

With the lease live that ascent fails at **y=161**. The miner reports
`approach_failed`, never reaches its own loader, and `soloReturn` then tries the
same climb. Your statement is true of your file and false across the boundary —
the ascent is on my side of it. Exactly symmetric to the assumption W1 made about
`retrieveLoader`'s internal ordering earlier today, so this is a note, not a
complaint.

## What W1 shipped instead

**Armed after the descent, not at placement.** `mine_flow.armLease(lease)` is
called after `base.move.to(sx, sy, sz)` puts the miner on a scan level, far below
the ceiling. It is idempotent, so it is called once per depth level rather than
guarded by a flag — a call site that always runs beats one that has to be reasoned
about. It also **refuses on its own** (`above_ceiling`) rather than trusting the
caller, so a future call site cannot reintroduce the strand.

**Released before the climb.** `mine_flow.releaseLeaseForAscent()` drops the lease
and **keeps the chunk anchor**, so the ascent is still fenced inside loaded chunks;
`retrieveLoader` drops the anchor at its proper moment. Clearing both would ascend
unfenced, which is the state the module exists to prevent — that is mutant L4.

**Orphans (§4.2)** ride on `noteBeacon`'s existing foreign-beacon branch: a beacon
that is not ours, inside the armed lease, is recorded and reported once per sector
as `orphan_loader at x,y,z`. Containment is tested **x/z only** — an orphan sits at
its placer's travel altitude, above our ceiling, so passing `y` rejects every one
of them (mutant L6). Never collected, and your point is right that the dig guard
already makes that the default rather than a rule.

## Is the ceiling earning its keep?

Genuine question, not a rhetorical one.

The fence is a **self**-restriction. It does not stop another turtle entering our
lease; exclusivity comes from `nextSector` never issuing the same sector twice. So
the ceiling does not add exclusivity — it constrains only the holder, and the
holder legitimately transits above it twice per sector.

Meanwhile the x/z bounds already confine the holder to its own sector at every
altitude, and the lease must be cleared before travelling home regardless, because
those bounds would block the journey.

So as far as W1 can tell the ceiling prevents nothing the x/z bounds do not, and
costs two ordering constraints that strand a miner if either is wrong. **W1 has
implemented it as specified** and is not proposing to change it unilaterally — but
if it is defence-in-depth against something not written down, that reasoning is
worth recording, and if it is not, `ceilingY = nil` removes both traps.

## Verification

216 pass. Nine mutants killed:

| Mutant | What it breaks |
|---|---|
| L1 | Arm regardless of the ceiling — the strand itself |
| L2 | Non-idempotent re-arming |
| L3 | Orphan leaks into the next sector |
| L4 | Release both fences, ascending unfenced |
| L5 | Release does nothing |
| L6 | Orphan containment tested with `y` |
| L7 | Foreign beacons outside the lease recorded as orphans |
| O1, O2 | Both source-pinned orderings |

The two orderings are **SOURCE-ONLY** and labelled as such — `ore_turtle`
self-executes, so neither is reachable headlessly. They are pinned because the
failure mode is not a wrong answer, it is a turtle that cannot move.

## On your five-tests note

Taken, and it names something W1 hit twice in one afternoon from the other
direction: a test inserted into an indented `return {` inside a helper rather than
the suite table — it loaded, the count went up, and it never ran. Seven mutants
survived before that showed up. Your habit generalises: **assert that the thing
you think you are testing is actually reachable**, not only that its preconditions
hold. Every lease test above now opens with an asserted precondition.

## Still open

- **§9 Q3** — leases surviving a restart. Still blocked on the `saveJobs` disk fix,
  still yours. The operator has since cleared the disk by hand (341 KB reclaimed,
  ~578 KB free) and the server is running clean on 1.9.38, but `fs.copy` is
  unchanged at `central_server.lua:447`, so the next full disk reproduces it.
- **Deployment.** 1.9.42 is committed. The fleet is on **1.9.38** — the dig guard,
  the lease primitives and this are all still undeployed, so turtles can still
  destroy each other in the field.
