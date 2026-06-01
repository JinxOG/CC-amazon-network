-- turtle_base.lua
-- Shared foundation for all turtle roles.
-- Handles: registration, dock assignment, heartbeat, movement, fuel, routing.

local proto = require("protocol")
local W     = require("waypoints")

local base = {}

-- ─── Config ──────────────────────────────────────────────────────────────────

local CFG = {
    HEARTBEAT_INTERVAL  = 10,
    FUEL_CRITICAL       = 200,
    MOVE_RETRIES        = 3,
    REGISTER_RETRIES    = 10,
    REGISTER_TIMEOUT    = 5,
    GPS_TIMEOUT         = 3,
    GPS_RESYNC_INTERVAL = 50,   -- re-sync GPS every N moves
}

-- ─── Internal State ──────────────────────────────────────────────────────────

local _self = {
    id        = nil,
    role      = nil,
    dock      = nil,    -- assigned dock from waypoints
    partnerId = nil,
    status    = proto.STATUS.IDLE,
    jobId     = nil,
    modem     = nil,
    pos       = { x = 0, y = 0, z = 0 },
    facing    = 0,      -- 0=north(-z) 1=east(+x) 2=south(+z) 3=west(-x)
    moveCount = 0,
    busy      = false,
    canDig    = true,   -- false for turtles without a pickaxe (e.g. support)
}

-- ─── Logging ─────────────────────────────────────────────────────────────────

local function log(level, msg)
    print(string.format("[%s][%s] %s", _self.id or "?", level, msg))
end
local function logInfo(m)  log("INFO",  m) end
local function logWarn(m)  log("WARN",  m) end
local function logError(m) log("ERROR", m) end

-- ─── Public Accessors ────────────────────────────────────────────────────────

function base.getSelfId()      return _self.id        end
function base.getModem()       return _self.modem     end
function base.getPos()         return { x=_self.pos.x, y=_self.pos.y, z=_self.pos.z } end
function base.getDock()        return _self.dock      end
function base.getPartnerId()   return _self.partnerId end
function base.setPartnerId(id) _self.partnerId = id   end
function base.setCanDig(val)   _self.canDig = val     end

-- ─── Comms ───────────────────────────────────────────────────────────────────

local comms = {}

function comms.init()
    _self.modem = peripheral.find("modem")
    if not _self.modem then
        error("No modem found. Attach a wireless or ender modem.")
    end
    proto.openChannels(_self.modem, { proto.CH_BROADCAST, proto.CH_PRIVATE, proto.CH_LOCAL })
    logInfo("Modem ready.")
end

function comms.toServer(msgType, payload)
    local msg = proto.encode(msgType, _self.id, "server", payload)
    proto.send(_self.modem, proto.CH_SERVER, msg)
end

-- ─── Position ────────────────────────────────────────────────────────────────

local function gpsSync()
    local x, y, z = gps.locate(CFG.GPS_TIMEOUT)
    if x then
        _self.pos = { x=math.floor(x), y=math.floor(y), z=math.floor(z) }
        return true
    end
    return false
end

-- Detect actual facing by moving forward one block and comparing GPS positions.
-- Without this, position tracking is wrong from the very first move.
local function detectFacing()
    local x1, y1, z1 = gps.locate(CFG.GPS_TIMEOUT)
    if not x1 then
        logWarn("Cannot detect facing — no GPS. Assuming north.")
        return
    end

    -- Try to move forward one step to detect direction
    if not turtle.forward() then
        -- Blocked — try turning until we find a free direction
        for _ = 1, 4 do
            turtle.turnRight()
            if turtle.forward() then break end
        end
    end

    local x2, y2, z2 = gps.locate(CFG.GPS_TIMEOUT)
    turtle.back()  -- return to original position

    if not x2 then
        logWarn("GPS lost during facing detection. Assuming north.")
        return
    end

    local dx = math.floor(x2) - math.floor(x1)
    local dz = math.floor(z2) - math.floor(z1)

    if     dz < 0 then _self.facing = 0  -- north (-Z)
    elseif dx > 0 then _self.facing = 1  -- east  (+X)
    elseif dz > 0 then _self.facing = 2  -- south (+Z)
    elseif dx < 0 then _self.facing = 3  -- west  (-X)
    end

    local names = { [0]="north", [1]="east", [2]="south", [3]="west" }
    logInfo("Facing: " .. names[_self.facing])
