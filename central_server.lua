-- central_server.lua
-- Core OS for the autonomous network.
-- Handles: turtle registry, job queue, pair dispatching, heartbeat monitoring.

local proto = require("protocol")
local W     = require("waypoints")

-- ─── Config ──────────────────────────────────────────────────────────────────

local CFG = {
    HEARTBEAT_TIMEOUT = 120,    -- seconds before a turtle is considered offline
    ACK_TIMEOUT       = 10,     -- seconds to wait for JOB_ACK before reassigning
    DISPATCH_INTERVAL = 2,      -- seconds between dispatcher ticks
    MAX_JOB_RETRIES   = 3,
    LOG_MAX_LINES     = 500,
}

-- ─── State ───────────────────────────────────────────────────────────────────

local state = {
    registry   = {},    -- [id] = turtle entry
    jobs       = {},    -- [jobId] = job entry
    log        = {},
    jobCounter = 0,
    modem      = nil,
}

-- ─── Logging ─────────────────────────────────────────────────────────────────

local function log(level, msg)
    local entry = { ts = os.epoch("utc"), level = level, msg = msg }
    table.insert(state.log, entry)
    if #state.log > CFG.LOG_MAX_LINES then table.remove(state.log, 1) end
    print(string.format("[%s] %s", level, msg))
end
local function logInfo(m)  log("INFO",  m) end
local function logWarn(m)  log("WARN",  m) end
local function logError(m) log("ERROR", m) end

-- ─── Helpers ─────────────────────────────────────────────────────────────────

local function newJobId()
    state.jobCounter = state.jobCounter + 1
    return string.format("job_%04d", state.jobCounter)
end

local function sendTo(turtleId, msgType, payload)
    local msg = proto.encode(msgType, "server", turtleId, payload)
    proto.send(state.modem, proto.CH_PRIVATE, msg)
end

local function sendBroadcast(msgType, payload)
    local msg = proto.encode(msgType, "server", "broadcast", payload)
    proto.send(state.modem, proto.CH_BROADCAST, msg)
end

-- ─── Registry ────────────────────────────────────────────────────────────────

local registry = {}

function registry.register(id, role, fuel, fuelMax, position)
    local isNew = state.registry[id] == nil

    -- Assign or recover a dock
    local dockRole = (role == proto.ROLE.SUPPORT) and "SUPPORT" or "DELIVERY"
    local dock = nil

    -- Always try to recover existing dock first
    dock = W.getDockFor(dockRole, id)

    -- If no existing dock (new turtle or dock was released), assign a fresh one
    if not dock then
        dock = W.assignDock(dockRole, id)
        if dock then
            logInfo(string.format("Assigned dock: bay %d row %s to %s", dock.bay, dock.row, id))
        else
            logWarn("No free docks for " .. id .. " [" .. role .. "] — depot full!")
        end
    end

    state.registry[id] = {
        id       = id,
        role     = role,
        dock     = dock,
        status   = proto.STATUS.IDLE,
        fuel     = fuel,
        fuelMax  = fuelMax,
        position = position,
        jobId    = nil,
        lastSeen = os.epoch("utc"),
        online   = true,
    }
    logInfo(string.format("%s %s [%s] fuel=%d/%d dock=%s",
        isNew and "Registered" or "Re-registered", id, role, fuel, fuelMax,
        dock and ("bay"..dock.bay..dock.row) or "none"))

    -- Re-queue any jobs that were assigned to this turtle before it rebooted
    -- so they get dispatched immediately instead of waiting for ACK timeout
    for _, job in pairs(state.jobs) do
        if job.assignedTo == id and
           (job.status == "ASSIGNED" or job.status == "IN_PROGRESS") then
            logWarn("Re-queuing " .. job.id .. " — turtle " .. id .. " rebooted")
            job.status     = "PENDING"
            job.assignedTo = nil
            job.linkedJob  = nil
        end
    end

    return dock
end

function registry.update(id, status, fuel, position, jobId)
    local t = state.registry[id]
    if not t then logWarn("Heartbeat from unknown turtle: " .. id) return end
    t.status   = status   or t.status
    t.fuel     = fuel     or t.fuel
    t.position = position or t.position
    t.jobId    = jobId
    t.lastSeen = os.epoch("utc")
    t.online   = true
end

function registry.getIdle(role)
    local result = {}
    for _, t in pairs(state.registry) do
        if t.online and t.status == proto.STATUS.IDLE
                    and (role == nil or t.role == role)
                    and (t.fuel or 0) > 0 then
            table.insert(result, t)
        end
    end
    -- Prefer highest fuel
    table.sort(result, function(a, b) return a.fuel > b.fuel end)
    return result
