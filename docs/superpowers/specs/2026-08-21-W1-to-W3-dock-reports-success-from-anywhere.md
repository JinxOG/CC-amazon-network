# W1 → W3: `returnToDockFromSky` reports success from 1,900 blocks away

**From:** W1 — Resource Intelligence
**To:** W3 — Fleet & Dispatch
**Date:** 2026-08-21
**Severity:** High — a turtle stranded anywhere in the world announces itself docked
**File:** `turtle_base.lua` (W3-owned; W1 has not touched it)
**Observed at:** server 1.9.31, miners 1.9.30

---

## Observed

After a server shutdown mid-job, two of four miners ended up here, both at
`FLOOR_Y` and both reporting `phase=DOCKED`:

| Miner | Reported position | Depot |
|---|---|---|
| `node_118` | **2150**, 67, −2642 | x 143–228 |
| `node_139` | **1340**, 67, −3657 | z −2817…−2782 |

Roughly 1,200 and 1,900 blocks from the depot. Both also abandoned their chunk
loaders, which are still standing and beaconing at exactly their recorded
positions (`node_161` at 1160,210,−2711 and `node_159` at 1192,210,−2647).

## The defect

The end of `returnToDockFromSky` detects the problem and then discards it:

```lua
gpsSync()
if _self.pos.x ~= _self.dock.x or _self.pos.z ~= _self.dock.z then
    logWarn(string.format("Post-dock GPS mismatch: at %d,%d want %d,%d — correcting",
        _self.pos.x, _self.pos.z, _self.dock.x, _self.dock.z))
    move.to(_self.dock.x, FLOOR_Y, _self.dock.z)   -- result discarded
end

move.face(W.dockFacing(_self.dock))
logInfo("Docked at bay " .. _self.dock.bay .. " row " .. _self.dock.row)
base.fuel.dockRefuel()
return true                                        -- true regardless
```

The GPS fix at the top of that block is doing its job: it knows the turtle is not
at its dock, and says so in the log. What follows throws that away.

`move.to` over ~1,900 blocks will exhaust its retries and return false. Nothing
reads it. The function then logs `Docked at bay N row R`, tries to refuel, and
**returns `true`** — so every caller believes the turtle is parked at its bay.

Two earlier `move.to` calls in the same function — the ascent to sky altitude and
the flight to above the arrivals hole — are also unchecked. Those are the likely
reason the turtle was 1,900 blocks out to begin with: the flight home runs in
whatever coordinate frame dead reckoning has drifted into, and only the final
`gpsSync()` reveals the truth, by which point the function is one line from
declaring success.

## Why W1's 1.9.31 does not cover it

W1 hit an adjacent symptom — a miner reporting DOCKED while sitting above the
arrivals hole — and fixed the two `ore_turtle.lua` call sites to stop discarding
this function's result:

```lua
local docked, dockErr = base.returnToDockFromSky()
if docked == false then ... report dock_not_reached, leave ERROR standing ... end
```

That works only when the function actually returns false, which it does for the
checked descent and route steps. **It cannot catch this case, because the
post-dock correction failing still returns `true`.** The caller has nothing to
check.

## Suggested fix

Verify before claiming. Something in the shape of:

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

Two properties worth keeping whatever the shape:

- **Re-sync after the correction, not just before it.** The correction moved the
  turtle; the belief that justified it is stale by the time it finishes.
- **Do not `dockRefuel()` on the failure path.** `dockRefuel` falls back to
  deploying the fuel ender chest, and doing that at a random world location is
  how a chest gets abandoned somewhere nobody will look.

Checking the two earlier unchecked `move.to` calls is worth considering in the
same pass, since a failed flight is the thing that produces the stranding.

## What this costs today

A stranded turtle is invisible. It reports DOCKED, `registry.getIdle` sees IDLE,
and it is eligible for dispatch — so the server sends it a job it cannot start.
Both of ours were then refused on `loader_outstanding` and benched by the 1.9.16
guard, which is the only reason they stopped consuming dispatches. Without that
guard they would have burned every job in the queue.

## Not part of this report

The retrieval failures themselves happened inside the modem-stowed comms gap and
produced no log line at all — no `loader_retrieve_failed`, no `approach_failed`,
no mismatch reason. That is W1's blind spot to look at, and it is a separate
piece of work from this one.
