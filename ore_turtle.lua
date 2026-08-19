-- ore_turtle.lua
-- Rename to startup.lua on any miner turtle.
--
-- SOLO miner. It carries its own chunk-loader turtle as cargo, places it at
-- each sector, swaps chunky -> pickaxe so it can mine inside that loader's
-- footprint, then swaps back and takes the loader with it. Mining has no
-- support partner any more. Delivery still does: signalPartner and the
-- MINE_RECALL/MINE_CLEAR/RETURN_TO_DOCK message types stay in turtle_base.lua
-- and protocol.lua untouched -- what was removed here is mining's *calls* into
-- them, not the mechanism.
--
-- Inventory layout (equipment.SLOTS is the authority):
--   Slot  1     advancedperipherals:geo_scanner (placed, used, picked back up)
--   Slot  2     the carried chunk-loader turtle
--   Slot  3     whichever of pickaxe/chunky is currently stowed
--   Slot  4     the modem, only during the retrieval window
--   Slots 5-13  mining output  -> dumped to the ore E-chest after each sector
--   Slot 14     coal reserve   (slot-14 top-up before EC refuel)
--   Slot 15     fuel ender chest (self-refuel coal source)
--   Slot 16     ore ender chest  (-> RS storage)

local base         = require("turtle_base")
local proto        = require("protocol")
local W            = require("waypoints")
local equipment    = require("equipment")
local geofence     = require("geofence")
local loader_state = require("loader_state")
local mine_flow    = require("mine_flow")

-- ── Slots ────────────────────────────────────────────────────────────────────
local S_SCANNER = equipment.SLOTS.SCANNER   -- 1
local S_LOADER  = equipment.SLOTS.LOADER    -- 2
local S_TOOL    = equipment.SLOTS.TOOL      -- 3
local S_MODEM   = equipment.SLOTS.MODEM     -- 4
local S_COAL    = equipment.SLOTS.COAL      -- 14
local S_FUEL_EC = equipment.SLOTS.FUEL_EC   -- 15
local S_ORE_EC  = equipment.SLOTS.ORE_EC    -- 16

-- Mining output lives ONLY in these slots now. Slots 2-4 hold the carried
-- loader turtle and whichever upgrades are not currently equipped; the old
-- 2-13 output range would have shipped the miner's own hardware to storage on
-- the first dump.
local MINE_FIRST, MINE_LAST = 5, 13

local PROTECTED = {
    [S_SCANNER] = true, [S_LOADER] = true, [S_TOOL] = true, [S_MODEM] = true,
    [S_COAL]    = true, [S_FUEL_EC] = true, [S_ORE_EC] = true,
}

-- Populated at startup: item name → home slot number.
-- Used as a name-based safety net so protected items can't be dumped
-- even if they're displaced out of their home slot.
local protectedItemNames = {}
-- Slot-indexed companion: home slot → expected item name.
-- Authoritative for rescue because both ECs share the same item name.
local protectedSlotNames = {}

-- ── Config ───────────────────────────────────────────────────────────────────
local SKY_Y        = 200   -- altitude for inter-sector sky travel
local SURVEY_TRAVEL_Y = 175  -- survey/first-sector travel altitude
local FUEL_WARN    = 3000  -- self-refuel threshold
local SCAN_RADIUS  = 16    -- geo scanner radius (blocks)
local SCANNER_NAME = equipment.ITEMS.SCANNER
local MIN_ORE_Y    = -58   -- 1.18+ world: bedrock ends at Y=-60; safe floor is -58

-- Footprint from docs/superpowers/specs/chunkloader-footprint.md. Measured in
-- CHUNKS: 1 => the 3x3 chunks around the loader's own chunk, which covers the
-- whole 33x33 sector. The pack loads 5x5 (chunkyTurtleRadius=2), so this leaves
-- one chunk of slack on every side.
--
-- This is the only thing keeping the miner inside loaded chunks while its own
-- chunky upgrade is stowed. Do NOT raise it without raising chunkyTurtleRadius
-- in the Advanced Peripherals config first -- nothing checks that they agree,
-- and a mismatch does not error, it freezes the turtle in an unloaded chunk.
local FENCE_CHUNK_RADIUS = 1

-- Where the miner stands to place its loader, as an offset from the sector
-- centre. Sector centres are multiples of SECTOR_STEP=32 and therefore sit
-- exactly ON a chunk boundary: placing from there would drop the loader into
-- whichever neighbouring chunk we happened to be facing, and the fence would
-- cover the wrong 3x3. From 8 blocks in, every facing keeps both the miner and
-- the loader inside the sector's own anchor chunk.
local STAND_OFFSET = 8
-- Face south before placing so the loader lands on the +Z side of the stand,
-- i.e. away from the sector centre the miner works and returns from. Facing is
-- read back from base.getFacing() rather than assumed -- this only decides
-- WHERE the loader goes, never where the code thinks it went.
local PLACE_FACING = 2

-- Loader liveness while mining. The loader beacons every 5s (loader_turtle.lua
-- BEACON_INTERVAL), but the job coroutine only sees modem traffic while it is
-- actually blocked in proto.receive: anything arriving while it is inside a
-- turtle move is delivered to turtle_base's control loop instead and is gone
-- before we look. So "no beacon" only means anything after we have deliberately
-- listened, which costs mining time -- hence a long interval, a listen window
-- comfortably wider than one beacon period, and a grace window spanning more
-- than two checks so a single missed window never abandons a good sector.
local BEACON_CHECK_EVERY = 90    -- seconds of mining between liveness polls
local BEACON_LISTEN_SECS = 7     -- listen this long each poll (> one beacon period)
local BEACON_GRACE_SECS  = 240   -- no matching beacon in this long => treat as dead

-- A server outage must not leave the miner parked in the field with a loader
-- force-loading a chunk. After this long, take ourselves home unaided.
local SERVER_DOWN_LIMIT_MS = 300000   -- 5 minutes

-- Y levels scanned per sector — each covers ±16 blocks vertically.
-- 1.18+ ore peaks: iron/coal y=16, copper/gold y=0, redstone y=-32, diamond y=-52.
local SCAN_LEVELS = { 16, 0, -32, -52 }

-- base.init is allowed to fail without killing the whole program.
--
-- comms.init() calls error("No modem found") when it cannot equip a modem, and
-- equipment.reconcile() cannot recover one that is not in the inventory. That is
-- reachable in the field: turtle_base's refuelFromChest drops slots 1-14 on the
-- ground when the inventory is nearly full, and slot 4 is the modem (reported to
-- W3, 2026-08-18).
--
-- Unprotected, that error propagated out of module load and everything below
-- this line never ran -- including recoverPlacedLoader(), so a turtle that lost
-- its modem also permanently abandoned its placed chunk loader, and the
-- os.reboot() at the bottom never fired either. The turtle simply stopped, deaf
-- and motionless, with an error on screen. One was found only because it
-- happened to be near the warehouse.
--
-- Booting on is strictly better: loader recovery does not need comms (Invariant
-- E -- a worker must reach its dock with no server contact at all), so a miner
-- that cannot talk can still retrieve its loader and stop being a lost turtle
-- plus a permanently force-loaded chunk.
local _commsOk, _commsErr = pcall(base.init, proto.ROLE.MINER)
if not _commsOk then
    print("[MINER] BOOT DEGRADED: " .. tostring(_commsErr))
    print("[MINER] Continuing without comms so the loader can still be recovered.")
    print("[MINER] Check slots: 1 scanner, 2 loader, 3 tool, 15 fuel EC, 16 ore EC.")
end

-- Forward declaration: checkFuel (defined below) calls rescueProtectedItems,
-- which is a `local function` further down the file. Without this declaration
-- that call compiled to a GLOBAL lookup and was nil at runtime — a latent
-- "attempt to call a nil value" crash on the fuel-EC-displaced path.
local rescueProtectedItems

-- Forward declaration: checkFuel and the FORCE_REFUEL handler both run before
-- dumpOres is defined, and both must empty the ore first. See its definition
-- below for why.
local dumpBeforeRefuel

-- ── Phase reporting ──────────────────────────────────────────────────────────
-- base has no job-id accessor, so the miner keeps its own copy for the phase
-- payloads. Set on entry to a job, cleared when it ends.
local _jobId = nil

local function currentChunk()
    local p = base.getPos()
    local cx, cz = geofence.chunkOf(p.x, p.z)
    return { cx = cx, cz = cz }
end

-- The block turtle.place() is about to fill, from the miner's own facing —
-- same convention as mine_flow.aheadBlock and turtle_base.applyMove.
local function aheadBlock()
    local p  = base.getPos()
    local f  = base.getFacing()
    local dx, dz = 0, 0
    if     f == 0 then dz = -1
    elseif f == 1 then dx =  1
    elseif f == 2 then dz =  1
    else               dx = -1 end
    return p.x + dx, p.y, p.z + dz
end