end

local function initPosition()
    if gpsSync() then
        logInfo(string.format("GPS fix: %d,%d,%d", _self.pos.x, _self.pos.y, _self.pos.z))
        detectFacing()
    else
        logWarn("No GPS fix. Tracking from (0,0,0). Facing assumed north.")
    end
end

local function applyMove(dir)
    if dir == "forward" then
        if     _self.facing == 0 then _self.pos.z = _self.pos.z - 1
        elseif _self.facing == 1 then _self.pos.x = _self.pos.x + 1
        elseif _self.facing == 2 then _self.pos.z = _self.pos.z + 1
        elseif _self.facing == 3 then _self.pos.x = _self.pos.x - 1
        end
    elseif dir == "back" then
        if     _self.facing == 0 then _self.pos.z = _self.pos.z + 1
        elseif _self.facing == 1 then _self.pos.x = _self.pos.x - 1
        elseif _self.facing == 2 then _self.pos.z = _self.pos.z - 1
        elseif _self.facing == 3 then _self.pos.x = _self.pos.x + 1
        end
    elseif dir == "up"   then _self.pos.y = _self.pos.y + 1
    elseif dir == "down" then _self.pos.y = _self.pos.y - 1
    end

    -- Periodic GPS re-sync to correct drift on long journeys
    _self.moveCount = _self.moveCount + 1
    if _self.moveCount % CFG.GPS_RESYNC_INTERVAL == 0 then
        gpsSync()
    end
end

-- ─── Movement ────────────────────────────────────────────────────────────────

local move = {}

local function tryMove(moveFn, digFn, dir)
    for _ = 1, CFG.MOVE_RETRIES do
        if moveFn() then applyMove(dir); return true end
        if digFn then digFn() end
        sleep(0.3)
    end
    return false, "blocked (" .. dir .. ")"
end

function move.forward() return tryMove(turtle.forward, turtle.dig,     "forward") end
function move.back()    return tryMove(turtle.back,    nil,             "back")    end
function move.up()      return tryMove(turtle.up,      turtle.digUp,   "up")      end
function move.down()    return tryMove(turtle.down,    turtle.digDown, "down")    end

function move.turnLeft()
    turtle.turnLeft()
    _self.facing = (_self.facing - 1) % 4
end

function move.turnRight()
    turtle.turnRight()
    _self.facing = (_self.facing + 1) % 4
end

function move.face(dir)
    dir = dir % 4
    local diff = (dir - _self.facing) % 4
    if     diff == 1 then move.turnRight()
    elseif diff == 2 then move.turnRight(); move.turnRight()
    elseif diff == 3 then move.turnLeft()
    end
end

-- Navigate to absolute world coordinate.
function move.to(tx, ty, tz)
    -- Vertical first
    while _self.pos.y < ty do
        local ok, err = move.up()
        if not ok then return false, "stuck up: " .. (err or "?") end
    end
    while _self.pos.y > ty do
        local ok, err = move.down()
        if not ok then return false, "stuck down: " .. (err or "?") end
    end
    -- X axis
    if _self.pos.x < tx then move.face(1) end
    if _self.pos.x > tx then move.face(3) end
    while _self.pos.x ~= tx do
        local ok, err = move.forward()
        if not ok then return false, "stuck X: " .. (err or "?") end
    end
    -- Z axis
    if _self.pos.z < tz then move.face(2) end
    if _self.pos.z > tz then move.face(0) end
    while _self.pos.z ~= tz do
        local ok, err = move.forward()
        if not ok then return false, "stuck Z: " .. (err or "?") end
    end
    return true
end

