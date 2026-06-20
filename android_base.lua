-- android_base.lua
-- Foundation for CC Android agents.
-- Handles: registration, heartbeat, modem comms via pocket ender modem on "right".

local proto = require("protocol")

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
        _self.pos = { x = math.floor(info.x), y = math.floor(info.y), z = math.floor(info.z) }
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
    _self.modem = peripheral.wrap("right")
    if not _self.modem then
        error("No modem on right side. Equip an ender modem pocket upgrade in main hand.")
    end
    proto.openChannels(_self.modem, { proto.CH_BROADCAST, proto.CH_PRIVATE })
    logInfo("Modem ready.")
end

local function toServer(msgType, payload)
    local msg = proto.encode(msgType, _self.id, "server", payload)
    proto.send(_self.modem, proto.CH_SERVER, msg)
end

-- ─── Registration ────────────────────────────────────────────────────────────

local function register()
    _self.id = proto.selfId()
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
    logInfo("Android online.")
end

function base.runHeartbeat()
    while true do
        heartbeat()
        local msg = proto.receive(_self.id, CFG.HEARTBEAT_INTERVAL)
        if msg then handleMsg(msg) end
    end
end

return base