-- mine_flow reports PLACING_LOADER with no detail (it has no comms dependency
-- at all). A LOADER_BEACON carries a position but no deployer — the placed
-- loader has no way to learn which miner put it there — so the miner id plus
-- the block the loader is about to occupy is the join key the server needs to
-- attribute a beacon (or an orphan) to a placement.
local function placingDetail()
    local lx, ly, lz = aheadBlock()
    return string.format("miner=%s loader=%d,%d,%d",
        tostring(base.getSelfId()), lx, ly, lz)
end

local function reportPhase(phase, detail)
    if phase == proto.PHASE.PLACING_LOADER and not detail then
        detail = placingDetail()
    end
    -- RETRIEVING is the deliberate comms-gap window: the server suppresses
    -- ghost/timeout detection while commsGap is set, so it must be set BEFORE
    -- the modem comes off — which it is, because mine_flow reports RETRIEVING
    -- before calling equipment.retrievalSwapIn().
    --
    -- DOCKED reports no chunk: the server clears the last worked chunk on that
    -- phase, and a heartbeat that kept re-sending the dock's own chunk would
    -- immediately undo it.
    local chunk = (phase ~= proto.PHASE.DOCKED) and currentChunk() or nil
    base.setPhase(phase, chunk, phase == proto.PHASE.RETRIEVING)
    base.sendToServer(proto.MSG.MINE_PHASE,
        proto.payloadMinePhase(_jobId, phase, detail))
    print(string.format("[MINER] phase %s%s", phase, detail and (" — " .. detail) or ""))
end

-- ── Autonomous return on a prolonged outage ──────────────────────────────────
-- The 5-minute rule is only useful if it can fire while the miner is actually
-- stuck, which is mid-sector: with the server unreachable the job coroutine is
-- either blocked in tryMove's serverDown hold or looping in waitMsg with a
-- deadline that resets every iteration. A check that only runs between sectors
-- (which is what the 5b brief's placement amounts to) can never fire in the
-- situation it exists for, because by then the loader is already retrieved.
--
-- So the condition is evaluated in three places: tryMove's hold (via the escape
-- hook), waitMsg's freeze, and the two mining loops. The first two only release
-- the wait; the mining loops are what actually turn it into a trip home.

local _serverDownSince = nil

-- Deliberately not latched: if the server comes back this goes false again by
-- itself, so a recovered outage cannot abort a later sector.
local function serverDownTooLong()
    if not base.isServerDown() then
        _serverDownSince = nil
        return false
    end
    _serverDownSince = _serverDownSince or os.epoch("utc")
    return (os.epoch("utc") - _serverDownSince) > SERVER_DOWN_LIMIT_MS
end

-- The state that makes waiting out an outage unacceptable rather than merely
-- inconvenient: a chunk loader of ours standing in the world, force-loading a
-- chunk, with the miner stranded beside it.
local function autonomousReturnDue()
    return serverDownTooLong() and loader_state.hasPlaced()
end

-- Only a miner with a placed loader may break turtle_base's serverDown movement
-- hold. Delivery/support/warehouse never install an escape, so their hold is
-- unchanged.
base.setServerDownEscape(autonomousReturnDue)

-- ── Messaging ────────────────────────────────────────────────────────────────

-- mine_flow's beacon gate calls this. Contract: block for roughly pollSeconds
-- when nothing is arriving (proto.receive does, via os.pullEvent), hand every
-- message straight to mine_flow.noteBeacon with msg.payload INTACT (noteBeacon
-- verifies a beacon by exact block position out of msg.payload.position — a
-- stripped payload silently disables that check), and never raise: mine_flow
-- does not pcall this hook.
--
-- Messages drained here are not stolen from anything. turtle_base runs its
-- control loop and the job coroutine under parallel.waitForAny, which delivers
-- every event to both, so RECALL / JOB_ASSIGN still reach the control loop.
local function pump(pollSeconds)
    local ok, err = pcall(function()
        local msg = proto.receive(base.getSelfId(), pollSeconds or 1)
        if msg then mine_flow.noteBeacon(msg) end
    end)
    if not ok then print("[MINER] pump error: " .. tostring(err)) end
end

mine_flow.setHooks({
    reportPhase = reportPhase,
    log         = function(m) print("[MINER] " .. m) end,
    -- facing is REQUIRED: placeLoader computes where the loader will land from
    -- it, and a wrong facing puts the loader in the wrong chunk.
    pos         = function()
        local p = base.getPos()
        p.facing = base.getFacing()
        return p
    end,
    pump        = pump,
})

local function waitMsg(types, secs)
    local set = {}
    for _, t in ipairs(types) do set[t] = true end
    local deadline = os.epoch("utc") / 1000 + secs
    while os.epoch("utc") / 1000 < deadline do
        if base.isRecalled() then return nil end
        if base.isServerDown() then
            -- Freeze deadline while server is unreachable so a crash doesn't
            -- trigger sector_request_timeout and dispatch a duplicate miner.
            -- Not forever, though: past the autonomous-return limit the caller
            -- has to be allowed to take the miner home.
            if serverDownTooLong() then return nil end
            deadline = os.epoch("utc") / 1000 + secs
            sleep(2)
        end
        local remain = deadline - os.epoch("utc") / 1000
        if remain <= 0 then break end
        local msg = proto.receive(base.getSelfId(), math.max(0.5, remain))
        if msg then
            -- Keep feeding the loader-liveness tracker even while waiting for
            -- something else; a beacon seen here is as good as one seen in pump.
            mine_flow.noteBeacon(msg)
            if set[msg.type] then return msg end
        end
    end
    return nil
end

-- ── Loader liveness ──────────────────────────────────────────────────────────

local _lastBeaconPoll = 0
local _beaconLost     = false

local function listenForBeacon(seconds)
    local deadline = os.epoch("utc") / 1000 + seconds
    while os.epoch("utc") / 1000 < deadline do
        if mine_flow.beaconSeenWithin(BEACON_GRACE_SECS) then return true end
        local remain = deadline - os.epoch("utc") / 1000
        if remain <= 0 then break end
        pump(math.max(0.5, remain))
    end
    return mine_flow.beaconSeenWithin(BEACON_GRACE_SECS)
end

-- False once the placed loader has stopped proving it is alive. Only meaningful
-- while the fence is armed: the fence is active exactly when the miner has
-- surrendered its own chunky upgrade and is depending on that loader.
local function loaderStillAlive()
    if not geofence.isActive() then return true end
    if _beaconLost then return false end
    local now = os.epoch("utc") / 1000
    if now - _lastBeaconPoll < BEACON_CHECK_EVERY then return true end
    _lastBeaconPoll = now
    if listenForBeacon(BEACON_LISTEN_SECS) then return true end
    _beaconLost = true
    return false
end

-- The loader has gone quiet. Restoring our own chunk loading is the only thing
-- that matters here — mining can wait, being unloaded cannot be undone — so
-- take the modem's side for chunky rather than the pickaxe's: we may be deep
-- underground and still need to dig our way back out to the loader. Comms stay
-- down until the retrieval swap-out puts the modem back.
local function handleBeaconLoss()
    reportPhase(proto.PHASE.RETRIEVING, "loader beacon lost — restoring own chunk loading")
    base.sendProgress("loader_beacon_lost — restoring own chunk loading")
    -- Comms go down on the next line and stay down until the retrieval swap-out,
    -- with a possibly long climb back to the loader in between. Without this the
    -- missed heartbeats set serverDown ~15s in and tryMove's hold blocks the
    -- trip home forever — a permanent field hang in the very path that exists to
    -- recover from a loader failure.
    base.setAutonomousReturn(true)
    local ok, why = equipment.retrievalSwapIn()   -- modem -> chunky, pickaxe stays
    if ok then
        -- Self-loading again: the fence has nothing left to protect and would
        -- only stop us reaching the loader or getting home.
        geofence.clear()
        print("[MINER] Own chunk loading restored after beacon loss.")
    else
        -- Keep the fence armed: staying inside the (possibly still loaded)
        -- footprint beats wandering out of it with no loading of our own.
        print("[MINER] WARNING: could not restore chunky after beacon loss: " .. tostring(why))
    end
end

-- ── Equipment helpers ────────────────────────────────────────────────────────

-- Get back to travel mode (modem + chunky) from whatever state a failure left
-- us in. Two sides, three upgrades, so exactly one of these applies.
local function restoreTravelMode()
    if not equipment.sideOf("chunky") then
        reportPhase(proto.PHASE.SWAP_TO_CHUNKY)
        local ok, why = equipment.toTravelMode()      -- pickaxe -> chunky
        if not ok then return false, why end
    end
    if not equipment.sideOf("modem") then
        local ok, why = equipment.retrievalSwapOut()  -- pickaxe -> modem, chunky stays
        -- The modem comes back on the side the PICKAXE was on, not the side it
        -- left from, so the wrapper turtle_base holds is stale and its channels
        -- belong to the old instance. Re-acquire before reporting anything.
        base.recoverModem()
        if not ok then return false, why end
    end
    return true
end

-- Never fly anywhere without our own chunk loading. If chunky is off, take the
-- MODEM's side for it rather than the pickaxe's: the trip home may still have
-- to dig up out of a half-mined shaft, and comms are the one thing that can be
-- afforded (they come back with restoreTravelMode once we are home). Falls back
-- to giving up the pickaxe instead if the modem swap is the one that fails —
-- loaded and unable to dig still beats unloaded.
local function prepareToFly()
    if equipment.sideOf("chunky") then return true end
    local ok = equipment.retrievalSwapIn()      -- modem -> chunky, pickaxe stays
    if ok then return true end
    return equipment.toTravelMode()             -- pickaxe -> chunky