-- Follow an ordered list of {x,y,z} waypoints.
function move.followRoute(waypoints)
    for _, wp in ipairs(waypoints) do
        local ok, err = move.to(wp.x, wp.y, wp.z)
        if not ok then return false, err end
    end
    return true
end

base.move = move

-- ─── Depot Routing ───────────────────────────────────────────────────────────

-- Navigate from current position (dock) to the world via the dispatch hole.
-- Call this at the start of every job before heading to destination.
function base.depart()
    if not _self.dock then logWarn("No dock assigned, departing from current pos.") return true end

    logInfo("Departing via dispatch lane...")
    base.setStatus(proto.STATUS.TRAVELLING)

    -- Follow white taxiway route to the hole
    local route = W.departureRoute(_self.dock)
    local ok, err = move.followRoute(route)
    if not ok then return false, "departure route failed: " .. (err or "?") end

    -- Only delivery turtles signal their support partner at the hole.
    -- Support turtles must NOT send this signal back or they stall each other.
    if _self.partnerId and _self.role == proto.ROLE.DELIVERY then
        logInfo("Signalling support turtle to depart...")
        local sig = proto.encode(proto.MSG.HOLE_READY, _self.id, _self.partnerId, {})
        proto.send(_self.modem, proto.CH_LOCAL, sig)

        -- Wait up to 20s for support to arrive near the hole
        logInfo("Waiting for support turtle at hole...")
        local deadline = os.clock() + 20
        while os.clock() < deadline do
            local info = base.queryTurtle(_self.partnerId, 3)
            if info and info.position then
                local dx = math.abs(info.position.x - _self.pos.x)
                local dz = math.abs(info.position.z - _self.pos.z)
                if dx + dz <= 6 then
                    logInfo("Support turtle nearby — descending.")
                    break
                end
            end
            sleep(2)
        end
    end

    -- Descend through dispatch hole
    logInfo("Descending dispatch hole...")
    for _ = 1, 10 do
        move.down()
        if _self.pos.y <= W.WORLD_EXIT.y then break end
    end

    logInfo(string.format("Exited depot at %d,%d,%d", _self.pos.x, _self.pos.y, _self.pos.z))
    return true
end

-- Navigate from the world back to dock via arrivals hole.
-- Call this when turtle is outside/underground after completing a job.
-- Always goes underground first then up through the arrivals hole.
function base.returnToDock()
    if not _self.dock then logWarn("No dock assigned, staying put.") return true end

    base.setStatus(proto.STATUS.RETURNING)

    local FLOOR_Y       = 67
    local UNDERGROUND_Y = W.WORLD_ENTRY.y  -- 60

    -- If turtle is at surface level outside, descend to underground travel Y first
    if _self.pos.y >= FLOOR_Y then
        logInfo("Descending to underground travel level...")
        local ok, err = move.to(_self.pos.x, UNDERGROUND_Y, _self.pos.z)
        if not ok then
            logWarn("Could not descend fully: " .. (err or "?"))
        end
    end

    -- Navigate underground to arrivals hole X,Z
    logInfo("Navigating underground to arrivals hole...")
    local ok, err = move.to(W.ARRIVALS_HOLE.x, UNDERGROUND_Y, W.ARRIVALS_HOLE.z)
    if not ok then return false, "could not reach arrivals hole: " .. (err or "?") end

    -- Ascend through arrivals hole into building
    logInfo("Ascending arrivals hole...")
    for _ = 1, 10 do
        move.up()
        if _self.pos.y >= FLOOR_Y then break end
    end

    -- Follow red taxiway back to dock
    local route = W.returnRoute(_self.dock)
    ok, err = move.followRoute(route)
    if not ok then return false, "return route failed: " .. (err or "?") end

    logInfo("Docked at bay " .. _self.dock.bay .. " row " .. _self.dock.row)

    -- Support turtles top up fuel at dock station
    if not _self.canDig then
        fuel.dockRefuel()
    end

    return true
end

