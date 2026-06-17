-- protocol.lua
-- Shared message protocol for the CC autonomous network.
-- Required by every computer and turtle. Load with:
--   local proto = require("protocol")

local proto = {}

proto.VERSION = "1.7.1"

-- ─── Channels ────────────────────────────────────────────────────────────────

proto.CH_SERVER    = 1    -- turtles → server
proto.CH_BROADCAST = 2    -- server → all turtles
proto.CH_PRIVATE   = 3    -- server → specific turtle (turtle filters by its own ID)
proto.CH_WAREHOUSE = 4    -- server ↔ warehouse computer
proto.CH_LOCAL     = 5    -- turtle ↔ turtle direct (short range coordination)

-- ─── Message Types ───────────────────────────────────────────────────────────

proto.MSG = {
    -- Turtle lifecycle
    REGISTER       = "REGISTER",        -- turtle → server: announce presence
    REGISTER_ACK   = "REGISTER_ACK",    -- server → turtle: registration confirmed
    HEARTBEAT      = "HEARTBEAT",       -- turtle → server: periodic alive ping
    RECALL         = "RECALL",          -- server → turtle: return to base

    -- Job flow
    JOB_ASSIGN     = "JOB_ASSIGN",      -- server → turtle: here is your job
    JOB_ACK        = "JOB_ACK",         -- turtle → server: job received
    STATUS_UPDATE  = "STATUS_UPDATE",   -- turtle → server: mid-job progress
    JOB_COMPLETE   = "JOB_COMPLETE",    -- turtle → server: finished successfully
    JOB_FAILED     = "JOB_FAILED",      -- turtle → server: failed, here's why

    -- Warehouse
    ITEM_REQUEST   = "ITEM_REQUEST",    -- turtle → warehouse: periodic queue-ping while waiting (not a pickup handshake)

    -- Position queries (used by support turtles to track their partner)
    TURTLE_QUERY   = "TURTLE_QUERY",    -- turtle → server: what is turtle X's position?
    TURTLE_INFO    = "TURTLE_INFO",     -- server → turtle: here is turtle X's state

    -- Turtle ↔ turtle direct coordination (CH_LOCAL)
    HOLE_READY     = "HOLE_READY",      -- delivery → support: I'm at the hole, come now

    -- Server → turtle heartbeat acknowledgement
    HEARTBEAT_ACK  = "HEARTBEAT_ACK",   -- server → turtle: I'm alive, you're still registered

    -- Real-time follow signals (CH_LOCAL)
    POSITION_UPDATE = "POSITION_UPDATE", -- delivery → support: here is where I just was
    ASCENDING       = "ASCENDING",       -- delivery → support: I'm going up, hold position
    DESCENDED       = "DESCENDED",       -- delivery → support: I'm back underground, resume

    -- Departure staging handshake (CH_LOCAL)
    SUPPORT_STAGED  = "SUPPORT_STAGED",  -- support → delivery: I'm 1 block behind you, descend now

    -- Return journey (CH_LOCAL)
    RETURN_TO_DOCK  = "RETURN_TO_DOCK",  -- delivery → support: I'm inside, ascend and return independently

    -- Job abort (CH_LOCAL)
    JOB_ABORT       = "JOB_ABORT",       -- delivery → support: job failed, return to dock immediately

    -- Remote dispatch (admin → server)
    JOB_REQUEST     = "JOB_REQUEST",     -- admin UI → server: submit a new delivery job

    -- Over-the-air update
    UPDATE_ALL      = "UPDATE_ALL",      -- server → all: download latest files and reboot


    -- Warehouse ↔ server ↔ turtle delivery handshake
    WAREHOUSE_QUEUED  = "WAREHOUSE_QUEUED",  -- warehouse → turtle: you're in queue at position N
    DELIVERY_ARRIVED  = "DELIVERY_ARRIVED",  -- turtle → warehouse: at destination, send chests
    CHESTS_READY      = "CHESTS_READY",      -- warehouse → turtle: N chests loaded, pull them
    CHESTS_PLACED     = "CHESTS_PLACED",     -- turtle → warehouse: chests placed, send items
    ITEMS_READY       = "ITEMS_READY",       -- warehouse → turtle: batch of items loaded, pull & fill
    BATCH_DONE        = "BATCH_DONE",        -- turtle → warehouse: batch pulled & distributed, send next
    ITEMS_DONE        = "ITEMS_DONE",        -- warehouse → turtle: all items sent, you're finished
    ITEM_COLLECTED    = "ITEM_COLLECTED",    -- turtle → warehouse: entangled chest clear, job done

    -- Mining sector handshake (miner ↔ server)
    SECTOR_REQUEST = "SECTOR_REQUEST",  -- miner → server: ready for next sector
    SECTOR_ASSIGN  = "SECTOR_ASSIGN",   -- server → miner: here is your sector
    SECTOR_SCAN    = "SECTOR_SCAN",     -- miner → server: one depth-level scan complete, here are found ores
    SECTOR_DONE    = "SECTOR_DONE",     -- miner → server: sector fully mined, here are mined ores
    MINE_COMPLETE  = "MINE_COMPLETE",   -- server → miner: all sectors exhausted, return home

    -- Mining fuel handshake (support ↔ miner, CH_LOCAL, field-only)
    FUEL_LOW    = "FUEL_LOW",    -- support → miner: I need coal
    FUEL_READY  = "FUEL_READY",  -- miner → support: inventory filled with coal, suck now
    FUEL_FILLED = "FUEL_FILLED", -- support → miner: done sucking, continue

    -- Mining recall (miner → support, CH_LOCAL)
    MINE_RECALL = "MINE_RECALL", -- miner → support: job recalled, ascend to sky and return home

    -- Admin commands (server → turtle)
    FORCE_REFUEL = "FORCE_REFUEL", -- server → idle turtle: refuel at dock now
}

