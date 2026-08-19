-- turtle_base.lua
-- Shared foundation for all turtle roles.
-- Handles: registration, dock assignment, heartbeat, movement, fuel, routing.

local proto = require("protocol")
local W     = require("waypoints")

-- geofence.lua is not installed on every turtle role (delivery/support don't
-- ship it — see install.lua). pcall so those roles behave exactly as before.
local ok_gf, _geofence = pcall(require, "geofence")
if not ok_gf then _geofence = nil end

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
    autonomousReturn = false,  -- true while navigating home without the server (see setAutonomousReturn)
    -- Solo-miner telemetry, carried on every heartbeat. nil for every other
    -- role (nothing else calls base.setPhase), which is exactly the shape
    -- proto.payloadHeartbeat's backward-compatibility contract requires.
    phase       = nil,
    chunk       = nil,   -- { cx=, cz= } the miner is working in
    commsGap    = nil,   -- true while a deliberate modem-off window is expected
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
-- Tracked heading: 0=north(-z) 1=east(+x) 2=south(+z) 3=west(-x).
-- mine_flow's pos() hook REQUIRES this: turtle.place() drops the carried chunk
-- loader one block AHEAD, and "ahead" cannot be derived from x/y/z alone. A
-- wrong facing here puts the loader in the wrong chunk, which is the one
-- placement error that cannot be undone without a pickaxe we aren't holding.
function base.getFacing()        return _self.facing     end
function base.getDock()          return _self.dock       end
function base.getPartnerId()     return _self.partnerId  end
function base.setPartnerId(id)   _self.partnerId = id    end
function base.setCanDig(val)     _self.canDig = val      end
function base.isServerDown()     return _self.serverDown  end
function base.isRecalled()       return _self.recalled    end
function base.setRecalled(v)     _self.recalled = v       end
function base.setSkyReturn(v)    _self.inSkyReturn = v    end

-- Exempts movement from the serverDown hold below for a solo miner navigating
-- home on its own (GPS beacons, not the server). Every other role leaves this
-- false permanently, so tryMove's hold behaves exactly as it does today for
-- delivery/support/warehouse turtles.
function base.setAutonomousReturn(v) _self.autonomousReturn = v end
function base.isAutonomousReturn()   return _self.autonomousReturn end

-- Optional predicate consulted by tryMove's serverDown hold, once per sleep
-- cycle: returning true releases the hold for that move.
--
-- The hold exists so the server never loses track of a turtle it cannot talk
-- to. For a solo miner with a chunk loader placed in the world that trade goes
-- the other way: waiting out a long outage in the field leaves a chunk
-- force-loaded and the turtle stranded, and the miner can navigate home
-- perfectly well without the server (GPS comes from beacons). Nothing else
-- installs one -- delivery, support and warehouse turtles leave it nil and
-- their hold loop is exactly what it has always been.
local _serverDownEscape = nil
function base.setServerDownEscape(fn) _serverDownEscape = fn end

-- Solo-miner phase telemetry piggy-backed onto the heartbeat, so the server
-- keeps seeing the miner's phase/chunk between MINE_PHASE messages and can
-- tell a deliberate comms gap from a failure even if the MINE_PHASE report
-- itself is the message that got lost. Only the miner calls this; every other
-- role leaves all three nil, so payloadHeartbeat produces exactly the payload
-- it always has for them (pinned by tests/test_mine_phase.lua).
function base.setPhase(phase, chunk, commsGap)
    _self.phase    = phase
    _self.chunk    = chunk
    _self.commsGap = commsGap
end

-- Exposed so the miner can set/clear the anchor around placed-loader work.
-- nil on roles that don't ship geofence.lua (see the pcall require above).
base.geofence = _geofence

local _customRefuelFn = nil
function base.setRefuelFn(fn)    _customRefuelFn = fn    end

