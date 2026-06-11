# Mining Robustness Design
# v1.6.71 — Crash Recovery, Stale Support Cleanup, Survey Collision Fix

## Overview

Four inter-related reliability problems fixed in a single release, motivated by
scale concerns (80 turtles) and two observed overnight failures:

1. Mining support turtle gets stuck on Minecraft server crash/reboot (can't dig
   down to meet miner, never returns home).
2. Stale support turtles left deployed after miner job completes or fails.
3. Survey mode inter-sector travel causes vertical turtle collision (miner
   ascends through support's FOLLOW_Y position; no bypass for vertical moves).
4. `jobQueue.fail()` does not cancel the paired support job on the server.

---

## Files Changed

| File | Changes |
|------|---------|
| `turtle_base.lua` | Add `base.isInsideBuilding(pos)`; make `base.init()` deferral role-aware |
| `ore_turtle.lua` | Add reboot guard in `mineJob()`; add `SURVEY_TRAVEL_Y` + `useSkyTravel` flag |
| `support_turtle.lua` | Restructure `fuelManage` block: shared follow loop with recovery path; add stale timeout |
| `central_server.lua` | Fix `jobQueue.fail()` linked cancel; add 30s stale support health check timer |
| `protocol.lua` | Bump `VERSION` to `"1.6.71"` |

---

## Problem 1 — Crash Recovery: Coordinated Sky Return

### Root Cause

`base.init()` calls `base.returnToDock()` for any turtle detected outside the
building. `returnToDock()` always descends to `UNDERGROUND_Y = 60` first.
A support turtle hovering at `FOLLOW_Y = 100` has no pickaxe (`canDig = false`)
and cannot dig through terrain to reach Y=60. It gets stuck indefinitely.

For the miner the underground return path works, but without the support
chunk-loading the path, distant chunks may not be loaded and the miner can stall.

### Approach: Job Re-Dispatch Driven Coordination

Turtles outside the building do NOT navigate home during `base.init()`.
They register with the central server, receive their re-dispatched job
(persisted in `jobs.dat`), and the job handler performs coordinated return
using the existing MINE_RECALL path — zero new protocol messages.

### Changes

#### `turtle_base.lua` — `base.isInsideBuilding(pos)` (new public helper)

```lua
function base.isInsideBuilding(pos)
    return pos.y >= CFG.FLOOR_Y
        and pos.x >= BUILDING.minX and pos.x <= BUILDING.maxX
        and pos.z >= BUILDING.minZ and pos.z <= BUILDING.maxZ
end
```

Replace the inlined check in `base.init()` with calls to this function.

#### `turtle_base.lua` — `base.init()` deferral

Replace the `elseif not insideBuilding then` branch:

```lua
elseif not insideBuilding then
    if _self.role == proto.ROLE.MINER then
        -- Defer: mineJob() will detect outside-building and call recallReturn()
        logInfo(string.format(
            "Miner rebooted outside building at %d,%d,%d — deferring return to job handler",
            p.x, p.y, p.z))
    elseif _self.role == proto.ROLE.SUPPORT and p.y > CFG.FLOOR_Y + 20 then
        -- High-altitude support (mining mode) — defer: job handler will enter recovery follow
        logInfo(string.format(
            "Mining support rebooted at altitude %d,%d,%d — deferring return to job handler",
            p.x, p.y, p.z))
    else
        -- Delivery turtles and ground-level supports: existing return path unchanged
        logInfo(string.format(
            "Rebooted outside building at %d,%d,%d — returning via arrivals hole",
            p.x, p.y, p.z))
        base.returnToDock()
    end
end
```

`CFG.FLOOR_Y + 20 = 87`. Anything above Y=87 outside the building is unambiguously
a sky-hovering mining support.

#### `ore_turtle.lua` — `mineJob()` reboot guard

At the very top of `mineJob()`, before `base.depart()`:

```lua
local function mineJob(job)
    local jobId = job.id

    -- Reboot guard: if we are outside the building, the server crashed while we
    -- were mid-job. Use the existing coordinated recall path (MINE_RECALL → sky
    -- return) so the support chunk-loads the miner's return journey.
    base.setPartnerId(job.params.partnerId)
    local startPos = base.getPos()
    if not base.isInsideBuilding(startPos) then
        base.sendProgress("Rebooted mid-job — coordinated sky return")
        recallReturn()   -- signals support via MINE_RECALL; leads to SKY_Y; returns home
        return
    end

    -- Normal departure path continues below ...
    base.setStatus(proto.STATUS.TRAVELLING, jobId)
    ...
```

`recallReturn()` is unchanged. It sends `MINE_RECALL` to the support (using the
`partnerId` from job params), ascends to `FOLLOW_Y=100`, waits 5s for support
alignment, ascends to `SKY_Y=200`, flies to arrivals, then calls `sendFailed`.

#### `support_turtle.lua` — recovery follow mode

Restructure the `fuelManage` block so both the normal path and the recovery path
share the follow loop. No `goto` needed — an `if/else` guard at the top of the
block lets both paths fall into the same loop.

```lua
if params.fuelManage then
    local SUPPORT_FUEL_WARN = 800
    local FOLLOW_Y          = 100

    local _reachedSky    = false
    local _miningMode    = false
    local _skyReturn     = false
    local _recalling     = false
    local lastUpdateTime = os.epoch("utc") / 1000

    local p = base.getPos()
    if not base.isInsideBuilding(p) then
        -- ── Recovery path ────────────────────────────────────────────────────
        -- Rebooted mid-job outside the building. Skip depart; enter the follow
        -- loop already in recall mode. The miner will send MINE_RECALL shortly
        -- via recallReturn(); we just need to be ready to receive it and track
        -- the miner's ascent to SKY_Y.
        base.setStatus(proto.STATUS.WORKING, job.id)
        base.sendProgress("Rebooted mid-job — awaiting miner MINE_RECALL")
        _miningMode = true
        _skyReturn  = true
        _recalling  = true
    else
        -- ── Normal path ──────────────────────────────────────────────────────
        base.fuel.dockRefuel()
        if base.fuel.isCritical() then
            return base.sendFailed("insufficient_fuel", false)
        end
        -- ... HOLE_READY wait, depart, status update — all unchanged ...
    end

    -- ── Shared follow loop (unchanged from current, plus stale timeout) ──────
    base.setStatus(proto.STATUS.TRAVELLING, job.id)
    base.sendProgress("Following miner")

    while true do
        -- ... (existing loop body, unmodified) ...

        -- Stale timeout: if no POSITION_UPDATE for 5min in mining mode,
        -- the miner is lost. Return via sky (safety net — server-side health
        -- check should catch this first within 30s).
        -- Add `lastUpdateTime = os.epoch("utc") / 1000` inside the
        -- POSITION_UPDATE handler, and this check inside the `not msg` branch:
        if not msg then
            local staleSec = os.epoch("utc") / 1000 - lastUpdateTime
            if _miningMode and staleSec > 300 then
                print("[SUPPORT] No miner update for 5min — returning")
                _skyReturn = true
                break
            end
            -- ... rest of existing not-msg handling ...
        end
    end
    ::mine_done::

    if _skyReturn then base.returnToDockFromSky() else base.returnToDock() end
    base.sendComplete()
    return
end
```

---

## Problem 2 — Stale Support Turtles

### Root Cause (server-side)

`jobQueue.fail()` does not cancel the linked support job. When the miner calls
`base.sendFailed()`, the server fails the miner's job but leaves the support job
`IN_PROGRESS`. The miner does send `JOB_ABORT` over CH_LOCAL, but if that is
missed there is no server-side backup. Result: orphaned support jobs that never
terminate.

### Root Cause (turtle-side)

In `_miningMode`, the support loop guards the partner-offline check with
`not _miningMode`, so when the miner's job disappears from the server after a
crash-and-return, the support waits forever for a `MINE_RECALL` that never comes.

### Changes

#### `central_server.lua` — `jobQueue.fail()` linked support cancel

Append to `jobQueue.fail()` after the FAILED/retry status is set:

```lua
if job.linkedJob then
    local linked = state.jobs[job.linkedJob]
    if linked
       and linked.status ~= JOB_STATUS.COMPLETE
       and linked.status ~= JOB_STATUS.CANCELLED
       and linked.status ~= JOB_STATUS.FAILED then
        server.cancelJob(job.linkedJob)
    end
end
```

#### `central_server.lua` — periodic stale support health check

Add `checkStaleSupports()` and a 30-second timer in `server.run()`.

```lua
local function checkStaleSupports()
    for _, job in pairs(state.jobs) do
        if (job.status == JOB_STATUS.ASSIGNED or job.status == JOB_STATUS.IN_PROGRESS)
           and job.params and job.params.masterJobId then
            local master = state.jobs[job.params.masterJobId]
            local masterActive = master
                and (master.status == JOB_STATUS.ASSIGNED
                  or master.status == JOB_STATUS.IN_PROGRESS)
            if not masterActive then
                logWarn(string.format(
                    "Stale support %s — master %s inactive, recalling",
                    job.id, job.params.masterJobId))
                server.cancelJob(job.id)
            end
        end
    end
end
```

Timer added alongside the existing `heartbeatTimer` and `bridgeTimer` in the
`server.run()` parallel loop. Fires every 30 seconds.

#### `support_turtle.lua` — stale mining timeout (turtle-side safety net)

In the `not msg` branch of the follow loop, after server-down check:

```lua
local staleSec = os.epoch("utc") / 1000 - lastUpdateTime
if _miningMode and staleSec > 300 then
    print("[SUPPORT] No miner update for 5min in mining mode — returning")
    _skyReturn = true
    break
end
```

`lastUpdateTime` is updated inside the `POSITION_UPDATE` handler.

---

## Problem 3 — Survey Mode Vertical Collision

### Root Cause

In survey mode the miner visits each scan level at exactly the sector centre
`(sx, sy, sz)`. After the deepest level (Y=8), it calls `move.to(sx, SKY_Y, sz)`
for the next sector. `move.to` ascends vertically first, so the miner rises from
Y=8 straight up through Y=100 — where the support is hovering.

`move.up()` uses `tryMove` which has no bypass for vertical direction
(`bypassForward()` only handles `"forward"`). The miner waits with progressive
backoff, times out after 120s, and returns a stuck error.

In mine mode the miner visits ore positions scattered around the sector; its last
move before ascending is lateral, so the support ends up 1 block offset — not
directly overhead. This is why mine mode does not exhibit the problem.

### Change — `ore_turtle.lua`

Add constant:
```lua
local SURVEY_TRAVEL_Y = 95   -- 5 below support FOLLOW_Y=100; miner stops here, no collision
```

Add `useSkyTravel` flag in `mineJob()`:
```lua
local useSkyTravel = false  -- flips true after first mine sector travel
```

Replace `base.move.to(sx, SKY_Y, sz)` with:
```lua
-- Survey sectors and the first mine sector (transition) use SURVEY_TRAVEL_Y=95
-- so the miner never ascends through FOLLOW_Y=100.
-- From mine sector 2 onwards, use SKY_Y=200 (same as before this fix).
local travelY = (surveyMode or not useSkyTravel) and SURVEY_TRAVEL_Y or SKY_Y
if not surveyMode then useSkyTravel = true end
base.move.to(sx, travelY, sz)
```

**Sector-by-sector travel altitude:**

| Sector | surveyMode | useSkyTravel (before) | travelY | useSkyTravel (after) |
|--------|-----------|----------------------|---------|----------------------|
| Survey 1…N | true | false | 95 | false |
| Mine 1 (transition) | false | false | 95 | true |
| Mine 2+ | false | true | 200 | true |

The first mine sector also uses Y=95, sidestepping the one-time survey→mine
transition collision. From mine sector 2 onwards the miner uses SKY_Y=200 and
moves laterally between ore positions within each sector, so the support is
offset when the miner ascends — existing behaviour that already works.

---

## Problem 4 — `jobQueue.fail()` Missing Linked Cancel

Covered under Problem 2 server-side changes above.

---

## Constants (unchanged, listed for reference)

```
SKY_Y       = 200   -- inter-sector sky travel altitude (mine mode)
FOLLOW_Y    = 100   -- support hover altitude
FLOOR_Y     = 67    -- building floor; turtles "inside" at or above this
SECTOR_STEP = 32    -- geo scanner radius=16, adjacent sectors overlap by 1 block
SCAN_LEVELS = {80, 48, 16, 8}
SURVEY_TRAVEL_Y = 95  -- NEW: inter-sector travel altitude during survey
```

---

## Edge Cases

**Central server slow to restart:** Deferred turtles loop inside `register()`,
retrying every 5s indefinitely. Existing behaviour — no change needed.

**Only one turtle of a pair reconnects:** `recallReturn()` sends `MINE_RECALL`
without waiting for acknowledgement, then ascends regardless. If the support
never receives it (unloaded chunk), the miner still returns home solo. The
support eventually returns via Fix 3 (5-minute stale timeout) once its chunk
loads. Acceptable for current scale.

**Resumed mine jobs (preDone > 0, no survey):** The `useSkyTravel = false`
initial state means the very first sector of a resumed job also uses
`SURVEY_TRAVEL_Y=95`. This is harmless — slightly lower travel altitude, no
collision risk. Switches to SKY_Y=200 from sector 2 onwards.

---

## Version

`proto.VERSION` must be bumped to `"1.6.71"` in `protocol.lua` and pushed to
remote as part of this release.