end

function registry.markOffline(id)
    local t = state.registry[id]
    if t and t.online then
        t.online = false
        logWarn("Turtle offline: " .. id)
        -- Release dock so another turtle can use it
        if t.dock then
            local dockRole = (t.role == proto.ROLE.SUPPORT) and "SUPPORT" or "DELIVERY"
            W.releaseDock(dockRole, id)
        end
    end
end

function registry.checkTimeouts()
    local now = os.epoch("utc")
    for id, t in pairs(state.registry) do
        if t.online and (now - t.lastSeen) > (CFG.HEARTBEAT_TIMEOUT * 1000) then
            registry.markOffline(id)
            if t.jobId then
                jobQueue.reassign(t.jobId, id, "turtle_timeout")
                t.jobId = nil
            end
        end
    end
end

-- ─── Job Queue ───────────────────────────────────────────────────────────────

local JOB_STATUS = {
    PENDING     = "PENDING",
    ASSIGNED    = "ASSIGNED",
    IN_PROGRESS = "IN_PROGRESS",
    COMPLETE    = "COMPLETE",
    FAILED      = "FAILED",
    CANCELLED   = "CANCELLED",
}

jobQueue = {}

function jobQueue.add(jobType, params, priority)
    local id  = newJobId()
    local now = os.epoch("utc")
    state.jobs[id] = {
        id         = id,
        type       = jobType,
        priority   = priority or 5,
        status     = JOB_STATUS.PENDING,
        assignedTo = nil,
        linkedJob  = nil,   -- support job ID paired with this worker job
        retries    = 0,
        createdAt  = now,
        updatedAt  = now,
        ackBy      = nil,
        params     = params,
        history    = {},
    }
    jobQueue._hist(id, "created", "priority=" .. (priority or 5))
    logInfo(string.format("Job queued: %s [%s] p=%d", id, jobType, priority or 5))
    return id
end

function jobQueue._hist(jobId, event, detail)
    local job = state.jobs[jobId]
    if not job then return end
    table.insert(job.history, { ts = os.epoch("utc"), event = event, detail = detail or "" })
end

function jobQueue.assign(jobId, turtleId)
    local job    = state.jobs[jobId]
    local turtle = state.registry[turtleId]
    if not job or not turtle then return false end

    job.status     = JOB_STATUS.ASSIGNED
    job.assignedTo = turtleId
    job.updatedAt  = os.epoch("utc")
    job.ackBy      = os.epoch("utc") + (CFG.ACK_TIMEOUT * 1000)
    turtle.status  = proto.STATUS.TRAVELLING
    turtle.jobId   = jobId
    jobQueue._hist(jobId, "assigned", "to=" .. turtleId)
    return true
end

function jobQueue.acknowledge(jobId, turtleId, accepted, reason)
    local job = state.jobs[jobId]
    if not job then return end
    if accepted then
        job.status    = JOB_STATUS.IN_PROGRESS
        job.updatedAt = os.epoch("utc")
        jobQueue._hist(jobId, "ack", turtleId)
        logInfo(string.format("Job %s accepted by %s", jobId, turtleId))
    else
        logWarn(string.format("Job %s rejected by %s: %s", jobId, turtleId, reason or "?"))
        jobQueue.reassign(jobId, turtleId, "rejected")
    end
end

function jobQueue.progress(jobId, status, detail)
    local job = state.jobs[jobId]
    if not job then return end
    job.updatedAt = os.epoch("utc")
    jobQueue._hist(jobId, "progress", string.format("[%s] %s", status, detail or ""))
end

function jobQueue.complete(jobId)
    local job = state.jobs[jobId]
    if not job then return end
    job.status    = JOB_STATUS.COMPLETE
    job.updatedAt = os.epoch("utc")
    jobQueue._hist(jobId, "complete", "")
    logInfo("Job complete: " .. jobId)

    local t = state.registry[job.assignedTo or ""]
    if t then t.status = proto.STATUS.IDLE; t.jobId = nil end

    -- If this is a worker job, also complete its linked support job
    if job.linkedJob then
        local supportJob = state.jobs[job.linkedJob]
        if supportJob and supportJob.status == JOB_STATUS.IN_PROGRESS then
            jobQueue.complete(job.linkedJob)
        end
    end
end

