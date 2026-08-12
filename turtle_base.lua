-- turtle_base.lua
-- Shared foundation for all turtle roles.
-- Handles: registration, dock assignment, heartbeat, movement, fuel, routing.

local proto = require("protocol")
local W     = require("waypoints")

local base = {}

-- ─── Config ──────────────────────────────────────────────────────────────────

local CFG = {
    HEARTBEAT_INTERVAL  = 5,
    FUEL_CRITICAL       = 200,
    FUEL_RESERVE        = 500,   -- conservative pre-departure reserve (full warehouse run)
    MOVE_RETRIES        = 3,
    REGISTER_RETRIES    = 10,
    REGISTER_TIMEOUT    = 5,
    GPS_TIMEOUT         = 3,
    GPS_RESYNC_INTERVAL = 50,   -- re-sync GPS every N moves
    FLOOR_Y             = 67,   -- building floor Y; turtles are "inside" at or above this
}

-- x/z bounding box of the depot building (used for "inside the building" checks).
local BUILDING = { minX = 143, maxX = 228, minZ = -2817, maxZ = -2782 }

-- ─── Internal State ──────────────────────────────────────────────────────────

local _self = {
    id         = nil,
    role       = nil,
    dock       = nil,    -- assigned dock from waypoints
    partnerId  = nil,
    status     = proto.STATUS.IDLE,
    jobId      = nil,
    modem      = nil,
    pos        = { x = 0, y = 0, z = 0 },
    facing     = 0,      -- 0=north(-z) 1=east(+x) 2=south(+z) 3=west(-x)
    moveCount  = 0,
    busy       = false,
    canDig      = true,   -- false for turtles without a pickaxe (e.g. support)
    serverDown  = false,  -- true while server is unreachable; pauses movement + freezes deadlines
    recalled    = false,  -- set by RECALL handler; causes waitForAny to exit the job runner
    inSkyReturn = false,  -- true during sky return; bypasses serverDown freeze (path is fixed)
}

-- ─── Logging ─────────────────────────────────────────────────────────────────

local function log(level, msg)
    print(string.format("[%s][%s] %s", _self.id or "?", level, msg))
end
local function logInfo(m)  log("INFO",  m) end
local function logWarn(m)  log("WARN",  m) end
local function logError(m) log("ERROR", m) end

-- ─── Remote Log Queue ────────────────────────────────────────────────────────
-- Captures every print() call (from any module) and batches lines to the
-- server every 15 seconds so turtle activity is visible without local console.
local _logQueue    = {}
local LOG_QUEUE_MAX = 40
do
    local _rawPrint = print
    print = function(...)
        _rawPrint(...)
        local line = table.concat({...}, "\t")
        if #_logQueue >= LOG_QUEUE_MAX then table.remove(_logQueue, 1) end
        table.insert(_logQueue, { ts = os.epoch("utc"), msg = line })
    end
end

-- ─── Public Accessors ────────────────────────────────────────────────────────

function base.getSelfId()        return _self.id         end
function base.getModem()         return _self.modem      end
function base.getPos()           return { x=_self.pos.x, y=_self.pos.y, z=_self.pos.z } end
function base.getDock()          return _self.dock       end
function base.getPartnerId()     return _self.partnerId  end
function base.setPartnerId(id)   _self.partnerId = id    end
function base.setCanDig(val)     _self.canDig = val      end
function base.isServerDown()     return _self.serverDown  end
function base.isRecalled()       return _self.recalled    end
function base.setRecalled(v)     _self.recalled = v       end
function base.setSkyReturn(v)    _self.inSkyReturn = v    end

local _customRefuelFn = nil
function base.setRefuelFn(fn)    _customRefuelFn = fn    end

function base.isInsideBuilding(pos)
    return pos.y >= CFG.FLOOR_Y
        and pos.x >= BUILDING.minX and pos.x <= BUILDING.maxX
        and pos.z >= BUILDING.minZ and pos.z <= BUILDING.maxZ
end

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

local function flushLogQueue()
    if not _self.modem or #_logQueue == 0 then return end
    local batch = _logQueue
    _logQueue = {}
    comms.toServer(proto.MSG.TURTLE_LOG, { lines = batch })
end

-- Throttled position push: sends current position as STATUS_UPDATE at most once
-- per 2 seconds. Intended for support turtles which move constantly but never
-- call sendProgress(). Without this the server only learns position via heartbeats
-- (every 5s), leaving the map up to 15+ blocks behind.
local _lastPositionPush = 0
function base.pushPosition()
    local now = os.epoch("utc")
    if now - _lastPositionPush < 2000 then return end
    _lastPositionPush = now
    comms.toServer(proto.MSG.STATUS_UPDATE, proto.payloadStatusUpdate(
        _self.jobId, _self.status, nil, base.getPos()))
end

-- ─── Position ────────────────────────────────────────────────────────────────

local function gpsSync()
    local x, y, z = gps.locate(CFG.GPS_TIMEOUT)
    if x then
        _self.pos = { x=math.floor(x), y=math.floor(y), z=math.floor(z) }
        return true
    else
        logWarn("GPS locate failed — continuing with dead-reckoned position")
        return false
    end
end

-- Public GPS resync — corrects position drift before precision bay navigation.
function base.gpsSync()
    local ok = gpsSync()
    if ok then
        logInfo(string.format("GPS resync: %d,%d,%d", _self.pos.x, _self.pos.y, _self.pos.z))
    else
        logWarn("GPS resync failed — continuing with dead-reckoned position")
    end
    return ok
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
    -- Save previous position before updating
    local prevX, prevY, prevZ = _self.pos.x, _self.pos.y, _self.pos.z

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

    -- Delivery and miner turtles broadcast their previous position so support can follow 1 block behind
    if _self.partnerId and (_self.role == proto.ROLE.DELIVERY or _self.role == proto.ROLE.MINER) and _self.modem then
        local sig = proto.encode(proto.MSG.POSITION_UPDATE, _self.id, _self.partnerId, {
            prev = { x=prevX, y=prevY, z=prevZ },
        })
        proto.send(_self.modem, proto.CH_LOCAL, sig)
    end
end

-- ─── Movement ────────────────────────────────────────────────────────────────

local move = {}

-- Inspect function for each direction (nil for back — no inspectBack in CC)
local INSPECT = {
    forward = turtle.inspect,
    up      = turtle.inspectUp,
    down    = turtle.inspectDown,
    back    = nil,
}

local function isTurtleBlock(dir)
    local fn = INSPECT[dir]
    if not fn then return false end
    local ok, data = fn()
    return ok and type(data) == "table"
           and type(data.name) == "string"
           and data.name:find("turtle")
end