-- Optional wrapper that guarantees a pickaxe is equipped for the duration of
-- the function it is handed: wrapper(what, fn).
--
-- fuel.refuelFromChest PLACES the fuel ender chest and then digs it back up. A
-- solo miner in travel mode has chunky where the pickaxe would be, so that dig
-- silently fails and the chest is left standing in the world -- the miner can
-- then never refuel again, which is a permanent field freeze, not "item loss".
-- base.setRefuelFn already protects the FORCE_REFUEL path; this is the same
-- protection for the fuel.ensureFuel path in the control loop, which is the
-- critical one.
--
-- Only ore_turtle installs one (equipment.toRetrieveMode / retrievalSwapOut are
-- miner-only concepts). Delivery, support and warehouse turtles leave this nil
-- and ensureFuel calls refuelFromChest directly, exactly as before -- they carry
-- a permanent pickaxe (or, for support, cannot dig at all, which this wrapper
-- could not change anyway).
local _digToolWrapper = nil
function base.setDigToolWrapper(fn) _digToolWrapper = fn end

function base.isInsideBuilding(pos)
    return pos.y >= CFG.FLOOR_Y
        and pos.x >= BUILDING.minX and pos.x <= BUILDING.maxX
        and pos.z >= BUILDING.minZ and pos.z <= BUILDING.maxZ
end

-- ─── Comms ───────────────────────────────────────────────────────────────────

local comms = {}

-- The one definition of which channels this turtle listens on. comms.init and
-- base.recoverModem both open exactly this list, so a re-acquired modem can
-- never end up subscribed to a different set than the original.
local CHANNELS = { proto.CH_BROADCAST, proto.CH_PRIVATE, proto.CH_LOCAL }

-- Consecutive comms.toServer failures; reset by any successful send or by a
-- successful modem recovery.
local _sendFailures = 0
local SEND_FAILURES_BEFORE_RECOVER = 3

function comms.init()
    _self.modem = peripheral.find("modem")
    if not _self.modem then
        -- A miner rebooted inside the retrieval swap window has its modem in
        -- inventory, not equipped. Recover it rather than erroring out, which
        -- would strand the turtle in the field until a player intervened.
        local ok, equipment = pcall(require, "equipment")
        if ok and equipment then
            logWarn("No modem equipped — attempting equipment reconciliation")
            local healed, reason = equipment.reconcile()
            if healed then
                _self.modem = peripheral.find("modem")
                logInfo("Modem recovered from inventory.")
            else
                logError("Equipment reconciliation failed: " .. tostring(reason))
            end
        end
    end
    if not _self.modem then
        error("No modem found. Attach a wireless or ender modem.")
    end
    proto.openChannels(_self.modem, CHANNELS)
    logInfo("Modem ready.")
end

-- Re-acquire the modem after an equipment swap moved it, and re-open the
-- channels on it.
--
-- This is not optional bookkeeping. equipment.retrievalSwapIn puts chunky on
-- the MODEM's side, and retrievalSwapOut puts the modem back on the side
-- OPPOSITE chunky -- i.e. the side the pickaxe was on. So the modem changes
-- side on every loader retrieval. _self.modem is a wrapper bound to a side
-- name, set once in comms.init, and the channel list was opened on that
-- instance: without this the miner would go permanently deaf and mute after
-- its first retrieval (no HEARTBEAT_ACK -> serverDown, no SECTOR_ASSIGN, no
-- RECALL, no LOADER_BEACON -> the next placeLoader fails closed on
-- loader_no_beacon).
--
-- Unconditional by design. Re-finding the modem and re-opening channels that
-- may already be open is a no-op, so this is correct whether or not a
-- re-equipped modem counts as a new peripheral instance with its channels
-- closed -- a distinction that cannot be verified outside a running world.
function base.recoverModem()
    local m = peripheral.find("modem")
    if not m then
        logWarn("recoverModem: no modem equipped")
        return false
    end
    _self.modem = m
    local ok, err = pcall(proto.openChannels, m, CHANNELS)
    if not ok then
        logWarn("recoverModem: could not open channels: " .. tostring(err))
        return false
    end
    _sendFailures = 0
    return true
end