-- Navigate from dock back to dock after a RECALL while inside building.
-- Uses internal red taxiway only — no underground needed.
function base.returnToDockInternal()
    if not _self.dock then return true end
    base.setStatus(proto.STATUS.RETURNING)
    logInfo("Returning to dock via internal taxiway...")
    local route = W.returnRoute(_self.dock)
    local ok, err = move.followRoute(route)
    if not ok then return false, "internal return failed: " .. (err or "?") end
    logInfo("Docked at bay " .. _self.dock.bay .. " row " .. _self.dock.row)
    if not _self.canDig then fuel.dockRefuel() end
    return true
end

-- ─── Fuel ────────────────────────────────────────────────────────────────────
-- Turtles carry an entangled chest in slot 16 (reserved).
-- When fuel is critical: place chest → suck out all coal → refuel → break chest → pocket it.

local CHEST_SLOT = 16
-- !! Set this to the exact item ID of your entangled chest mod !!
-- Common: "entangled:entangled_tile"  "enderstorage:ender_chest"
local CHEST_ITEM = "enderstorage:ender_chest"

local fuel = {}

function fuel.level()      return turtle.getFuelLevel() end
function fuel.max()        return turtle.getFuelLimit()  end
function fuel.isCritical() return fuel.level() < CFG.FUEL_CRITICAL end

-- Find or make a free adjacent side for placing the chest.
-- Preference: down → up → front.
-- If all blocked, digs a hole rather than giving up.
-- Returns placeFn, digFn, suckFn, cleanupFn
-- cleanupFn fills the dug hole back in after (nil if nothing was dug)
local function findFreeSpace()
    -- Check existing free spaces first (no digging needed)
    if not turtle.detectDown() then
        return turtle.placeDown, turtle.digDown, turtle.suckDown, nil
    elseif not turtle.detectUp() then
        return turtle.placeUp, turtle.digUp, turtle.suckUp, nil
    elseif not turtle.detect() then
        return turtle.place, turtle.dig, turtle.suck, nil
    end

    -- All sides blocked
    if not _self.canDig then
        -- No pickaxe (support turtle) — can't dig, report and give up
        logWarn("Surrounded and no pickaxe — cannot deploy chest. Waiting for clear space...")
        return nil
    end

    -- Has pickaxe — dig a temporary hole
    logWarn("Surrounded — digging temporary refuel hole...")
    if turtle.digDown() then
        return turtle.placeDown, turtle.digDown, turtle.suckDown, nil
    end
    if turtle.digUp() then
        return turtle.placeUp, turtle.digUp, turtle.suckUp, nil
    end
    if turtle.dig() then
        return turtle.place, turtle.dig, turtle.suck, nil
    end

    -- Completely surrounded by unbreakable blocks
    return nil
end

-- Quick scan of inventory slots 1-15 for any loose burnable items (used on boot).
-- Skips if already at max fuel to avoid wasting coal from previous runs.
function fuel.refuel()
    if fuel.level() >= fuel.max() then return end
    local before = fuel.level()
    for slot = 1, 15 do
        if turtle.getItemCount(slot) > 0 then
            turtle.select(slot)
            turtle.refuel()
        end
        if fuel.level() >= fuel.max() then break end
    end
    turtle.select(1)
    local gained = fuel.level() - before
    if gained > 0 then
        logInfo(string.format("Refuelled +%d (now %d)", gained, fuel.level()))
    end
end