-- Attempt to route around a turtle blocking the forward path.
-- Tries (in order): left strafe, right strafe, dig UP over it, dig DOWN under it.
-- Vertical bypasses work even in 1-block-wide tunnels where lateral strafes fail.
-- All position tracking is done internally; caller must NOT call applyMove again.
-- Returns true if the turtle successfully moved past the obstacle.
local function bypassForward()

    -- ── Lateral bypass (left or right) ───────────────────────────────────────
    local function tryStrafe(isLeft)
        local turnOut = isLeft and move.turnLeft  or move.turnRight
        local turnRtn = isLeft and move.turnRight or move.turnLeft

        turnOut()
        if not turtle.forward() then turnRtn(); return false end
        applyMove("forward")
        turnRtn()

        local advanced = 0
        for _ = 1, 3 do
            if turtle.forward() then
                applyMove("forward")
                advanced = advanced + 1
                if not isTurtleBlock("forward") then break end
            else
                break
            end
        end

        if advanced == 0 then
            turnRtn(); turtle.forward(); applyMove("forward"); turnOut()
            return false
        end

        turnRtn()
        if turtle.forward() then applyMove("forward") end
        turnOut()
        return true
    end

    -- ── Vertical bypass (up over obstacle, then back down) ───────────────────
    -- Needs canDig (delivery has a pickaxe, support does not).
    -- Advances 2 blocks at the upper level so delivery is fully past support
    -- before descending (support is 1 block wide so 2 steps = safely clear).
    local function tryVertical(isUp)
        if not _self.canDig then return false end

        local digLayer  = isUp and turtle.digUp   or turtle.digDown
        local moveLayer = isUp and turtle.up      or turtle.down
        local applyDir  = isUp and "up"           or "down"
        local returnDig = isUp and turtle.digDown or turtle.digUp
        local returnMov = isUp and turtle.down    or turtle.up
        local returnDir = isUp and "down"         or "up"
        local detectLayer = isUp and turtle.detectUp or turtle.detectDown

        -- 1. Dig and move to upper/lower level
        if detectLayer() then digLayer() end
        if not moveLayer() then return false end
        applyMove(applyDir)

        -- 2. Advance 2 blocks past the obstacle at this level (dig terrain if needed)
        local advanced = 0
        for _ = 1, 2 do
            if not turtle.forward() then
                if isTurtleBlock("forward") then break end  -- another turtle, stop
                turtle.dig()                                -- terrain — dig it
                sleep(0.2)
                if not turtle.forward() then break end
            end
            applyMove("forward")
            advanced = advanced + 1
        end

        if advanced < 2 then
            -- Couldn't clear obstacle at this level — go back
            if isUp and turtle.detectDown() then turtle.digDown() end
            if not isUp and turtle.detectUp() then turtle.digUp() end
            returnMov(); applyMove(returnDir)
            return false
        end

        -- 3. Return to original Y level (dig if terrain moved in)
        local returnDetect = isUp and turtle.detectDown or turtle.detectUp
        if returnDetect() then returnDig() end
        if not returnMov() then
            -- Stuck at the new level — still report success (move.to will fix Y)
            logWarn("Vertical bypass: could not return to original Y — move.to will correct")
            return true
        end
        applyMove(returnDir)
        return true
    end

    logInfo("Turtle blocking forward — attempting intelligent bypass...")
    if tryStrafe(true)  then logInfo("Bypass: left lane");  return true end
    if tryStrafe(false) then logInfo("Bypass: right lane"); return true end
    -- Vertical bypass (dig up/down) is only safe underground in tight tunnels.
    -- Inside the surface depot (y >= FLOOR_Y) never dig — just wait or strafe.
    if _self.pos.y < CFG.FLOOR_Y then
        if tryVertical(true)  then logInfo("Bypass: dug UP over blocker");    return true end
        if tryVertical(false) then logInfo("Bypass: dug DOWN under blocker"); return true end
    end
    logInfo("All bypass routes failed — waiting for path to clear")
    return false
end