local _lastSendWarn = 0
function comms.toServer(msgType, payload)
    local msg = proto.encode(msgType, _self.id, "server", payload)
    -- A solo miner deliberately unequips its modem during the loader-retrieval
    -- swap (equipment.retrievalSwapIn: chunk loading outranks comms). That
    -- DETACHES this wrapped peripheral, and calling a detached peripheral's
    -- method RAISES rather than returning false. Unprotected, that error came
    -- out of sendHeartbeat inside controlLoop and killed the whole
    -- parallel.waitForAny runner -- i.e. the running job -- every single time a
    -- miner retrieved its loader. A send that cannot go out is not fatal for
    -- any role: the message is simply lost, exactly as if the server were not
    -- listening. Throttled warn so a genuinely broken modem is still visible
    -- without a line every heartbeat during an expected gap.
    local ok, err = pcall(proto.send, _self.modem, proto.CH_SERVER, msg)
    if ok then
        _sendFailures = 0
        return
    end
    _sendFailures = _sendFailures + 1
    local now = os.epoch("utc")
    if now - _lastSendWarn > 30000 then
        _lastSendWarn = now
        logWarn("Send failed (modem detached or missing?): " .. tostring(err))
    end
    -- Escalate rather than warning forever: repeated failures mean the wrapper
    -- is stale (a swap moved the modem to the other side) far more often than
    -- they mean the radio is broken, and warning is not a fix. Cheap and
    -- idempotent, so trying it costs nothing when the modem really is gone.
    if _sendFailures >= SEND_FAILURES_BEFORE_RECOVER then
        _sendFailures = 0
        pcall(base.recoverModem)
    end
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

-- ─── Geofence helpers ───────────────────────────────────────────────────────
-- Shared by tryMove's own dir-based guard AND bypassForward's raw turtle.
-- forward() calls below -- bypassForward turns and moves the turtle directly,
-- bypassing tryMove entirely, so it needs the identical check applied at
-- every individual step or the fence stops meaning anything once a turtle
-- (e.g. a placed chunk loader sitting right in front of the miner, which the
-- solo-miner design does on purpose) blocks the forward path.

-- Position after a single forward/back step from the CURRENT facing, without
-- mutating any state.
local function projectStep(dir)
    local nx, nz = _self.pos.x, _self.pos.z
    local sign = (dir == "forward") and 1 or -1
    if     _self.facing == 0 then nz = nz - sign
    elseif _self.facing == 1 then nx = nx + sign
    elseif _self.facing == 2 then nz = nz + sign
    else                          nx = nx - sign end
    return nx, nz
end

-- True when the fence is active and stepping `dir` from the current facing
-- would leave it. Always false when the fence is absent/inactive, so callers
-- never need to separately check isActive().
local function fenceBlocksStep(dir)
    if not (_geofence and _geofence.isActive()) then return false end
    local nx, nz = projectStep(dir)
    return not _geofence.contains(nx, nz)
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
        if fenceBlocksStep("forward") then turnRtn(); return false end
        if not turtle.forward() then turnRtn(); return false end
        applyMove("forward")
        turnRtn()

        local advanced = 0
        for _ = 1, 3 do
            if fenceBlocksStep("forward") then break end
            if turtle.forward() then
                applyMove("forward")
                advanced = advanced + 1
                if not isTurtleBlock("forward") then break end
            else
                break
            end
        end

        if advanced == 0 then
            turnRtn()
            -- Undoing the sideways step. Original code called turtle.forward()
            -- + applyMove unconditionally here (not even checking forward()'s
            -- return) -- preserved exactly when the fence isn't blocking; only
            -- skip the real move when it would breach the fence.
            if fenceBlocksStep("forward") then
                turnOut()
                return false
            end
            turtle.forward(); applyMove("forward")
            turnOut()
            return false
        end

        turnRtn()
        if not fenceBlocksStep("forward") then
            if turtle.forward() then applyMove("forward") end
        end
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
        -- This is horizontal (x/z) movement despite living inside the "vertical"
        -- bypass -- the up/down step itself never touches x/z and needs no
        -- check, but this forward advance does, same as tryStrafe above.
        local advanced = 0
        for _ = 1, 2 do
            if fenceBlocksStep("forward") then break end
            if not turtle.forward() then
                if isTurtleBlock("forward") then break end  -- another turtle, stop
                turtle.dig()                                -- terrain — dig it
                sleep(0.2)
                if fenceBlocksStep("forward") then break end
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
    -- Hold position while the server is unreachable so it does not lose track of
    -- us — except during a fixed-path sky return, or an autonomous return, where
    -- the whole point is to get home WITHOUT the server. Blocking there would
    -- strand the miner in the field for as long as the server stays down, and
    -- leave its placed loader force-loading a chunk indefinitely.
    while _self.serverDown
          and not _self.inSkyReturn
          and not _self.autonomousReturn do
        -- Escape hatch for a solo miner holding a placed loader (see
        -- base.setServerDownEscape). nil for every other role, so their loop
        -- body stays exactly `sleep(2)`. pcall'd so a faulty predicate can
        -- never break movement for the whole fleet.
        if _serverDownEscape then
            local pok, escape = pcall(_serverDownEscape)
            if pok and escape then break end
        end
        sleep(2)
    end

    -- Geofence: refuse any move that would leave the placed loader's footprint.
    -- Enforced here, at the single choke point every move passes through, so a
    -- new call site cannot bypass it. Only forward/back change x/z (and hence
    -- chunk); up/down only change y, which the chunk grid ignores, so vertical
    -- moves are never fenced. (bypassForward below has its own raw turtle.
    -- forward() calls that bypass this function entirely -- see fenceBlocksStep.)
    if (dir == "forward" or dir == "back") and fenceBlocksStep(dir) then
        local nx, nz = projectStep(dir)
        local a = _geofence.anchor()
        logWarn(string.format(
            "Geofence: refusing move to %d,%d (anchor chunk %d,%d r%d)",
            nx, nz, a.cx, a.cz, a.chunkRadius))
        return false, "geofence_breach"
    end

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
            -- Signal support to start its departure route
            logInfo("At hole — signalling support to stage...")
            local sig = proto.encode(proto.MSG.HOLE_READY, _self.id, _self.partnerId, {})
            proto.send(_self.modem, proto.CH_LOCAL, sig)

            -- Wait for support to reach staging position (1 block behind us)
            -- Loop so we don't consume unrelated messages (heartbeat ACKs etc.)
            logInfo("Waiting for SUPPORT_STAGED...")
            local deadline = os.epoch("utc") / 1000 + 60
            while os.epoch("utc") / 1000 < deadline do
                if base.isRecalled() then break end
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
            logInfo("Staged behind hole — signalling delivery to descend.")
            local sig = proto.encode(proto.MSG.SUPPORT_STAGED, _self.id, _self.partnerId, {})
            proto.send(_self.modem, proto.CH_LOCAL, sig)
        end

        -- Brief pause so delivery starts descending first (clears the hole entrance)
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