function jobQueue.fail(jobId, reason, recoverable)
    local job = state.jobs[jobId]
    if not job then return end
    job.updatedAt = os.epoch("utc")
    jobQueue._hist(jobId, "failed", reason or "unknown")

    local t = state.registry[job.assignedTo or ""]
    if t then t.status = proto.STATUS.IDLE; t.jobId = nil end

    if recoverable and job.retries < CFG.MAX_JOB_RETRIES then
        job.retries    = job.retries + 1
        job.status     = JOB_STATUS.PENDING
        job.assignedTo = nil
        logWarn(string.format("Job %s retry %d/%d: %s", jobId, job.retries, CFG.MAX_JOB_RETRIES, reason or "?"))
    else
        job.status = JOB_STATUS.FAILED
        logError("Job permanently failed: " .. jobId .. " (" .. (reason or "?") .. ")")
    end
end

function jobQueue.reassign(jobId, fromId, reason)
    local job = state.jobs[jobId]
    if not job then return end
    job.status     = JOB_STATUS.PENDING
    job.assignedTo = nil
    job.updatedAt  = os.epoch("utc")
    jobQueue._hist(jobId, "reassign", string.format("from=%s reason=%s", fromId, reason or "?"))
    logWarn(string.format("Job %s back to queue (from %s: %s)", jobId, fromId, reason or "?"))
end

function jobQueue.getPending()
    local pending = {}
    for _, job in pairs(state.jobs) do
        if job.status == JOB_STATUS.PENDING then
            table.insert(pending, job)
        end
    end
    table.sort(pending, function(a, b)
        if a.priority ~= b.priority then return a.priority < b.priority end
        return a.createdAt < b.createdAt
    end)
    return pending
end

function jobQueue.checkAckTimeouts()
    local now = os.epoch("utc")
    for _, job in pairs(state.jobs) do
        if job.status == JOB_STATUS.ASSIGNED and job.ackBy and now > job.ackBy then
            logWarn(string.format("ACK timeout: job %s from %s", job.id, job.assignedTo))
            local t = state.registry[job.assignedTo or ""]
            if t then t.status = proto.STATUS.IDLE; t.jobId = nil end
            jobQueue.reassign(job.id, job.assignedTo, "ack_timeout")
        end
    end
end

-- ─── Role Map ────────────────────────────────────────────────────────────────

local JOB_ROLE = {
    [proto.JOB.DELIVER]        = proto.ROLE.DELIVERY,
    [proto.JOB.BUILD]          = proto.ROLE.BUILDER,
    [proto.JOB.SUPPORT_FOLLOW] = proto.ROLE.SUPPORT,
    [proto.JOB.PATROL]         = proto.ROLE.SUPPORT,
}

-- ─── Dispatcher ──────────────────────────────────────────────────────────────
-- Every tick, try to pair each pending worker job with an idle support turtle.
-- Both must be available before either gets assigned.

local dispatcher = {}

function dispatcher.tick()
    local pending = jobQueue.getPending()
    if #pending == 0 then return end

    -- Filter out support jobs (they are created internally, not dispatched here)
    local workerJobs = {}
    for _, job in ipairs(pending) do
        if job.type ~= proto.JOB.SUPPORT_FOLLOW and job.type ~= proto.JOB.PATROL then
            table.insert(workerJobs, job)
        end
    end

    for _, job in ipairs(workerJobs) do
        local role     = JOB_ROLE[job.type]
        local workers  = registry.getIdle(role)
        local supports = registry.getIdle(proto.ROLE.SUPPORT)

        if #workers > 0 and #supports > 0 then
            local worker  = workers[1]
            local support = supports[1]

            -- Create the paired support job
            local supportJobId = jobQueue.add(proto.JOB.SUPPORT_FOLLOW, {
                partnerId   = worker.id,
                masterJobId = job.id,
            }, job.priority)

            -- Link the two jobs so completing the worker job finishes the support job
            job.linkedJob = supportJobId

            -- Assign worker
            jobQueue.assign(job.id, worker.id)
            sendTo(worker.id, proto.MSG.JOB_ASSIGN, proto.payloadJobAssign(
                job.id, job.type,
                -- Merge partnerId into the existing params
                (function()
                    local p = {}
                    for k, v in pairs(job.params) do p[k] = v end
                    p.partnerId = support.id
                    return p
                end)()
            ))

            -- Assign support
            jobQueue.assign(supportJobId, support.id)
            sendTo(support.id, proto.MSG.JOB_ASSIGN, proto.payloadJobAssign(
                supportJobId, proto.JOB.SUPPORT_FOLLOW, {
                    partnerId   = worker.id,
                    masterJobId = job.id,
                    destination = job.params.destination,  -- so support can navigate directly
                }
            ))

            logInfo(string.format("Dispatched %s→%s with support %s→%s",
                job.id, worker.id, supportJobId, support.id))

            -- Auto-mock: if this job was flagged while PENDING, send ITEM_READY once assigned
            if job.mockOnReady then
                job.mockOnReady = nil
                -- Small delay so turtle has time to send ITEM_REQUEST first
                os.startTimer(3)
                -- Store pending mock so the timer handler can fire it
                state.pendingMock = { jobId = job.id, turtleId = worker.id }
                logInfo("Auto-mock queued for " .. job.id)
            end
        end
    end
