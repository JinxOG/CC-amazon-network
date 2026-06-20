-- android_base.lua
-- Foundation for CC Android agents.
-- Handles: registration, heartbeat, modem comms via pocket ender modem on "right".

local proto = require("protocol")

local ANDROID_VERSION = "1.0.3"

local base = {}

local CFG = {
    HEARTBEAT_INTERVAL = 5,
    REGISTER_RETRIES   = 10,
    REGISTER_TIMEOUT   = 5,
}

local _self = {
    id     = nil,
    role   = proto.ROLE.ANDROID,
    status = proto.STATUS.IDLE,
    jobId  = nil,
    modem  = nil,
    pos    = { x = 0, y = 0, z = 0 },
}

-- ─── Logging ─────────────────────────────────────────────────────────────────

local function log(level, msg)
    print(string.format("[%s][%s] %s", _self.id or "?", level, msg))
end
local function logInfo(m)  log("INFO",  m) end
local function logWarn(m)  log("WARN",  m) end

-- ─── Position ────────────────────────────────────────────────────────────────

local function updatePos()
    local info = android.getSelf()
    if info then
        _self.pos = { x = math.floor(info.posX), y = math.floor(info.posY), z = math.floor(info.posZ) }
    end
end

function base.getPos()    return { x = _self.pos.x, y = _self.pos.y, z = _self.pos.z } end
function base.getSelfId() return _self.id   end
function base.getModem()  return _self.modem end

function base.setStatus(s, jobId)
    _self.status = s
    _self.jobId  = jobId or _self.jobId
end

-- ─── Comms ───────────────────────────────────────────────────────────────────

local function commsInit()
    _self.modem = peripheral.find("modem")
    if not _self.modem then
        error("No ender modem found. Equip the ender modem pocket upgrade.")
    end
    proto.openChannels(_self.modem, { proto.CH_BROADCAST, proto.CH_PRIVATE })
    logInfo("Modem ready.")
end

local function autoRefuel()
    local fuel = android.fuelLevel()
    if fuel and fuel > 100 then return end
    -- Redstone is in off-hand — swap so redstone is in main hand, refuel, swap back
    android.swapHands()
    local ok, result = pcall(android.refuel)
    android.swapHands()
    if ok then
        logInfo("Refuelled. Fuel: " .. tostring(android.fuelLevel()))
    else
        logWarn("Refuel failed: " .. tostring(result))
    end
end

local function toServer(msgType, payload)
    local msg = proto.encode(msgType, _self.id, "server", payload)
    proto.send(_self.modem, proto.CH_SERVER, msg)
end

-- ─── Registration ────────────────────────────────────────────────────────────

local function register()
    local info = android.getSelf()
    _self.id = (info and info.name ~= "" and info.name) or proto.selfId()
    logInfo("Registering as " .. _self.id .. " (ANDROID)")

    for attempt = 1, CFG.REGISTER_RETRIES do
        updatePos()
        local fuel = android.fuelLevel()
        toServer(proto.MSG.REGISTER, proto.payloadRegister(
            proto.ROLE.ANDROID, fuel, 1000, _self.pos
        ))
        local reply = proto.receive(_self.id, CFG.REGISTER_TIMEOUT)
        if reply and reply.type == proto.MSG.REGISTER_ACK then
            logInfo("Registered OK.")
            return true
        end
        logWarn(string.format("Register attempt %d/%d — no ACK", attempt, CFG.REGISTER_RETRIES))
    end
    error("Failed to register after " .. CFG.REGISTER_RETRIES .. " attempts.")
end

-- ─── Movement ────────────────────────────────────────────────────────────────