-- Slots and item names the debris sweep in refuelFromChest must never drop.
--
-- That sweep was written for support turtles, which accumulate road debris in
-- slots 1..BURN_MAX and keep nothing else there. A miner keeps its entire kit in
-- that range -- scanner, carried loader, stowed tool, and the modem during the
-- retrieval window -- so the sweep was throwing the turtle's own hardware on the
-- ground. Losing the modem is the one that bricks it: equipment.reconcile looks
-- for the modem in the inventory it was just dropped from, so Invariant B cannot
-- hold, comms.init errors, and base.init takes ore_turtle's module load down
-- with it -- skipping recoverPlacedLoader() and abandoning the placed loader.
--
-- Empty by default, so delivery and support keep exactly the behaviour they had.
local _protectedSlots = {}
local _protectedNames = {}

-- Slots are each protected item's declared home; names cover the same item after
-- it has been physically displaced into a mining slot -- dug up during movement,
-- or a retrieved loader turtle landing in the first free slot. ore_turtle
-- already learned it needs both (see its rescueProtectedItems), so the sweep
-- honours both rather than trusting slot position alone.
function base.setProtectedSlots(slots, names)
    _protectedSlots, _protectedNames = {}, {}
    for _, s in ipairs(slots or {}) do _protectedSlots[s] = true end
    for _, n in ipairs(names or {}) do _protectedNames[n] = true end
end