-- Deploy the entangled chest, drain all coal, break it, pocket it.
function fuel.refuelFromChest()
    local chestData = turtle.getItemDetail(CHEST_SLOT)
    if not chestData then
        logWarn("Slot " .. CHEST_SLOT .. " has no entangled chest!")
        return false
    end

    local placeFn, digFn, suckFn = findFreeSpace()
    if not placeFn then
        logError("Completely surrounded by unbreakable blocks — cannot deploy chest!")
        return false
    end

    -- Place chest
    turtle.select(CHEST_SLOT)
    if not placeFn() then
        logWarn("Failed to place entangled chest.")
        return false
    end
    sleep(0.5)  -- wait for peripheral/block to register

    -- Suck all coal into inventory (slots 1-15, skip reserved slot 16)
    local pulled = 0
    for _ = 1, 16 do
        if suckFn(64) then
            pulled = pulled + 1
        else
            break
        end
    end

    if pulled == 0 then
        logWarn("Entangled chest is empty — no coal available!")
    end

    -- Refuel from slots 1-15 only
    local before = fuel.level()
    for slot = 1, 15 do
        if turtle.getItemCount(slot) > 0 then
            turtle.select(slot)
            turtle.refuel()
        end
    end
    local gained = fuel.level() - before
    logInfo(string.format("Refuelled +%d (now %d/%d)", gained, fuel.level(), fuel.max()))

    -- Break chest — drops as item, turtle auto-collects
    digFn()
    sleep(0.3)

    -- Coal may have landed in slot 16 while chest was placed — move it out first
    local s16 = turtle.getItemDetail(CHEST_SLOT)
    if s16 and s16.name ~= CHEST_ITEM then
        turtle.select(CHEST_SLOT)
        for s = 1, 15 do
            if turtle.getItemCount(s) == 0 then
                turtle.transferTo(s)
                break
            end
        end
    end

    -- Find chest in ANY slot (1-16) and move to reserved slot 16
    for slot = 1, 16 do
        local item = turtle.getItemDetail(slot)
        if item and item.name == CHEST_ITEM then
            if slot ~= CHEST_SLOT then
                turtle.select(slot)
                turtle.transferTo(CHEST_SLOT)
            end
            break
        end
    end
    turtle.select(1)

    return gained > 0
end

-- Refuel from a chest placed below/above/front at the dock station.
-- Called on boot and after returning to dock.
-- Fills up as much as possible then stops.
-- Skips entirely if fuel is already above 80% to avoid burning existing coal.
function fuel.dockRefuel()
    local pct = fuel.level() / math.max(fuel.max(), 1)
    if pct >= 0.8 then
        logInfo(string.format("Fuel already at %d%% — skipping dock refuel.", math.floor(pct*100)))
        return true
    end
    logInfo("Refuelling at dock station...")
    local gained = 0

    -- Suck coal from dock chest (below by default, then try other sides)
    local suckFns = { turtle.suckDown, turtle.suckUp, turtle.suck }
    for _, suckFn in ipairs(suckFns) do
        for _ = 1, 16 do
            if not suckFn(64) then break end
        end
    end

    -- Burn everything in slots 1-15
    local before = fuel.level()
    for slot = 1, 15 do
        if turtle.getItemCount(slot) > 0 then
            turtle.select(slot)
            turtle.refuel()
        end
    end
    turtle.select(1)
    gained = fuel.level() - before

    if gained > 0 then
        logInfo(string.format("Dock refuel +%d (now %d/%d)", gained, fuel.level(), fuel.max()))
    else
        logWarn("Dock refuel: no coal found in station — check chest below dock!")
    end
    return gained > 0
end

function fuel.ensureFuel()
    while fuel.isCritical() do
        logWarn(string.format("Fuel critical (%d) — deploying entangled chest...", fuel.level()))
        -- Send heartbeat so server doesn't mark us offline during refuel
        if _self.id then
            comms.toServer(proto.MSG.HEARTBEAT, proto.payloadHeartbeat(
                proto.STATUS.ERROR, fuel.level(), base.getPos(), _self.jobId))
        end
        local ok = fuel.refuelFromChest()
        if not ok or fuel.isCritical() then
            comms.toServer(proto.MSG.STATUS_UPDATE, proto.payloadStatusUpdate(
                _self.jobId, proto.STATUS.ERROR, "fuel_critical_no_coal", base.getPos()))
            -- Wait but keep sending heartbeats every 5 seconds
            for _ = 1, 6 do
                if _self.id then
                    comms.toServer(proto.MSG.HEARTBEAT, proto.payloadHeartbeat(
                        proto.STATUS.ERROR, fuel.level(), base.getPos(), _self.jobId))
                end
                sleep(5)
                if not fuel.isCritical() then break end
            end
        end
    end