end

-- Recovering an ender chest means digging it back up, and digging needs a
-- pickaxe. In travel mode the tool side holds chunky, so borrow the MODEM's
-- side for the duration — never chunky's: a comms gap is recoverable, being
-- unloaded is not. A no-op (and zero behaviour change) whenever the pickaxe is
-- already on, which is the whole of normal mining.
local function withDigTool(what, fn)
    if equipment.sideOf("pickaxe") then return fn() end
    local swapped, why = equipment.toRetrieveMode()   -- modem -> pickaxe
    if not swapped then
        print(string.format("[MINER] %s skipped — cannot equip pickaxe: %s",
            what, tostring(why)))
        return nil
    end
    local ok, err = pcall(fn)
    local back, why2 = equipment.retrievalSwapOut()   -- pickaxe -> modem
    base.recoverModem()   -- the modem came back on the other side; rebind it
    if not back then
        print(string.format("[MINER] WARNING: modem not restored after %s: %s",
            what, tostring(why2)))
    end
    if not ok then error(err, 0) end
    return true
end

-- ── Ore detection ────────────────────────────────────────────────────────────

local function isOre(name, tags)
    if name:find("ore") then return true end
    if type(tags) == "table" then
        for k in pairs(tags) do
            if type(k) == "string" and (k:find("ores") or k:find("ore")) then return true end
        end
    end
    return false
end

-- ── Fuel management ──────────────────────────────────────────────────────────

local function tryRefuelSlot14()
    turtle.select(S_COAL)
    if turtle.getItemCount() > 0 then turtle.refuel() end
end

-- Full refuel using the existing base.fuel.refuelFromChest() — already handles
-- CHEST_SLOT=15, slot selection, direction finding, and chest recovery.
-- refuelFromChest deploys the entangled chest and breaks it again to recover
-- it, so it needs a pickaxe just like the dump does. FORCE_REFUEL arrives while
-- the miner is docked and idle — i.e. in travel mode, with the pickaxe stowed.
-- The other refuel path: fuel.ensureFuel() in turtle_base's control loop calls
-- refuelFromChest directly, and that PLACES the fuel ender chest and digs it
-- back up. Unwrapped, a miner in travel mode (chunky on the tool side) places
-- the chest, fails to dig it, and is left unable to ever refuel again. Handing
-- base the same withDigTool used everywhere else here closes that path; roles
-- that never install a wrapper keep calling refuelFromChest directly.
base.setDigToolWrapper(withDigTool)

base.setRefuelFn(function()
    -- FORCE_REFUEL arrives while docked and idle, and goes straight into
    -- refuelFromChest — the call that drops slots 1-14 when the inventory is
    -- tight. Empty the ore first for the same reason checkFuel does.
    dumpBeforeRefuel("force refuel")
    withDigTool("force refuel", function()
        while turtle.getFuelLevel() < turtle.getFuelLimit() do
            if not base.fuel.refuelFromChest() then break end  -- EC empty or missing
        end
        print(string.format("[FUEL] Full refuel complete: %d/%d",
            turtle.getFuelLevel(), turtle.getFuelLimit()))
    end)
end)

-- ── Pre-departure preflight ──────────────────────────────────────────────────
-- The server gained a distance-aware dispatch gate in 1.9.8, but it reasons from
-- zone bounds and cannot see this turtle's real position or what is actually in
-- its inventory. These are the authoritative checks, and the dock is the last
-- point at which refusing a job costs nothing.
--
-- On 1.9.7 a miner departed on 2965 fuel, self-recalled seconds later, and a
-- second stranded mid-air at 0. Both were already doomed when they left.