-- Role-installed hook that makes room for coal WITHOUT throwing anything away.
--
-- The debris sweep below is a last resort: it drops on the ground, where items
-- despawn. A role that has somewhere better to put its cargo installs it here,
-- and when the hook frees enough slots the sweep never runs at all.
--
-- This is deliberately a callback rather than a chest slot for turtle_base to
-- deploy itself. Banking cargo means placing an ender chest and digging it back
-- up, and this file already carries hard-won evidence of how badly that goes:
-- see the recovery comment further down, where both of a turtle's ender chests
-- share ONE registry name (EnderStorage separates them by colour frequency, not
-- item id), so nothing here can tell the fuel chest from the payload chest.
-- Deploying a second, name-identical chest inside this same function -- while a
-- loose one may already be in flight -- walks straight into the failure that
-- comment records: slot 15 ending with two chests and slot 16 with none.
--
-- The miner already solves all of this in ore_turtle's dumpToEC, which banks to
-- the ore chest, preserves coal, rescues displaced hardware, and guards the dock
-- station chest. The hook reaches that code from the one refuel path that does
-- not otherwise pass through it: fuel.ensureFuel() firing asynchronously from
-- the control loop.
--
-- The installed function must be safe to call with the pickaxe already held,
-- since refuelFromChest normally runs inside the dig-tool wrapper.
--
-- nil by default: delivery and support keep exactly the behaviour they have.
local _makeRoomFn = nil
function base.setMakeRoomFn(fn) _makeRoomFn = fn end

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

    -- Bank the cargo first if the role knows how, so the sweep has nothing left
    -- to throw away. Guarded by pcall: a hook that fails must not take the
    -- refuel down with it, because a turtle that cannot refuel is a worse
    -- outcome than a stack of cobblestone on the floor.
    if freeCount() < 4 and _makeRoomFn then
        local ok, err = pcall(_makeRoomFn)
        if not ok then
            logWarn("Make-room hook failed (" .. tostring(err)
                .. ") — falling back to the debris sweep")
        end
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
                if not isFuel and not _protectedSlots[s] and not _protectedNames[n] then
                    turtle.select(s)
                    -- Prefer dropping down; fall back to forward
                    if not turtle.dropDown() then turtle.drop() end
                end
            end
        end
        -- Protected hardware can hold the count below the target. That is the
        -- correct outcome -- less coal this trip beats a miner that has thrown
        -- away its scanner -- but it must not pass silently, because a miner
        -- that never frees a slot draws no coal and will be back here shortly.
        local free = freeCount()
        if free < 4 then
            logWarn(string.format(
                "Debris sweep freed only %d slot(s) — protected items left in place; "
                .. "this refuel will draw less coal than usual", free))
        else
            logInfo(string.format("Debris cleared — %d free slot(s) now available", free))
        end
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

    -- Recover the deployed chest into CHEST_SLOT, taking exactly ONE item.
    --
    -- Both of this turtle's ender chests share a single item name (EnderStorage
    -- separates them by colour frequency, not registry id), so neither this
    -- search nor getItemDetail can tell the fuel chest from the ore/delivery
    -- chest in the slot above. Two consequences, both observed:
    --
    --   * Scanning all 16 slots could "recover" the chest out of slot 16, which
    --     leaves a miner with nowhere to dump ore for the rest of the job.
    --   * The dug chest can merge into that slot's existing chest stack, and
    --     transferTo with no count then moves BOTH, emptying slot 16. Probing
    --     the field refuel showed exactly that: slot 15 ended with 2 chests and
    --     slot 16 with none.
    --
    -- So: prefer the working slots, and only ever draw from a reserved slot when
    -- it holds 2+ chests (proof ours merged in), never a lone one.
    local function chestAt(s)
        local i = turtle.getItemDetail(s)
        if i and i.name == CHEST_ITEM then return i end
        return nil
    end
    if not chestAt(CHEST_SLOT) then
        local from
        for slot = 1, CHEST_SLOT - 1 do
            if chestAt(slot) then from = slot; break end
        end
        if not from then
            for slot = CHEST_SLOT + 1, 16 do
                local i = chestAt(slot)
                if i and i.count >= 2 then from = slot; break end
            end
        end
        if from then
            turtle.select(from)
            turtle.transferTo(CHEST_SLOT, 1)
        else
            logWarn(string.format(
                "Entangled chest not recovered into slot %d — check inventory", CHEST_SLOT))
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
        return true
    end

    logWarn("Dock refuel: no coal found in station — check chest below dock!")

    -- Fall back to the turtle's own fuel ender chest.
    --
    -- dockRefuel only ever sucked from the dock station chest, so a miner
    -- carrying a full coal ender chest could not top itself up at the dock. It
    -- then cleared the flat 500-fuel pre-departure gate and flew out on fuel
    -- that could not bring it home. On 1.9.7 that stranded one miner mid-air at
    -- 0 fuel and brought a second home nearly empty.
    --
    -- MINER only, deliberately: delivery and support must stay behaviourally
    -- identical, and they are not the roles that strand thousands of blocks out.
    if _self.role ~= proto.ROLE.MINER then return false end

    -- Never dig here. refuelFromChest falls back to digging when down, up and
    -- front are all blocked, and at a dock the blocked space below is the
    -- station chest itself. Bailing out is better than breaking it.
    if turtle.detectDown() and turtle.detectUp() and turtle.detect() then
        logWarn("Fuel EC fallback skipped — no free space to deploy without digging")
        return false
    end

    logInfo("Dock chest dry — falling back to the fuel ender chest")
    local ecBefore = fuel.level()
    local target   = fuel.max() * 0.8   -- same 80% mark dockRefuel considers "full"
    for _ = 1, 8 do
        if fuel.level() >= target then break end
        if not fuel.protectedRefuelFromChest() then break end
    end
    local ecGained = fuel.level() - ecBefore
    if ecGained > 0 then
        logInfo(string.format("Fuel EC refuel +%d (now %d/%d)",
            ecGained, fuel.level(), fuel.max()))
        return true
    end
    logWarn("Fuel EC refuel yielded nothing — is the coal ender chest stocked?")
    return false