local function tryMove(moveFn, digFn, dir)
    -- Hold position while server is unreachable; resume when reconnected.
    -- Exception: sky return has a fixed safe path — don't freeze in the arrivals shaft.
    while _self.serverDown and not _self.inSkyReturn do sleep(2) end

    local maxDig      = (digFn and _self.canDig) and 12 or CFG.MOVE_RETRIES
    local digAttempts = 0

    -- Separate deadline for turtle-blocked waiting (2 minutes max)
    local turtleDeadline  = os.clock() + 120
    local turtleWaits     = 0
    local bypassAttempted = false

    while true do
        if moveFn() then applyMove(dir); return true end

        if isTurtleBlock(dir) then
            -- Another turtle is in the way — wait, then try to route around it
            if os.clock() > turtleDeadline then
                return false, "blocked by turtle (" .. dir .. ")"
            end
            turtleWaits = turtleWaits + 1
            -- After ~3 s of waiting, attempt a one-block lateral bypass (forward only)
            if dir == "forward" and turtleWaits >= 6 and not bypassAttempted then
                bypassAttempted = true
                if bypassForward() then
                    return true   -- position already updated inside bypassForward
                end
            end
            -- Back off progressively: 0.5s → 1s → 1.5s → 2s (cap)
            sleep(math.min(2.0, 0.5 * turtleWaits))
        else
            -- Static block (terrain, gravel, etc.) — dig it
            digAttempts = digAttempts + 1
            if digAttempts > maxDig then
                return false, "blocked (" .. dir .. ")"
            end
            if digFn and _self.canDig then
                digFn()
                sleep(digAttempts <= 4 and 0.2 or 0.4)
            else
                sleep(0.3)
            end
        end
    end
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
    -- X axis: recalculate facing each step so a bypass overshoot auto-corrects
    -- (without this, a 2-block bypass past the target leaves facing wrong and
    --  the turtle drives away from the target forever)
    while _self.pos.x ~= tx do
        if _self.pos.x < tx then move.face(1) else move.face(3) end
        local ok, err = move.forward()
        if not ok then return false, "stuck X: " .. (err or "?") end
    end
    -- Z axis: same per-step facing recalc
    while _self.pos.z ~= tz do
        if _self.pos.z < tz then move.face(2) else move.face(0) end
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
function base.depart(noDescend)
    if not _self.dock then logWarn("No dock assigned, departing from current pos.") return true end

    -- Pre-departure fuel reserve check. A flat critical threshold isn't enough for a
    -- full warehouse run, so require a conservative reserve before leaving the dock.
    if turtle.getFuelLevel() < CFG.FUEL_RESERVE then
        logWarn(string.format("Pre-departure fuel check: %d < %d, attempting refuel",
            turtle.getFuelLevel(), CFG.FUEL_RESERVE))
        base.fuel.dockRefuel()
        if turtle.getFuelLevel() < CFG.FUEL_RESERVE then
            base.setStatus(proto.STATUS.ERROR)
            comms.toServer(proto.MSG.STATUS_UPDATE, proto.payloadStatusUpdate(
                _self.jobId, proto.STATUS.ERROR, "insufficient fuel for departure", base.getPos()))
            return false, "insufficient fuel for departure (have " .. turtle.getFuelLevel()
                .. ", need " .. CFG.FUEL_RESERVE .. ")"
        end
    end

    logInfo("Departing via dispatch lane...")
    base.setStatus(proto.STATUS.TRAVELLING)

    -- GPS resync from dock position before precision bay navigation.
    -- Corrects any position drift from previous trips so the aisle routes are exact.
    gpsSync()
    -- Face toward taxiway before departing — consistent starting orientation.
    move.face(W.dockFacing(_self.dock))

    if _self.role == proto.ROLE.DELIVERY or _self.role == proto.ROLE.MINER then
        -- ── Delivery / Miner departure ────────────────────────────────────────
        -- Navigate to hole entrance, signal support, wait for support to stage
        -- behind us, THEN descend so they go down together.

        local route = W.departureRoute(_self.dock)
        local ok, err = move.followRoute(route)
        if not ok then return false, "departure route failed: " .. (err or "?") end

        if _self.partnerId then
            -- Signal support to start its departure route. Reliable: if this is
            -- lost the support waits out its full HOLE_READY timeout and the
            -- pair is stranded, so resend until it ACKs.
            logInfo("At hole — signalling support to stage...")
            base.signalPartnerReliable(proto.MSG.HOLE_READY, {})

            -- Wait for support to reach staging position (1 block behind us)
            -- base.receive() routes anything else to the inbox instead of dropping it.
            logInfo("Waiting for SUPPORT_STAGED...")
            local deadline = os.epoch("utc") / 1000 + 60
            local staged = false
            local held   = {}
            while os.epoch("utc") / 1000 < deadline do
                if base.isRecalled() then break end
                local msg = base.receive(5)
                if msg then
                    if msg.type == proto.MSG.SUPPORT_STAGED and msg.from == _self.partnerId then
                        logInfo("Support staged — descending together.")
                        staged = true
                        break
                    end
                    -- Held, not re-queued inline: base.receive drains the inbox
                    -- first, so pushing back here would re-pop it and spin.
                    held[#held + 1] = msg
                end
            end
            for i = 1, #held do base.pushJobInbox(held[i]) end
            if not staged and not base.isRecalled() then
                logWarn("SUPPORT_STAGED never arrived — descending anyway.")
            end
            if base.isRecalled() then return true end
        end

        if not noDescend then
            logInfo("Descending dispatch hole...")
            for _ = 1, 10 do
                move.down()
                if _self.pos.y <= W.WORLD_EXIT.y then break end
            end
        end

    else
        -- ── Support departure ─────────────────────────────────────────────────
        -- Navigate to 1 block before the hole (staging), signal delivery,
        -- then move to hole and descend.

        local route = W.supportDepartureRoute(_self.dock)
        local ok, err = move.followRoute(route)
        if not ok then return false, "departure route failed: " .. (err or "?") end

        -- At staging position — tell delivery it can descend
        if _self.partnerId then
            -- Reliable: if this is lost the worker waits out its full 60s stage
            -- timeout and descends without its chunk loader.
            logInfo("Staged behind hole — signalling delivery to descend.")
            base.signalPartnerReliable(proto.MSG.SUPPORT_STAGED, {}, { attempts = 4, interval = 2 })
        end

        -- Brief pause so the worker starts moving off the hole entrance first.
        -- Do NOT wait on the worker's altitude here: mining workers depart with
        -- noDescend=true and ascend to SKY_Y instead of entering the shaft, so a
        -- "descended below WORLD_EXIT" check never becomes true for them and the
        -- support sits at staging blocking the departure lane behind it.
        -- move.to() below already retries when the worker is still in the way.
        sleep(1)

        -- Move to hole and descend
        move.to(W.DISPATCH_HOLE.x, W.DISPATCH_HOLE.y, W.DISPATCH_HOLE.z)
        if not noDescend then
            logInfo("Descending dispatch hole...")
            for _ = 1, 10 do
                move.down()
                if _self.pos.y <= W.WORLD_EXIT.y then break end
            end
        end
    end

    logInfo(string.format("Exited depot at %d,%d,%d", _self.pos.x, _self.pos.y, _self.pos.z))
    return true
end

-- Navigate from the world back to dock via arrivals hole.
-- Call this when turtle is outside/underground after completing a job.
-- Always goes underground first then up through the arrivals hole.
-- Above this altitude a turtle is flying, not walking: the only safe way home is
-- the sky route. Matches the threshold the RECALL handler already uses for idle
-- turtles. Delivery traffic runs at UNDERGROUND_Y=60 and is unaffected.
local SKY_ALTITUDE = 100

function base.returnToDock()
    if not _self.dock then logWarn("No dock assigned, staying put.") return true end

    -- Safety net, deliberately at the choke point rather than at each call site.
    -- Return mode is DERIVED from altitude instead of tracked in a _skyReturn flag
    -- threaded through a dozen break paths — one missed assignment used to send an
    -- airborne support diving ~130 blocks through terrain toward UNDERGROUND_Y.
    if _self.pos.y >= SKY_ALTITUDE and not base.isInsideBuilding(_self.pos) then
        logWarn(string.format(
            "returnToDock at sky altitude Y=%d — using sky route instead of descending.",
            _self.pos.y))
        return base.returnToDockFromSky()
    end

    base.setStatus(proto.STATUS.RETURNING)

    local FLOOR_Y       = CFG.FLOOR_Y
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
    -- Support is following via position broadcasts so it arrives right behind us
    logInfo("Navigating underground to arrivals hole...")
    local ok, err = move.to(W.ARRIVALS_HOLE.x, UNDERGROUND_Y, W.ARRIVALS_HOLE.z)
    if not ok then return false, "could not reach arrivals hole: " .. (err or "?") end

    -- Stop position broadcasts and tell support to hold BEFORE ascending.
    -- Clearing partnerId immediately is critical: if support misses the ASCENDING
    -- signal (it can happen if support is mid-move.to()), it would otherwise keep
    -- following POSITION_UPDATEs all the way to the surface and block delivery.
    local savedPartnerId = nil
    if _self.partnerId and _self.role == proto.ROLE.DELIVERY then
        savedPartnerId  = _self.partnerId
        _self.partnerId = nil   -- kills all further POSITION_UPDATE broadcasts NOW
        -- Send ASCENDING so support knows to hold (best-effort; if missed it's OK
        -- because broadcasts have already stopped so support gets no more updates)
        local sig = proto.encode(proto.MSG.ASCENDING, _self.id, savedPartnerId, {})
        proto.send(_self.modem, proto.CH_LOCAL, sig)
        sleep(0.5)
    end

    -- Ascend through arrivals hole into building (no POSITION_UPDATEs, partnerId is nil)
    logInfo("Ascending arrivals hole...")
    for _ = 1, 10 do
        move.up()
        if _self.pos.y >= FLOOR_Y then break end
    end

    -- GPS resync now that we're on the surface — corrects any drift from underground
    -- travel before precision bay navigation (tight corridors, 1-block clearance).
    gpsSync()

    -- Navigate to red taxiway to fully clear the arrivals hole exit, THEN signal
    -- support so it has room to ascend without colliding with us.
    if savedPartnerId then
        move.to(W.ARRIVALS_HOLE.x, FLOOR_Y, W.RED_Z)
        logInfo("Clear of arrivals hole — signalling support to return.")
        local sig = proto.encode(proto.MSG.RETURN_TO_DOCK, _self.id, savedPartnerId, {})
        proto.send(_self.modem, proto.CH_LOCAL, sig)
        -- partnerId already nil, nothing more to clear
    end

    -- Follow red taxiway back to dock
    local route = W.returnRoute(_self.dock)
    ok, err = move.followRoute(route)
    if not ok then
        base.setStatus(proto.STATUS.ERROR)
        comms.toServer(proto.MSG.STATUS_UPDATE, proto.payloadStatusUpdate(
            _self.jobId, proto.STATUS.ERROR, "return route failed: " .. (err or "?"), base.getPos()))
        return false, "return route failed: " .. (err or "?")
    end

    -- GPS verify final dock position; correct if off by 1 from route rounding.
    gpsSync()
    if _self.pos.x ~= _self.dock.x or _self.pos.z ~= _self.dock.z then
        logWarn(string.format("Post-dock GPS mismatch: at %d,%d want %d,%d — correcting",
            _self.pos.x, _self.pos.z, _self.dock.x, _self.dock.z))
        move.to(_self.dock.x, FLOOR_Y, _self.dock.z)
    end

    -- Face toward the taxiway so departure always starts from the same orientation.
    -- This makes the first move (toward the back aisle) consistent and predictable.
    move.face(W.dockFacing(_self.dock))

    logInfo("Docked at bay " .. _self.dock.bay .. " row " .. _self.dock.row)

    -- All roles top up fuel at dock (dockRefuel skips at ≥80% so miners at full are unaffected).
    base.fuel.dockRefuel()

    return true
end

-- Sky-path variant of returnToDock: ascend to Y=200, fly to arrivals hole at
-- altitude, then descend through the hole and follow the normal return route.
-- Use for mining recall where both turtles come back via the sky rather than
-- navigating underground (which risks terrain collisions from deep scan depths).
function base.returnToDockFromSky()
    if not _self.dock then logWarn("No dock assigned, staying put.") return true end

    base.setStatus(proto.STATUS.RETURNING)

    local FLOOR_Y     = CFG.FLOOR_Y
    local SKY_RETURN_Y = 200

    -- 1. Ascend straight up to sky altitude from current position
    logInfo("Ascending to sky Y=" .. SKY_RETURN_Y .. " for sky return...")
    move.to(_self.pos.x, SKY_RETURN_Y, _self.pos.z)

    -- 2. Fly at sky altitude to directly above arrivals hole (move.to is vertical-first,
    --    so targeting the same Y means only X then Z movement happens here)
    logInfo("Flying to arrivals hole at Y=" .. SKY_RETURN_Y .. "...")
    move.to(W.ARRIVALS_HOLE.x, SKY_RETURN_Y, W.ARRIVALS_HOLE.z)

    -- 3. Descend straight down through the arrivals hole to floor level
    logInfo("Descending through arrivals hole...")
    local ok, err = move.to(W.ARRIVALS_HOLE.x, FLOOR_Y, W.ARRIVALS_HOLE.z)
    if not ok then
        base.setStatus(proto.STATUS.ERROR)
        return false, "sky descent failed: " .. (err or "?")
    end

    gpsSync()

    -- 4. Follow standard return route from arrivals hole to dock
    local route = W.returnRoute(_self.dock)
    ok, err = move.followRoute(route)
    if not ok then
        base.setStatus(proto.STATUS.ERROR)
        return false, "sky return route failed: " .. (err or "?")
    end

    gpsSync()
    if _self.pos.x ~= _self.dock.x or _self.pos.z ~= _self.dock.z then
        logWarn(string.format("Post-dock GPS mismatch: at %d,%d want %d,%d — correcting",
            _self.pos.x, _self.pos.z, _self.dock.x, _self.dock.z))
        move.to(_self.dock.x, FLOOR_Y, _self.dock.z)
    end

    move.face(W.dockFacing(_self.dock))
    logInfo("Docked at bay " .. _self.dock.bay .. " row " .. _self.dock.row)

    -- All roles top up fuel at dock (dockRefuel skips at ≥80% so miners at full are unaffected).
    base.fuel.dockRefuel()

    return true
end

-- Navigate from anywhere inside the building back to dock.
-- Uses an aisle route that moves Z first so the turtle never cuts
-- through occupied dock rows.  Safe to call from any floor position.
function base.returnToDockInternal()
    if not _self.dock then return true end
    -- GPS sync first so current position is accurate
    gpsSync()
    -- Re-derive heading from GPS before following the route. A physical bump or
    -- chunk reload can desync _self.facing; a wrong heading here causes the most
    -- damage (cutting across occupied dock rows), so correct it up front.
    detectFacing()
    -- Already at dock? Just orient and done.
    if _self.pos.x == _self.dock.x and _self.pos.z == _self.dock.z then
        move.face(W.dockFacing(_self.dock))
        logInfo("Already at dock bay " .. _self.dock.bay .. " row " .. _self.dock.row)
        return true
    end
    base.setStatus(proto.STATUS.RETURNING)
    logInfo(string.format("Homing to dock from %d,%d,%d...",
        _self.pos.x, _self.pos.y, _self.pos.z))
    -- Position-aware route: moves Z to the red taxiway FIRST at the current X
    -- column so the turtle never traverses another dock row sideways.
    local route = W.internalReturnRouteFrom(_self.dock, _self.pos.x, _self.pos.z)
    local ok, err = move.followRoute(route)
    if not ok then
        base.setStatus(proto.STATUS.ERROR)
        comms.toServer(proto.MSG.STATUS_UPDATE, proto.payloadStatusUpdate(
            _self.jobId, proto.STATUS.ERROR, "internal return route failed: " .. (err or "?"), base.getPos()))
        return false, "internal return failed: " .. (err or "?")
    end
    -- GPS verify — correct any sub-block drift before accepting future jobs.
    gpsSync()
    if _self.pos.x ~= _self.dock.x or _self.pos.z ~= _self.dock.z then
        logWarn(string.format("Post-dock mismatch: at %d,%d want %d,%d — correcting",
            _self.pos.x, _self.pos.z, _self.dock.x, _self.dock.z))
        move.to(_self.dock.x, CFG.FLOOR_Y, _self.dock.z)
    end
    move.face(W.dockFacing(_self.dock))
    logInfo("Docked at bay " .. _self.dock.bay .. " row " .. _self.dock.row)
    if not _self.canDig then base.fuel.dockRefuel() end
    return true
end

-- ─── Fuel ────────────────────────────────────────────────────────────────────
-- Turtles carry an entangled chest in a reserved slot.
-- Delivery turtles use slot 15 (slot 16 is reserved for the delivery ender chest).
-- Support/chunk-loader turtles use slot 16.
-- Set by base.init() based on role.

local CHEST_SLOT = 16  -- overridden to 15 for DELIVERY role in base.init()
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

-- Slots we never burn fuel from or suck coal into.
-- Delivery: slot 15 = fuel EC, slot 16 = delivery EC.
-- Support:  slot 16 = fuel EC, slot 15 kept free as safety margin.
-- Both roles: only use slots 1-BURN_MAX for fuel operations.
local BURN_MAX = 14   -- updated to CHEST_SLOT-1 (min 14) in base.init()

-- Support turtle coal reserve slots — carried on-board for field self-refueling.
-- Support has no EC or pickaxe; coal slots replace the old FUEL_LOW handshake.
local COAL_SLOTS = { 13, 14 }
local COAL_ITEM_NAMES = {
    ["minecraft:coal"]       = true,
    ["minecraft:charcoal"]   = true,
    ["minecraft:coal_block"] = true,
}

-- Quick scan of inventory slots 1-BURN_MAX for any loose burnable items (used on boot).
-- Skips if already at max fuel to avoid wasting coal from previous runs.
function fuel.refuel()
    if fuel.level() >= fuel.max() then return end
    local before = fuel.level()
    for slot = 1, BURN_MAX do
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

-- Deploy the entangled chest, drain coal into slots 1-BURN_MAX, burn it, recover chest.
-- Before deploying, clears non-fuel debris from slots 1-BURN_MAX to ensure there is
-- room for coal (support turtles accumulate road debris while following delivery).
function fuel.refuelFromChest()
    local chestData = turtle.getItemDetail(CHEST_SLOT)
    if not chestData then
        logWarn("Slot " .. CHEST_SLOT .. " has no entangled chest!")
        return false
    end
    if chestData.name ~= CHEST_ITEM then
        logWarn(string.format("Slot %d has wrong item (%s) — expected %s, cannot refuel",
            CHEST_SLOT, chestData.name, CHEST_ITEM))
        return false
    end

    -- ── Clear debris to make room ────────────────────────────────────────────
    local function freeCount()
        local n = 0
        for s = 1, BURN_MAX do
            if turtle.getItemCount(s) == 0 then n = n + 1 end
        end
        return n
    end

    if freeCount() < 4 then
        logInfo("Clearing debris from inventory to make room for coal...")
        for s = 1, BURN_MAX do
            if freeCount() >= 4 then break end
            local item = turtle.getItemDetail(s)
            if item then
                local n = item.name
                local isFuel = (n == "minecraft:coal" or n == "minecraft:charcoal"
                                or n == "minecraft:coal_block" or n == CHEST_ITEM)
                if not isFuel then
                    turtle.select(s)
                    -- Prefer dropping down; fall back to forward
                    if not turtle.dropDown() then turtle.drop() end
                end
            end
        end
        logInfo(string.format("Debris cleared — %d free slot(s) now available", freeCount()))
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

    -- Suck coal into slots 1-BURN_MAX only.
    -- Explicitly select each target slot before sucking so CC never auto-fills
    -- into slots 15 or 16 (reserved for ender chests).
    local pulled = 0
    for s = 1, BURN_MAX do
        if turtle.getItemCount(s) == 0 then
            turtle.select(s)
            if suckFn(64) then pulled = pulled + 1 end
        end
    end
    turtle.select(1)

    if pulled == 0 then
        logWarn("Entangled chest is empty — no coal available!")
    end

    -- Burn slots 1-BURN_MAX only (never touch slots 15 or 16)
    local before = fuel.level()
    for slot = 1, BURN_MAX do
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

    -- If coal accidentally landed in CHEST_SLOT, burn it before recovering the chest
    local cs = turtle.getItemDetail(CHEST_SLOT)
    if cs and cs.name ~= CHEST_ITEM then
        turtle.select(CHEST_SLOT)
        turtle.refuel()   -- burns coal; EC is not burnable so this is safe
    end

    -- Find chest in any slot (1-16) and move to CHEST_SLOT
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

    -- Suck coal from dock chest into slots 1-BURN_MAX only
    local suckFns = { turtle.suckDown, turtle.suckUp, turtle.suck }
    for _, suckFn in ipairs(suckFns) do
        for s = 1, BURN_MAX do
            if turtle.getItemCount(s) == 0 then
                turtle.select(s)
                if not suckFn(64) then break end
            end
        end
    end
    turtle.select(1)

    -- Burn slots 1-BURN_MAX only
    local before = fuel.level()
    for slot = 1, BURN_MAX do
        if turtle.getItemCount(slot) > 0 then
            turtle.select(slot)
            turtle.refuel()
        end
    end
    turtle.select(1)
    local gained = fuel.level() - before

    if gained > 0 then
        logInfo(string.format("Dock refuel +%d (now %d/%d)", gained, fuel.level(), fuel.max()))
    else
        logWarn("Dock refuel: no coal found in station — check chest below dock!")
    end
    return gained > 0
end

-- Burn coal from COAL_SLOTS (support self-refueling, no EC required).
-- Returns true if any fuel was gained, false if coal slots are empty.
function fuel.selfRefuel()
    local before = fuel.level()
    for _, slot in ipairs(COAL_SLOTS) do
        local item = turtle.getItemDetail(slot)
        if item and COAL_ITEM_NAMES[item.name] then
            turtle.select(slot)
            turtle.refuel()
        end
    end
    turtle.select(1)
    local gained = fuel.level() - before
    if gained > 0 then
        logInfo(string.format("Self-refueled +%d from coal slots (now %d)", gained, fuel.level()))
    end
    return gained > 0
end

-- Pre-fill COAL_SLOTS from the dock chest (called at mining support departure).
-- Sucks coal into slots 13 and 14 only; never touches slots 1-12 or 15-16.
function fuel.dockFillCoal()
    local suckFns = { turtle.suckDown, turtle.suckUp, turtle.suck }
    local filled = 0
    for _, slot in ipairs(COAL_SLOTS) do
        if turtle.getItemCount(slot) == 0 then
            turtle.select(slot)
            for _, suckFn in ipairs(suckFns) do
                if suckFn(64) then filled = filled + 1; break end
            end
        else
            filled = filled + 1  -- already has coal
        end
    end
    turtle.select(1)
    logInfo(string.format("Coal pre-fill: %d/%d slot(s) loaded", filled, #COAL_SLOTS))
    return filled > 0
end

local MAX_FUEL_RETRIES = 5

function fuel.ensureFuel()
    local fuelRetries = 0
    while fuel.isCritical() do
        fuelRetries = fuelRetries + 1
        if fuelRetries > MAX_FUEL_RETRIES then
            logWarn("Cannot refuel after " .. MAX_FUEL_RETRIES .. " attempts — setting ERROR status")
            base.setStatus(proto.STATUS.ERROR)
            return false  -- caller must handle
        end
        logWarn(string.format("Fuel critical (%d) — deploying entangled chest...", fuel.level()))
        -- Send heartbeat so server doesn't mark us offline during refuel
        if _self.id then
            comms.toServer(proto.MSG.HEARTBEAT, proto.payloadHeartbeat(
                proto.STATUS.ERROR, fuel.level(), base.getPos(), _self.jobId))
        end
        local ok = fuel.refuelFromChest()
        if not ok or fuel.isCritical() then
            -- GPS resync before reporting ERROR position — corrects position if turtle
            -- was physically relocated (e.g. player moved it to dock while stuck).
            gpsSync()
            comms.toServer(proto.MSG.STATUS_UPDATE, proto.payloadStatusUpdate(
                _self.jobId, proto.STATUS.ERROR, "fuel_critical_no_coal", base.getPos()))
            -- Wait but keep sending heartbeats every 5 seconds
            for _ = 1, 6 do
                if _self.id then
                    comms.toServer(proto.MSG.HEARTBEAT, proto.payloadHeartbeat(
                        proto.STATUS.ERROR, fuel.level(), base.getPos(), _self.jobId))
                end
                sleep(5)
                gpsSync()  -- keep position current in case turtle is moved during wait
                if not fuel.isCritical() then break end
            end
        end
    end
    return true
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
        -- midJob=true tells server this is a reconnect, not a fresh boot:
        -- the turtle's job coroutine is still alive and will resume automatically.
        -- Server re-links the job instead of re-queuing it for a new pair.
        comms.toServer(proto.MSG.REGISTER, {
            role     = _self.role,
            fuel     = fuel.level(),
            fuelMax  = fuel.max(),
            position = base.getPos(),
            midJob   = _self.busy,
        })

        local reply = proto.receive(_self.id, CFG.REGISTER_TIMEOUT)
        if reply and reply.type == proto.MSG.REGISTER_ACK and reply.payload.ok then
            -- Server sends assigned dock in the ACK
            if reply.payload.dock then
                _self.dock = reply.payload.dock
                logInfo(string.format("Assigned dock: bay %d row %s (%d,%d,%d)",
                    _self.dock.bay, _self.dock.row,
                    _self.dock.x, _self.dock.y, _self.dock.z))
            end
            if _self.serverDown then
                local p = _self.pos
                logInfo(string.format(
                    "Server reconnected — resuming from %d,%d,%d", p.x, p.y, p.z))
                _self.serverDown = false
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
local _heartbeatCount = 0

local function sendHeartbeat()
    _heartbeatCount = _heartbeatCount + 1
    -- Periodic GPS resync so idle or error-state turtles self-correct position drift.
    -- GPS locate needs no movement — just radio signal from beacons. Silent on failure.
    if _heartbeatCount % 12 == 0 then
        gpsSync()
    end
    comms.toServer(proto.MSG.HEARTBEAT, proto.payloadHeartbeat(
        _self.status, fuel.level(), base.getPos(), _self.jobId))
    _missedHeartbeats = _missedHeartbeats + 1

    -- If too many heartbeats go unacknowledged, server is unreachable.
    -- Pause movement and wait — re-register until server responds.
    if _missedHeartbeats >= MAX_MISSED then
        if not _self.serverDown then
            logWarn(string.format(
                "Server unreachable — pausing at %d,%d,%d and waiting for reconnect...",
                _self.pos.x, _self.pos.y, _self.pos.z))
            _self.serverDown = true
        end
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
    -- Tell support to abort immediately so it doesn't wait 180s for HOLE_READY
    if _self.partnerId then
        base.signalPartnerDirect(proto.MSG.JOB_ABORT, _self.partnerId, { reason = reason })
    end
    comms.toServer(proto.MSG.JOB_FAILED, proto.payloadJobFailed(_self.jobId, reason, recoverable))
    _self.status    = proto.STATUS.IDLE
    _self.jobId     = nil
    _self.partnerId = nil
    _self.busy      = false
end

-- Generic send to server — used by delivery turtle for warehouse handshake messages
function base.sendToServer(msgType, payload)
    comms.toServer(msgType, payload)
end

-- Send a direct CH_LOCAL signal to the paired partner turtle
function base.signalPartner(msgType, payload)
    if not _self.partnerId or not _self.modem then return end
    local sig = proto.encode(msgType, _self.id, _self.partnerId, payload or {})
    proto.send(_self.modem, proto.CH_LOCAL, sig)
end

-- Like signalPartner but uses an explicit target ID.
-- Use this when partnerId has been temporarily cleared to stop broadcasts
-- but you still need to send one final signal (e.g. ASCENDING, RETURN_TO_DOCK).
function base.signalPartnerDirect(msgType, targetId, payload)
    if not targetId or not _self.modem then return end
    local sig = proto.encode(msgType, _self.id, targetId, payload or {})
    proto.send(_self.modem, proto.CH_LOCAL, sig)
end

-- ─── Shared message inbox ────────────────────────────────────────────────────
-- base.run() drives controlLoop and jobRunner under parallel.waitForAny, so both
-- coroutines drain the SAME OS event queue. Whichever one pulls an event first
-- consumes it. Before this inbox existed, a coordination signal pulled by the
-- control loop (RETURN_TO_DOCK, MINE_CLEAR, TURTLE_INFO, …) was silently
-- discarded, because the control loop only ever acted on four message types.
-- POSITION_UPDATE survived that by sheer volume; once-only signals did not.
--
-- Each coroutine now hands off whatever it pulls that belongs to the other,
-- instead of dropping it. Nothing addressed to this turtle is ever lost.
local _jobInbox  = {}   -- coordination messages awaiting the job runner
local _ctrlInbox = {}   -- control messages awaiting the control loop

-- Message types the control loop owns. Everything else belongs to the job runner.
-- HEARTBEAT_ACK is listed so it always reaches the control loop: it is the only
-- proof the server is alive, and if the job runner absorbed it instead,
-- _missedHeartbeats would reach MAX_MISSED and falsely trip serverDown, which
-- freezes all movement in tryMove().
local CTRL_TYPES = {
    [proto.MSG.JOB_ASSIGN]    = true,
    [proto.MSG.RECALL]        = true,
    [proto.MSG.FORCE_REFUEL]  = true,
    [proto.MSG.UPDATE_ALL]    = true,
    [proto.MSG.HEARTBEAT_ACK] = true,
}

local _ackedSigs  = {}   -- sigId → true; ACKs seen for signals we sent
local _seenSigs   = {}   -- sigId → timestamp; signals we received (duplicate filter)
local _seenCount  = 0
local _sigCounter = 0

local MAX_INBOX = 64

local function pushJobInbox(msg)
    -- Cap the queue: a message no loop ever claims would otherwise circulate
    -- (popped, not matched, pushed back) and grow the table without bound.
    if #_jobInbox >= MAX_INBOX then table.remove(_jobInbox, 1) end
    _jobInbox[#_jobInbox + 1] = msg
    os.queueEvent("inbox_job")
end

local function pushCtrlInbox(msg)
    _ctrlInbox[#_ctrlInbox + 1] = msg
    os.queueEvent("inbox_ctrl")
end

base.pushJobInbox  = pushJobInbox
base.hasCtrlInbox  = function() return #_ctrlInbox > 0 end
base.popCtrlInbox  = function() return table.remove(_ctrlInbox, 1) end

-- ACK a reliable signal and report whether it is a duplicate retransmission.
-- Returns true if this sigId was already delivered once (caller should drop it).
local function ackSignal(msg)
    -- Never ACK an ACK — its payload also carries _sigId, so acking it would
    -- ping-pong forever between the two turtles.
    if msg.type == proto.MSG.SIGNAL_ACK then return true end
    local sid = msg.payload and msg.payload._sigId
    if not sid then return false end
    if _self.modem then
        proto.send(_self.modem, proto.CH_LOCAL,
            proto.encode(proto.MSG.SIGNAL_ACK, _self.id, msg.from, { _sigId = sid }))
    end
    if _seenSigs[sid] then return true end
    -- Bound the duplicate filter: drop entries older than 5 minutes once it grows.
    _seenCount = _seenCount + 1
    if _seenCount > 200 then
        local cutoff = os.epoch("utc") - 300000
        for k, ts in pairs(_seenSigs) do
            if ts < cutoff then _seenSigs[k] = nil end
        end
        _seenCount = 0
    end
    _seenSigs[sid] = os.epoch("utc")
    return false
end
-- Exposed so the control loop can ACK a coordination signal it pulled before
-- handing it to the job runner. Only ever call this at first receipt — messages
-- re-queued into the inbox were already ACKed and must not be filtered twice.
base.ackSignal = ackSignal

-- Record an ACK for a signal we sent, so sendReliable() can stop retrying.
-- Needed because the control loop may pull the ACK before sendReliable does.
function base.noteSignalAck(msg)
    local sid = msg.payload and msg.payload._sigId
    if sid then _ackedSigs[sid] = true end
end

-- Receive one message for the job runner.
-- Drains the shared inbox first, then the OS event queue. Control messages
-- pulled here are handed to the control loop rather than dropped, and
-- SIGNAL_ACKs are absorbed into _ackedSigs for sendReliable().
function base.receive(timeout)
    if #_jobInbox > 0 then return table.remove(_jobInbox, 1) end
    local timer = timeout and os.startTimer(timeout) or nil
    while true do
        local event, evtArg2, _ch, _rep, raw = os.pullEvent()
        if event == "modem_message" then
            local parsed = type(raw) == "table" and raw or textutils.unserialise(raw)
            if parsed then
                local valid, msg = proto.decode(parsed)
                if valid and (msg.to == _self.id or msg.to == "broadcast") then
                    -- Any decodable message addressed to us proves the radio is
                    -- live. The control loop used to do this for every message it
                    -- pulled; preserve that here now that we intercept some.
                    resetMissedHeartbeats()
                    if msg.type == proto.MSG.SIGNAL_ACK then
                        local sid = msg.payload and msg.payload._sigId
                        if sid then _ackedSigs[sid] = true end
                    elseif CTRL_TYPES[msg.type] then
                        pushCtrlInbox(msg)
                    elseif not ackSignal(msg) then
                        return msg
                    end
                end
            end
        elseif event == "inbox_job" then
            if #_jobInbox > 0 then return table.remove(_jobInbox, 1) end
        elseif event == "timer" and evtArg2 == timer then
            return nil
        end
    end
end

-- Receive the first message satisfying pred(msg). Messages that don't match are
-- held and returned to the inbox afterwards, so waiting for one signal can never
-- consume another.
local function receiveMatching(pred, timeout)
    local deadline = os.epoch("utc") / 1000 + (timeout or 5)
    local held, found = {}, nil
    while os.epoch("utc") / 1000 < deadline do
        local remain = deadline - os.epoch("utc") / 1000
        local m = base.receive(math.max(0.2, remain))
        if m then
            if pred(m) then found = m; break end
            held[#held + 1] = m
        end
    end
    for i = 1, #held do _jobInbox[#_jobInbox + 1] = held[i] end
    if #held > 0 then os.queueEvent("inbox_job") end
    return found
end
base.receiveMatching = receiveMatching

-- Send a coordination signal and resend until the partner ACKs it.
-- Use for once-only signals whose loss strands the partner (RETURN_TO_DOCK,
-- HOLE_READY, SUPPORT_STAGED, JOB_ABORT). High-frequency loss-tolerant traffic
-- (POSITION_UPDATE) should keep using signalPartner instead.
-- Returns true if acknowledged, false if every attempt timed out.
function base.sendReliable(msgType, targetId, payload, opts)
    if not targetId or not _self.modem then return false end
    opts = opts or {}
    local attempts = opts.attempts or 6
    local interval = opts.interval or 2

    _sigCounter = _sigCounter + 1
    local sigId = _self.id .. "#" .. _sigCounter
    local body = {}
    for k, v in pairs(payload or {}) do body[k] = v end
    body._sigId = sigId

    local held, acked = {}, false
    for _ = 1, attempts do
        proto.send(_self.modem, proto.CH_LOCAL,
            proto.encode(msgType, _self.id, targetId, body))
        local deadline = os.epoch("utc") / 1000 + interval
        while os.epoch("utc") / 1000 < deadline do
            if _ackedSigs[sigId] then break end
            local remain = deadline - os.epoch("utc") / 1000
            -- Poll in short slices. base.receive() absorbs SIGNAL_ACK internally
            -- and keeps blocking, so a full-interval timeout here would sit out
            -- the whole 2s even when the partner ACKed instantly — dead time that
            -- multiplies across every pair serialising through the dispatch hole.
            local m = base.receive(math.max(0.05, math.min(0.25, remain)))
            if m then held[#held + 1] = m end
        end
        if _ackedSigs[sigId] then acked = true; break end
    end

    _ackedSigs[sigId] = nil
    -- Hand back everything we intercepted so the caller's own loop still sees it.
    for i = 1, #held do _jobInbox[#_jobInbox + 1] = held[i] end
    if #held > 0 then os.queueEvent("inbox_job") end

    if not acked then
        logWarn(string.format("%s to %s never ACKed after %d attempts",
            msgType, targetId, attempts))
    end
    return acked
end

-- Reliable variant of signalPartner, using the current partnerId.
function base.signalPartnerReliable(msgType, payload, opts)
    return base.sendReliable(msgType, _self.partnerId, payload, opts)
end

function base.queryTurtle(targetId, timeout)
    comms.toServer(proto.MSG.TURTLE_QUERY, proto.payloadTurtleQuery(targetId))
    local reply = receiveMatching(
        function(m) return m.type == proto.MSG.TURTLE_INFO end, timeout or 5)
    return reply and reply.payload or nil
end

-- Wait for one of several message types, returning the message or nil on
-- timeout / recall. Freezes the deadline while the server is unreachable.
function base.waitForAny(types, seconds)
    local set = {}
    for _, t in ipairs(types) do set[t] = true end
    local deadline = os.epoch("utc") / 1000 + seconds
    local held = {}
    local found = nil
    while os.epoch("utc") / 1000 < deadline do
        if base.isRecalled() then break end
        if base.isServerDown() then
            deadline = os.epoch("utc") / 1000 + seconds
            sleep(2)
        else
            local msg = base.receive(math.max(1, deadline - os.epoch("utc") / 1000))
            if msg then
                if set[msg.type] then found = msg; break end
                held[#held + 1] = msg
            end
        end
    end
    -- Non-matching messages go back to the inbox rather than being discarded.
    for i = 1, #held do base.pushJobInbox(held[i]) end
    return found
end

-- ─── Init ────────────────────────────────────────────────────────────────────

function base.init(role)
    _self.id   = proto.selfId()
    _self.role = role
    -- Delivery and miner turtles reserve slot 16 for their own ender chest
    -- (delivery EC / ore EC), so the fuel ender chest lives in slot 15.
    if role == proto.ROLE.DELIVERY or role == proto.ROLE.MINER then
        CHEST_SLOT = 15
        logInfo("Fuel ender chest slot set to 15 (" .. role .. " role)")
    end
    -- BURN_MAX = highest slot we'll ever suck coal into or burn from.
    -- Always cap at 14 so slots 15 and 16 are never touched by fuel ops.
    BURN_MAX = math.min(CHEST_SLOT - 1, 14)
    logInfo("Fuel burn range: slots 1-" .. BURN_MAX)
    print(string.format("=== %s [%s] v%s booting ===", _self.id, role, proto.VERSION))
    comms.init()
    initPosition()
    fuel.refuel()
    register()
    -- If not physically at assigned dock, home there now before accepting any jobs.
    -- This corrects position mismatches caused by crashes, reassignments, or reboots.
    -- Only runs when inside the building at floor level (safe to use internal taxiway).
    if _self.dock then
        gpsSync()
        local p = _self.pos
        local insideBuilding = base.isInsideBuilding(p)
        local atDock = (p.x == _self.dock.x and p.z == _self.dock.z)
        if insideBuilding and not atDock then
            logInfo(string.format("Not at dock (%d,%d) — homing from (%d,%d)...",
                _self.dock.x, _self.dock.z, p.x, p.z))
            base.returnToDockInternal()
        elseif not insideBuilding then
            if _self.role == proto.ROLE.MINER then
                logInfo(string.format(
                    "Miner rebooted outside building at %d,%d,%d — deferring return to job handler",
                    p.x, p.y, p.z))
            elseif _self.role == proto.ROLE.SUPPORT and p.y > CFG.FLOOR_Y + 20 then
                logInfo(string.format(
                    "Mining support rebooted at altitude %d,%d,%d — deferring return to job handler",
                    p.x, p.y, p.z))
            else
                logInfo(string.format(
                    "Rebooted outside building at %d,%d,%d — returning via arrivals hole",
                    p.x, p.y, p.z))
                base.returnToDock()
            end
        end
    end
    -- Startup homing may have set status to RETURNING — reset to IDLE now we're docked.
    _self.status = proto.STATUS.IDLE
    _self.jobId  = nil
    -- Face toward taxiway so the turtle is oriented consistently at its dock on boot.
    if _self.dock then move.face(W.dockFacing(_self.dock)) end
    logInfo(string.format("Ready. Fuel:%d/%d  Pos:%d,%d,%d  Dock:%s",
        fuel.level(), fuel.max(),
        _self.pos.x, _self.pos.y, _self.pos.z,
        _self.dock and ("bay ".. _self.dock.bay .." row ".. _self.dock.row) or "none"))
end

-- ─── Main Event Loop ─────────────────────────────────────────────────────────
-- Uses parallel to run the job handler and the control loop concurrently.
-- This ensures the job coroutine receives warehouse events (e.g. CHESTS_READY)
-- while the control loop still handles heartbeats and RECALL.

function base.run(jobHandler)
    -- Wall-clock heartbeat: immune to timer events being consumed by sleep() inside ensureFuel()
    local lastHeartbeatWall = os.epoch("utc")
    local lastLogFlushWall  = os.epoch("utc")
    local wakeupTimer       = os.startTimer(CFG.HEARTBEAT_INTERVAL)
    local pendingJob        = nil   -- job table waiting to be started
    local jobCo             = nil   -- running job coroutine

    -- Defined below controlLoop; forward-declared so controlLoop can call it.
    local handleControlMessage

    -- Control loop: handles heartbeat, RECALL, and JOB_ASSIGN
    local function controlLoop()
        while true do
            if fuel.isCritical() then
                fuel.ensureFuel()
                -- ensureFuel()'s sleep() calls consume timer events; restart wakeup timer
                -- so the loop doesn't block indefinitely after recovering from ERROR state.
                wakeupTimer = os.startTimer(CFG.HEARTBEAT_INTERVAL)
            end

            -- Wall-clock heartbeat check (survives timer events being swallowed by sleep())
            local now = os.epoch("utc")
            if now - lastHeartbeatWall >= CFG.HEARTBEAT_INTERVAL * 1000 then
                sendHeartbeat()
                lastHeartbeatWall = now
            end
            -- Batch-forward accumulated print() lines to server every 15 seconds.
            if now - lastLogFlushWall >= 15000 then
                flushLogQueue()
                lastLogFlushWall = now
            end

            -- Drain control messages the job runner pulled and handed to us.
            while base.hasCtrlInbox() do
                handleControlMessage(base.popCtrlInbox())
            end

            local event, p1, p2, p3, p4 = os.pullEvent()

            if event == "modem_message" then
                local parsed = type(p4) == "table" and p4 or textutils.unserialise(p4)
                if parsed then
                    local valid, msg = proto.decode(parsed)
                    if valid and (msg.to == _self.id or msg.to == "broadcast") then
                        if not handleControlMessage(msg) then
                            -- Belongs to the job runner. Hand it over instead of
                            -- dropping it — this is what stranded recalled supports.
                            if not base.ackSignal(msg) then
                                base.pushJobInbox(msg)
                            end
                        end
                    end
                end

            elseif event == "timer" and p1 == wakeupTimer then
                -- Wakeup timer fired — wall-clock check above handles actual heartbeat.
                wakeupTimer = os.startTimer(CFG.HEARTBEAT_INTERVAL)
            end
        end
    end

    -- Handle one control-plane message.
    -- Returns true if consumed, false if it belongs to the job runner.
    handleControlMessage = function(msg)
        resetMissedHeartbeats()

        if msg.type == proto.MSG.HEARTBEAT_ACK then
            -- resetMissedHeartbeats() above is the entire point of routing it here.

        elseif msg.type == proto.MSG.SIGNAL_ACK then
            base.noteSignalAck(msg)

        elseif msg.type == proto.MSG.JOB_ASSIGN and not _self.busy then
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
            if _self.busy then
                -- Set the flag and nothing else. The job runner owns the terminal
                -- report; reporting here used to clear partnerId/jobId/busy while
                -- the handler was still mid-coordination, which fired a spurious
                -- JOB_ABORT at the partner and stranded recalled mining supports.
                -- The control loop must also never navigate, or the two coroutines
                -- fight over movement.
                _self.recalled = true
                pendingJob = nil
            else
                -- Idle turtle: navigate directly.
                local insideBuilding = base.isInsideBuilding(_self.pos)
                if insideBuilding then
                    base.returnToDockInternal()
                elseif _self.pos.y >= 100 then
                    -- Turtle is at sky altitude (mine recall position) —
                    -- fly home at Y=200 via arrivals hole, not underground.
                    base.returnToDockFromSky()
                else
                    base.returnToDock()
                end
                _self.busy   = false
                _self.status = proto.STATUS.IDLE
                _self.jobId  = nil
            end

        elseif msg.type == proto.MSG.FORCE_REFUEL then
            if not _self.busy and not _self.recalled
                    and base.isInsideBuilding(_self.pos) then
                logInfo("FORCE_REFUEL received — refuelling at dock")
                if _customRefuelFn then
                    _customRefuelFn()
                else
                    fuel.dockRefuel()
                end
                -- Push fresh fuel level so fleet panel updates immediately
                comms.toServer(proto.MSG.HEARTBEAT, proto.payloadHeartbeat(
                    _self.status, fuel.level(), base.getPos(), _self.jobId))
            elseif not base.isInsideBuilding(_self.pos) then
                logWarn("FORCE_REFUEL ignored — turtle not at dock")
            end

        elseif msg.type == proto.MSG.UPDATE_ALL then
            logWarn("UPDATE_ALL received — running updater then rebooting...")
            if _self.busy and _self.jobId then
                base.sendFailed("update_all", false)
            end
            sleep(1)
            if fs.exists("updater.lua") then
                shell.run("updater")
            else
                logWarn("updater.lua not found — rebooting anyway")
                os.reboot()
            end

        else
            return false   -- job runner's message
        end
        return true
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
            elseif _self.busy then
                -- The handler returned without reporting a terminal status.
                -- The control loop used to report on our behalf the moment RECALL
                -- arrived, which tore down partnerId/jobId mid-coordination. The
                -- job runner is the only place that knows the handler is really
                -- finished, so the report happens here instead.
                base.sendFailed(
                    _self.recalled and "recalled" or "handler_returned_without_report", true)
            end
            _self.recalled = false   -- clear after job exits regardless of reason
        end
    end

    -- Run both loops in parallel so events are shared between them
    parallel.waitForAny(controlLoop, jobRunner)
end

return base
