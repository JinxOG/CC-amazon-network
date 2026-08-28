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

-- Retrieval retries. A mismatch is usually a block or two of dead-reckoning
-- drift, which a fresh GPS fix plus the loader's own broadcast position
-- corrects. Three is enough for that and small enough that a genuinely missing
-- loader still fails quickly rather than burning a job's worth of time.
local RETRIEVE_ATTEMPTS    = 3
-- Loaders beacon every 5s, so one interval plus margin. Kept under Invariant J's
-- 10-second silent-wait limit, and the wait logs what it is waiting for anyway.
local RETRIEVE_BEACON_WAIT = 7
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
local dumpIfInventoryTight

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

-- Burn the slot-14 reserve, and unblock the slot if what is in it will not burn.
--
-- The old version selected slot 14 and called refuel() unconditionally. On a
-- slot full of coal ORE that fails silently and leaves it full, which is the
-- state that made the buffer unusable for the rest of the job. tendFuelSlot
-- evicts a non-combustible occupant so the next refuelFromEC has room to suck
-- into.
local function tryRefuelSlot14()
    mine_flow.tendFuelSlot({ slot = S_COAL, first = MINE_FIRST, last = MINE_LAST })
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

-- Bank ore to the ore ender chest when turtle_base's refuel debris sweep is
-- about to run, so it has nothing left to throw on the ground (W3, 1.9.26).
--
-- This is the only thing that covers fuel.ensureFuel() firing from the control
-- loop: that path reaches refuelFromChest with no W1 code in front of it, so
-- guarding the entrances with dumpIfInventoryTight never could have caught it.
--
-- dumpIfInventoryTight rather than dumpOres, because the two thresholds are
-- provably compatible and this avoids pointless work. The sweep counts free
-- slots across 1-14 and fires below 4; the dump counts free MINING slots 5-13
-- and fires below 4. free(1..14) >= free(5..13) always, so free(5..13) >= 4
-- implies free(1..14) >= 4 and the sweep would not have fired at all. Whenever
-- the sweep fires, the dump fires too -- while dumpOres unconditionally would
-- deploy and recover a chest on refuels that do not need one.
--
-- Safe to call from inside the dig-tool wrapper, which is where refuelFromChest
-- normally runs: withDigTool short-circuits to fn() when a pickaxe is already
-- equipped, so no nested upgrade swap happens. Verified, not assumed.
base.setMakeRoomFn(function() dumpIfInventoryTight("refuel sweep") end)