end

-- refuelFromChest, run through the installed dig-tool wrapper when there is one.
-- With no wrapper installed (delivery / support / warehouse) this is literally
-- `return fuel.refuelFromChest()`.
--
-- pcall'd because withDigTool re-raises anything the body threw after putting
-- the modem back; ensureFuel runs inside controlLoop, and an error escaping here
-- kills the whole parallel.waitForAny runner (i.e. the running job).
function fuel.protectedRefuelFromChest()
    if not _digToolWrapper then return fuel.refuelFromChest() end
    local result = false
    local ok, ran = pcall(_digToolWrapper, "critical refuel", function()
        result = fuel.refuelFromChest()
    end)
    if not ok then
        logWarn("Guarded refuel failed: " .. tostring(ran))
        return false
    end
    -- `result` is initialised to false and only ever set inside the injected
    -- body, so it already carries the right answer for both of withDigTool's
    -- paths: false if the body never ran (no pickaxe available, nothing
    -- placed), or whatever fuel.refuelFromChest() actually returned if it did.
    return result
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
        local ok = fuel.protectedRefuelFromChest()
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

-- Attempts the MINER role's BOOT registration is allowed before base.init gives
-- up and returns. ~6 * (REGISTER_TIMEOUT + 5s) = about a minute of trying.
--
-- Why only the miner, and only at boot: this loop blocking forever is correct
-- for a turtle that cannot do anything useful without the server. A solo miner
-- that reboots in the field with a chunk loader PLACED is the one exception --
-- ore_turtle's recoverPlacedLoader runs after base.init returns, so an
-- unbounded wait here means the loader is never retrieved and the miner never
-- comes home, which is exactly the no-server-contact invariant. Every other
-- role passes maxAttempts = nil and gets the original unbounded loop, so
-- delivery/support/warehouse boot behaviour is byte-for-byte unchanged.
local BOOT_REGISTER_ATTEMPTS = 6

-- Returns true once the server ACKs. Returns false only when maxAttempts is set
-- and exhausted; with maxAttempts nil it never returns false.
--
-- Deliberately does NOT set _self.serverDown on giving up. serverDown is only
-- ever cleared inside this function's success branch, and sendHeartbeat only
-- calls register() once _missedHeartbeats trips -- which never happens while
-- the server is ACKing. Setting it here could therefore latch a turtle into a
-- permanent serverDown that nothing clears if the server was in fact up.
local function register(maxAttempts)
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
            return true
        end

        if maxAttempts and attempt >= maxAttempts then
            logWarn(string.format(
                "No response from server after %d attempts — continuing unregistered. "
                .. "Heartbeats will keep retrying.", attempt))
            return false
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
        _self.status, fuel.level(), base.getPos(), _self.jobId,
        { phase = _self.phase, chunk = _self.chunk, commsGap = _self.commsGap }))
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

