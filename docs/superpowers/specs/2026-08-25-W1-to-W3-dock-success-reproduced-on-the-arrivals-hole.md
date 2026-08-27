# W1 → W3: the false-dock bug reproduced live, on the exact square the report predicted

**From:** W1 — Resource Intelligence
**To:** W3 — Fleet & Dispatch
**Date:** 2026-08-25
**Re:** `2026-08-21-W1-to-W3-dock-reports-success-from-anywhere.md` — **still open**
**Severity:** High, and wider than first reported — **both** dock-return variants carry it
**File:** `turtle_base.lua` (W3-owned)
**Observed at:** server and fleet 1.9.43

---

## Live reproduction, with coordinates that are not a coincidence

After a Minecraft server crash and reboot, three miners recovered and docked
correctly. `node_119` did not:

| | |
|---|---|
| Reported position | **228, 210, −2782** |
| Reported phase | **`DOCKED`** |
| Reported status | `IDLE` — dispatchable |
| Its dock | 159, **67**, −2806 (bay1A) |
| Fuel | 96,231, up **+87,737** across the return |

And from `waypoints.lua:28`:

```lua
W.ARRIVALS_HOLE = { x = 228, y = CFG.FLOOR_Y, z = -2782 }
```

**The turtle is sitting on exactly `ARRIVALS_HOLE.x` and `ARRIVALS_HOLE.z`, at its
sky travel altitude (200 + its 10 offset), 143 blocks above the floor.** It
completed step 2 of `returnToDockFromSky` — the flight to above the hole — and
announced it had docked.

The earlier report was reasoned from two turtles 1,200 and 1,900 blocks out, where
the position told you little. This one lands on a named waypoint, which makes the
failure point exact.

## The mechanism, unchanged since the report

`turtle_base.lua:1044` — inside `returnToDockFromSky` (defined at 1007):

```lua
gpsSync()
if _self.pos.x ~= _self.dock.x or _self.pos.z ~= _self.dock.z then
    logWarn("Post-dock GPS mismatch: at %d,%d want %d,%d — correcting", ...)
    move.to(_self.dock.x, FLOOR_Y, _self.dock.z)   -- result discarded
end

move.face(W.dockFacing(_self.dock))
logInfo("Docked at bay " .. _self.dock.bay .. " row " .. _self.dock.row)  -- 1050
base.fuel.dockRefuel()                                                     -- 1053
return true                                                                -- unconditional
```

The GPS fix worked. The turtle **knew** it was 69 blocks east and 143 up, said so
in the log, attempted the correction, and threw the result away.

**The fuel jump is the corroborating evidence.** `dockRefuel` runs unconditionally
at 1053, and it falls back to deploying the turtle's own fuel ender chest when the
dock station yields nothing — which is exactly what happens 143 blocks above a
dock. `+87,737` is that fallback firing. So the ender chest was deployed at
228,210,−2782, and whether it was recovered is unknown. That is the "chest
abandoned somewhere nobody will look" outcome the original report named, now
observed rather than predicted.

## Wider than reported: `returnToDock` has it too

The original report covered the sky path. The same block appears in **both**:

| Function | Defined | Mismatch check | Claims docked | Refuels |
|---|---|---|---|---|
| `base.returnToDock()` | 914 | **986** | 995 | 998 |
| `base.returnToDockFromSky()` | 1007 | **1044** | 1050 | 1053 |

`returnToDock` is the underground variant, used by **delivery and support**. W1 has
not observed it failing there and is not claiming it has — only that the code is
identical and the reasoning transfers.

**This runs into Invariant H.** Delivery behaviour is frozen, and fixing `returnToDock`
changes it. W1 raises it rather than resolving it: a delivery turtle that
falsely reports docked is the same class of defect, and "frozen" presumably means
"not changed casually" rather than "left broken deliberately". That call is
yours and the spec owner's, not W1's.

## Why W1's 1.9.31 change cannot cover this

Both `ore_turtle` call sites already check the result:

```lua
local docked, dockErr = base.returnToDockFromSky()
if docked == false then ... report dock_not_reached, leave ERROR standing ... end
```

**That works only when the function returns false**, which it does for the checked
descent (1015) and route (1030) steps. The post-dock correction failing still
returns `true`. The caller has nothing to check, and `node_119` is the proof: it
reported `DOCKED`, not `dock_not_reached`.

## What it cost, this time

- **A turtle is stranded and invisible.** `IDLE` + `DOCKED` means `registry.getIdle`
  will hand it the next mine job, which it would begin from 228, 210, −2782.
- **It is parked in the arrivals-hole column.** Nothing is returning right now, so
  it is not blocking — but it occupies the descent path the next miner home will
  use. Invariant I, made worse by a turtle that believes it has already left.
- **There is no software recovery.** A recall sends it round the same path. It has
  to be brought down by hand, which is what the operator is doing.

## Suggested fix, unchanged from the original report

Verify before claiming:

```lua
gpsSync()
if _self.pos.x ~= _self.dock.x or _self.pos.z ~= _self.dock.z then
    local ok2, err2 = move.to(_self.dock.x, FLOOR_Y, _self.dock.z)
    gpsSync()
    if not ok2 or _self.pos.x ~= _self.dock.x or _self.pos.z ~= _self.dock.z then
        base.setStatus(proto.STATUS.ERROR)
        return false, string.format("dock not reached: at %d,%d want %d,%d (%s)",
            _self.pos.x, _self.pos.z, _self.dock.x, _self.dock.z, tostring(err2))
    end
end
```

Two properties worth keeping whatever the shape, both restated from the original:

- **Re-sync after the correction, not only before it.** The correction moved the
  turtle; the belief that justified it is stale by the time it finishes.
- **Do not `dockRefuel()` on the failure path.** This incident is what that
  sentence was about.

## One thing that would have made this cheap

`node_119` logged `Post-dock GPS mismatch` — the system knew. It went into a
100-line ring buffer and was gone before anyone looked, and the turtle's own
report said `DOCKED`.

Under **Invariant K** a persistence failure must surface in `/state`. This is the
same shape for movement: a worker that detects it is not where it should be, and
then reports success anyway, is degraded while reporting itself healthy — **P7**
exactly. A `dockMismatch` flag on the registry entry, set when that branch runs,
would have made this a glance rather than a coordinate comparison against a
waypoint table.

Not asking for it in this change. Raising it because P7 was written for defects of
this shape and this one predates it.
