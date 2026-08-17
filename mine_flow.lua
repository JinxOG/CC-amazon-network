-- mine_flow.lua
-- The place / swap / mine / swap / retrieve cycle for a solo miner that
-- carries its own chunk-loader turtle as cargo.
--
-- Ordering is the whole safety argument, so it lives in one place:
--
--   placeLoader:    place loader  ->  confirm standing  ->  wait for its
--                   beacon  ->  chunky->pickaxe  ->  arm fence (on the
--                   LOADER's chunk)
--   retrieveLoader: verify chunky carried (or already equipped)  ->  verify
--                   the block ahead IS the recorded loader, by position AND
--                   identity  ->  modem->chunky (or modem->pickaxe if chunky
--                   is already on but pickaxe isn't -- see toRetrieveMode
--                   below -- or skip entirely if both are already on)  ->
--                   dig  ->  confirm the loader actually came back  ->
--                   release the fence/record  ->  pickaxe->modem
--
-- Known, deliberately-not-fixed limitations (see the report for the full
-- reasoning): the identity check (turtle.inspect() naming the block) cannot
-- distinguish OUR loader from any other advanced turtle -- computercraft:
-- turtle_advanced is the same registry name every advanced turtle uses, ours
-- included as cargo -- the position check is what actually narrows it down
-- to a specific block. And the post-dig recovery check is presence, not a
-- count delta: a spare loader turtle already sitting in inventory for an
-- unrelated reason would mask a genuinely lost dig.
--
-- Placement removes chunky only AFTER the loader is confirmed down AND has
-- proven -- via a LOADER_BEACON reporting the exact block it landed on --
-- that it is actually holding the chunk. Retrieval equips chunky BEFORE the
-- loader comes up, and never digs on trust: turtle.detect() alone only
-- proves SOMETHING is in front of the miner, never that it's the loader. At
-- no instant is the miner both unloaded (no chunky of its own) and outside
-- the base-loaded area.
--
-- turtle.place() drops the loader one block AHEAD of the miner, which can be
-- a DIFFERENT chunk than the miner's own position. So every fence anchors on
-- the loader's target chunk, never on the miner's position. This is also why
-- _hooks.pos() must return facing as well as x/y/z: "ahead" cannot be
-- computed from bare coordinates.
--
-- loader_state.record() is called before turtle.place() and loader_state.
-- clear() only once the loader is confirmed back in our own inventory, so a
-- crash at any instant errs toward "we may have a loader out there" rather
-- than silently losing one (see loader_state.lua). A *clean* place() failure
-- (not a crash -- we get a definite answer back) does roll the record back,
-- because leaving a false positive on disk is strictly worse than a correct
-- one and we know for certain nothing was placed. A place() that reports
-- success but then can't be confirmed standing leaves the record in place:
-- we do NOT know what happened there, and the cautious assumption is that it
-- exists.

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
--       first LOADER_BEACON, until either a matching beacon arrives or
--       BEACON_WAIT_SECONDS of real wall-clock time elapse -- NOT a fixed
--       attempt count: a pump that drains one message and returns near-
--       instantly (e.g. non-beacon traffic -- server heartbeats, job
--       messages) must not be able to burn through the whole wait in well
--       under a second. Each call is expected to block for roughly
--       `pollSeconds` real seconds when there is nothing to drain (a
--       proto.receive-style wait blocks via os.pullEvent, so this falls out
--       naturally) and to call mine_flow.noteBeacon(msg) for any
--       LOADER_BEACON message it sees during that window. A pump that never
--       delivers a beacon is a safe default (fail closed): placeLoader will
--       refuse rather than silently proceed.
--
--       IMPORTANT: pump must forward the message as proto.decode() produced
--       it -- msg.payload.position intact, not stripped down to msg.type.
--       noteBeacon verifies the beacon is from THIS placed loader by exact
--       block-position match against where placeLoader put it, so a caller
--       that discards the payload before calling noteBeacon silently
--       disables the position check (every beacon would look "positionless"
--       and get refused as loader_beacon_no_position).
--
--       IMPORTANT: mine_flow does not pcall this hook. An error thrown
--       inside pump propagates straight out of placeLoader uncaught. State
--       fails safe either way (nothing has been surrendered yet at the point
--       pump is called), but Task 8b's pump implementation must wrap its own
--       body in pcall if it wants placeLoader to return a reason string
--       instead of raising.
--
-- Boot recovery -- NOT a hook, a function 8b's boot path calls INTO this
-- module: if loader_state.hasPlaced() is true on boot (a loader was placed
-- before the last reboot), call mine_flow.adoptRecordedLoader() once before
-- relying on beaconSeenWithin() for anything. Without it, _expectedLoaderPos
-- is empty after a reboot (it is in-memory only), so noteBeacon() silently
-- ignores every beacon and beaconSeenWithin() reports false forever, even
-- for a loader that is genuinely still standing and beaconing.
-- retrieveLoader() does not need this itself -- it reads loader_state.get()
-- directly -- this is only for liveness queries made before retrieveLoader
-- is called.
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

local BEACON_WAIT_SECONDS = 15     -- real deadline the loader has to prove it's alive
local BEACON_POLL_SECONDS = 1
-- Last-resort backstop against a frozen or non-monotonic clock spinning this
-- forever. Should never bind in real use: a real pump always blocks on at
-- least one os.pullEvent per call, so BEACON_WAIT_SECONDS of wall-clock time
-- elapses in far fewer than this many iterations.
local BEACON_MAX_POLLS    = 100000

local _lastBeaconAt           = nil    -- os.epoch("utc")/1000 of the most recent MATCHING beacon
local _beaconArrivedSinceGate = false  -- reset at the start of every wait; see waitForFreshBeacon
local _mismatchSinceGate      = false  -- a LOADER_BEACON arrived from the WRONG position
local _nilPositionSinceGate   = false  -- a LOADER_BEACON arrived with no GPS fix at all

-- The position placeLoader expects ITS placed loader to report, set right
-- before waitForFreshBeacon() runs and cleared once the loader is retrieved.
-- Everything below is scoped to this: proof that SOME loader is alive is
-- not proof that OURS is, and with more than one loader in radio range (a
-- neighbouring miner's sector, or an orphan left standing from an earlier
-- failure -- Task 5b's loader_state exists precisely because that happens)
-- mistaking one for the other is exactly the unrecoverable freeze this
-- module exists to prevent.
local _expectedLoaderPos = nil

local function samePosition(a, b)
    return a ~= nil and b ~= nil and a.x == b.x and a.y == b.y and a.z == b.z
end

-- Call for every message the caller receives; harmless to call for anything
-- else. A no-op unless the message is a LOADER_BEACON AND there is a placed
-- loader in flight to verify it against (matching is impossible before
-- placeLoader has computed where its loader landed, and the beacon itself
-- carries no ID the miner can match against -- the loader is placed cargo
-- with no known computer ID until after it's already down).
--
-- position comparison is exact-integer-block equality: the loader's own
-- gps.locate() reports the block it is physically standing in, which is
-- exactly the block placeLoader computed as "ahead of the miner" before
-- placing it there.
function mine_flow.noteBeacon(msg)
    if type(msg) ~= "table" or msg.type ~= "LOADER_BEACON" then return end
    if not _expectedLoaderPos then return end

    local payload = msg.payload
    local pos = payload and payload.position

    if pos and samePosition(pos, _expectedLoaderPos) then
        _lastBeaconAt = os.epoch("utc") / 1000
        _beaconArrivedSinceGate = true
    elseif pos then
        -- A real beacon, just not from our loader.
        _mismatchSinceGate = true
    else
        -- Our loader may well be the sender, but with no GPS fix in the
        -- payload there is nothing to verify against -- an unverifiable
        -- beacon is not verification.
        _nilPositionSinceGate = true
    end
end

-- General-purpose liveness query: has OUR placed loader's beacon been seen
-- in the last `seconds` real seconds? Scoped to _expectedLoaderPos exactly
-- like the placement gate below -- a mid-mining monitor (Task 8b) that
-- silently followed a neighbouring loader's beacon would be the same bug in
-- slower motion. Returns false once _expectedLoaderPos is cleared (no
-- placement in flight, e.g. after a successful retrieveLoader) even if
-- _lastBeaconAt is technically still recent -- a stale "yes" surviving into
-- the NEXT sector, when nothing is even placed yet, is exactly the failure
-- this scoping exists to prevent.
function mine_flow.beaconSeenWithin(seconds)
    if not _expectedLoaderPos then return false end
    if not _lastBeaconAt then return false end
    return (os.epoch("utc") / 1000 - _lastBeaconAt) <= seconds
end

-- Blocks (via repeated _hooks.pump calls) until a MATCHING beacon arrives,
-- or BEACON_WAIT_SECONDS of real wall-clock time elapse. Returns ok, reason
-- -- reason distinguishes "nothing answered at all" from "something
-- answered, but not our loader" from "our loader may have answered, but
-- with no way to check", because an operator investigating a stuck miner
-- needs to know which one happened: the first is a plain timeout, the other
-- two mean a second loader (or a GPS coverage gap) needs attention.
--
-- This is a WALL-CLOCK DEADLINE, not an attempt count: counting pump() calls
-- instead would let a pump that returns near-instantly on non-beacon traffic
-- (server heartbeats, job messages arriving while we wait) burn through the
-- entire budget in well under a second and fail closed on a loader that was
-- about to answer moments later. BEACON_MAX_POLLS is a separate, much larger
-- safety backstop against a frozen/non-monotonic clock -- it should never be
-- the thing that actually ends the loop in practice.
--
-- The MATCH itself uses its own flags rather than a timestamp comparison
-- against when the wait started: two events a few real milliseconds apart
-- can land in the same integer second under os.epoch's precision, which
-- would make a "was it seen since time T" comparison unreliable right at a
-- placement boundary -- exactly where it matters most. A beacon from the
-- PREVIOUS sector's (now-retrieved) loader must never satisfy THIS sector's
-- gate, so the flags (and _lastBeaconAt) are explicitly reset before waiting
-- rather than inferred from a clock reading.
local function waitForFreshBeacon()
    _beaconArrivedSinceGate = false
    _mismatchSinceGate      = false
    _nilPositionSinceGate   = false
    _lastBeaconAt           = nil

    local deadline = os.epoch("utc") / 1000 + BEACON_WAIT_SECONDS
    local polls = 0
    while os.epoch("utc") / 1000 < deadline and polls < BEACON_MAX_POLLS do
        if _beaconArrivedSinceGate then return true end
        _hooks.pump(BEACON_POLL_SECONDS)
        polls = polls + 1
    end
    if _beaconArrivedSinceGate then return true end
    if _mismatchSinceGate then return false, "loader_beacon_mismatch" end
    if _nilPositionSinceGate then return false, "loader_beacon_no_position" end
    return false, "loader_no_beacon"
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
    -- A record we could not write is a loader we must not place: the whole
    -- record-before-place ordering exists so a crash errs toward "we may have
    -- one out there". Fail closed with the loader still in inventory.
    local recorded, recErr = loader_state.record(tx, p.y, tz, anchorChunk, chunkRadius)
    if not recorded then
        return false, recErr or "loader_state_write_failed"
    end

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

    -- Only a beacon reporting THIS exact block counts from here on.
    _expectedLoaderPos = { x = tx, y = p.y, z = tz }

    log("Waiting for loader beacon before giving up chunk loading...")
    local beaconOk, beaconErr = waitForFreshBeacon()
    if not beaconOk then
        -- The loader is down (and recorded) but has not proven -- or a
        -- DIFFERENT loader has disproven -- that it is alive. Never
        -- surrender our own chunk loading on anything less than exact
        -- confirmation.
        return false, beaconErr
    end
    log("Loader beacon confirmed.")

    report("SWAP_TO_PICKAXE")
    local swapped, why = equipment.toMineMode()
    if not swapped then
        -- equipment.toMineMode() swaps chunky for pickaxe FIRST, and only
        -- THEN runs a trailing equipment.validate("mine") as its own success
        -- check (equipment.lua:156). If that trailing check is what failed,
        -- the swap already landed: chunky is off. The loader is already
        -- confirmed alive via the beacon gate above, so arm the fence anyway
        -- -- leaving chunky off AND the fence unarmed would be exactly the
        -- unloaded-and-unfenced state this module exists to prevent, and the
        -- loader really is holding this chunk regardless of why toMineMode
        -- reported failure.
        if equipment.sideOf("chunky") == nil then
            geofence.setAnchorBlock(tx, tz, chunkRadius)
            log("toMineMode failed after the swap already landed -- " ..
                "fence armed anyway since the loader is confirmed alive: " .. tostring(why))
        end
        return false, why
    end

    -- Anchor on the loader's chunk, not the miner's position.
    geofence.setAnchorBlock(tx, tz, chunkRadius)
    log(string.format("Fence armed on chunk %d,%d radius %d (loader at %d,%d)",
        lcx, lcz, chunkRadius, tx, tz))
    return true
end

-- After a retrieval has confirmed the loader is physically back in
-- inventory, move it into its home slot (equipment.SLOTS.LOADER) so it never
-- permanently occupies a mining slot and so ore_turtle.lua's
-- initProtectedSlots finds it where it expects on the next boot.
-- turtle.dig()'s real inventory-add algorithm deposits into whatever slot it
-- picks (typically the currently-selected tool slot, or the first free
-- slot) -- never necessarily slot 2 -- so this cannot be assumed to have
-- already happened.
--
-- Never destroys anything: if slot 2 is occupied by something else (most
-- plausibly the upgrade the retrieval swap stowed there), that occupant is
-- relocated to any other free/compatible slot first, never overwritten or
-- dropped. If there's nowhere to put either item, this gives up quietly --
-- the caller must treat that as non-fatal, since the loader is already
-- safe in inventory by the time this runs.
local function normalizeLoaderSlot()
    local home = equipment.SLOTS.LOADER
    local loaderSlot = equipment.findSlot(equipment.ITEMS.LOADER_TURTLE)
    if not loaderSlot then return false, "loader_not_found_for_normalise" end
    if loaderSlot == home then return true end -- already home; no-op

    if turtle.getItemDetail(home) then
        -- Home slot is taken by something else -- move IT out of the way
        -- first. transferTo merges into a matching stack if one exists, or
        -- lands in the first slot that will take it otherwise; either way
        -- nothing is destroyed.
        turtle.select(home)
        local relocated = false
        for s = 1, 16 do
            if s ~= home and turtle.transferTo(s) then
                relocated = turtle.getItemDetail(home) == nil
                if relocated then break end
            end
        end
        if not relocated then
            return false, "loader_home_slot_occupied"
        end
    end

    turtle.select(loaderSlot)
    if not turtle.transferTo(home) then
        return false, "loader_normalise_transfer_failed"
    end
    return true
end

-- Restore self-loading, then take the loader back. Never dig it up first,
-- and never dig on trust: turtle.detect() alone only proves SOMETHING is in
-- front of the miner, not that it's our loader. A block that happens to be
-- there for any other reason (a neighbour's build, terrain, a mistake in
-- positioning) would otherwise get silently destroyed while this function
-- calls the retrieval a success.
function mine_flow.retrieveLoader()
    -- Refuse before touching anything if we cannot restore our own loading.
    -- Chunky already equipped counts as success here too, not failure --
    -- findSlot() alone can't see it (equipped items aren't in inventory),
    -- and equipment.reconcile() (the documented boot self-heal) or a reboot
    -- landing mid-retrieval (right after retrievalSwapIn, before dig()) can
    -- both leave chunky already on. Matches equipment.toTravelMode's
    -- identical "already there is fine" pattern (equipment.lua:164).
    local chunkyCarried  = equipment.findSlot(equipment.ITEMS.CHUNKY) ~= nil
    local chunkyEquipped = equipment.sideOf("chunky") ~= nil
    if not chunkyCarried and not chunkyEquipped then
        return false, "chunky_missing"
    end

    -- Verify the block ahead IS our loader before touching anything else:
    -- by position (against the persisted, reboot-safe record of where it
    -- actually is) AND by identity (turtle.inspect() naming it, not just
    -- turtle.detect() proving something is there).
    local recorded = loader_state.get()
    if not recorded then
        return false, "no_loader_recorded"
    end
    local p = _hooks.pos()
    local ax, az = aheadBlock(p)
    if ax ~= recorded.x or p.y ~= recorded.y or az ~= recorded.z then
        return false, "loader_position_mismatch"
    end
    local inspected, block = turtle.inspect()
    if not inspected or block.name ~= equipment.ITEMS.LOADER_TURTLE then
        return false, "loader_not_in_front"
    end

    report("RETRIEVING", "comms gap expected")

    if not chunkyEquipped then
        -- Sacrifice the modem, not chunk loading: offline is recoverable,
        -- unloaded is not. Comms are down from here until the swap-out
        -- below. Skipped entirely when chunky is already equipped -- this
        -- step has already happened, most likely because a reboot landed
        -- between it and the dig below.
        local ok, reason = equipment.retrievalSwapIn()
        if not ok then return false, reason end
    elseif not equipment.sideOf("pickaxe") then
        -- Chunky is on, but pickaxe isn't -- chunky+MODEM, not chunky+
        -- pickaxe. This is the dead end equipment.reconcile() leaves behind
        -- after a reboot mid-retrieval with both sides already full: it
        -- displaces the pickaxe there, never the modem, because chunk
        -- safety correctly outranks digging -- but that alone leaves
        -- nothing able to finish the transition to retrieval mode.
        -- equipment.toRetrieveMode() is exactly that missing step.
        local ok, reason = equipment.toRetrieveMode()
        if not ok then return false, reason end
    end

    -- Whichever path got us here, never dig without both upgrades
    -- confirmed on: this is the one invariant that makes digging safe at
    -- all (loaded AND able to dig, simultaneously).
    if not equipment.sideOf("chunky") or not equipment.sideOf("pickaxe") then
        return false, "retrieval_equipment_invalid"
    end

    local dug = turtle.dig()
    if not dug then
        -- Put comms back before reporting the failure. Chunky stays on
        -- throughout this recovery attempt regardless of whether it
        -- succeeds -- chunk loading is never the thing given up.
        equipment.retrievalSwapOut()
        return false, "loader_dig_failed"
    end

    -- turtle.dig() succeeding proves SOMETHING was collected, not that it
    -- was our loader turtle specifically. In real CC:Tweaked, digging with
    -- an inventory that has no room at all for the drop still returns true
    -- -- the block is gone, but the item is destroyed rather than
    -- collected -- so this is a real, reachable failure mode, not just
    -- theoretical race-guarding.
    if not equipment.findSlot(equipment.ITEMS.LOADER_TURTLE) then
        -- The chunk is DEFINITELY no longer held (the block really is
        -- gone), and chunky is already equipped on every path that reaches
        -- here, so it is correct to release the fence immediately -- there
        -- is nothing left for it to protect. The persisted record must NOT
        -- be cleared, though: a physical loader turtle is genuinely lost,
        -- and that is exactly the kind of thing an operator needs to see,
        -- not have silently erased.
        equipment.retrievalSwapOut()
        geofence.clear()
        _expectedLoaderPos = nil
        _lastBeaconAt = nil
        return false, "loader_lost_after_dig"
    end

    -- The loader is physically back in our inventory from here on, whatever
    -- happens next below: it is no longer standing in the world holding
    -- anything, so the persisted record and the fence around its chunk are
    -- both stale as of THIS instant, regardless of how the comms swap-out
    -- goes.
    loader_state.clear()
    geofence.clear()
    _expectedLoaderPos = nil
    _lastBeaconAt = nil

    -- Tidy-up only, never a retrieval failure: the loader is already
    -- physically recovered above, so a problem here just gets logged.
    local normalised, normErr = normalizeLoaderSlot()
    if not normalised then
        log("Could not return loader to its home slot: " .. tostring(normErr) ..
            " -- loader is safely in inventory, continuing.")
    end

    local restored, why = equipment.retrievalSwapOut()
    if not restored then
        -- The loader really is retrieved (see above) -- this is purely an
        -- equipment problem: chunky is on, modem never came back, comms are
        -- down. Distinct from loader_dig_failed so a caller (and an
        -- operator reading the failure reason) can tell "the loader is
        -- safe in your inventory, fix your radio" apart from "the loader
        -- may still be standing out there."
        return false, "loader_recovered_comms_down"
    end

    log("Loader retrieved; self-loading restored.")
    return true
end

-- Re-establishes beacon tracking for an ALREADY-placed loader after a
-- reboot. _expectedLoaderPos is in-memory only and does not survive a
-- restart, so without this, noteBeacon() is a permanent no-op and
-- beaconSeenWithin() is permanently false for a loader that may genuinely
-- still be standing and beaconing -- retrieveLoader doesn't need this (it
-- reads loader_state.get() directly), but a Task 8b boot-recovery path that
-- wants to check liveness BEFORE deciding what to do does. Call once at
-- boot when loader_state.hasPlaced() is true.
function mine_flow.adoptRecordedLoader()
    local recorded = loader_state.get()
    if not recorded then return false, "no_loader_recorded" end
    _expectedLoaderPos = { x = recorded.x, y = recorded.y, z = recorded.z }
    return true
end

return mine_flow