-- ─── Turtle Roles ────────────────────────────────────────────────────────────

proto.ROLE = {
    DELIVERY = "DELIVERY",
    BUILDER  = "BUILDER",
    SUPPORT  = "SUPPORT",
    MINER    = "MINER",
}

-- ─── Job Types ───────────────────────────────────────────────────────────────

proto.JOB = {
    DELIVER        = "DELIVER",         -- carry items from warehouse to destination
    BUILD          = "BUILD",           -- construct a structure from blueprint
    SUPPORT_FOLLOW = "SUPPORT_FOLLOW",  -- follow a partner turtle to keep it chunk loaded
    PATROL         = "PATROL",          -- chunk-load a static region
    MINE           = "MINE",            -- scan sectors and mine ore veins
}

-- ─── Turtle Status ───────────────────────────────────────────────────────────

proto.STATUS = {
    IDLE        = "IDLE",
    TRAVELLING  = "TRAVELLING",
    LOADING     = "LOADING",
    WORKING     = "WORKING",
    RETURNING   = "RETURNING",
    ERROR       = "ERROR",
}

-- ─── Sequence Counter ────────────────────────────────────────────────────────

local _seq = 0
local function nextSeq()
    _seq = _seq + 1
    return _seq
end

-- ─── Core Encode / Decode ────────────────────────────────────────────────────

function proto.encode(msgType, from, to, payload)
    return {
        type    = msgType,
        from    = from,
        to      = to,
        seq     = nextSeq(),
        ts      = os.epoch("utc"),
        payload = payload or {},
    }
end

-- Returns true, msg on success or false, err on failure.
function proto.decode(msg)
    if type(msg) ~= "table" then
        return false, "message is not a table"
    end
    for _, field in ipairs({"type", "from", "to", "seq", "ts", "payload"}) do
        if msg[field] == nil then
            return false, "missing field: " .. field
        end
    end
    if not proto.MSG[msg.type] then
        return false, "unknown message type: " .. tostring(msg.type)
    end
    return true, msg
end

-- ─── Payload Builders ────────────────────────────────────────────────────────

function proto.payloadRegister(role, fuelLevel, fuelMax, position)
    return {
        role     = role,
        fuel     = fuelLevel,
        fuelMax  = fuelMax,
        position = position,
    }
end

function proto.payloadHeartbeat(status, fuelLevel, position, jobId)
    return {
        status   = status,
        fuel     = fuelLevel,
        position = position,
        jobId    = jobId,
        version  = proto.VERSION,
    }
end

