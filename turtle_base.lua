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
    canDig     = true,   -- false for turtles without a pickaxe (e.g. support)
    serverDown = false,  -- true while server is unreachable; pauses movement + freezes deadlines
    recalled   = false,  -- set by RECALL handler; causes waitForAny to exit the job runner
}

-- ─── Logging ─────────────────────────────────────────────────────────────────

local function log(level, msg)
    print(string.format("[%s][%s] %s", _self.id or "?", level, msg))
end
local function logInfo(m)  log("INFO",  m) end
local function logWarn(m)  log("WARN",  m) end
local function logError(m) log("ERROR", m) end

-- ─── Public Accessors ────────────────────────────────────────────────────────

function base.getSelfId()        return _self.id         end
function base.getModem()         return _self.modem      end
function base.getPos()           return { x=_self.pos.x, y=_self.pos.y, z=_self.pos.z } end
function base.getDock()          return _self.dock       end
function base.getPartnerId()     return _self.partnerId  end
function base.setPartnerId(id)   _self.partnerId = id    end
function base.setCanDig(val)     _self.canDig = val      end
function base.isServerDown()     return _self.serverDown end
function base.isRecalled()       return _self.recalled   end

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

    -- Delivery turtles broadcast their previous position so support can follow 1 block behind
    if _self.partnerId and _self.role == proto.ROLE.DELIVERY and _self.modem then
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
    while _self.serverDown do sleep(2) end

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
function base.depart()
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

    if _self.role == proto.ROLE.DELIVERY then
        -- ── Delivery departure ────────────────────────────────────────────────
        -- Navigate to hole entrance, signal support, wait for support to stage
        -- behind us, THEN descend so they go down together.

        local route = W.departureRoute(_self.dock)
        local ok, err = move.followRoute(route)
        if not ok then return false, "departure route failed: " .. (err or "?") end

        if _self.partnerId then
            -- Signal support to start its departure route
            logInfo("At hole — signalling support to stage...")
            local sig = proto.encode(proto.MSG.HOLE_READY, _self.id, _self.partnerId, {})
            proto.send(_self.modem, proto.CH_LOCAL, sig)

            -- Wait for support to reach staging position (1 block behind us)
            -- Loop so we don't consume unrelated messages (heartbeat ACKs etc.)
            logInfo("Waiting for SUPPORT_STAGED...")
            local deadline = os.epoch("utc") / 1000 + 60
            while os.epoch("utc") / 1000 < deadline do
                local msg = proto.receive(_self.id, 5)
                if not msg then
                    -- timeout tick — keep waiting
                elseif msg.type == proto.MSG.SUPPORT_STAGED and msg.from == _self.partnerId then
                    logInfo("Support staged — descending together.")
                    break
                end
                -- Any other message (HEARTBEAT_ACK etc.) is silently ignored here;
                -- controlLoop also receives it via parallel and handles it there.
            end
        end

        -- Descend through dispatch hole
        logInfo("Descending dispatch hole...")
        for _ = 1, 10 do
            move.down()
            if _self.pos.y <= W.WORLD_EXIT.y then break end
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
            logInfo("Staged behind hole — signalling delivery to descend.")
            local sig = proto.encode(proto.MSG.SUPPORT_STAGED, _self.id, _self.partnerId, {})
            proto.send(_self.modem, proto.CH_LOCAL, sig)
        end

        -- Brief pause so delivery starts descending first (clears the hole entrance)
        sleep(1)

        -- Move to hole and descend
        move.to(W.DISPATCH_HOLE.x, W.DISPATCH_HOLE.y, W.DISPATCH_HOLE.z)
        logInfo("Descending dispatch hole...")
        for _ = 1, 10 do
            move.down()
            if _self.pos.y <= W.WORLD_EXIT.y then break end
        end
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

    -- Support turtles top up fuel at dock station
    if not _self.canDig then
        base.fuel.dockRefuel()
    end

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

local function sendHeartbeat()
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
    -- Delivery turtles reserve slot 16 for the delivery ender chest,
    -- so their fuel ender chest lives in slot 15 instead.
    if role == proto.ROLE.DELIVERY then
        CHEST_SLOT = 15
        logInfo("Fuel ender chest slot set to 15 (delivery role)")
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
        local insideBuilding = p.y >= CFG.FLOOR_Y
            and p.x >= BUILDING.minX and p.x <= BUILDING.maxX
            and p.z >= BUILDING.minZ and p.z <= BUILDING.maxZ
        local atDock = (p.x == _self.dock.x and p.z == _self.dock.z)
        if insideBuilding and not atDock then
            logInfo(string.format("Not at dock (%d,%d) — homing from (%d,%d)...",
                _self.dock.x, _self.dock.z, p.x, p.z))
            base.returnToDockInternal()
        elseif not insideBuilding then
            -- Rebooted outside the building (e.g. at a destination, or underground
            -- mid-delivery). Use the full return route: descend → arrivals hole → dock.
            logInfo(string.format("Rebooted outside building at %d,%d,%d — returning via arrivals hole",
                p.x, p.y, p.z))
            base.returnToDock()
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
                            if _self.busy then
                                -- Signal the job runner to exit its current wait loop.
                                -- The job runner will clean up (pick up EC etc.) then
                                -- call returnToDock itself. Control loop must NOT also
                                -- navigate or the two coroutines fight over movement.
                                _self.recalled = true
                                base.sendFailed("recalled", true)
                                pendingJob = nil
                            else
                                -- Idle turtle: navigate directly.
                                local insideBuilding = _self.pos.y >= CFG.FLOOR_Y
                                    and _self.pos.x >= BUILDING.minX and _self.pos.x <= BUILDING.maxX
                                    and _self.pos.z >= BUILDING.minZ and _self.pos.z <= BUILDING.maxZ
                                if insideBuilding then
                                    base.returnToDockInternal()
                                else
                                    base.returnToDock()
                                end
                                _self.busy   = false
                                _self.status = proto.STATUS.IDLE
                                _self.jobId  = nil
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
            _self.recalled = false   -- clear after job exits regardless of reason
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