end

base.fuel = fuel

-- ─── Registration ────────────────────────────────────────────────────────────

local function register()
    -- Small delay so ender modem has time to connect after boot
    sleep(2)

    local attempt = 0
    while true do
        attempt = attempt + 1
        logInfo(string.format("Registering (attempt %d)...", attempt))
        comms.toServer(proto.MSG.REGISTER, proto.payloadRegister(
            _self.role, fuel.level(), fuel.max(), base.getPos()))

        local reply = proto.receive(_self.id, CFG.REGISTER_TIMEOUT)
        if reply and reply.type == proto.MSG.REGISTER_ACK and reply.payload.ok then
            -- Server sends assigned dock in the ACK
            if reply.payload.dock then
                _self.dock = reply.payload.dock
                logInfo(string.format("Assigned dock: bay %d row %s (%d,%d,%d)",
                    _self.dock.bay, _self.dock.row,
                    _self.dock.x, _self.dock.y, _self.dock.z))
            end
            logInfo("Registered successfully.")
            return
        end

        -- Not connected yet — wait and retry automatically (no reboot needed)
        logWarn("No response from server. Retrying in 5s... (is the server running?)")
        sleep(5)
    end
end

-- ─── Heartbeat ───────────────────────────────────────────────────────────────

local _missedHeartbeats = 0
local MAX_MISSED = 3  -- re-register after this many missed ACKs

local function sendHeartbeat()
    comms.toServer(proto.MSG.HEARTBEAT, proto.payloadHeartbeat(
        _self.status, fuel.level(), base.getPos(), _self.jobId))
    _missedHeartbeats = _missedHeartbeats + 1

    -- If too many heartbeats go unacknowledged, server may have restarted
    -- Re-register to get back on the active list
    if _missedHeartbeats >= MAX_MISSED then
        logWarn("Server may be down or restarted — re-registering...")
        _missedHeartbeats = 0
        local ok = pcall(register)
        if not ok then
            logWarn("Re-registration failed, will retry next heartbeat.")
        end
    end
end

-- Called when server responds to confirm it's alive (on any valid message back)
local function resetMissedHeartbeats()
    _missedHeartbeats = 0
end

-- ─── Job Helpers ─────────────────────────────────────────────────────────────

function base.setStatus(status, jobId)
    _self.status = status
    if jobId ~= nil then _self.jobId = jobId end
end

function base.sendProgress(detail)
    comms.toServer(proto.MSG.STATUS_UPDATE, proto.payloadStatusUpdate(
        _self.jobId, _self.status, detail, base.getPos()))
end

function base.sendComplete(result)
    comms.toServer(proto.MSG.JOB_COMPLETE, proto.payloadJobComplete(_self.jobId, result))
    _self.status    = proto.STATUS.IDLE
    _self.jobId     = nil
    _self.partnerId = nil
    _self.busy      = false
end

function base.sendFailed(reason, recoverable)
    comms.toServer(proto.MSG.JOB_FAILED, proto.payloadJobFailed(_self.jobId, reason, recoverable))
    _self.status    = proto.STATUS.IDLE
    _self.jobId     = nil
    _self.partnerId = nil
    _self.busy      = false
end

function base.requestItems(items, pickupPoint, timeout)
    comms.toServer(proto.MSG.ITEM_REQUEST, proto.payloadItemRequest(
        _self.jobId, items, pickupPoint or base.getPos()))
    logInfo("Waiting for warehouse...")
    local reply = proto.receive(_self.id, timeout or 60)
    if reply and reply.type == proto.MSG.ITEM_READY then
        logInfo("Items loaded.")
        return reply.payload.loaded
    end
    logWarn("Item request timed out.")
    return nil
end

function base.queryTurtle(targetId, timeout)
    comms.toServer(proto.MSG.TURTLE_QUERY, proto.payloadTurtleQuery(targetId))
    local reply = proto.receive(_self.id, timeout or 5)
    if reply and reply.type == proto.MSG.TURTLE_INFO then
        return reply.payload
    end
    return nil