-- params is job-specific. Always includes partnerId for the paired turtle.
--   DELIVER:        { items={[name]=count}, destination={x,y,z}, partnerId="id" }
--   BUILD:          { blueprint="name", origin={x,y,z}, facing=0, partnerId="id" }
--   SUPPORT_FOLLOW: { partnerId="id", masterJobId="job_id", fuelManage=false }
--   MINE:           { centerX=n, centerZ=n, radius=n, scanY=56, partnerId="id" }
function proto.payloadJobAssign(jobId, jobType, params)
    return {
        jobId   = jobId,
        jobType = jobType,
        params  = params,
    }
end

function proto.payloadJobAck(jobId, accepted, reason)
    return {
        jobId    = jobId,
        accepted = accepted,
        reason   = reason,
    }
end

function proto.payloadStatusUpdate(jobId, status, detail, position)
    return {
        jobId    = jobId,
        status   = status,
        detail   = detail,
        position = position,
    }
end

function proto.payloadJobComplete(jobId, result)
    return { jobId = jobId, result = result or {} }
end

function proto.payloadJobFailed(jobId, reason, recoverable)
    return {
        jobId       = jobId,
        reason      = reason,
        recoverable = recoverable or false,
    }
end

function proto.payloadItemRequest(jobId, items, pickupPoint)
    return {
        jobId       = jobId,
        items       = items,
        pickupPoint = pickupPoint,
    }
end

function proto.payloadRecall(reason)
    return { reason = reason or "server_request" }
end

function proto.payloadTurtleQuery(targetId)
    return { targetId = targetId }
end

function proto.payloadTurtleInfo(targetId, online, status, position, jobId, fuel)
    return {
        targetId = targetId,
        online   = online,
        status   = status,
        position = position,
        jobId    = jobId,
        fuel     = fuel,
    }
end

-- ─── Mining Payload Builders ─────────────────────────────────────────────────

function proto.payloadSectorRequest(jobId)
    return { jobId = jobId }
end

function proto.payloadSectorAssign(jobId, sectorX, sectorZ, scanY, surveyMode)
    return {
        jobId      = jobId,
        sectorX    = sectorX,
        sectorZ    = sectorZ,
        scanY      = scanY or 56,
        surveyMode = surveyMode == true,
    }
end

function proto.payloadSectorScan(jobId, sectorX, sectorZ, scanY, foundOres, minedOres)
    return {
        jobId      = jobId,
        sectorX    = sectorX,
        sectorZ    = sectorZ,
        scanY      = scanY,
        foundOres  = foundOres or {},
        minedOres  = minedOres or {},
    }
end

function proto.payloadSectorDone(jobId, sectorX, sectorZ, oreCount, foundOres, minedOres)
    return {
        jobId      = jobId,
        sectorX    = sectorX,
        sectorZ    = sectorZ,
        oreCount   = oreCount  or 0,
        foundOres  = foundOres or {},
        minedOres  = minedOres or {},
    }
end

-- ─── Modem Helpers ───────────────────────────────────────────────────────────

function proto.openChannels(modem, channels)
    for _, ch in ipairs(channels) do
        modem.open(ch)
    end
end

function proto.send(modem, channel, msg)
    local ok, encoded = pcall(textutils.serialise, msg)
    if not ok then return end  -- silently drop unserializable message
    modem.transmit(channel, proto.CH_SERVER, encoded)
end

-- Receive one message addressed to selfId (or "broadcast"), with optional timeout.
-- evtArg2 holds the modem side for modem_message events and the timer ID
-- for timer events; a single name avoids the misleading legacy 'side' alias.
function proto.receive(selfId, timeout)
    local timer
    if timeout then timer = os.startTimer(timeout) end

    while true do
        local event, evtArg2, ch, repCh, raw = os.pullEvent()
        -- evtArg2: modem side (modem_message) or timer ID (timer)

        if event == "modem_message" then
            local msg = type(raw) == "table" and raw or textutils.unserialise(raw)
            local ok  = msg ~= nil
            if ok and msg then
                local valid, decoded = proto.decode(msg)
                if valid and (decoded.to == selfId or decoded.to == "broadcast") then
                    return decoded
                end
            end
        elseif event == "timer" and evtArg2 == timer then
            return nil
        end
    end
end

-- ─── ID Helpers ──────────────────────────────────────────────────────────────

function proto.selfId()
    local label = os.getComputerLabel()
    if label and label ~= "" then return label end
    return "node_" .. tostring(os.getComputerID())
end

return proto