-- Wait for one of several message types, returning the message or nil on
-- timeout / recall. Freezes the deadline while the server is unreachable.
function base.waitForAny(types, seconds)
    local set = {}
    for _, t in ipairs(types) do set[t] = true end
    local deadline = os.epoch("utc") / 1000 + seconds
    while os.epoch("utc") / 1000 < deadline do
        if base.isRecalled() then return nil end
        if base.isServerDown() then
            deadline = os.epoch("utc") / 1000 + seconds
            sleep(2)
        else
            local msg = proto.receive(_self.id, math.max(1, deadline - os.epoch("utc") / 1000))
            if msg and set[msg.type] then return msg end
        end
    end
    return nil
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
    -- A miner's kit lives in slots 1-4, inside the debris sweep's range, so it
    -- must be protected before anything can refuel. Registered here rather than
    -- left to ore_turtle for two reasons: it has to hold on every boot including
    -- one where comms.init below fails and ore_turtle's module load never gets
    -- past base.init, and turtle_base owns the sweep so it owns the guard.
    --
    -- equipment.lua does not ship to delivery or support (see install.lua
    -- PROFILES), so this is deliberately optional -- those roles keep the
    -- unprotected sweep, which is correct for them.
    if role == proto.ROLE.MINER then
        local okEq, eq = pcall(require, "equipment")
        if okEq and eq then
            base.setProtectedSlots(
                { eq.SLOTS.SCANNER, eq.SLOTS.LOADER, eq.SLOTS.TOOL, eq.SLOTS.MODEM },
                { eq.ITEMS.SCANNER, eq.ITEMS.LOADER_TURTLE,
                  eq.ITEMS.PICKAXE, eq.ITEMS.CHUNKY, eq.ITEMS.MODEM })
            logInfo("Protected slots 1-4 — the debris sweep will not drop miner hardware")
        else
            logWarn("equipment.lua unavailable — debris sweep is UNPROTECTED on this miner")
        end
    end
    print(string.format("=== %s [%s] v%s booting ===", _self.id, role, proto.VERSION))
    comms.init()
    initPosition()
    fuel.refuel()
    -- Miner only: bounded so a field reboot with a placed loader can get to
    -- ore_turtle's recoverPlacedLoader without the server. nil (unbounded, the
    -- original behaviour) for every other role.
    register(role == proto.ROLE.MINER and BOOT_REGISTER_ATTEMPTS or nil)
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

            local event, p1, p2, p3, p4 = os.pullEvent()

            if event == "modem_message" then
                local parsed = type(p4) == "table" and p4 or textutils.unserialise(p4)
                if parsed then
                    local valid, msg = proto.decode(parsed)
                    if valid and (msg.to == _self.id or msg.to == "broadcast") then

                        -- ONLY the server's own traffic is evidence the server
                        -- is alive. Every server->turtle message carries
                        -- from = "server" (central_server.lua sendTo/
                        -- sendBroadcast are the only two senders), so this gate
                        -- is exact.
                        --
                        -- Resetting on *any* addressed message was a fleet-wide
                        -- fault, not a miner-only one: a placed chunk loader
                        -- broadcasts LOADER_BEACON to "broadcast" on CH_LOCAL
                        -- every 5s (loader_turtle.lua), every turtle opens
                        -- CH_LOCAL, and the modems are ender modems with
                        -- effectively unlimited range. MAX_MISSED=3 at a 5s
                        -- heartbeat needs 15s to trip, so one loader standing
                        -- anywhere in the world held _missedHeartbeats at 0 for
                        -- EVERY turtle. That suppressed the missed-ACK
                        -- re-registration path in sendHeartbeat -- which is the
                        -- only way a running turtle rejoins the server's
                        -- in-memory registry after a restart -- for delivery and
                        -- support too, and made base.isServerDown() permanently
                        -- false exactly when a loader was out.
                        --
                        -- Partner traffic (POSITION_UPDATE, SUPPORT_STAGED, ...)
                        -- and warehouse traffic (from = "warehouse") are not
                        -- evidence about the server either, so this gate is
                        -- strictly more correct than resetting on all of them.
                        if msg.from == "server" then
                            resetMissedHeartbeats()
                        end

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
                                pendingJob = nil
                                -- A miner's recallReturn() has to retrieve its placed
                                -- chunk loader before it can come home, and it reports
                                -- the failure itself once that is done. sendFailed here
                                -- would end the job while the loader is still standing.
                                if _self.role ~= proto.ROLE.MINER then
                                    base.sendFailed("recalled", true)
                                end
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
                        end
                    end
                end

            elseif event == "timer" and p1 == wakeupTimer then
                -- Wakeup timer fired — wall-clock check above handles actual heartbeat.
                wakeupTimer = os.startTimer(CFG.HEARTBEAT_INTERVAL)
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