local function moveWithRetry(tx, ty, tz)
    -- Try direct path first
    autoRefuel()
    if android.moveTo(tx, ty, tz) then return true end

    -- Direct path blocked — try sky routing (climb, traverse, descend)
    updatePos()
    local skyY = math.max(ty, _self.pos.y) + 35
    logWarn(string.format("Direct path failed — trying sky route at Y=%d", skyY))

    autoRefuel()
    if not android.moveTo(_self.pos.x, skyY, _self.pos.z) then
        logWarn("Can't climb to sky — punching through roof")
        -- Break a full column upward to clear any ceiling/roof
        updatePos()
        for clearY = _self.pos.y + 1, _self.pos.y + 40 do
            pcall(android.breakBlock, _self.pos.x, clearY, _self.pos.z)
        end
        autoRefuel()
        android.moveTo(_self.pos.x, skyY, _self.pos.z)
    end

    autoRefuel()
    android.moveTo(tx, skyY, tz)

    autoRefuel()
    if android.moveTo(tx, ty, tz) then
        logInfo("Sky route complete.")
        return true
    end

    logWarn("Move failed after sky route.")
    return false
end

-- ─── Heartbeat ───────────────────────────────────────────────────────────────

local function heartbeat()
    updatePos()
    local fuel = android.fuelLevel()
    toServer(proto.MSG.HEARTBEAT, proto.payloadHeartbeat(
        _self.status, fuel, _self.pos, _self.jobId
    ))
end

-- ─── Message Handler ─────────────────────────────────────────────────────────

local _handlers = {}

function base.onMessage(msgType, fn)
    _handlers[msgType] = fn
end

local function handleMsg(msg)
    local fn = _handlers[msg.type]
    if fn then
        fn(msg)
    elseif msg.type == proto.MSG.JOB_ASSIGN then
        local job = msg.payload
        if job.jobType == "MOVE" then
            local p = job.params
            _self.status = proto.STATUS.TRAVELLING
            _self.jobId  = job.jobId
            toServer(proto.MSG.JOB_ACK, proto.payloadJobAck(job.jobId, true))
            logInfo(string.format("Moving to %.0f,%.0f,%.0f", p.x, p.y, p.z))
            local ok = moveWithRetry(p.x, p.y, p.z)
            if ok then
                _self.status = proto.STATUS.IDLE
                _self.jobId  = nil
                toServer(proto.MSG.JOB_COMPLETE, proto.payloadJobComplete(job.jobId, {}))
                logInfo("Move complete.")
            else
                _self.status = proto.STATUS.ERROR
                _self.jobId  = nil
                toServer(proto.MSG.JOB_FAILED, proto.payloadJobFailed(job.jobId, "stuck after retries"))
                logWarn("Move failed after all retries.")
            end
        end
    elseif msg.type == proto.MSG.UPDATE_ALL then
        logInfo("UPDATE_ALL received — downloading latest files...")
        local BASE = "https://raw.githubusercontent.com/JinxOG/CC-amazon-network/master/"
        local files = { "protocol.lua", "android_base.lua", "android_main.lua", "android_update.lua" }
        for _, name in ipairs(files) do
            local res = http.get(BASE .. name)
            if res then
                local f = fs.open(name, "w")
                f.write(res.readAll())
                f.close()
                res.close()
            end
        end
        logInfo("Update complete. Rebooting...")
        os.reboot()

    elseif msg.type == proto.MSG.RECALL then
        logInfo("RECALL received — going idle.")
        _self.status = proto.STATUS.IDLE
        _self.jobId  = nil
    elseif msg.type == proto.MSG.HEARTBEAT_ACK then
        -- server alive
    else
        logWarn("Unhandled message: " .. tostring(msg.type))
    end
end

-- ─── Init / Run ──────────────────────────────────────────────────────────────

function base.init()
    commsInit()
    register()
    android.changeFace("angry")
    logInfo("Android v" .. ANDROID_VERSION .. " online.")
end

function base.runHeartbeat()
    while true do
        heartbeat()
        local msg = proto.receive(_self.id, CFG.HEARTBEAT_INTERVAL)
        if msg then handleMsg(msg) end
    end
end

return base