end

-- ─── Message Handlers ────────────────────────────────────────────────────────

local handlers = {}

handlers[proto.MSG.REGISTER] = function(msg)
    local p    = msg.payload
    local dock = registry.register(msg.from, p.role, p.fuel, p.fuelMax, p.position)
    sendTo(msg.from, proto.MSG.REGISTER_ACK, {
        ok       = true,
        serverTs = os.epoch("utc"),
        dock     = dock,   -- nil if depot full, turtle will log a warning
    })
    -- Immediately try to dispatch any pending jobs now that a new turtle is online
    pcall(dispatcher.tick)
end

handlers[proto.MSG.HEARTBEAT] = function(msg)
    local p = msg.payload
    local known = state.registry[msg.from] ~= nil
    if known then
        registry.update(msg.from, p.status, p.fuel, p.position, p.jobId)
        -- ACK only known turtles so their missed counter resets and they never re-register spuriously
        sendTo(msg.from, proto.MSG.HEARTBEAT_ACK, { ts = os.epoch("utc") })
    else
        -- Unknown turtle (server restarted) — no ACK means missed counter runs up → auto re-registers
        logWarn("Heartbeat from unknown turtle: " .. msg.from .. " (will re-register shortly)")
    end
end

handlers[proto.MSG.JOB_ACK] = function(msg)
    local p = msg.payload
    jobQueue.acknowledge(p.jobId, msg.from, p.accepted, p.reason)
end

handlers[proto.MSG.STATUS_UPDATE] = function(msg)
    local p = msg.payload
    registry.update(msg.from, p.status, nil, p.position, p.jobId)
    jobQueue.progress(p.jobId, p.status, p.detail)
end

handlers[proto.MSG.JOB_COMPLETE] = function(msg)
    jobQueue.complete(msg.payload.jobId)
end

handlers[proto.MSG.JOB_FAILED] = function(msg)
    local p = msg.payload
    jobQueue.fail(p.jobId, p.reason, p.recoverable)
end

handlers[proto.MSG.JOB_REQUEST] = function(msg)
    local p    = msg.payload
    local dest = p.destination
    if not dest or not dest.x or not dest.y or not dest.z then
        logWarn("JOB_REQUEST from " .. msg.from .. " missing destination — ignored")
        return
    end
    local id = server.submitJob("DELIVER", {
        items       = p.items or { ["minecraft:cobblestone"] = 1 },
        destination = { x = dest.x, y = dest.y, z = dest.z },
    }, p.priority or 1)
    logInfo(string.format("Remote job from %s → %s (%d,%d,%d)",
        msg.from, id, dest.x, dest.y, dest.z))
end

handlers[proto.MSG.ITEM_REQUEST] = function(msg)
    logInfo(string.format("Item request from %s (job %s)", msg.from, msg.payload.jobId))
    local fwd = proto.encode(proto.MSG.ITEM_REQUEST, "server", "warehouse", msg.payload)
    proto.send(state.modem, proto.CH_WAREHOUSE, fwd)
end

handlers[proto.MSG.ITEM_READY] = function(msg)
    local p   = msg.payload
    local job = state.jobs[p.jobId]
    if job and job.assignedTo then
        sendTo(job.assignedTo, proto.MSG.ITEM_READY, p)
    end
end

-- ── Warehouse delivery handshake forwarding ───────────────────────────────────
-- Turtle → warehouse (forward to CH_WAREHOUSE)
local function fwdToWarehouse(msg)
    local fwd = proto.encode(msg.type, msg.from, "warehouse", msg.payload)
    proto.send(state.modem, proto.CH_WAREHOUSE, fwd)
end
handlers[proto.MSG.DELIVERY_ARRIVED] = fwdToWarehouse
handlers[proto.MSG.CHESTS_PLACED]    = fwdToWarehouse
handlers[proto.MSG.BATCH_DONE]       = fwdToWarehouse
handlers[proto.MSG.ITEM_COLLECTED]   = fwdToWarehouse