base.setRefuelFn(function()
    -- FORCE_REFUEL arrives while docked and idle, and goes straight into
    -- refuelFromChest — the call that drops slots 1-14 when the inventory is
    -- tight. Empty the ore first for the same reason checkFuel does.
    dumpIfInventoryTight("force refuel")
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
    -- dumpIfInventoryTight — a refuel with full mining slots makes refuelFromChest
    -- drop the scanner, loader, tool and modem on the ground.
    dumpIfInventoryTight("refuel")

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
-- Say so, loudly, when we are carrying an advanced turtle that cannot be ours.
--
-- A miner that acquires one has almost certainly just destroyed a fleet member,
-- and the wreckage is recoverable if somebody knows to look: node_119 booted
-- with its ID, filesystem and role intact once it was placed back down. Nothing
-- in the system told anyone it was in a slot -- W1 diagnosed it as a missing
-- turtle for most of a session. Rate-limited to one report per slot per find so
-- a dump loop cannot flood the log.
local _foreignTurtleReported = {}
local function reportForeignTurtle(slot, item)
    if _foreignTurtleReported[slot] then return end
    _foreignTurtleReported[slot] = true
    -- Ask for the DETAILED form: displayName is absent from the plain query in
    -- real CC (and now in the stub too, W3 2026-08-22). It is the single most
    -- useful field here, because the name is upgrade-derived -- "Advanced Ender
    -- Mining Turtle" versus "Advanced Chunky Ender Turtle" tells an operator
    -- which phase the victim was in when it died, and so roughly where to look.
    local d = turtle.getItemDetail(slot, true) or item
    local detail = string.format(
        "foreign_turtle_carried in slot %d (%s) — our loader is on record as "
        .. "standing; this is most likely a destroyed fleet turtle", slot,
        tostring(d and (d.displayName or d.name) or "?"))
    print("[MINER] " .. detail)
    base.sendProgress(detail)
end

rescueProtectedItems = function()
    -- Scans slots 1..14, not just the mining slots.
    --
    -- turtle.dig() puts drops in the first FREE slot, and slots 2, 3 and 4 are
    -- all empty during their swap windows -- the loader while it stands in the
    -- world, the tool and modem while equipped. So displaced hardware can land
    -- anywhere in that range, not only in 5-13, and a loader sitting in slot 4
    -- was invisible to this.
    --
    -- An item already in its own home is skipped for free: the home is then
    -- occupied by the item itself, so the getItemCount(home) == 0 guard below
    -- fails and nothing moves.
    --
    -- 15 and 16 are deliberately NOT scanned. Both hold ender chests with the
    -- same registry name, so a scan that reached them could "rescue" the ore
    -- chest out of 16 into an empty 15 -- the cannibalisation this codebase has
    -- already been bitten by once.
    for s = 1, S_COAL do
        local item = turtle.getItemDetail(s)
        if item then
            -- Check protected slots in priority order (15 before 16) so that when
            -- both ECs share the same item name, the fuel EC home wins.
            for _, home in ipairs({ S_SCANNER, S_LOADER, S_FUEL_EC, S_ORE_EC }) do
                if protectedSlotNames[home] == item.name then
                    -- A turtle we cannot account for is NOT our loader.
                    --
                    -- foreignTurtleSlot() fires only when our own loader is on
                    -- record as standing in the world, which makes any advanced
                    -- turtle in the inventory something we picked up -- almost
                    -- certainly a fleet member we just dug up. Promoting it into
                    -- slot 2 is how node_119 rode home in node_139's loader slot
                    -- and then passed every possession check in the system.
                    --
                    -- Safe against the retrieval window: mine_flow clears the
                    -- record (line 588) BEFORE normalizeLoaderSlot (595), so a
                    -- legitimately retrieved loader always arrives here with
                    -- hasPlaced() already false and rescues normally.
                    if home == S_LOADER and equipment.foreignTurtleSlot() then
                        reportForeignTurtle(s, item)
                        break
                    end
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

-- Keep slot 14 holding fuel, and burn any fuel found in the payload slots.
--
-- Replaces a substring match on "coal", which also matched minecraft:coal_ore
-- and minecraft:deepslate_coal_ore -- 1,691 and 65 of them in the live zone
-- history. Neither burns. Swept into slot 14 they bricked the fuel buffer
-- permanently, because refuelFromEC sizes its suck as 64 - getItemCount(14) and
-- that is then always 0. node_119 was found at 1,845 fuel against 1,696 needed
-- to get home, looping on LOW, carrying six stacks of coal it could not burn.
--
-- Burning here rather than hoarding is deliberate: only slot 14 is exempt from
-- dumpToEC, so coal anywhere else was being shipped to the ore chest as cargo.
local function sweepCoalToSlot14()
    local burned, evicted = mine_flow.tendFuelSlot({
        slot = S_COAL, first = MINE_FIRST, last = MINE_LAST,
    })
    if evicted > 0 then
        base.sendProgress("fuel_slot_cleared: non-combustible item evicted from slot "
            .. S_COAL .. " (mined coal ore, most likely)")
    end
    return burned
end

-- Deploys the ore ender chest, so it must be able to dig it back up: always
-- called through withDigTool by dumpOres below.
local function dumpToEC()
    sweepCoalToSlot14()

    -- Banking moved to mine_flow.bankPayload so it can be tested.
    --
    -- What was here: turtle.placeDown() with its result ignored, then a drop
    -- loop that ran regardless. turtle.dropDown() with no container underneath
    -- throws the items into the world, so any failure to place the chest
    -- scattered the whole payload -- observed in-world 2026-08-22 as piles of
    -- ore across the mining zone. Two ways it failed routinely: the deepest
    -- scan level bottoms out in bedrock where digDown() refuses, and a
    -- displaced ore chest is rescued into slot 15 (both ender chests share one
    -- registry name), leaving slot 16 empty at dump time.
    --
    -- ore_turtle self-executes and cannot be loaded headlessly, so nothing in
    -- the suite could ever reach this code. bankPayload lives in a requirable
    -- module and is covered by tests that model a drop into thin air as
    -- distinct from a drop into the chest -- a distinction stub_cc's own
    -- drop() does not make, which is why this survived so long.
    local banked, why = mine_flow.bankPayload({
        chestSlot = S_ORE_EC,
        afterDig  = rescueProtectedItems,
        shouldDump = function(s, item)
            local isHardware = item and protectedItemNames[item.name] ~= nil
            local reserved   = PROTECTED[s] == true

            -- Foreign items squatting in a reserved slot must be dumped too.
            --
            -- While the loader is standing in the world its home slot is EMPTY,
            -- and turtle.dig() puts drops in the first free slot -- so ore lands
            -- in slot 2. Skipping every reserved slot meant that ore was never
            -- dumped: it sat there permanently, costing capacity, and on
            -- retrieval normalizeLoaderSlot() could not return the loader home,
            -- so it ended up in a mining slot instead. Observed in-world.
            --
            -- The same reasoning covers slots 3 and 4, which are also empty
            -- during their swap windows. S_COAL is excluded because coal in it
            -- is the fuel buffer working exactly as intended, and hardware is
            -- excluded wherever it sits -- that is what protectedItemNames is
            -- for, and rescueProtectedItems puts it back afterwards.
            local foreignInReserved = reserved and s ~= S_COAL and not isHardware

            return (not reserved and not isHardware) or foreignInReserved
        end,
    })

    if not banked then
        -- Keep the payload. A full inventory home is a bad trip; a sector's ore
        -- on the floor is gone. The old code chose the floor, silently.
        print("[MINER] Ore chest could not be deployed (" .. tostring(why)
            .. ") — payload kept aboard, nothing dropped")
        base.sendProgress("bank_failed: " .. tostring(why)
            .. " — payload retained, nothing dropped")
    end

    -- Clear slot 16 if something (from a full EC) landed there during the dump
    local inSlot = turtle.getItemDetail(S_ORE_EC)
    if inSlot and inSlot.name ~= protectedSlotNames[S_ORE_EC] then
        turtle.select(S_ORE_EC)
        for free = MINE_FIRST, MINE_LAST do
            if turtle.getItemCount(free) == 0 then turtle.transferTo(free); break end
        end
    end
    -- No digDown() here any more: bankPayload takes the chest back on whichever
    -- face it used. A blind digDown() at this point would dig whatever happens
    -- to be below instead -- terrain, ore, or another turtle.
    turtle.select(S_ORE_EC)

    -- Put displaced hardware back in its home slot, on EVERY dump.
    --
    -- This used to run only inside the `if turtle.detectDown()` branch at the
    -- top -- i.e. only when a block happened to need digging before the chest
    -- could be placed. On the ordinary path it never ran at all, even though
    -- the comment in the drop loop above promises it does.
    --
    -- The consequence reached the dock: node_138 finished a job carrying its
    -- chunk loader in a mining slot instead of slot 2. turtle.dig() puts drops
    -- in the first free slot, so a retrieved loader lands wherever there was
    -- room; mine_flow's normalizeLoaderSlot is explicitly tidy-up-only and gives
    -- up if the home slot is occupied at that instant -- which it often was,
    -- because ore squatted there while the loader was standing in the world.
    --
    -- Running it here, after the drop loop has cleared foreign items out of the
    -- reserved slots and after the ore chest is back in hand, means the home
    -- slot is free by the time we try. Dumps happen whenever the mining slots
    -- fill, at sector end, and on the way home, so this is the periodic
    -- inventory tidy rather than a one-off.
    rescueProtectedItems()
    turtle.select(S_ORE_EC)   -- rescueProtectedItems leaves its own slot selected
end

local function dumpOres()
    reportPhase(proto.PHASE.DUMPING)
    withDigTool("ore dump", dumpToEC)
end

-- Tidy up on arrival at the dock.
--
-- soloReturn already dumps before leaving the sector, so in principle a miner
-- arrives empty. In practice it does not: the flight home runs through
-- base.move.to, which digs any static obstruction in its path, and CC collects
-- what it breaks. So a turtle reaches its bay carrying travel debris -- the same
-- mechanism that refilled the inventory between the pre-approach dump and the
-- loader dig.
--
-- Ordered deliberately. rescueProtectedItems needs no chest and cannot fail
-- destructively, so it runs unconditionally: hardware ends up in its home slot
-- even when the ore cannot be banked. Banking is attempted second, and only
-- when there is somewhere safe to put the chest.
local function tidyAtDock()
    -- Always reorient, chest or no chest.
    rescueProtectedItems()

    local carrying = false
    for s = MINE_FIRST, MINE_LAST do
        if turtle.getItemCount(s) > 0 then carrying = true; break end
    end
    if not carrying then return end

    -- Never dig here. dumpToEC digs the block below to place the ore chest, and
    -- at a dock that block is very often the station chest dockRefuel draws
    -- from. Keeping a stack of cobblestone is strictly better than destroying
    -- the operator's chest.
    if turtle.detectDown() then
        print("[MINER] Dock tidy: no free space below for the ore chest — "
            .. "travel debris kept aboard")
        return
    end

    print("[MINER] Dock tidy: banking travel debris")
    dumpOres()
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
dumpIfInventoryTight = function(why)
    local free = 0
    for s = MINE_FIRST, MINE_LAST do
        if turtle.getItemCount(s) == 0 then free = free + 1 end
    end
    if free >= REFUEL_FREE_SLOTS then return end

    -- dumpToEC digs whatever is below to place the ore chest. That is fine in
    -- the field -- it is one block of stone -- but when the miner is docked the
    -- block below is the dock station chest, and destroying it to bank ore is
    -- not a trade worth making.
    --
    -- So the guard is scoped to the depot rather than to "anything below".
    -- Previously it skipped on ANY obstruction, which meant a miner refuelling
    -- in a tunnel skipped the dump and then let turtle_base's debris sweep
    -- throw that ore on the ground, where it is lost rather than banked to RS.
    if base.isInsideBuilding(base.getPos()) and turtle.detectDown() then
        print(string.format(
            "[MINER] Pre-op dump skipped — docked with the station chest below (%d free slots)",
            free))
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
    -- Drop ore the fence will not let us reach. The scanner sees 33 blocks wide
    -- and the lease is 32, so roughly 6% of every scan sits outside it -- ore
    -- that belongs to the neighbouring sector and is mined when that lease is
    -- issued. Counting it here credited it to the wrong sector and made every
    -- sector look like it left 6% behind.
    local reachable, dropped = mine_flow.filterToLease(ores)
    if dropped > 0 then
        print(string.format("[SCAN] Found %d ore blocks (%d outside the lease, "
            .. "left for the neighbouring sector)", #reachable, dropped))
    else
        print("[SCAN] Found " .. #reachable .. " ore blocks")
    end
    return reachable
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

    -- Get a true position before working out the approach.
    --
    -- The stand square and the loader's recorded position were both captured at
    -- the moment the loader went down. Everything since is dead reckoning across
    -- a whole sector of mining, and it drifts. Observed in-world: two miners came
    -- back believing they stood one block west of where they actually were,
    -- walked to that belief, found something other than their loader in front of
    -- them, and correctly refused to dig. Both jobs died and both loaders were
    -- left standing.
    --
    -- move.to cannot catch this on its own: it loops until its own tracked
    -- position equals the target, so a drifted turtle arrives "successfully" at
    -- the wrong block. One GPS fix puts the turtle back in the same frame the
    -- record was written in, so the approach lands on the real square.
    --
    -- Fails soft by contract -- base.gpsSync() logs and returns false without
    -- raising, leaving the dead-reckoned position, which is exactly today's
    -- behaviour. So this can only improve the odds, never make them worse.
    --
    -- This does NOT fix the drift itself, only stop it costing a job and a
    -- stranded loader. The source of the lost block is still unknown.
    base.gpsSync()

    -- Make room BEFORE digging the loader up, on every path.
    --
    -- turtle.dig() with no room for the drop still returns TRUE: the block is
    -- destroyed and the item is simply lost. mine_flow documents this and
    -- detects it afterwards as loader_lost_after_dig -- but detection is too
    -- late, because by then a physical loader turtle no longer exists.
    --
    -- Observed live after a server restart: four miners resumed boot recovery
    -- carrying a full load of ore from the interrupted job, dug up their
    -- loaders, and TWO of the four destroyed them outright. A third had partial
    -- room and the loader landed in a mining slot rather than its home slot.
    --
    -- soloReturn already dumped first; boot recovery and the sector-end
    -- retrieval did not. Putting it here rather than at the call sites means no
    -- future path can forget it -- the dig is the thing that needs the room, so
    -- the guard belongs next to the dig.
    dumpIfInventoryTight("loader retrieval")

    -- Approach, and retry on a position mismatch rather than giving up.
    --
    -- A single attempt cannot be made reliable. The record is written from the
    -- miner's dead-reckoned belief at placement, that belief drifts over a
    -- sector of mining, and move.to loops until its OWN tracked position matches
    -- the target -- so a drifted turtle arrives "successfully" at the wrong
    -- block and the mismatch check correctly refuses to dig. Resyncing before
    -- the approach did not fix it (1.9.28): the approach is itself a long
    -- flight, and turtle_base resyncs every 50 moves, so a correction can land
    -- after move.to has already declared victory.
    --
    -- So make the operation self-correcting instead, using the one authority
    -- that is not guessing: the loader broadcasts its own gps.locate() fix every
    -- 5 seconds. On a mismatch we resync, listen for that beacon, believe it
    -- over our record, and go again.
    local lastReason
    for attempt = 1, RETRIEVE_ATTEMPTS do
        if attempt > 1 then
            -- Fresh fix first: cheap, and corrects the common case where only
            -- our own position was wrong.
            base.gpsSync()

            -- Then ask the loader where IT thinks it is. The modem is still on
            -- at this point -- retrieveLoader's position check runs before
            -- retrievalSwapIn -- so beacons can still reach us. Only beacons
            -- within NEAR_MISS_RADIUS of the record are believed, and sectors
            -- are 32 blocks apart, so nothing but our own loader can qualify.
            print(string.format(
                "[MINER] Retrieval attempt %d/%d — listening %ds for the loader's own position",
                attempt, RETRIEVE_ATTEMPTS, RETRIEVE_BEACON_WAIT))
            local deadline = os.epoch("utc") / 1000 + RETRIEVE_BEACON_WAIT
            while os.epoch("utc") / 1000 < deadline do
                if mine_flow.nearbyBeaconPos() then break end
                pump(1)
            end

            local beaconPos = mine_flow.nearbyBeaconPos()
            if beaconPos then
                print(string.format(
                    "[MINER] Loader reports %d,%d,%d — record said %d,%d,%d; believing the loader",
                    beaconPos.x, beaconPos.y, beaconPos.z, rec.x, rec.y, rec.z))
                base.sendProgress(string.format(
                    "loader_record_corrected to %d,%d,%d from %d,%d,%d",
                    beaconPos.x, beaconPos.y, beaconPos.z, rec.x, rec.y, rec.z))
                loader_state.record(beaconPos.x, beaconPos.y, beaconPos.z,
                    rec.sector, rec.radius)
                rec = loader_state.get() or rec
                -- The stand square was derived from the stale record, so it is
                -- stale too. Derive a fresh one from the corrected position.
                stand = nil
            else
                print("[MINER] No loader beacon heard — retrying on the resynced position alone")
            end
        end

        local sx, sy, sz, facing
        if stand then
            sx, sy, sz, facing = stand.x, stand.y, stand.z, stand.facing
        else
            sx, sy, sz, facing = approachFor(rec, base.getPos())
        end

        -- move.to is vertical-first. Climbing while still in the loader's OWN
        -- x/z column would run straight into it from below: turtle_base sees a
        -- turtle block, refuses to dig it, and waits out its 2-minute blocked
        -- deadline. Stepping to the approach column at the current altitude
        -- first avoids the loader entirely. Only done when we are actually in
        -- its column, so the normal end-of-sector retrieval still ascends
        -- before travelling.
        -- Drop the LEASE before climbing, keeping the chunk anchor.
        --
        -- The loader stands at travel altitude and the lease ceiling is 160, so
        -- an armed lease fails this ascent at y=161: approach_failed, and the
        -- miner cannot reach its own loader. mine_flow.retrieveLoader does clear
        -- the fence, but only AFTER the dig -- which is on the far side of this
        -- climb, so it cannot help here.
        --
        -- The chunk anchor deliberately survives: it is what keeps us inside
        -- loaded chunks for the climb, and retrieveLoader drops it at the right
        -- moment. Releasing both here would ascend unfenced.
        mine_flow.releaseLeaseForAscent()

        local here = base.getPos()
        if here.x == rec.x and here.z == rec.z and here.y ~= sy then
            base.move.to(sx, here.y, sz)
        end

        local ok, err = base.move.to(sx, sy, sz)
        if not ok then return false, "approach_failed: " .. tostring(err) end
        base.move.face(facing)

        -- Make room AGAIN, now that we have actually arrived.
        --
        -- The dump at the top of this function happens before the approach, and
        -- the approach refills the inventory: base.move.to digs through any
        -- static obstruction and CC collects what it breaks. Climbing ~200
        -- blocks from mining depth to a loader at y=200 is easily enough stone
        -- to consume every slot that dump just freed.
        --
        -- Observed in-world: node_139 lost a loader to loader_lost_after_dig on
        -- 1.9.30, which already carried the pre-approach dump. turtle.dig() with
        -- no room returns TRUE and destroys the drop, so the loader turtle was
        -- gone -- not standing, not recoverable.
        --
        -- Room has to be guaranteed at the instant of the dig, not before the
        -- journey to it. This is the check that actually protects the loader;
        -- the earlier one just avoids travelling with a full load.
        dumpIfInventoryTight("loader dig")

        local got, reason = mine_flow.retrieveLoader()
        -- retrieveLoader ends in equipment.retrievalSwapOut on both its success
        -- and most of its failure paths, which moves the modem to the other
        -- side.
        base.recoverModem()
        if got then
            if attempt > 1 then
                print(string.format("[MINER] Loader recovered on attempt %d.", attempt))
            end
            return true
        end

        lastReason = reason
        -- Only a position mismatch is worth another go. Everything else --
        -- chunky missing, nothing in front, the dig failing -- is a different
        -- problem that a fresh position cannot solve, and retrying would just
        -- burn fuel and time before failing the same way.
        if not (reason and tostring(reason):match("^loader_position_mismatch")) then
            return false, reason
        end
        print(string.format("[MINER] Attempt %d/%d: %s",
            attempt, RETRIEVE_ATTEMPTS, tostring(reason)))
    end

    return false, lastReason
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
-- Returns true when a recorded loader placement was provably stale and has been
-- cleared. Used both at boot and at the pre-departure guard, so a turtle handed
-- a replacement loader recovers without needing a reboot to notice.
local function clearStaleLoaderRecord()
    if not loader_state.hasPlaced() then return false end
    local s = loader_state.get()

    -- Possession settles the record before anything else is attempted.
    --
    -- Invariant D says the record is "cleared only after confirmed retrieval",
    -- and a loader turtle sitting in this turtle's inventory IS that
    -- confirmation: the same physical object cannot be carried and standing in
    -- the world at once. That makes this positive evidence, not the
    -- beacon-silence INFERENCE that D rules out -- and the distinction is real,
    -- because a loader placed by turtle.place() is powered off and beacons
    -- nothing at all. Silence proves nothing; possession proves it.
    --
    -- The case this gets wrong is an operator supplying a REPLACEMENT loader
    -- while the original is still standing somewhere. That is no worse than the
    -- remedy it replaces -- deleting loader_state.dat by hand, which an operator
    -- does in exactly those circumstances -- and unlike the manual delete it
    -- leaves the coordinates in the log and reports them to the server, so the
    -- dashboard's orphan check can still flag a loader that really is out there.
    --
    -- Searches the whole inventory rather than slot 2 alone: a loader displaced
    -- into a mining slot is still a loader we are carrying, and the operator's
    -- intent when they drop one in is unambiguous either way.
    -- Possession is only proof if we can tell WHAT we possess.
    --
    -- The reasoning below is still right -- the same physical object cannot be
    -- carried and standing at once -- but its premise broke: every advanced
    -- turtle in the fleet is computercraft:turtle_advanced, so "a loader turtle
    -- in our inventory" was really "an advanced turtle in our inventory", and a
    -- mined-up miner satisfied it. Clearing on that evidence abandons a loader
    -- that really is out there.
    --
    -- With a label configured, findLoaderSlot answers the real question and the
    -- original convenience stands. Without one, refuse and say so: the operator
    -- remedy is then the documented loader_state.dat delete, which is explicit
    -- about what it is asserting. Fails toward keeping a record we might not
    -- need, never toward forgetting a loader that is standing in the world.
    local carried = equipment.findLoaderSlot()
    if carried and equipment.LOADER_LABEL == nil then
        reportForeignTurtle(carried, turtle.getItemDetail(carried))
        print("[MINER] Carrying an advanced turtle but loaders are unlabelled — "
            .. "cannot prove it is ours, keeping the record at "
            .. string.format("%d,%d,%d", s.x, s.y, s.z))
        base.sendProgress(string.format(
            "loader_record_kept at %d,%d,%d (carried turtle in slot %d is not "
            .. "provably a loader; set equipment.LOADER_LABEL or delete "
            .. "loader_state.dat)", s.x, s.y, s.z, carried))
        return false
    end
    if carried then
        print(string.format(
            "[MINER] Loader recorded at %d,%d,%d, but one is carried in slot %d — "
            .. "record is stale, clearing.", s.x, s.y, s.z, carried))
        base.sendProgress(string.format(
            "stale_loader_record_cleared at %d,%d,%d (loader carried in slot %d)",
            s.x, s.y, s.z, carried))
        loader_state.clear()
        return true
    end
    return false
end

local function recoverPlacedLoader()
    if clearStaleLoaderRecord() then return end
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
    --
    -- Report each leg explicitly. Position reaches the dashboard on heartbeats,
    -- heartbeats are sent only by the control loop, and the control loop does
    -- not start until base.run() -- which is AFTER this entire recovery. So for
    -- the whole retrieval and flight the dashboard holds whatever position the
    -- turtle last reported, and an operator cannot tell a turtle flying home
    -- from one that has died in the field. Observed live: four miners appeared
    -- frozen at their loader coordinates for several minutes and only jumped to
    -- the dock on arrival.
    --
    -- base.sendProgress is the only public call that carries base.getPos(), so
    -- the legs report through it. Coarse -- three fixes for the trip rather than
    -- one every five seconds -- but it distinguishes moving from stopped, which
    -- is the question actually being asked. A no-op if the retrieval left comms
    -- down; that case is reported as loader_recovered_comms_down above.
    local function legReport(what)
        base.sendProgress("boot recovery: " .. what)
    end

    local p = base.getPos()
    base.setSkyReturn(true)
    legReport("ascending to the sky lane")
    base.move.to(p.x, SKY_Y, p.z)
    legReport("flying to arrivals")
    base.move.to(W.ARRIVALS_HOLE.x, SKY_Y, W.ARRIVALS_HOLE.z)
    legReport("descending to dock")
    local docked, dockErr = base.returnToDockFromSky()
    base.setSkyReturn(false)
    base.setAutonomousReturn(false)

    local restored, why3 = restoreTravelMode()
    if not restored then
        print("[MINER] WARNING: could not restore travel mode: " .. tostring(why3))
    end

    -- Hand the turtle back as dispatchable. base.returnToDockFromSky() above
    -- sets STATUS.RETURNING, and the ONLY things that reset it to IDLE are
    -- sendComplete and sendFailed -- both of which report the outcome of a JOB.
    -- Boot recovery is not a job, so neither is ever called, and without this
    -- line the turtle finishes recovery parked at its dock, fully healthy, in a
    -- state registry.getIdle() rejects. It can then never be dispatched again.
    --
    -- Observed live: all four miners recovered their loaders after a server
    -- restart, flew home correctly, and then sat at the dock showing RETURNING
    -- while their four jobs stayed PENDING behind "idle=0 fuel>=500". The
    -- recovery worked perfectly and the fleet was still deadlocked.
    --
    -- ONLY when the dock was actually reached, though. returnToDockFromSky sets
    -- STATUS.ERROR and returns false when the descent or the return route fails
    -- -- which is what happens to the LAST miner home when the others are still
    -- queued at the single-block arrivals hole. Forcing IDLE unconditionally
    -- overwrote that ERROR and reported DOCKED, so a turtle stranded above the
    -- arrivals hole announced itself parked at its bay and was dispatched again
    -- from the wrong place. That was this line's fault, added in 1.9.22.
    --
    -- On failure the ERROR status is left standing: a miner sitting in the
    -- arrivals chokepoint must be visible and must NOT be handed more work,
    -- because flying it out from there is how the hole stays blocked.
    if docked == false then
        print("[MINER] Boot recovery did NOT reach the dock: " .. tostring(dockErr))
        base.sendProgress("dock_not_reached: " .. tostring(dockErr))
        return
    end
    tidyAtDock()
    base.setStatus(proto.STATUS.IDLE)
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
        local docked, dockErr = base.returnToDockFromSky()
        base.setSkyReturn(false)

        local restored, why2 = restoreTravelMode()
        if not restored then
            print("[MINER] WARNING: could not restore travel mode: " .. tostring(why2))
            base.sendProgress("travel_mode_not_restored: " .. tostring(why2))
        end

        -- Do not claim DOCKED when the dock was not reached. The failure is
        -- reachable and routine: the last miner home finds the single-block
        -- arrivals hole still occupied by the others, the return route fails,
        -- and returnToDockFromSky sets STATUS.ERROR. Reporting DOCKED over that
        -- told the dashboard a stranded turtle was parked at its bay.
        --
        -- sendComplete/sendFailed will follow this and set IDLE either way --
        -- this job really is over -- but the operator gets told where the turtle
        -- actually is rather than where it was supposed to end up.
        if docked == false then
            print("[MINER] Did NOT reach the dock: " .. tostring(dockErr))
            base.sendProgress("dock_not_reached: " .. tostring(dockErr))
            return
        end
        tidyAtDock()
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
    -- A loader we are demonstrably carrying cannot also be standing out there.
    -- Checked here as well as at boot so an operator who drops a replacement
    -- into a docked miner does not additionally have to reboot it.
    clearStaleLoaderRecord()
    if loader_state.hasPlaced() then
        local s = loader_state.get()
        local detail = string.format("loader_outstanding at %d,%d,%d", s.x, s.y, s.z)
        print("[MINER] Refusing job — " .. detail)
        base.sendProgress(detail .. " — put a loader turtle in slot "
            .. S_LOADER .. " and it will clear itself, or delete loader_state.dat")
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
    -- A confirmed position, before anything moves. Without a GPS fix the turtle
    -- navigates from (0,0,0) and flies the wrong delta across the world -- see
    -- the boot-time wait for what that cost in the field. Re-checked here rather
    -- than trusting the boot result, because the hosts can go down again while
    -- the miner sits idle at its dock.
    if not base.gpsSync() then
        local detail = "no_gps_fix: cannot confirm position, refusing to depart"
        print("[MINER] Refusing job — " .. detail)
        base.sendProgress(detail)
        base.sendFailed(detail, true)   -- recoverable: retry when the hosts return
        _jobId = nil
        return
    end

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
        -- Additive (P6): nil from a server that predates leases, and every use
        -- below tolerates that by doing nothing.
        local lease      = msg.payload.lease
        local orphanSaid = false   -- report an orphan once per sector, not per level
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
            -- Arm the lease HERE, not in placeLoader.
            --
            -- The loader goes down from travel altitude (175 or 200) and the
            -- ceiling is 160, so arming at placement would fail every direction
            -- at once and strand the miner on the placement square with its
            -- loader already deployed. By this point we have descended to a
            -- scan level, which is far below the ceiling.
            --
            -- Called every level rather than once: armLease is idempotent, and
            -- a single call site that always runs beats one that has to be
            -- reasoned about. It refuses on its own if we are somehow high.
            if lease then
                local armed, why = mine_flow.armLease(lease)
                if not armed and why ~= "already_armed" then
                    base.sendProgress("lease_not_armed: " .. tostring(why))
                end
            end

            -- An orphan loader standing in our leased sector (§4.2). Reported,
            -- never collected: recovery is a different job from mining, and a
            -- miner already carrying its own loader cannot tell two of them
            -- apart while loaders are unlabelled. The dig guard means movement
            -- refuses to dig it anyway, so "work around it" needs no code --
            -- only somebody being told it is there, which is the part that has
            -- been missing every time this has happened.
            if not orphanSaid then
                local orphan = mine_flow.orphanLoaderInLease()
                if orphan then
                    orphanSaid = true
                    local at = string.format("orphan_loader at %d,%d,%d",
                        orphan.x, orphan.y, orphan.z)
                    print("[MINER] " .. at .. " — working around it")
                    base.sendProgress(at)
                end
            end
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

-- Wait for the GPS constellation before doing ANYTHING that moves.
--
-- turtle_base's initPosition falls back to "Tracking from (0,0,0)" when
-- gps.locate() returns nothing, and then lets the turtle navigate anyway. Every
-- movement after that is computed in a false frame: flying home means flying the
-- delta from the ORIGIN to the arrivals hole, from wherever the turtle actually
-- is.
--
-- That is not theoretical. After a server shutdown on 2026-08-21, two of four
-- miners ended up 1,200 and 1,900 blocks from the depot, at FLOOR_Y, reporting
-- DOCKED, with their loaders abandoned untouched at the recorded positions. The
-- axis-by-axis distances match an origin-frame flight almost exactly. A
-- 1,900-block error cannot accumulate a block at a time -- it is a frame error,
-- not drift.
--
-- The cause is timing, so the fix is to wait rather than to invent a position:
-- on a server restart everything boots at once and a turtle can query GPS before
-- the host computers are up and triangulating. Retrying for a couple of minutes
-- costs a stalled job; flying blind costs a lost turtle, an abandoned loader and
-- a permanently force-loaded chunk.
local GPS_WAIT_ATTEMPTS = 6
local GPS_RETRY_SECONDS = 20
local _haveGpsFix = false
for attempt = 1, GPS_WAIT_ATTEMPTS do
    if base.gpsSync() then
        _haveGpsFix = true
        break
    end
    print(string.format(
        "[MINER] No GPS fix (attempt %d/%d) — GPS hosts may still be booting. Retrying in %ds.",
        attempt, GPS_WAIT_ATTEMPTS, GPS_RETRY_SECONDS))
    if attempt < GPS_WAIT_ATTEMPTS then sleep(GPS_RETRY_SECONDS) end
end

if not _haveGpsFix then
    -- Stay put. A miner that cannot place itself must not fly, must not try to
    -- retrieve a loader, and must not accept a job -- the pre-departure preflight
    -- refuses too. It still boots and registers, so it is visible and reachable
    -- rather than silently absent.
    print("[MINER] NO GPS FIX after " .. (GPS_WAIT_ATTEMPTS * GPS_RETRY_SECONDS)
        .. "s — refusing to move. Check the GPS host computers.")
    base.sendProgress("no_gps_fix: refusing to move until the GPS hosts are up")
else
    -- Recover an abandoned loader before any job can be accepted.
    local rok, rerr = pcall(recoverPlacedLoader)
    if not rok then
        print("[MINER] Loader recovery crashed: " .. tostring(rerr))
    end
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