end

-- ─── Init ────────────────────────────────────────────────────────────────────

function base.init(role)
    _self.id   = proto.selfId()
    _self.role = role
    print("=== " .. _self.id .. " [" .. role .. "] booting ===")
    comms.init()
    initPosition()
    fuel.refuel()
    register()
    logInfo(string.format("Ready. Fuel:%d/%d  Pos:%d,%d,%d  Dock:%s",
        fuel.level(), fuel.max(),
        _self.pos.x, _self.pos.y, _self.pos.z,
        _self.dock and ("bay ".. _self.dock.bay .." row ".. _self.dock.row) or "none"))
end

-- ─── Main Event Loop ─────────────────────────────────────────────────────────
-- Uses parallel to run the job handler and the control loop concurrently.
-- This ensures the job coroutine receives events it's waiting for (e.g. ITEM_READY)
-- while the control loop still handles heartbeats and RECALL.

function base.run(jobHandler)
    local heartbeatTimer = os.startTimer(CFG.HEARTBEAT_INTERVAL)
    local pendingJob     = nil   -- job table waiting to be started
    local jobCo          = nil   -- running job coroutine

    -- Control loop: handles heartbeat, RECALL, and JOB_ASSIGN
    local function controlLoop()
        while true do
            if fuel.isCritical() then fuel.ensureFuel() end

            local event, p1, p2, p3, p4 = os.pullEvent()

            if event == "modem_message" then
                local parsed = type(p4) == "table" and p4 or textutils.unserialise(p4)
                if parsed then
                    local valid, msg = proto.decode(parsed)
                    if valid and (msg.to == _self.id or msg.to == "broadcast") then

                        resetMissedHeartbeats()

                    if msg.type == proto.MSG.JOB_ASSIGN and not _self.busy then
                            local job = msg.payload
                            comms.toServer(proto.MSG.JOB_ACK,
                                proto.payloadJobAck(job.jobId, true, nil))
                            _self.busy   = true
                            _self.jobId  = job.jobId
                            _self.status = proto.STATUS.TRAVELLING
                            pendingJob   = { id=job.jobId, type=job.jobType, params=job.params }

                        elseif msg.type == proto.MSG.JOB_ASSIGN and _self.busy then
                            comms.toServer(proto.MSG.JOB_ACK,
                                proto.payloadJobAck(msg.payload.jobId, false, "busy"))

                        elseif msg.type == proto.MSG.RECALL then
                            logWarn("RECALL: " .. (msg.payload.reason or "?"))
                            if _self.busy and _self.jobId then
                                base.sendFailed("recalled", true)
                            end
                            if _self.busy or _self.status ~= proto.STATUS.IDLE then
                                -- Inside building = use internal taxiway only
                                -- Outside/underground = go underground then arrivals hole
                                local insideBuilding = _self.pos.y >= 67
                                    and _self.pos.x >= 143 and _self.pos.x <= 228
                                    and _self.pos.z >= -2817 and _self.pos.z <= -2782
                                if insideBuilding then
                                    base.returnToDockInternal()
                                else
                                    base.returnToDock()
                                end
                            else
                                logInfo("Already idle at dock, ignoring recall movement.")
                            end
                            _self.busy  = false
                            pendingJob  = nil
                        end
                    end
                end

            elseif event == "timer" and p1 == heartbeatTimer then
                sendHeartbeat()
                heartbeatTimer = os.startTimer(CFG.HEARTBEAT_INTERVAL)
            end
        end
    end

    -- Job runner: waits for a pending job then executes it
    local function jobRunner()
        while true do
            -- Wait until a job is assigned
            while not pendingJob do
                os.pullEvent()
            end

            local job = pendingJob
            pendingJob = nil

            local ok, err = pcall(jobHandler, job)
            if not ok then
                logError("Job handler crashed: " .. tostring(err))
                base.sendFailed(tostring(err), true)
            end
        end
    end

    -- Run both loops in parallel so events are shared between them
    parallel.waitForAny(controlLoop, jobRunner)
end

return base