-- Warehouse → turtle (forward to turtle by jobId → assignedTo)
local function fwdToTurtle(msg)
    local p   = msg.payload
    local job = state.jobs[p.jobId]
    if job and job.assignedTo then
        sendTo(job.assignedTo, msg.type, p)
    end
end
handlers[proto.MSG.WAREHOUSE_QUEUED] = fwdToTurtle
handlers[proto.MSG.CHESTS_READY]     = fwdToTurtle
handlers[proto.MSG.ITEMS_READY]      = fwdToTurtle
handlers[proto.MSG.ITEMS_DONE]       = fwdToTurtle

handlers[proto.MSG.TURTLE_QUERY] = function(msg)
    local targetId = msg.payload.targetId
    local t        = state.registry[targetId]
    if t then
        sendTo(msg.from, proto.MSG.TURTLE_INFO, proto.payloadTurtleInfo(
            targetId, t.online, t.status, t.position, t.jobId, t.fuel))
    else
        sendTo(msg.from, proto.MSG.TURTLE_INFO, proto.payloadTurtleInfo(
            targetId, false, nil, nil, nil, nil))
    end
end

-- ─── Public API ──────────────────────────────────────────────────────────────

local server = {}

function server.submitJob(jobType, params, priority)
    local id = jobQueue.add(jobType, params, priority)
    -- Dispatch immediately rather than waiting for the next 2s timer tick
    pcall(dispatcher.tick)
    return id
end

function server.cancelJob(jobId)
    local job = state.jobs[jobId]
    if not job then return false, "not found" end
    if job.status == JOB_STATUS.COMPLETE or job.status == JOB_STATUS.FAILED then
        return false, "already finished"
    end
    if job.assignedTo then
        sendTo(job.assignedTo, proto.MSG.RECALL, proto.payloadRecall("job_cancelled"))
        local t = state.registry[job.assignedTo]
        if t then t.status = proto.STATUS.IDLE; t.jobId = nil end
    end
    job.status = JOB_STATUS.CANCELLED
    jobQueue._hist(jobId, "cancelled", "")
    -- Cancel linked support job too
    if job.linkedJob then server.cancelJob(job.linkedJob) end
    logInfo("Job cancelled: " .. jobId)
    return true
end

function server.recallAll(reason)
    sendBroadcast(proto.MSG.RECALL, proto.payloadRecall(reason or "server_recall"))
    logWarn("Recalled all turtles: " .. (reason or "server_recall"))
end

function server.getState() return state end
function server.getLogs()  return state.log end

-- ─── Main Loop ───────────────────────────────────────────────────────────────

function server.run()
    state.modem = peripheral.find("modem")
    if not state.modem then
        error("No modem found. Attach a wireless or ender modem.")
    end
    proto.openChannels(state.modem, {
        proto.CH_SERVER, proto.CH_BROADCAST, proto.CH_PRIVATE, proto.CH_WAREHOUSE,
    })
    logInfo("Central server online. ID: " .. proto.selfId())

    local dispatchTimer = os.startTimer(CFG.DISPATCH_INTERVAL)
    local healthTimer   = os.startTimer(CFG.HEARTBEAT_TIMEOUT)

    while true do
        local event, p1, p2, p3, p4 = os.pullEvent()

        if event == "modem_message" then
            local parsed = textutils.unserialise(p4)
            if parsed then
                local valid, msg = proto.decode(parsed)
                if valid then
                    local handler = handlers[msg.type]
                    if handler then
                        local ok, err = pcall(handler, msg)
                        if not ok then logError("Handler [" .. msg.type .. "]: " .. tostring(err)) end
                    end
                end
            end

        elseif event == "timer" then
            if p1 == dispatchTimer then
                local ok, err = pcall(function()
                    jobQueue.checkAckTimeouts()
                    dispatcher.tick()
                end)
                if not ok then logError("Dispatcher: " .. tostring(err)) end
                dispatchTimer = os.startTimer(CFG.DISPATCH_INTERVAL)

            elseif p1 == healthTimer then
                local ok, err = pcall(registry.checkTimeouts)
                if not ok then logError("Health check: " .. tostring(err)) end
                healthTimer = os.startTimer(CFG.HEARTBEAT_TIMEOUT)

            elseif state.pendingMock then
                -- Fire auto-mock ITEM_READY after the small delay
                local m = state.pendingMock
                state.pendingMock = nil
                local msg = proto.encode(proto.MSG.ITEM_READY, "server", m.turtleId,
                    { jobId = m.jobId, loaded = {} })
                proto.send(state.modem, proto.CH_PRIVATE, msg)
                logInfo("Auto-mock ITEM_READY sent to " .. m.turtleId)
            end
        end
    end
end

return server
