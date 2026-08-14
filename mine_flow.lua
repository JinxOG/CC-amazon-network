-- mine_flow.lua
-- The place / swap / mine / swap / retrieve cycle for a solo miner that
-- carries its own chunk-loader turtle as cargo.
--
-- Ordering is the whole safety argument, so it lives in one place:
--
--   placeLoader:    place loader  ->  confirm standing  ->  wait for its
--                   beacon  ->  chunky->pickaxe  ->  arm fence (on the
--                   LOADER's chunk)
--   retrieveLoader: verify chunky carried  ->  modem->chunky  ->  dig  ->
--                   pickaxe->modem  ->  release fence
--
-- Placement removes chunky only AFTER the loader is confirmed down AND has
-- proven -- via a LOADER_BEACON -- that it is actually holding the chunk.
-- Retrieval equips chunky BEFORE the loader comes up. At no instant is the
-- miner both unloaded (no chunky of its own) and outside the base-loaded
-- area.
--
-- turtle.place() drops the loader one block AHEAD of the miner, which can be
-- a DIFFERENT chunk than the miner's own position. So every fence anchors on
-- the loader's target chunk, never on the miner's position. This is also why
-- _hooks.pos() must return facing as well as x/y/z: "ahead" cannot be
-- computed from bare coordinates.
--
-- loader_state.record() is called before turtle.place() and loader_state.
-- clear() only after a confirmed retrieval, so a crash at any instant errs
-- toward "we may have a loader out there" rather than silently losing one
-- (see loader_state.lua). A *clean* place() failure (not a crash -- we get a
-- definite answer back) does roll the record back, because leaving a false
-- positive on disk is strictly worse than a correct one and we know for
-- certain nothing was placed. A place() that reports success but then can't
-- be confirmed standing leaves the record in place: we do NOT know what
-- happened there, and the cautious assumption is that it exists.

local equipment    = require("equipment")
local geofence      = require("geofence")
local loader_state = require("loader_state")

local mine_flow = {}

-- Hook contract -- implemented by ore_turtle.lua (Task 8b). This module stays
-- free of comms and movement; everything it needs from the world comes
-- through these:
--
--   reportPhase(phase, detail)
--       phase is a plain string matching one of proto.PHASE.* by value
--       (mine_flow does not require protocol.lua -- the caller owns turning
--       this into a proto.payloadMinePhase() and sending it).
--
--   log(msg)
--       Human-readable progress line.
--
--   pos() -> { x = , y = , z = , facing = }
--       The miner's current position AND facing. Facing is required: it is
--       the only way to compute the block turtle.place() will actually drop
--       the loader on (see aheadBlock below).
--
--   pump(pollSeconds)
--       Called repeatedly while placeLoader waits for the placed loader's
--       first LOADER_BEACON. Each call is expected to block for roughly
--       `pollSeconds` real seconds (a proto.receive-style wait blocks via
--       os.pullEvent, so this falls out naturally) and to call
--       mine_flow.noteBeacon(msg) for any LOADER_BEACON message it sees
--       during that window. mine_flow calls it up to BEACON_WAIT_ATTEMPTS
--       times, so real-world wait time is approximately
--       BEACON_WAIT_ATTEMPTS * pollSeconds. A pump that never delivers a
--       beacon is a safe default (fail closed): placeLoader will refuse
--       rather than silently proceed.
local _hooks = {
    reportPhase = function() end,
    log         = print,
    pos         = nil,
    pump        = function() end,
}
function mine_flow.setHooks(h)
    for k, v in pairs(h) do _hooks[k] = v end
end

local function report(phase, detail) _hooks.reportPhase(phase, detail) end
local function log(msg) _hooks.log(msg) end

-- One block ahead of the miner -- where turtle.place() will put the loader.
local function aheadBlock(p)
    local dx, dz = 0, 0
    if     p.facing == 0 then dz = -1
    elseif p.facing == 1 then dx =  1
    elseif p.facing == 2 then dz =  1
    else                      dx = -1 end
    return p.x + dx, p.z + dz
end

-- ─── Beacon gate (deferred from Task 5c) ────────────────────────────────────
-- Never surrender the miner's own chunk loading to a placed loader that has
-- not proven it is alive.
--
-- LOADER_BEACON is spelled out literally here (matching proto.MSG.
-- LOADER_BEACON's value, pinned by tests/test_loader_beacon.lua) rather than
-- requiring protocol.lua, for the same reason phase names are plain strings
-- above: this module has no wire dependency, only a value-shape one.

local BEACON_WAIT_ATTEMPTS = 15   -- ~15s of real time if pump() blocks ~1s/call
local BEACON_POLL_SECONDS  = 1

local _lastBeaconAt          = nil    -- os.epoch("utc")/1000 of the most recent beacon
local _beaconArrivedSinceGate = false -- reset at the start of every wait; see waitForFreshBeacon

-- Call for every message the caller receives; harmless to call for anything
-- else (it is a no-op unless the message is actually a LOADER_BEACON).
function mine_flow.noteBeacon(msg)
    if type(msg) ~= "table" or msg.type ~= "LOADER_BEACON" then return end
    _lastBeaconAt = os.epoch("utc") / 1000
    _beaconArrivedSinceGate = true
end

-- General-purpose liveness query: has a beacon been seen in the last
-- `seconds` real seconds? Independent of the placement gate below.
function mine_flow.beaconSeenWithin(seconds)
    if not _lastBeaconAt then return false end
    return (os.epoch("utc") / 1000 - _lastBeaconAt) <= seconds
end

-- Blocks (via repeated _hooks.pump calls) until a beacon arrives THAT WAS
-- NOTED AFTER THIS CALL STARTED, or BEACON_WAIT_ATTEMPTS run out.
--
-- This deliberately does not reuse beaconSeenWithin's timestamp math: two
-- events a few real milliseconds apart can land in the same integer second
-- under os.epoch's precision, which would make a "was it seen since time T"
-- comparison unreliable right at a placement boundary -- exactly where it
-- matters most. A beacon from the PREVIOUS sector's (now-retrieved) loader
-- must never satisfy THIS sector's gate, so the flag is explicitly reset
-- before waiting rather than inferred from a clock reading.
local function waitForFreshBeacon()
    _beaconArrivedSinceGate = false
    for _ = 1, BEACON_WAIT_ATTEMPTS do
        if _beaconArrivedSinceGate then return true end
        _hooks.pump(BEACON_POLL_SECONDS)
    end
    return _beaconArrivedSinceGate
end

-- Place the carried loader turtle ahead, confirm it is standing, wait for it
-- to prove it's alive, then hand chunk duty over to it and arm the fence
-- around it.
--
-- anchorChunk is the chunk the sector requires the loader to occupy: with
-- SECTOR_STEP=32 and SCAN_RADIUS=16 the work area is exactly the 3x3 chunks
-- centred on chunkOf(sectorCentre). Placing one chunk off leaves the sector's
-- far edge unloaded, so this is checked BEFORE the loader leaves the
-- inventory -- recovering it afterwards would need a pickaxe we are not
-- holding.
function mine_flow.placeLoader(chunkRadius, anchorChunk)
    report("PLACING_LOADER")

    local ok, reason = equipment.validate("travel")
    if not ok then return false, reason end

    local slot = equipment.findSlot(equipment.ITEMS.LOADER_TURTLE)
    if not slot then return false, "loader_turtle_missing" end

    -- turtle.place() puts the loader one block AHEAD, which can be in a
    -- different chunk than the miner. The fence must describe the LOADER's
    -- chunk, since that is the thing doing the loading -- anchoring on the
    -- miner's own position is wrong wherever the two straddle a boundary.
    local p = _hooks.pos()
    local tx, tz = aheadBlock(p)
    local lcx, lcz = geofence.chunkOf(tx, tz)

    if anchorChunk and (lcx ~= anchorChunk.cx or lcz ~= anchorChunk.cz) then
        -- Caller must reposition; never place a loader that cannot cover the
        -- sector. Recovering it would need a pickaxe we are not holding.
        return false, "loader_target_wrong_chunk"
    end

    turtle.select(slot)
    if turtle.detect() then
        return false, "placement_blocked"
    end

    -- Persist the "a loader is about to leave our inventory" fact BEFORE it
    -- actually does: a crash between here and the confirmed-standing check
    -- below must leave a record a recovery pass can act on, never silence.
    loader_state.record(tx, p.y, tz, anchorChunk, chunkRadius)

    if not turtle.place() then
        -- A known-clean failure, not a crash: the item never left the
        -- inventory (real turtle.place() only consumes it on success), so
        -- the record just written would be a false positive. We know for
        -- certain nothing is out there, so undo it.
        loader_state.clear()
        return false, "loader_place_failed"
    end

    -- Confirm it is actually standing before giving up our own chunk
    -- loading.
    if not turtle.detect() then
        -- place() reported success but we can't confirm it. Unlike above, we
        -- do NOT know nothing was placed -- the cautious assumption is that
        -- it exists, so the record stays for recovery to resolve.
        return false, "loader_not_detected_after_place"
    end
    log("Loader placed and confirmed standing.")

    log("Waiting for loader beacon before giving up chunk loading...")
    if not waitForFreshBeacon() then
        -- The loader is down (and recorded) but has not proven it is alive.
        -- Never surrender our own chunk loading to an unconfirmed one.
        return false, "loader_no_beacon"
    end
    log("Loader beacon confirmed.")

    report("SWAP_TO_PICKAXE")
    local swapped, why = equipment.toMineMode()
    if not swapped then
        -- We still hold chunky, so we are safe; the loader is down and will
        -- be retrieved by the caller's failure path.
        return false, why
    end

    -- Anchor on the loader's chunk, not the miner's position.
    geofence.setAnchorBlock(tx, tz, chunkRadius)
    log(string.format("Fence armed on chunk %d,%d radius %d (loader at %d,%d)",
        lcx, lcz, chunkRadius, tx, tz))
    return true
end

-- Restore self-loading, then take the loader back. Never dig it up first.
function mine_flow.retrieveLoader()
    -- Refuse before touching anything if we cannot restore our own loading.
    if not equipment.findSlot(equipment.ITEMS.CHUNKY) then
        return false, "chunky_missing"
    end
    if not turtle.detect() then
        return false, "loader_not_in_front"
    end

    report("RETRIEVING", "comms gap expected")

    -- Sacrifice the modem, not chunk loading: offline is recoverable,
    -- unloaded is not. Comms are down from here until the swap-out below.
    local ok, reason = equipment.retrievalSwapIn()
    if not ok then return false, reason end

    local dug = turtle.dig()
    if not dug then
        -- Put comms back before reporting the failure. Chunky stays on
        -- throughout this recovery attempt regardless of whether it
        -- succeeds -- chunk loading is never the thing given up.
        equipment.retrievalSwapOut()
        return false, "loader_dig_failed"
    end

    local restored, why = equipment.retrievalSwapOut()
    if not restored then return false, why end

    -- Only now is the loader confirmed back in our own inventory: clear the
    -- persisted record. Any earlier failure above must leave it intact.
    loader_state.clear()

    geofence.clear()
    log("Loader retrieved; self-loading restored.")
    return true
end

return mine_flow