local MINE_DEEPEST_Y      = SCAN_LEVELS[#SCAN_LEVELS] - SCAN_RADIUS  -- -52 - 16
local MINE_WORK_ALLOWANCE = 3000  -- in-sector navigation, loader place/retrieve, dumps

-- Round-trip fuel for the whole zone: climb to travel altitude, fly to the
-- farthest corner, drop to the deepest scan level, and the same again home.
-- Mirrors mineTripFuel() in central_server.lua; both are deliberately
-- conservative, since being wrong high costs a dispatch hold and being wrong
-- low costs a turtle.
local function fuelForZone(params, skyY)
    if not (params and params.x1 and params.z1 and params.x2 and params.z2) then
        return 0   -- no bounds to reason about; in-field checkFuel still applies
    end
    local p  = base.getPos()
    local dx = math.max(math.abs(params.x1 - p.x), math.abs(params.x2 - p.x))
    local dz = math.max(math.abs(params.z1 - p.z), math.abs(params.z2 - p.z))
    local oneWay = (dx + dz) + math.max(0, skyY - p.y) + (skyY - MINE_DEEPEST_Y)
    return math.ceil(2 * oneWay + MINE_WORK_ALLOWANCE)
end

-- Both ender chests share one item name (EnderStorage separates them by colour
-- frequency, not registry id), so this cannot tell the fuel chest from the ore
-- chest -- only that a chest is present where one is required. That is still
-- enough to catch the layout mistakes that actually happen: a chest sitting in
-- the coal buffer slot, or a missing chest. initProtectedSlots only printed a
-- warning for these and let the miner fly out regardless.
local function looksLikeEnderChest(item)
    if not item then return false end
    return item.name:find("ender") ~= nil or item.name:find("entangled") ~= nil
end

local function preflightSlots()
    -- Without a scanner the miner is not broken, which is the problem: scanSector
    -- prints an error, returns an empty ore list, and the sector completes having
    -- found nothing. It would work its way through a whole zone reporting zero
    -- ore. Refusing at the dock is far cheaper than a silently useless survey.
    local scanner = turtle.getItemDetail(S_SCANNER)
    if not scanner or scanner.name ~= SCANNER_NAME then
        return false, "slot_" .. S_SCANNER .. "_must_hold_the_geo_scanner"
    end
    if not looksLikeEnderChest(turtle.getItemDetail(S_FUEL_EC)) then
        return false, "slot_" .. S_FUEL_EC .. "_must_hold_the_fuel_ender_chest"
    end
    if not looksLikeEnderChest(turtle.getItemDetail(S_ORE_EC)) then
        return false, "slot_" .. S_ORE_EC .. "_must_hold_the_ore_ender_chest"
    end
    -- Slot 14 is the buffer coal is sucked INTO. A chest parked there means the
    -- whole layout is shifted down one, and every fuel path would then read the
    -- ore chest instead of the coal chest.
    if looksLikeEnderChest(turtle.getItemDetail(S_COAL)) then
        return false, "slot_" .. S_COAL .. "_must_be_free_for_coal_not_a_chest"
    end
    return true
end

-- Estimate fuel required to fly home from the current position.
local function fuelToReturn()
    local p  = base.getPos()
    local ah = W.ARRIVALS_HOLE
    local ascent  = math.max(0, SKY_Y - p.y)
    local lateral = math.abs(p.x - ah.x) + math.abs(p.z - ah.z)
    return math.ceil(ascent + lateral + 300)  -- 300 = descent + dock nav + margin
end

-- Deploys the fuel ender chest, so it must be able to dig it back up: always
-- called through withDigTool by checkFuel below.
local function refuelFromEC(jobId)
    -- Restore fuel EC to slot 15 if displaced or crowded out by overflow coal.
    -- suckDown overflow and dumpOres can push the EC out of slot 15.
    do
        local slot15 = turtle.getItemDetail(S_FUEL_EC)
        local ecName = protectedSlotNames[S_FUEL_EC]
        if ecName and (not slot15 or slot15.name ~= ecName) then
            if slot15 then
                -- Wrong item in slot 15 (e.g. overflow coal) — clear it to slot 14.
                turtle.select(S_FUEL_EC)
                turtle.transferTo(S_COAL)
            end
            rescueProtectedItems()  -- find EC in the mining slots and restore it
        end
    end

    local ecItem = turtle.getItemDetail(S_FUEL_EC)
    local ecName = protectedSlotNames[S_FUEL_EC]
    if ecItem and ecName and ecItem.name == ecName then
        turtle.select(S_FUEL_EC)
        if turtle.detectDown() then turtle.digDown() end
        if turtle.placeDown() then
            -- Suck only as much as slot 14 can hold to prevent overflow into slot 15.
            turtle.select(S_COAL)
            local space = 64 - turtle.getItemCount(S_COAL)
            if space == 0 then turtle.refuel(); space = 64 - turtle.getItemCount(S_COAL) end
            if space > 0 then turtle.suckDown(space) end
            if turtle.getItemCount(S_COAL) > 0 then
                turtle.refuel()
            else
                print("[FUEL] EC chest is empty — no coal available")
                base.sendProgress("FUEL WARNING: EC chest empty, fuel=" .. turtle.getFuelLevel())
            end
            -- Recover EC; clear slot 15 first in case overflow landed there
            local s15 = turtle.getItemDetail(S_FUEL_EC)
            if s15 and s15.name ~= protectedSlotNames[S_FUEL_EC] then
                turtle.select(S_FUEL_EC)
                for free = MINE_FIRST, MINE_LAST do
                    if turtle.getItemCount(free) == 0 then turtle.transferTo(free); break end
                end
            end
            turtle.select(S_FUEL_EC)
            turtle.digDown()
            -- Safety: if EC landed in a mining slot despite precautions, rescue it now.
            local recovered = turtle.getItemDetail(S_FUEL_EC)
            if not recovered or recovered.name ~= ecName then
                if recovered then turtle.select(S_FUEL_EC); turtle.transferTo(S_COAL) end
                rescueProtectedItems()
            end
        else
            print("[FUEL] Failed to place fuel EC")
        end
    else
        print(string.format("[FUEL] EC missing from slot %d — cannot refuel from chest", S_FUEL_EC))
        base.sendProgress("FUEL WARNING: EC missing from slot " .. S_FUEL_EC
                .. ", fuel=" .. turtle.getFuelLevel())
    end
end

local function checkFuel(jobId)
    if turtle.getFuelLevel() >= FUEL_WARN then return end

    -- Step 0: make room BEFORE any refuel touches the inventory. See
    -- dumpBeforeRefuel — a refuel with full mining slots makes refuelFromChest
    -- drop the scanner, loader, tool and modem on the ground.
    dumpBeforeRefuel("refuel")

    -- Step 1: burn slot-14 coal reserve (needs no tool)
    tryRefuelSlot14()
    if turtle.getFuelLevel() >= FUEL_WARN then return end

    -- Step 2+3: deploy the fuel EC. Needs a pickaxe to pick the chest back up.
    withDigTool("fuel EC refuel", function() refuelFromEC(jobId) end)

    -- Step 4: assess post-refuel fuel level
    local fuel   = turtle.getFuelLevel()
    if fuel >= FUEL_WARN then return end  -- successfully topped up

    local needed = fuelToReturn()
    if fuel < needed then
        print(string.format("[FUEL] CRITICAL: %d fuel, need ~%d to return — aborting job", fuel, needed))
        base.sendProgress("FUEL CRITICAL: " .. fuel .. " fuel (need ~" .. needed
                .. " to return) — returning to base")
        base.setRecalled(true)
    else
        -- Enough to get home, but too low to keep mining comfortably — warn and continue.
        print(string.format("[FUEL] LOW: %d fuel (min %d to return) — continuing cautiously", fuel, needed))
        base.sendProgress("FUEL LOW: " .. fuel .. " fuel (min ~" .. needed .. " to return)")
    end
end

-- ── Inventory ────────────────────────────────────────────────────────────────

-- Record item names in the protected slots so they can never be dumped even if
-- physically displaced into a mining slot (e.g. dug up during movement, or a
-- retrieved loader turtle landing in the first free slot).
local function initProtectedSlots()
    for _, s in ipairs({ S_SCANNER, S_LOADER, S_TOOL, S_MODEM, S_FUEL_EC, S_ORE_EC }) do
        local item = turtle.getItemDetail(s)
        if item then
            protectedItemNames[item.name] = s   -- last-write-wins; used only for boolean "is protected?" checks
            protectedSlotNames[s] = item.name   -- slot → name; authoritative for rescue
            print(string.format("[INIT] Protected slot %d: %s", s, item.name))
        elseif s == S_MODEM or s == S_TOOL then
            -- Expected to be empty outside their swap windows: the modem is
            -- only stowed during retrieval, and the tool slot is empty
            -- whenever both upgrades happen to be equipped.
            print(string.format("[INIT] Slot %d empty (swap slot) — ok", s))
        else
            print(string.format("[INIT] WARNING: slot %d is empty — expected protected item", s))
        end
    end
    -- Name-based protection for the miner's own hardware, independent of which
    -- slot it happens to be sitting in. dumpOres consults this table, so a
    -- pickaxe/chunky/modem/loader displaced into a mining slot is never dropped
    -- into the ore ender chest.
    protectedItemNames[equipment.ITEMS.SCANNER]       = protectedItemNames[equipment.ITEMS.SCANNER]       or S_SCANNER
    protectedItemNames[equipment.ITEMS.LOADER_TURTLE] = protectedItemNames[equipment.ITEMS.LOADER_TURTLE] or S_LOADER
    protectedItemNames[equipment.ITEMS.PICKAXE]       = protectedItemNames[equipment.ITEMS.PICKAXE]       or S_TOOL
    protectedItemNames[equipment.ITEMS.CHUNKY]        = protectedItemNames[equipment.ITEMS.CHUNKY]        or S_TOOL
    protectedItemNames[equipment.ITEMS.MODEM]         = protectedItemNames[equipment.ITEMS.MODEM]         or S_MODEM
end

-- If a protected item was dug up and landed in a mining slot, move it home.
-- (Declared local at the top of the file: checkFuel is defined before this.)
rescueProtectedItems = function()
    for s = MINE_FIRST, MINE_LAST do
        local item = turtle.getItemDetail(s)
        if item then
            -- Check protected slots in priority order (15 before 16) so that when
            -- both ECs share the same item name, the fuel EC home wins.
            for _, home in ipairs({ S_SCANNER, S_LOADER, S_FUEL_EC, S_ORE_EC }) do
                if protectedSlotNames[home] == item.name then
                    if turtle.getItemCount(home) == 0 then
                        turtle.select(s)
                        turtle.transferTo(home)
                        print(string.format("[WARN] Rescued %s from slot %d → slot %d", item.name, s, home))
                        break
                    end
                    -- Home occupied; try next protected slot with the same item name.
                end
            end
        end
    end
end

local function sweepCoalToSlot14()
    for s = MINE_FIRST, MINE_LAST do
        local it = turtle.getItemDetail(s)
        if it and it.name:find("coal") then
            local space = turtle.getItemSpace(S_COAL)
            if space > 0 then
                turtle.select(s)
                turtle.transferTo(S_COAL, math.min(it.count, space))
            end
        end
    end
end

-- Deploys the ore ender chest, so it must be able to dig it back up: always
-- called through withDigTool by dumpOres below.
local function dumpToEC()
    sweepCoalToSlot14()
    turtle.select(S_ORE_EC)
    if turtle.detectDown() then
        turtle.digDown()
        rescueProtectedItems()  -- recover anything displaced into mining slots
        turtle.select(S_ORE_EC)  -- re-select: rescueProtectedItems changes selected slot
    end
    turtle.placeDown()
    for s = 1, 16 do
        local item = turtle.getItemDetail(s)
        if not PROTECTED[s]
                and turtle.getItemCount(s) > 0
                and not (item and protectedItemNames[item.name]) then
            turtle.select(s)
            turtle.dropDown()
        end
    end
    -- Clear slot 16 if something (from a full EC) landed there during the dump
    local inSlot = turtle.getItemDetail(S_ORE_EC)
    if inSlot and inSlot.name ~= protectedSlotNames[S_ORE_EC] then
        turtle.select(S_ORE_EC)
        for free = MINE_FIRST, MINE_LAST do
            if turtle.getItemCount(free) == 0 then turtle.transferTo(free); break end
        end
    end
    turtle.select(S_ORE_EC)
    turtle.digDown()
end

local function dumpOres()
    reportPhase(proto.PHASE.DUMPING)
    withDigTool("ore dump", dumpToEC)
end

-- Mining slots that must be free before a refuel is allowed to start.
--
-- turtle_base's refuelFromChest triggers its debris clear at fewer than 4 free
-- slots counted across 1-14. On a miner, slots 1-3 are permanently occupied and
-- 14 usually holds coal, so essentially the whole margin is the mining slots.
local REFUEL_FREE_SLOTS = 4

-- Empty the ore before any refuel.
--
-- refuelFromChest clears "debris" by DROPPING slots 1-14 on the ground when
-- fewer than 4 are free (turtle_base.lua, W3-owned; reported 2026-08-18). On a
-- miner that range holds the geo scanner, the carried chunk loader, the stowed
-- tool and the modem, so a refuel with a full inventory throws the turtle's own
-- hardware away -- and once the modem is gone, equipment.reconcile() cannot
-- recover it and the turtle goes permanently silent.
--
-- Dumping first means the count is never low enough for that branch to run.
-- It is also correct on its own terms: refuelling with a full inventory is
-- pointless, because the coal has nowhere to land.
--
-- This narrows the window. It does not close it -- the drop can still happen
-- before the miner reaches a dump point, and it does nothing for other roles.
-- The whitelist in refuelFromChest is the real fix and belongs to W3.
dumpBeforeRefuel = function(why)
    local free = 0
    for s = MINE_FIRST, MINE_LAST do
        if turtle.getItemCount(s) == 0 then free = free + 1 end
    end
    if free >= REFUEL_FREE_SLOTS then return end

    -- Never dig to make room for the chest here. dumpToEC digs whatever is
    -- below it, and when the miner is docked that block is the dock station
    -- chest. Skipping is always safe; destroying the station chest is not.
    if turtle.detectDown() then
        print(string.format(
            "[MINER] Pre-refuel dump skipped — no free space below (%d free slots)", free))
        return
    end

    print(string.format("[MINER] Dumping ore before %s — only %d free mining slot(s)",
        why, free))
    dumpOres()
end

local function inventoryFull()
    local free = 0
    for s = MINE_FIRST, MINE_LAST do
        if turtle.getItemCount(s) == 0 then free = free + 1 end
    end
    return free < 2
end

-- ── Geo Scanner ──────────────────────────────────────────────────────────────

-- ── Placed geo scanner: persistence and recovery ─────────────────────────────
--
-- Invariant D exists for the chunk loader: "placement is persisted to disk
-- before placing and cleared only after confirmed retrieval, so a crash at any
-- instant errs toward 'we may have one out there'." The geo scanner is placed as
-- a world block by exactly the same pattern and had no record at all, so any
-- interruption between placeDown() and digDown() abandoned it silently. A
-- scanner went missing in the field on 2026-08-18.
--
-- Losing it is not cosmetic: scanSector refuses to run without a scanner in
-- slot 1 and returns an empty ore list, so the miner keeps working sectors and
-- silently finds nothing.

local SCANNER_STATE_FILE = "scanner_state.dat"

local function scannerRecord(x, y, z)
    local ok = pcall(function()
        local f = fs.open(SCANNER_STATE_FILE, "w")
        if not f then error("open failed", 0) end
        f.write(textutils.serialise({ x = x, y = y, z = z }))
        f.close()
    end)
    return ok
end

local function scannerClear()
    pcall(function()
        if fs.exists(SCANNER_STATE_FILE) then fs.delete(SCANNER_STATE_FILE) end
    end)
end

local function scannerRecorded()
    local ok, rec = pcall(function()
        if not fs.exists(SCANNER_STATE_FILE) then return nil end
        local f = fs.open(SCANNER_STATE_FILE, "r")
        if not f then return nil end
        local raw = f.readAll(); f.close()
        local t = textutils.unserialise(raw)
        if type(t) ~= "table" then return nil end
        return t
    end)
    if ok then return rec end
    return nil
end

-- Called at boot, before any job is accepted. The scanner is placed directly
-- below the turtle and picked straight back up, so the turtle has not moved
-- between the two: recovery is verify-and-dig, with no navigation at all.
local function recoverPlacedScanner()
    local rec = scannerRecorded()
    if not rec then return end
    print(string.format("[SCAN] Boot: scanner recorded at %d,%d,%d — recovering",
        rec.x, rec.y, rec.z))

    -- Identity check before digging, never turtle.detectDown() alone: digging
    -- whatever happens to be underneath is how the loader retrieval used to
    -- destroy the wrong block.
    local seen, block = turtle.inspectDown()
    if seen and block and block.name == SCANNER_NAME then
        turtle.select(S_SCANNER)
        if turtle.digDown() then
            print("[SCAN] Scanner recovered to slot 1.")
            scannerClear()
        else
            print("[SCAN] WARNING: scanner is below but could not be dug up.")
        end
        return
    end

    -- Nothing of ours below. If we are standing where we placed it, it is
    -- genuinely gone and the record has done its job -- keeping it would warn
    -- forever with no action available. If we are somewhere else, the scanner is
    -- still out there at the recorded position, so the record must survive.
    local p = base.getPos()
    if p.x == rec.x and p.y == rec.y + 1 and p.z == rec.z then
        print("[SCAN] No scanner below and we are at the placement square — "
            .. "it is gone. Put one in slot 1.")
        scannerClear()
    else
        print(string.format("[SCAN] Scanner still recorded at %d,%d,%d and we are "
            .. "elsewhere — collect it by hand or clear %s",
            rec.x, rec.y, rec.z, SCANNER_STATE_FILE))
    end
end

local function scanSector()
    local item = turtle.getItemDetail(S_SCANNER)
    if not item or item.name ~= SCANNER_NAME then
        print("[SCAN] ERROR: geo scanner not in slot 1 (found: " .. tostring(item and item.name) .. ")")
        return {}
    end

    turtle.select(S_SCANNER)
    if turtle.detectDown() then turtle.digDown() end

    -- Record BEFORE placing, exactly as loader_state does: a crash between the
    -- write and the place leaves a false positive that recovery resolves
    -- harmlessly, while a crash the other way round loses the scanner for good.
    local p0 = base.getPos()
    if not scannerRecord(p0.x, p0.y - 1, p0.z) then
        print("[SCAN] ERROR: could not persist scanner placement — refusing to place")
        return {}
    end

    if not turtle.placeDown() then
        -- A clean failure: turtle.place() only consumes the item on success, so
        -- nothing is out there and the record just written is a false positive.
        scannerClear()
        print("[SCAN] ERROR: failed to place geo scanner below")
        return {}
    end
    print("[SCAN] Scanner placed — wrapping peripheral...")
    sleep(0.5)

    local sc = peripheral.wrap("bottom")
    if not sc then
        print("[SCAN] ERROR: peripheral.wrap('bottom') returned nil")
        turtle.select(S_SCANNER)
        if turtle.digDown() then scannerClear() end
        return {}
    end
    print("[SCAN] Scanning radius " .. SCAN_RADIUS .. "...")

    -- pcall'd so a scanner fault cannot skip the recovery below and abandon the
    -- block. The scan is the one call here that talks to a peripheral and can
    -- throw for reasons outside this program.
    local scanOk, raw = pcall(sc.scan, SCAN_RADIUS)
    turtle.select(S_SCANNER)
    if turtle.digDown() then
        scannerClear()
    else
        print("[SCAN] WARNING: scanner left placed — record kept for boot recovery")
    end

    if not scanOk then
        print("[SCAN] ERROR: sc.scan() threw: " .. tostring(raw))
        return {}
    end
    if not raw then
        print("[SCAN] ERROR: sc.scan() returned nil")
        return {}
    end
    print("[SCAN] Raw scan: " .. #raw .. " blocks")

    local p    = base.getPos()
    local ores = {}
    for _, b in ipairs(raw) do
        if isOre(b.name, b.tags) then
            table.insert(ores, {
                name = b.name,
                x    = p.x + b.x,
                y    = (p.y - 1) + b.y,
                z    = p.z + b.z,
            })
        end
    end
    print("[SCAN] Found " .. #ores .. " ore blocks")
    return ores
end

-- ── Mining ───────────────────────────────────────────────────────────────────

local function navToOre(ore, jobId)
    checkFuel(jobId)
    local p = base.getPos()
    local ok1 = base.move.to(ore.x, p.y, ore.z)
    if not ok1 then return false end
    checkFuel(jobId)
    local ok2 = base.move.to(ore.x, ore.y, ore.z)
    return ok2
end

-- Returns mined, byType, abortReason. abortReason is non-nil only when the
-- placed loader stopped beaconing: at that point mining is over for this
-- sector regardless of what is left in the list.
local function mineOreList(ores, jobId, sx, sz, sy)
    -- Greedy nearest-neighbour: re-sort after every mine so the miner stays
    -- in a vein until it's exhausted before jumping to a distant one.
    -- Skip ores below MIN_ORE_Y — the scanner at Y=8 can still detect them
    -- but navigating there risks hitting indestructible bedrock.
    local remaining = {}
    for _, o in ipairs(ores) do
        if o.y >= MIN_ORE_Y then table.insert(remaining, o) end
    end

    local SCAN_BATCH = 25   -- send one SECTOR_SCAN per N ores to avoid modem flood
    local mined      = 0
    local skipped    = 0
    local byType     = {}
    local scanBatch  = {}   -- accumulated since last flush: oreName → count

    local function flushScanBatch()
        if next(scanBatch) then
            base.sendToServer(proto.MSG.SECTOR_SCAN,
                proto.payloadSectorScan(jobId, sx, sz, sy, {}, scanBatch))
            scanBatch = {}
        end
    end

    while #remaining > 0 do
        if base.isRecalled() then break end
        if not loaderStillAlive() then
            handleBeaconLoss()
            flushScanBatch()
            return mined, byType, "loader_beacon_lost"
        end
        if autonomousReturnDue() then
            -- Outage long enough that sitting here with a loader placed is the
            -- worse option. The trip home is what actually retrieves it.
            flushScanBatch()
            return mined, byType, "server_unreachable_autonomous_return"
        end
        local p = base.getPos()
        table.sort(remaining, function(a, b)
            local da = math.abs(a.x-p.x) + math.abs(a.y-p.y) + math.abs(a.z-p.z)
            local db = math.abs(b.x-p.x) + math.abs(b.y-p.y) + math.abs(b.z-p.z)
            return da < db
        end)
        local ore = table.remove(remaining, 1)
        if inventoryFull() then dumpOres() end
        local reached = navToOre(ore, jobId)
        if not reached then
            -- Includes geofence refusals: an ore outside the placed loader's
            -- footprint is simply not minable this sector. Skipping it is
            -- correct; chasing it would strand the turtle in an unloaded chunk.
            skipped = skipped + 1
        else
            byType[ore.name]    = (byType[ore.name]    or 0) + 1
            scanBatch[ore.name] = (scanBatch[ore.name] or 0) + 1
            mined = mined + 1
            if mined % SCAN_BATCH == 0 then flushScanBatch() end
            if mined % 25 == 0 and turtle.getFuelLevel() < FUEL_WARN then
                checkFuel(jobId)
            end
        end
    end
    flushScanBatch()   -- send any remainder before SECTOR_DONE
    if skipped > 0 then
        print(string.format("[MINER] Skipped %d unreachable ores (bedrock/fenced/blocked)", skipped))
    end
    return mined, byType, nil
end

-- Wait for SECTOR_ASSIGN or MINE_COMPLETE. On timeout (server restart wiped
-- the in-memory zone) retry once with a fresh SECTOR_REQUEST so the server
-- can recreate the zone from on-disk persistentZones and respond correctly.
local function waitSectorResponse(jobId)
    local msg = waitMsg({ proto.MSG.SECTOR_ASSIGN, proto.MSG.MINE_COMPLETE }, 20)
    if msg or base.isRecalled() then return msg end
    base.sendProgress("sector response timeout — server restart? retrying SECTOR_REQUEST")
    base.sendToServer(proto.MSG.SECTOR_REQUEST, proto.payloadSectorRequest(jobId))
    return waitMsg({ proto.MSG.SECTOR_ASSIGN, proto.MSG.MINE_COMPLETE }, 30)
end

-- ── Placed loader: approach and retrieval ────────────────────────────────────

-- The square to stand on to dig the loader back up, and the facing to do it
-- from. mine_flow.retrieveLoader verifies the block ahead against the persisted
-- record by exact position, so being anywhere else fails with
-- loader_position_mismatch — this is what makes retrieval work after a reboot,
-- when the standing square we used at placement time is no longer in memory.
--
-- Approach from the side we are already on so the leg in never has to pass
-- through the loader itself.
local function approachFor(rec, from)
    if from.z > rec.z then return rec.x, rec.y, rec.z + 1, 0 end   -- stand south, face north
    if from.z < rec.z then return rec.x, rec.y, rec.z - 1, 2 end   -- stand north, face south
    if from.x > rec.x then return rec.x + 1, rec.y, rec.z, 3 end   -- stand east,  face west
    return rec.x - 1, rec.y, rec.z, 1                              -- stand west,  face east
end

-- Fly to the placed loader and take it back. `stand` is the square we actually
-- placed from when we still know it; otherwise one is derived from the record.
local function retrievePlacedLoader(stand)
    local rec = loader_state.get()
    if not rec then return false, "no_loader_recorded" end

    local sx, sy, sz, facing
    if stand then
        sx, sy, sz, facing = stand.x, stand.y, stand.z, stand.facing
    else
        sx, sy, sz, facing = approachFor(rec, base.getPos())
    end

    -- move.to is vertical-first. Climbing while still in the loader's OWN x/z
    -- column would run straight into it from below: turtle_base sees a turtle
    -- block, refuses to dig it, and waits out its 2-minute blocked deadline.
    -- Stepping to the approach column at the current altitude first avoids the
    -- loader entirely. Only done when we are actually in its column, so the
    -- normal end-of-sector retrieval still ascends before travelling.
    local here = base.getPos()
    if here.x == rec.x and here.z == rec.z and here.y ~= sy then
        base.move.to(sx, here.y, sz)
    end

    local ok, err = base.move.to(sx, sy, sz)
    if not ok then return false, "approach_failed: " .. tostring(err) end
    base.move.face(facing)

    local got, reason = mine_flow.retrieveLoader()
    -- retrieveLoader ends in equipment.retrievalSwapOut on both its success and
    -- most of its failure paths, which moves the modem to the other side.
    base.recoverModem()
    return got, reason
end

-- ── Boot recovery (Task 5b, deferred to here) ────────────────────────────────
-- A reboot with a loader still placed would otherwise abandon it: the turtle is
-- lost from the fleet and its chunk stays force-loaded with nothing recording
-- why. Runs before base.run, so recovery always precedes accepting new work.
--
-- Deliberately does NOT call equipment.reconcile(). comms.init already runs it
-- at boot for the one state it exists to fix (modem in inventory, not
-- equipped), and calling it here would raise a false chunky_unrecoverable on
-- every healthy mine-mode boot: a miner mid-sector legitimately carries the
-- chunky item with both upgrade sides full, which is exactly reconcile's
-- failure signature.
--
-- The approach mode is chunky + pickaxe (equipment's "retrieve" mode): loaded
-- AND able to dig, which is the only combination that can climb out of a
-- half-mined shaft without ever being unloaded. Comms are down for the flight —
-- the RETRIEVING phase report goes out first so the server expects the gap —
-- and come back when retrieveLoader swaps the modem in at the end.
local function recoverPlacedLoader()
    if not loader_state.hasPlaced() then return end
    local s = loader_state.get()
    print(string.format("[MINER] Boot: loader recorded at %d,%d,%d — recovering",
        s.x, s.y, s.z))
    base.sendProgress(string.format("recovering abandoned loader at %d,%d", s.x, s.z))

    -- Re-establish beacon tracking: _expectedLoaderPos is in-memory only, so
    -- without this every beacon from a loader that IS still alive is ignored.
    mine_flow.adoptRecordedLoader()

    -- Never fly (or dig) out of the depot. If a stale record survived a trip
    -- home, an operator has to resolve it: leaving the building under our own
    -- navigation would mean digging through the building itself.
    if base.isInsideBuilding(base.getPos()) then
        print("[MINER] Loader recorded but we are docked — NOT flying out. " ..
              "Collect it by hand or clear loader_state.dat.")
        base.sendProgress(string.format(
            "orphan_loader_at %d,%d,%d (miner is docked)", s.x, s.y, s.z))
        return
    end

    reportPhase(proto.PHASE.RETRIEVING,
        string.format("boot recovery — loader at %d,%d,%d", s.x, s.y, s.z))
    base.setAutonomousReturn(true)

    -- Reach chunky + pickaxe from wherever the reboot left us. base.init
    -- guarantees a modem is equipped by this point (comms.init errors out
    -- otherwise), so exactly one of these two transitions applies.
    local ready, why
    if not equipment.sideOf("chunky") then
        ready, why = equipment.retrievalSwapIn()   -- mine mode:   modem -> chunky
    elseif not equipment.sideOf("pickaxe") then
        ready, why = equipment.toRetrieveMode()    -- travel mode: modem -> pickaxe
    else
        ready = true                                -- already chunky + pickaxe
    end
    if not ready then
        print("[MINER] Loader recovery blocked — cannot reach chunky+pickaxe: " .. tostring(why))
        base.sendProgress("loader_recovery_blocked: " .. tostring(why))
        base.setAutonomousReturn(false)
        return
    end

    local ok, reason = retrievePlacedLoader(nil)
    if ok then
        print("[MINER] Loader recovered.")   -- mine_flow cleared the record
        base.sendProgress("loader recovered on boot")
    else
        -- Report loudly and leave the record in place: an operator needs to
        -- know a loader is standing out there, and the next boot retries.
        print("[MINER] Loader recovery FAILED: " .. tostring(reason))
        base.sendProgress("loader_recovery_failed: " .. tostring(reason))
    end

    -- Chunk loading first, comms later: a failed retrieval can leave us
    -- underground, where the pickaxe is what gets us out. On the success path
    -- retrieveLoader has already put the modem back, so this is a no-op there.
    local flyable, why2 = prepareToFly()
    if flyable then
        geofence.clear()
    else
        -- Same rule as soloReturn: never trade an armed fence for an unloaded
        -- flight. Boot recovery never arms one itself, so this only matters if
        -- something else did.
        print("[MINER] WARNING: no chunk loading of our own for the trip home: " .. tostring(why2))
    end

    -- Come home under our own navigation; the server may not even be up.
    local p = base.getPos()
    base.setSkyReturn(true)
    base.move.to(p.x, SKY_Y, p.z)
    base.move.to(W.ARRIVALS_HOLE.x, SKY_Y, W.ARRIVALS_HOLE.z)
    base.returnToDockFromSky()
    base.setSkyReturn(false)
    base.setAutonomousReturn(false)

    local restored, why3 = restoreTravelMode()
    if not restored then
        print("[MINER] WARNING: could not restore travel mode: " .. tostring(why3))
    end
    reportPhase(proto.PHASE.DOCKED)
end

-- ── Job handler ──────────────────────────────────────────────────────────────

local function mineJob(job)
    local jobId    = job.id
    local totalOre = 0
    _jobId         = jobId

    -- Per-miner altitude slot: concurrent miners each get a unique vertical
    -- band so they never occupy the same Y during inter-sector transit.
    -- Slot 0 (default) = baseline constants; slot N adds N*10 to each.
    local yOff           = (job.params.travelYOffset or 0)
    local SKY_Y          = 200 + yOff   -- shadows module-level constant
    local SURVEY_TRAVEL_Y = 175 + yOff  -- shadows module-level constant

    -- The square this sector's loader was placed from, so retrieval can stand
    -- exactly where mine_flow expects. nil whenever no loader is out.
    local stand           = nil
    local _serverDownSince = nil

    -- Solo return. No partner to coordinate with, so this is just: take the
    -- loader with us if one is still placed — leaving it behind loses a turtle
    -- and permanently loads a chunk — make sure we are self-loading, then fly
    -- home.
    local function soloReturn()
        reportPhase(proto.PHASE.RETURNING)
        -- Dump first: the pickaxe is still on during a normal sector end, and
        -- withDigTool covers the cases where it is not.
        dumpOres()

        if loader_state.hasPlaced() then
            local ok, reason = retrievePlacedLoader(stand)
            if not ok then
                print("[MINER] WARNING: could not retrieve loader: " .. tostring(reason))
                base.sendProgress("loader_left_behind: " .. tostring(reason))
            end
            stand = nil
            -- Re-report RETURNING now that the modem is back. Without this the
            -- last phase the server heard was RETRIEVING, and nothing else is
            -- reported until DOCKED — so the whole flight home displayed as a
            -- comms gap, and past the grace window as "Stuck in loader swap".
            reportPhase(proto.PHASE.RETURNING)
        end

        -- Restore our own chunk loading regardless of how the retrieval went,
        -- so we can get home either way. The modem comes back at the dock, not
        -- here: a failed retrieval can leave us underground, where the pickaxe
        -- is what gets us out.
        local flyable, why = prepareToFly()
        if flyable then
            -- Self-loading: the fence has nothing left to describe and would
            -- only block the way home.
            geofence.clear()
        else
            -- Chunky could not be restored. If a loader is still standing, that
            -- fence is now the ONLY thing keeping us inside loaded chunks —
            -- clearing it and flying is exactly "unloaded and outside the
            -- loaded area". Stay fenced and let the movement below refuse at
            -- the boundary; a miner parked inside a loaded footprint is
            -- recoverable, one frozen in an unloaded chunk is not.
            print("[MINER] WARNING: no chunk loading of our own for the trip home: " .. tostring(why))
            base.sendProgress("returning_without_chunk_loading: " .. tostring(why))
            if not geofence.isActive() then
                print("[MINER] No fence and no chunky — flying home unprotected.")
            end
        end

        checkFuel(jobId)
        local p = base.getPos()
        base.setSkyReturn(true)
        base.move.to(p.x, SKY_Y, p.z)
        base.move.to(W.ARRIVALS_HOLE.x, SKY_Y, W.ARRIVALS_HOLE.z)
        base.returnToDockFromSky()
        base.setSkyReturn(false)

        local restored, why2 = restoreTravelMode()
        if not restored then
            print("[MINER] WARNING: could not restore travel mode: " .. tostring(why2))
            base.sendProgress("travel_mode_not_restored: " .. tostring(why2))
        end
        reportPhase(proto.PHASE.DOCKED)
    end

    local function recallReturn(failReason, failRecoverable)
        soloReturn()
        base.sendFailed(failReason or "recalled", failRecoverable ~= nil and failRecoverable or false)
        _jobId = nil
    end

    local startPos = base.getPos()
    if not base.isInsideBuilding(startPos) then
        base.sendProgress("Rebooted mid-job — solo return")
        recallReturn("reboot_recovery", true)
        return
    end
    -- ── Pre-departure preflight ──────────────────────────────────────────────
    -- Both checks below MUST run before base.depart, not after it.
    --
    -- A miner whose retrieval failed still has its loader standing in the world
    -- and nothing in slot 2, so equipment.validate("travel") returns
    -- loader_turtle_missing. Run after departing, that produced: FAILED job ->
    -- server auto-respawns a replacement MINE job -> the dispatcher hands it
    -- straight back to the same (now idle) miner -> repeat. Roughly once a
    -- minute, forever, since no sector can ever complete -- and each cycle left
    -- the miner parked at the dispatch hole instead of its dock, burning fuel on
    -- the way there. Nothing cleared it: recoverPlacedLoader's docked branch
    -- deliberately returns with the record intact.
    --
    -- Checking first means the miner never leaves its dock, and the distinct
    -- non-retryable reasons tell an operator which of the two states it is in.
    if loader_state.hasPlaced() then
        local s = loader_state.get()
        local detail = string.format("loader_outstanding at %d,%d,%d", s.x, s.y, s.z)
        print("[MINER] Refusing job — " .. detail)
        base.sendProgress(detail .. " — collect it by hand or clear loader_state.dat")
        base.sendFailed(detail, false)
        _jobId = nil
        return
    end

    -- Everything below depends on being in travel mode with a loader aboard.
    local eqOk, eqReason = equipment.validate("travel")
    if not eqOk then
        print("[MINER] Equipment check failed: " .. tostring(eqReason))
        base.sendProgress("equipment_invalid: " .. tostring(eqReason))
        base.sendFailed("equipment_invalid: " .. tostring(eqReason), false)
        _jobId = nil
        return
    end

    -- Slot and fuel preflight. Both MUST run before base.depart, for the same
    -- reason the two checks above do: a refusal after departing produces a
    -- FAILED job, an auto-respawned replacement, and a miner parked at the
    -- dispatch hole burning fuel on every cycle.
    local slotOk, slotReason = preflightSlots()
    if not slotOk then
        print("[MINER] Refusing job — " .. slotReason)
        base.sendProgress(slotReason .. " — fix the inventory layout")
        base.sendFailed(slotReason, false)
        _jobId = nil
        return
    end

    local needFuel = fuelForZone(job.params, SKY_Y)
    if turtle.getFuelLevel() < needFuel then
        -- Try to top up first. dockRefuel falls back to the coal ender chest as
        -- of 1.9.8, so a miner sitting on a dry dock chest can still recover
        -- here instead of being stuck low forever.
        print(string.format("[MINER] Need ~%d fuel for this zone, have %d — refuelling",
            needFuel, turtle.getFuelLevel()))
        base.fuel.dockRefuel()
    end
    if turtle.getFuelLevel() < needFuel then
        local detail = string.format("insufficient_fuel_for_zone: have %d, need ~%d",
            turtle.getFuelLevel(), needFuel)
        print("[MINER] Refusing job — " .. detail)
        base.sendProgress(detail .. " — stock the coal ender chest")
        -- Recoverable: the job returns to PENDING, and the server's own
        -- distance-aware gate holds it until some miner can actually afford it.
        base.sendFailed(detail, true)
        _jobId = nil
        return
    end

    base.setStatus(proto.STATUS.TRAVELLING, jobId)
    base.sendProgress("Departing for mining zone")
    reportPhase(proto.PHASE.DEPARTING)

    local ok, err = base.depart(true)  -- stay at floor level, ascend directly
    if not ok then
        base.sendFailed("departure_failed: " .. (err or "?"), true)
        _jobId = nil
        return
    end

    checkFuel(jobId)
    local p = base.getPos()
    base.move.to(p.x, SKY_Y, p.z)

    -- ── Sector loop ──────────────────────────────────────────────────────────
    -- Request first sector. Thereafter: place loader → scan → mine → retrieve
    -- loader → SECTOR_DONE → request next.

    base.sendToServer(proto.MSG.SECTOR_REQUEST, proto.payloadSectorRequest(jobId))
    local msg = waitSectorResponse(jobId)

    local useSkyTravel = false  -- true after first mine sector; switches to SKY_Y=200

    while msg and msg.type == proto.MSG.SECTOR_ASSIGN do
        if base.isRecalled() then
            recallReturn()
            return
        end

        -- Between-sectors case: no loader is placed here (it was retrieved
        -- before SECTOR_DONE), so the elapsed check alone applies. The
        -- mid-sector case — the one that matters, and the one a check in this
        -- position can never catch — is handled by autonomousReturnDue() in the
        -- mining loops and by the escape hook in tryMove's hold.
        if serverDownTooLong() then
            print("[MINER] Server unreachable 5min — autonomous return")
            base.setAutonomousReturn(true)
            soloReturn()
            base.setAutonomousReturn(false)
            base.sendFailed("server_unreachable_autonomous_return", true)
            _jobId = nil
            return
        end

        local sx         = msg.payload.sectorX
        local sz         = msg.payload.sectorZ
        local surveyMode = msg.payload.surveyMode == true
        local modeTag    = surveyMode and "[SURVEY] " or ""

        base.setStatus(proto.STATUS.TRAVELLING, jobId)
        base.sendProgress(string.format("%sTravelling to sector %d,%d", modeTag, sx, sz))
        reportPhase(proto.PHASE.TRAVELLING, string.format("sector %d,%d", sx, sz))

        -- Survey sectors and the first mine sector travel at SURVEY_TRAVEL_Y;
        -- from mine sector 2 onwards, at SKY_Y.
        checkFuel(jobId)
        local travelY = (surveyMode or not useSkyTravel) and SURVEY_TRAVEL_Y or SKY_Y
        if not surveyMode then useSkyTravel = true end

        -- Every sector starts in travel mode with a loader aboard; anything
        -- else and placement would fail with the loader already half-committed.
        local tOk, tReason = equipment.validate("travel")
        if not tOk then
            print("[MINER] Equipment check failed: " .. tostring(tReason))
            base.sendProgress("equipment_invalid: " .. tostring(tReason))
            soloReturn()
            base.sendFailed("equipment_invalid: " .. tostring(tReason), false)
            _jobId = nil
            return
        end

        -- Fly lateral-then-vertical when descending so the long horizontal leg
        -- happens at the altitude we arrived at.
        local standX, standZ = sx + STAND_OFFSET, sz + STAND_OFFSET
        local curPos = base.getPos()
        if curPos.y > travelY then
            base.move.to(standX, curPos.y, standZ)
        end
        -- The result MUST be checked. placeLoader records the loader from the
        -- turtle's ACTUAL position, while `stand` below used to record the
        -- intended one -- so a move that ran out of retries (another miner in
        -- the way, most often) left the two describing different squares. The
        -- loader went down wherever the turtle really was, retrieval flew to
        -- where it meant to be, and the block ahead failed the record check
        -- with loader_position_mismatch. That is a non-recoverable failure, so
        -- the miner went home and left its loader standing -- which then
        -- blocked it from taking any further job via the loader_outstanding
        -- guard. Two miners were lost that way in one run.
        local mOk, mErr = base.move.to(standX, travelY, standZ)
        if not mOk then
            print("[MINER] Cannot reach the placement square: " .. tostring(mErr))
            base.sendProgress("sector_setup_failed: approach_failed: " .. tostring(mErr))
            soloReturn()
            base.sendFailed("sector_setup_failed: approach_failed: " .. tostring(mErr), true)
            _jobId = nil
            return
        end
        base.move.face(PLACE_FACING)

        -- Hand chunk duty to the placed loader before giving up our own. The
        -- fence must end up on the LOADER's chunk, which is the sector's anchor
        -- chunk: placing one chunk off would leave the sector's far edge
        -- unloaded.
        local acx, acz = geofence.chunkOf(sx, sz)
        -- Taken from where the turtle ACTUALLY is, never from where it was told
        -- to go. placeLoader records the loader relative to base.getPos() too,
        -- so both now describe the same square by construction and cannot drift
        -- apart even if the move above ever succeeds only partially.
        local standPos = base.getPos()
        stand = { x = standPos.x, y = standPos.y, z = standPos.z,
                  facing = base.getFacing() }
        _beaconLost     = false
        _lastBeaconPoll = os.epoch("utc") / 1000

        local placed, placeErr =
            mine_flow.placeLoader(FENCE_CHUNK_RADIUS, { cx = acx, cz = acz })
        if not placed then
            print("[MINER] Cannot start sector: " .. tostring(placeErr))
            base.sendProgress("sector_setup_failed: " .. tostring(placeErr))
            -- soloReturn takes the loader back with us if it did go down before
            -- the failure (loader_state is the authority, not the fence).
            soloReturn()
            base.sendFailed("sector_setup_failed: " .. tostring(placeErr), true)
            _jobId = nil
            return
        end

        -- Scan every depth level; only mine if not in survey mode.
        -- seenOres deduplicates across depth levels: scan spheres overlap
        -- (Y=16 covers Y 0-32, Y=8 covers Y -8 to 24 — 24-block overlap),
        -- so the same ore block appears in multiple raw scan results.
        local count       = 0
        local sectorFound = {}   -- {[name]=count} from geo scan (deduplicated)
        local sectorMined = {}   -- {[name]=count} actually mined (0 during survey)
        local seenOres    = {}   -- "x,y,z" → true; prevents double-counting
        local abort       = nil  -- non-nil once the sector must be abandoned
        for i, sy in ipairs(SCAN_LEVELS) do
            if not loaderStillAlive() then
                handleBeaconLoss()
                abort = "loader_beacon_lost"
                break
            end
            if autonomousReturnDue() then
                abort = "server_unreachable_autonomous_return"
                break
            end
            checkFuel(jobId)
            base.move.to(sx, sy, sz)
            base.setStatus(proto.STATUS.WORKING, jobId)
            base.sendProgress(string.format("%sScanning %d,%d depth %d/%d (Y=%d)",
                modeTag, sx, sz, i, #SCAN_LEVELS, sy))
            reportPhase(proto.PHASE.SCANNING, string.format("%d,%d Y=%d", sx, sz, sy))
            local rawOres = scanSector()
            -- Deduplicate: only keep ore blocks not seen at a previous depth level.
            local ores      = {}
            local scanFound = {}
            for _, o in ipairs(rawOres) do
                local key = o.x .. "," .. o.y .. "," .. o.z
                if not seenOres[key] then
                    seenOres[key] = true
                    table.insert(ores, o)
                    scanFound[o.name]    = (scanFound[o.name]    or 0) + 1
                    sectorFound[o.name] = (sectorFound[o.name] or 0) + 1
                end
            end
            -- Report scan results immediately so the dashboard updates in real time.
            if next(scanFound) then
                base.sendToServer(proto.MSG.SECTOR_SCAN,
                    proto.payloadSectorScan(jobId, sx, sz, sy, scanFound))
            end
            -- During survey: report ores found but do not mine them
            if #ores > 0 and not surveyMode then
                base.sendProgress(string.format("Mining %d ores at Y=%d", #ores, sy))
                reportPhase(proto.PHASE.MINING, string.format("%d ores at Y=%d", #ores, sy))
                local c, byType, mineAbort = mineOreList(ores, jobId, sx, sz, sy)
                count = count + c
                for name, n in pairs(byType) do
                    sectorMined[name] = (sectorMined[name] or 0) + n
                end
                if mineAbort then abort = mineAbort; break end
            end
            if base.isRecalled() then break end
        end

        if count > 0 or inventoryFull() then dumpOres() end
        totalOre = totalOre + count

        -- Either the loader stopped proving it was alive (chunk loading is
        -- already back on our own upgrade via handleBeaconLoss) or the server
        -- has been unreachable too long to keep waiting. Both end the same way:
        -- take the loader home and let the server re-dispatch.
        if abort then
            base.sendProgress("sector abandoned: " .. abort)
            -- The trip home must not be held by tryMove's serverDown wait, and
            -- on the beacon-loss path our modem is off until the retrieval
            -- swap-out, so the hold would otherwise engage and never release.
            base.setAutonomousReturn(true)
            soloReturn()
            base.setAutonomousReturn(false)
            base.sendFailed(abort, true)
            _jobId = nil
            return
        end

        if base.isRecalled() then
            recallReturn()
            return
        end

        -- Take the loader back BEFORE reporting the sector done: the next
        -- SECTOR_ASSIGN arrives immediately and travel must start in travel
        -- mode with the loader aboard.
        local got, retErr = retrievePlacedLoader(stand)
        if not got then
            print("[MINER] Cannot retrieve loader: " .. tostring(retErr))
            base.sendProgress("loader_retrieve_failed: " .. tostring(retErr))
            -- Do not keep mining. soloReturn restores our own chunk loading,
            -- releases the fence, and retries the retrieval once on the way
            -- out (loader_state still records it as standing).
            soloReturn()
            base.sendFailed("loader_retrieve_failed: " .. tostring(retErr), false)
            _jobId = nil
            return
        end
        stand = nil

        -- Report done; server immediately replies with next SECTOR_ASSIGN or MINE_COMPLETE
        base.sendToServer(proto.MSG.SECTOR_DONE,
            proto.payloadSectorDone(jobId, sx, sz, count, sectorFound, sectorMined))

        msg = waitSectorResponse(jobId)
        if not msg then
            if base.isRecalled() then
                recallReturn()
            elseif serverDownTooLong() then
                -- waitMsg gave up on the freeze rather than waiting out the
                -- outage; go home unaided instead of reporting a timeout that
                -- would never reach the server anyway.
                print("[MINER] Server unreachable 5min — autonomous return")
                base.setAutonomousReturn(true)
                recallReturn("server_unreachable_autonomous_return", true)
                base.setAutonomousReturn(false)
            else
                recallReturn("sector_request_timeout", true)
            end
            return
        end
    end

    -- ── Return home ──────────────────────────────────────────────────────────
    base.sendProgress(string.format("All sectors done — %d ore mined. Returning.", totalOre))
    soloReturn()
    base.sendComplete({ oreCount = totalOre })
    _jobId = nil
end

initProtectedSlots()
-- Recover an abandoned loader before any job can be accepted.
local rok, rerr = pcall(recoverPlacedLoader)
if not rok then
    print("[MINER] Loader recovery crashed: " .. tostring(rerr))
end
-- Same for the geo scanner. Runs after the loader because the loader is the
-- expensive one -- a whole turtle plus a permanently force-loaded chunk -- and
-- both are pcall'd separately so a failure in either still lets the other run.
local sok, serr = pcall(recoverPlacedScanner)
if not sok then
    print("[MINER] Scanner recovery crashed: " .. tostring(serr))
end
local ok, err = pcall(base.run, mineJob)
if not ok then
    -- Unhandled crash. Print so it's visible on the terminal, then reboot
    -- so the turtle re-registers with the server and can be re-dispatched.
    -- The 20s pause keeps the error readable before the screen clears.
    print("[MINER] Fatal crash: " .. tostring(err))
    print("[MINER] Rebooting in 20s...")
    sleep(20)
end
os.reboot()
