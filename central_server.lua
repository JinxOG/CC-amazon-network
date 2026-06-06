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
    -- Multi-turtle: minimum seconds between dispatching consecutive pairs.
    -- Gives the previous pair time to clear the dispatch hole and taxiway
    -- before the next pair starts their departure route.
    DISPATCH_STAGGER  = 60,
    -- Web dashboard bridge
    BRIDGE_URL        = "http://127.0.0.1:3000/update",
    BRIDGE_INTERVAL   = 2,      -- seconds between state pushes
}

-- ─── State ───────────────────────────────────────────────────────────────────

local state = {
    registry        = {},    -- [id] = turtle entry
    jobs            = {},    -- [jobId] = job entry
    log             = {},
    jobCounter      = 0,
    modem           = nil,
    lastDispatchTime = 0,   -- epoch ms of last successful pair dispatch
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
    if not turtleId or not state.registry[turtleId] then
        logWarn("sendTo: unknown turtle '" .. tostring(turtleId) .. "' — dropping " .. tostring(msgType))
        return
    end
    local msg = proto.encode(msgType, "server", turtleId, payload)
    proto.send(state.modem, proto.CH_PRIVATE, msg)
end

local function sendBroadcast(msgType, payload)
    local msg = proto.encode(msgType, "server", "broadcast", payload)
    proto.send(state.modem, proto.CH_BROADCAST, msg)
end

-- ─── Registry ────────────────────────────────────────────────────────────────

local registry = {}

-- registry.register returns (dock, reSendJob).
-- reSendJob is non-nil when a rebooted turtle had an active job — the caller
-- must send JOB_ASSIGN AFTER sending REGISTER_ACK so the turtle sets its dock
-- from the ACK before receiving the job assignment.
function registry.register(id, role, fuel, fuelMax, position, midJob)
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
        offlineSince = nil,   -- cleared on (re-)register so active turtles aren't pruned
    }
    logInfo(string.format("%s %s [%s] fuel=%d/%d dock=%s",
        isNew and "Registered" or "Re-registered", id, role, fuel, fuelMax,
        dock and ("bay"..dock.bay..dock.row) or "none"))

    -- Handle jobs currently assigned to this turtle.
    -- midJob=true: turtle was mid-job when server went down, just re-link it.
    -- midJob=false/nil: turtle actually rebooted — keep job active and flag it
    --   for re-dispatch, but do NOT call sendTo here.  The handler must send
    --   JOB_ASSIGN AFTER REGISTER_ACK so the turtle sets its dock first.
    local reSendJob = nil
    for _, job in pairs(state.jobs) do
        if job.assignedTo == id and
           (job.status == "ASSIGNED" or job.status == "IN_PROGRESS") then
            if midJob then
                -- Server was down; turtle's job coroutine is still alive and paused.
                -- Re-link so heartbeat/status tracking works. No JOB_ASSIGN needed.
                state.registry[id].status = proto.STATUS.TRAVELLING
                state.registry[id].jobId  = job.id
                logInfo(string.format("Re-linked %s to job %s at %d,%d,%d (server was down)",
                    id, job.id, position.x or 0, position.y or 0, position.z or 0))
            else
                -- Turtle rebooted — keep job IN_PROGRESS so no new pair is dispatched
                -- to the same destination.  Re-send JOB_ASSIGN after REGISTER_ACK.
                logWarn(string.format("Queuing re-send of %s to rebooted turtle %s", job.id, id))
                state.registry[id].status = proto.STATUS.TRAVELLING
                state.registry[id].jobId  = job.id
                job.status = "IN_PROGRESS"
                job.ackBy  = os.epoch("utc") + (CFG.ACK_TIMEOUT * 1000)
                reSendJob  = job
            end
        end
    end

    return dock, reSendJob
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
    t.offlineSince = nil   -- back online via heartbeat — don't prune
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
        t.status = proto.STATUS.IDLE
        t.jobId  = nil
        t.offlineSince = os.epoch("utc") / 1000   -- mark for stale-pruning
        logWarn("Turtle offline: " .. id)
        -- Do NOT release the dock here. Turtles temporarily offline (chunk unload,
        -- server reboot) should return to the same dock. Docks are released only
        -- when a turtle is permanently decommissioned (explicit recall + remove).
    end
end

function registry.checkTimeouts()
    local now = os.epoch("utc")
    for id, t in pairs(state.registry) do
        if t.online and (now - t.lastSeen) > (CFG.HEARTBEAT_TIMEOUT * 1000) then
            local jobId = t.jobId
            registry.markOffline(id)
            if jobId then
                local job = state.jobs[jobId]
                jobQueue.reassign(jobId, id, "turtle_timeout")
                t.jobId = nil

                local linkedId = job and job.linkedJob
                if linkedId then
                    local linkedJob = state.jobs[linkedId]
                    if linkedJob and (linkedJob.status == "ASSIGNED" or linkedJob.status == "IN_PROGRESS") then
                        local supportTurtle = linkedJob.assignedTo
                        linkedJob.status = "CANCELLED"
                        linkedJob.assignedTo = nil
                        if supportTurtle and state.registry[supportTurtle] then
                            state.registry[supportTurtle].status = proto.STATUS.IDLE
                            state.registry[supportTurtle].jobId  = nil
                            sendTo(supportTurtle, proto.MSG.RECALL, proto.payloadRecall("partner_timed_out"))
                        end
                        logInfo("Cancelled linked support job " .. tostring(linkedId) .. " after partner timeout")
                    end
                end
            end
        elseif not t.online then
            -- Already offline — prune if it has been offline for >5 minutes so
            -- the registry doesn't accumulate ghost turtles indefinitely.
            local offlineSince = t.offlineSince or (now / 1000)
            if not t.offlineSince then t.offlineSince = offlineSince end
            if (now / 1000) - t.offlineSince > 300 then
                state.registry[id] = nil
                logInfo("Pruned stale offline turtle: " .. id)
            end
        end
    end
end

-- ─── Persistence ─────────────────────────────────────────────────────────────

local JOB_SAVE_FILE = "jobs.dat"

local function saveJobs()
    -- Persist all active jobs (including SUPPORT_FOLLOW) so original turtles
    -- can be re-linked on server reboot. Terminal states are not worth keeping.
    local toSave = {}
    for id, job in pairs(state.jobs) do
        local active = job.status == "PENDING"
                    or job.status == "ASSIGNED"
                    or job.status == "IN_PROGRESS"
        if active then
            toSave[id] = job
        end
    end
    local ok, err = pcall(function()
        local data = textutils.serialise({
            jobs       = toSave,
            jobCounter = state.jobCounter,
        })
        local f = fs.open("jobs.tmp", "w")
        if not f then error("could not open jobs.tmp for writing") end
        f.write(data)
        f.close()
        if fs.exists(JOB_SAVE_FILE) then fs.delete(JOB_SAVE_FILE) end
        fs.move("jobs.tmp", JOB_SAVE_FILE)
    end)
    if not ok then logWarn("saveJobs failed: " .. tostring(err)) end
end

local function loadJobs()
    if not fs.exists(JOB_SAVE_FILE) then return end
    local f = fs.open(JOB_SAVE_FILE, "r")
    if not f then return end
    local raw  = f.readAll(); f.close()
    local data = textutils.unserialise(raw)
    if type(data) ~= "table" then return end

    state.jobCounter = data.jobCounter or 0
    local nRestored  = 0
    for id, job in pairs(data.jobs or {}) do
        if job.assignedTo then
            -- Job was mid-flight. Keep assignedTo so registry.register can
            -- re-link the turtle when it reconnects with midJob=true.
            -- Turtles are paused (serverDown mode) so no new pair is needed.
            job.status = "IN_PROGRESS"
            state.jobs[id] = job
            nRestored = nRestored + 1
            logInfo(string.format("Restored job %s [%s] assignedTo=%s — waiting for turtle to reconnect",
                id, job.type, job.assignedTo))
        elseif job.type ~= proto.JOB.SUPPORT_FOLLOW
            and job.type ~= proto.JOB.PATROL then
            -- Job was queued but not yet assigned — dispatch fresh
            job.status = "PENDING"
            state.jobs[id] = job
            nRestored = nRestored + 1
            logInfo(string.format("Restored job %s [%s] as PENDING (was unassigned)", id, job.type))
        end
    end
    if nRestored > 0 then
        logInfo(string.format("Loaded %d job(s) from disk", nRestored))
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
    saveJobs()
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
    saveJobs()   -- persist assignedTo so server reboot can re-link, not re-queue
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

    -- Complete the linked support job too so it isn't left dangling as an active
    -- job (which would keep its destination marked busy and block re-dispatch).
    if job.linkedJob then
        local linked = state.jobs[job.linkedJob]
        if linked then
            linked.status = JOB_STATUS.COMPLETE
            -- Do NOT reset the support turtle's registry entry here.
            -- The support turtle may still be physically returning to dock.
            -- It will send its own JOB_COMPLETE message which will free it correctly.
        end
    end
    saveJobs()
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
    saveJobs()
end

function jobQueue.reassign(jobId, fromId, reason)
    local job = state.jobs[jobId]
    if not job then return end
    job.status     = JOB_STATUS.PENDING
    job.assignedTo = nil
    job.updatedAt  = os.epoch("utc")
    jobQueue._hist(jobId, "reassign", string.format("from=%s reason=%s", fromId, reason or "?"))
    logWarn(string.format("Job %s back to queue (from %s: %s)", jobId, fromId, reason or "?"))
    saveJobs()
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
            -- BUG #13: Don't re-queue while the turtle may still be travelling —
            -- that would let a second pair target the same destination (destinationBusy
            -- only checks ASSIGNED/IN_PROGRESS jobs). Instead, RECALL the turtle and
            -- leave the job ASSIGNED. The turtle will return and send JOB_FAILED,
            -- which re-queues the job via the existing failure handler.
            if job.assignedTo then
                sendTo(job.assignedTo, proto.MSG.RECALL, proto.payloadRecall("ack_timeout"))
            end
            -- Stop firing this timeout repeatedly while we wait for the recall.
            job.ackBy = nil
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

-- Returns true if another job is already ASSIGNED or IN_PROGRESS to the same (x, z).
local function destinationBusy(dest)
    if not dest then return false end
    for _, j in pairs(state.jobs) do
        if (j.status == JOB_STATUS.ASSIGNED or j.status == JOB_STATUS.IN_PROGRESS)
           and j.params and j.params.destination
           and j.params.destination.x == dest.x
           and j.params.destination.z == dest.z then
            return true
        end
    end
    return false
end

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

    -- Multi-turtle stagger: only dispatch one new pair per DISPATCH_STAGGER window.
    -- This prevents two pairs from colliding at the single-block dispatch hole.
    local now = os.epoch("utc")
    local msSinceLast = now - state.lastDispatchTime
    if msSinceLast < CFG.DISPATCH_STAGGER * 1000 then
        local waitSec = math.ceil((CFG.DISPATCH_STAGGER * 1000 - msSinceLast) / 1000)
        logInfo(string.format("Dispatch stagger: next pair in %ds", waitSec))
        return
    end

    for _, job in ipairs(workerJobs) do
        -- Skip if another delivery is already active to this exact destination
        if job.params and destinationBusy(job.params.destination) then
            logInfo(string.format("Skip %s — destination already has an active delivery", job.id))
            -- continue loop; another pending job may have a different destination
        else

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

            -- Link the two jobs
            job.linkedJob = supportJobId

            -- Assign worker
            jobQueue.assign(job.id, worker.id)
            sendTo(worker.id, proto.MSG.JOB_ASSIGN, proto.payloadJobAssign(
                job.id, job.type,
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
                    destination = job.params.destination,
                }
            ))

            logInfo(string.format("Dispatched %s->%s with support %s->%s",
                job.id, worker.id, supportJobId, support.id))

            -- Record dispatch time — stagger next pair
            state.lastDispatchTime = os.epoch("utc")

            -- Only dispatch ONE pair per tick (stagger enforced above for subsequent ticks)
            return
        end

        end -- destination-busy else
    end
end

-- ─── Message Handlers ────────────────────────────────────────────────────────

local handlers = {}

handlers[proto.MSG.REGISTER] = function(msg)
    local p    = msg.payload
    local dock, reSendJob = registry.register(msg.from, p.role, p.fuel, p.fuelMax, p.position, p.midJob)
    -- REGISTER_ACK FIRST — turtle must receive dock assignment before any job.
    sendTo(msg.from, proto.MSG.REGISTER_ACK, {
        ok       = true,
        serverTs = os.epoch("utc"),
        dock     = dock,
    })
    -- Re-send job to rebooted turtle AFTER the ACK so it has its dock set.
    if reSendJob then
        sendTo(msg.from, proto.MSG.JOB_ASSIGN,
            proto.payloadJobAssign(reSendJob.id, reSendJob.type, reSendJob.params))
        logInfo(string.format("Re-sent job %s to %s (after REGISTER_ACK)", reSendJob.id, msg.from))
    end
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
    pcall(dispatcher.tick)
end

handlers[proto.MSG.JOB_FAILED] = function(msg)
    local p = msg.payload
    jobQueue.fail(p.jobId, p.reason, p.recoverable)
    -- Job may have re-queued for retry — try to dispatch right away
    pcall(dispatcher.tick)
end

-- JOB_REQUEST handler registered after 'server' is declared (see below)

handlers[proto.MSG.ITEM_REQUEST] = function(msg)
    logInfo(string.format("Item request from %s (job %s)", msg.from, msg.payload.jobId))
    -- Forward with the real turtle ID so the warehouse knows who to talk to
    local fwd = proto.encode(proto.MSG.ITEM_REQUEST, msg.from, "warehouse", msg.payload)
    proto.send(state.modem, proto.CH_WAREHOUSE, fwd)
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
        logInfo(string.format("[ROUTE] %s job=%s → %s", msg.type, tostring(p.jobId), job.assignedTo))
        sendTo(job.assignedTo, msg.type, p)
    else
        logWarn(string.format("[ROUTE] %s job=%s — NOT FOUND, sending JOB_ABORT to warehouse",
            msg.type, tostring(p.jobId)))
        -- Warehouse has a stale job the server no longer knows about (e.g. after reboot).
        -- Tell it to abort immediately so it can move on to the next queue entry.
        local abort = proto.encode(proto.MSG.JOB_ABORT, "server", "warehouse", { jobId = p.jobId })
        proto.send(state.modem, proto.CH_WAREHOUSE, abort)
    end
end
handlers[proto.MSG.WAREHOUSE_QUEUED] = fwdToTurtle
handlers[proto.MSG.CHESTS_READY]     = fwdToTurtle
handlers[proto.MSG.ITEMS_READY]      = fwdToTurtle
handlers[proto.MSG.ITEMS_DONE]       = fwdToTurtle
-- Warehouse can proactively recall a turtle on a timeout-abort (carries jobId so
-- it routes by jobId → assignedTo, same as the other warehouse→turtle messages).
handlers[proto.MSG.RECALL]           = fwdToTurtle

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

-- Registered here so server.submitJob is in scope
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

-- ─── Console Command Handler ─────────────────────────────────────────────────
-- Type commands directly into the server terminal while it runs.
--
--   job <x> <y> <z>   — queue a single delivery job
--   stress             — queue 8 test jobs in a ring ~90 blocks out
--   recall             — recall all turtles
--   jobs               — print pending/active job count
--   help               — list commands

local STRESS_DESTINATIONS = {
    { x = 143, y = 64, z = -2903, label = "N"  },
    { x = 143, y = 64, z = -2723, label = "S"  },
    { x = 233, y = 64, z = -2813, label = "E"  },
    { x =  53, y = 64, z = -2813, label = "W"  },
    { x = 207, y = 64, z = -2877, label = "NE" },
    { x =  79, y = 64, z = -2877, label = "NW" },
    { x = 207, y = 64, z = -2749, label = "SE" },
    { x =  79, y = 64, z = -2749, label = "SW" },
}

local consoleBuffer = ""

local function handleConsoleChar(ch)
    if ch == "\n" or ch == "\r" then return end
    consoleBuffer = consoleBuffer .. ch
end

local function handleConsoleEnter()
    local line = consoleBuffer:match("^%s*(.-)%s*$")  -- trim
    consoleBuffer = ""
    if line == "" then return end

    local parts = {}
    for w in line:gmatch("%S+") do parts[#parts+1] = w end
    local cmd = parts[1] and parts[1]:lower() or ""

    if cmd == "help" then
        print("Commands:")
        print("  job <x> <y> <z>  queue one delivery job")
        print("  stress           queue 8 test jobs (~90 blocks out)")
        print("  fueltest         queue job ~80 blocks out to test refueling")
        print("  recall           recall all turtles")
        print("  jobs             show job counts")

    elseif cmd == "job" then
        local x, y, z = tonumber(parts[2]), tonumber(parts[3]), tonumber(parts[4])
        if not (x and y and z) then
            print("Usage: job <x> <y> <z>")
        else
            local id = server.submitJob("DELIVER", {
                items       = { ["minecraft:cobblestone"] = 64 },
                destination = { x = x, y = y, z = z },
            }, 5)
            print("Queued " .. id .. " -> " .. x .. "," .. y .. "," .. z)
        end

    elseif cmd == "stress" then
        print("Queuing " .. #STRESS_DESTINATIONS .. " stress-test jobs...")
        for i, dest in ipairs(STRESS_DESTINATIONS) do
            local id = server.submitJob("DELIVER", {
                items       = { ["minecraft:cobblestone"] = 64 },
                destination = { x = dest.x, y = dest.y, z = dest.z },
            }, 5)
            print(string.format("  [%d] %s queued -> %s (%d,%d,%d)",
                i, id, dest.label, dest.x, dest.y, dest.z))
        end
        print("Done. Watch the admin monitor.")

    elseif cmd == "fueltest" then
        -- Queue one delivery job ~80 blocks out to test in-field refueling.
        local dest = { x = 143, y = 64, z = -2893 }  -- ~80 blocks north
        local id = server.submitJob("DELIVER", {
            items       = { ["minecraft:cobblestone"] = 1 },
            destination = dest,
        }, 5)
        print(string.format("Fuel test job queued: %s -> (%d,%d,%d)", id, dest.x, dest.y, dest.z))

    elseif cmd == "recall" then
        server.recallAll("console_recall")
        print("Recalled all turtles.")

    elseif cmd == "update" then
        local base = "https://raw.githubusercontent.com/JinxOG/CC-amazon-network/master/"
        local files = {
            "protocol.lua", "waypoints.lua",
            "turtle_base.lua", "delivery_turtle.lua",
            "support_turtle.lua", "warehouse.lua",
            "central_server.lua", "admin_ui.lua",
        }
        print("Run this on each computer to update:")
        print("")
        for _, f in ipairs(files) do
            print("rm " .. f .. " && wget " .. base .. f .. " " .. f)
        end
        print("")
        print("Then reboot each computer.")
        print("(On turtles, delivery_turtle.lua / support_turtle.lua")
        print(" should be saved as startup.lua)")
        print("")
        print("Updating server now...")
        for _, f in ipairs({"protocol.lua","waypoints.lua","central_server.lua"}) do
            if fs.exists(f) then fs.delete(f) end
            shell.run("wget", base .. f, f)
        end
        print("Server files updated — reboot to apply.")

    elseif cmd == "jobs" then
        local pending, active, done = 0, 0, 0
        for _, job in pairs(state.jobs) do
            if     job.status == JOB_STATUS.PENDING     then pending = pending + 1
            elseif job.status == JOB_STATUS.ASSIGNED
                or job.status == JOB_STATUS.IN_PROGRESS then active  = active  + 1
            else                                              done    = done    + 1
            end
        end
        print(string.format("Jobs — pending:%d  active:%d  done:%d", pending, active, done))

    else
        print("Unknown command: " .. line .. "  (type 'help')")
    end
end

-- ─── Main Loop ───────────────────────────────────────────────────────────────

function server.run()
    state.modem = peripheral.find("modem")
    if not state.modem then
        error("No modem found. Attach a wireless or ender modem.")
    end
    proto.openChannels(state.modem, {
        proto.CH_SERVER, proto.CH_BROADCAST, proto.CH_PRIVATE, proto.CH_WAREHOUSE,
    })
    -- ── Bridge command dedup (BUG #11) ────────────────────────────────────────
    -- If the CC server's HTTP response is lost in transit, the bridge has already
    -- cleared its queue, but a re-send could double-dispatch a command. Guard with
    -- a small cache keyed on the server-assigned timestamp + command type.
    local recentCmds = {}
    local function isDuplicate(cmd)
        local key = (cmd.ts or 0) .. ":" .. (cmd.type or "")
        if recentCmds[key] then return true end
        recentCmds[key] = true
        -- Prune entries older than 60s (cmd.ts is a Unix ms timestamp from server.js).
        local now = os.epoch("utc") / 1000
        for k, _ in pairs(recentCmds) do
            local ts = (tonumber(k:match("^(%d+)")) or 0) / 1000
            if now - ts > 60 then recentCmds[k] = nil end
        end
        return false
    end

    -- ── Bridge command handler ────────────────────────────────────────────────
    -- Called for each command the dashboard queued since the last push.
    -- Commands arrive in the response body of the /update POST.
    local function handleBridgeCommand(cmd)
        if isDuplicate(cmd) then
            logInfo("Bridge cmd: duplicate ignored (" .. tostring(cmd.type) .. ")")
            return
        end
        local t = cmd.type or ""
        local p = cmd.params or {}
        logInfo("Bridge cmd: " .. t)

        if t == "DISPATCH_DELIVERY" then
            local x = tonumber(p.x)
            local y = tonumber(p.y) or 67
            local z = tonumber(p.z)
            if not (x and z) then
                logWarn("DISPATCH_DELIVERY: missing x/z coords — ignored")
                return
            end
            local id = server.submitJob(proto.JOB.DELIVER, {
                items       = { ["minecraft:cobblestone"] = 1 },
                destination = { x = x, y = y, z = z },
            }, 5)
            logInfo(string.format("Dashboard dispatch: %s → %d,%d,%d", id, x, y, z))

        elseif t == "RECALL" then
            local tid = p.turtleId
            if tid and state.registry[tid] then
                sendTo(tid, proto.MSG.RECALL, proto.payloadRecall(p.reason or "admin_recall"))
                logInfo("Dashboard recall: " .. tid)
            else
                logWarn("RECALL: turtle not found: " .. tostring(tid))
            end

        elseif t == "RECALL_ALL" then
            server.recallAll(p.reason or "admin_recall")

        elseif t == "UPDATE_ALL" then
            sendBroadcast(proto.MSG.UPDATE_ALL, {})
            logInfo("Dashboard: UPDATE_ALL broadcast sent")
            -- Flag for self-update; handled in the main loop OUTSIDE the
            -- parallel.waitForAny(pushToBridge, sleep(5)) timeout so the
            -- updater is not killed mid-download.
            logWarn("UPDATE_ALL — self-update queued...")
            pendingUpdate = true

        elseif t == "CANCEL_JOB" then
            local jobId = p.jobId
            if jobId then
                local ok, reason = server.cancelJob(jobId)
                if ok then
                    logInfo("Dashboard cancelled job: " .. tostring(jobId))
                else
                    logWarn("Dashboard cancel " .. tostring(jobId) .. ": " .. tostring(reason))
                end
            end

        elseif t == "SET_IDLE" then
            local tid = p.turtleId
            if tid and state.registry[tid] then
                state.registry[tid].status = proto.STATUS.IDLE
                state.registry[tid].jobId  = nil
                logInfo("Dashboard set idle: " .. tid)
            else
                logWarn("SET_IDLE: turtle not found: " .. tostring(tid))
            end

        elseif t == "RESET_STATUS" then
            local count = 0
            for _, tr in pairs(state.registry) do
                tr.status = proto.STATUS.IDLE
                tr.jobId  = nil
                count = count + 1
            end
            logInfo(string.format("Dashboard: reset %d turtle(s) to IDLE", count))

        elseif t == "CLEAR_JOBS" then
            local count = 0
            for _, job in pairs(state.jobs) do
                -- Recall any turtle currently assigned to this job
                if job.assignedTo and
                   (job.status == "ASSIGNED" or job.status == "IN_PROGRESS") then
                    sendTo(job.assignedTo, proto.MSG.RECALL, proto.payloadRecall("jobs_cleared"))
                    local tr = state.registry[job.assignedTo]
                    if tr then tr.status = proto.STATUS.IDLE; tr.jobId = nil end
                    -- BUG #12: also recall the paired support turtle, otherwise it
                    -- keeps flying with no delivery partner.
                    if job.linkedJob then
                        local linked = state.jobs[job.linkedJob]
                        if linked and linked.assignedTo then
                            sendTo(linked.assignedTo, proto.MSG.RECALL, proto.payloadRecall("jobs_cleared"))
                            local st = state.registry[linked.assignedTo]
                            if st then st.status = proto.STATUS.IDLE; st.jobId = nil end
                        end
                    end
                end
                count = count + 1
            end
            state.jobs = {}
            saveJobs()
            logInfo(string.format("Dashboard: cleared %d job(s)", count))

        elseif t == "REMOVE_TURTLE" then
            local tid = p.turtleId
            local tr  = state.registry[tid]
            if not tr then
                logWarn("REMOVE_TURTLE: turtle not found: " .. tostring(tid))
                return
            end
            -- Cancel active job and recall the linked partner
            for _, job in pairs(state.jobs) do
                if job.assignedTo == tid and
                   (job.status == "ASSIGNED" or job.status == "IN_PROGRESS") then
                    job.status = "CANCELLED"
                    if job.linkedJob then
                        local linked = state.jobs[job.linkedJob]
                        if linked and linked.assignedTo then
                            sendTo(linked.assignedTo, proto.MSG.RECALL,
                                proto.payloadRecall("turtle_removed"))
                            local st = state.registry[linked.assignedTo]
                            if st then st.status = proto.STATUS.IDLE; st.jobId = nil end
                            linked.status = "CANCELLED"
                        end
                    end
                end
            end
            W.releaseDock(tr.role, tid)
            state.registry[tid] = nil
            logInfo("Dashboard removed turtle from fleet: " .. tid)

        elseif t == "REASSIGN_BAY" then
            local tid = p.turtleId
            local bay = tonumber(p.bay)
            local tr  = state.registry[tid]
            if not tr then
                logWarn("REASSIGN_BAY: turtle not found: " .. tostring(tid))
                return
            end
            if not bay then
                logWarn("REASSIGN_BAY: invalid bay number for " .. tostring(tid))
                return
            end
            -- Cancel any active job so it is not re-dispatched when the turtle
            -- reboots. Also recall the partner if one exists.
            for _, job in pairs(state.jobs) do
                if job.assignedTo == tid and
                   (job.status == "ASSIGNED" or job.status == "IN_PROGRESS") then
                    job.status = "CANCELLED"
                    if job.linkedJob then
                        local linked = state.jobs[job.linkedJob]
                        if linked and linked.assignedTo then
                            sendTo(linked.assignedTo, proto.MSG.RECALL,
                                proto.payloadRecall("partner_bay_reassigned"))
                            local st = state.registry[linked.assignedTo]
                            if st then st.status = proto.STATUS.IDLE; st.jobId = nil end
                            linked.status = "CANCELLED"
                        end
                    end
                end
            end
            -- Recall the turtle so it stops whatever it is doing and idles.
            sendTo(tid, proto.MSG.RECALL, proto.payloadRecall("bay_reassigned"))
            tr.jobId = nil
            -- Reassign the dock slot.
            local newDock = W.assignDockAt(tr.role, tid, bay)
            if newDock then
                tr.dock = newDock
                logInfo(string.format("Dashboard reassigned %s → bay %d%s (recalled)",
                    tid, newDock.bay, newDock.row))
            else
                logWarn(string.format("REASSIGN_BAY: no free slot at bay %d for %s [%s]",
                    bay, tid, tr.role))
            end

        else
            logWarn("Unknown bridge command: " .. tostring(t))
        end
    end

    -- Set by UPDATE_ALL handler; acted on in the main loop outside the
    -- parallel.waitForAny timeout so the updater is not killed mid-download.
    local pendingUpdate = false

    -- ── Bridge push ───────────────────────────────────────────────────────────
    -- Pushes state to the Node bridge every BRIDGE_INTERVAL seconds.
    -- The bridge returns any dashboard commands queued since the last push
    -- in the response body — we read and execute them here.
    local function pushToBridge()
        local turtles = {}
        for id, t in pairs(state.registry) do
            turtles[id] = {
                role   = t.role,
                status = t.status,
                fuel   = t.fuel,
                jobId  = t.jobId,
                online = t.online,
                dock   = t.dock and string.format("bay%d%s", t.dock.bay, t.dock.row) or nil,
                dockX  = t.dock and t.dock.x or nil,
                dockZ  = t.dock and t.dock.z or nil,
                dockJX = t.dock and t.dock.junction and t.dock.junction.x or nil,
                x      = t.position and t.position.x or nil,
                y      = t.position and t.position.y or nil,
                z      = t.position and t.position.z or nil,
            }
        end
        local jobs = {}
        for id, j in pairs(state.jobs) do
            table.insert(jobs, {
                id          = id,
                status      = j.status,
                assignedTo  = j.assignedTo,
                type        = j.type,
                linkedJob   = j.linkedJob,
                destination = j.params and j.params.destination or nil,
            })
        end
        local payload = textutils.serialiseJSON({ turtles = turtles, jobs = jobs, version = proto.VERSION })
        local resp, err = http.post(CFG.BRIDGE_URL, payload, { ["Content-Type"] = "application/json" })
        if resp then
            -- Read the body BEFORE closing — the bridge sends pending dashboard
            -- commands in the response (commands: [...]).  Previously we called
            -- resp.close() immediately and silently discarded all of them.
            local body = resp.readAll()
            resp.close()
            local ok2, data = pcall(textutils.unserialiseJSON, body)
            if ok2 and type(data) == "table" and type(data.commands) == "table" then
                for _, cmd in ipairs(data.commands) do
                    pcall(handleBridgeCommand, cmd)
                end
            end
        else
            logWarn("Bridge push failed: " .. tostring(err))
        end
    end

    logInfo(string.format("Central server online v%s  ID: %s", proto.VERSION, proto.selfId()))
    W.loadDockAssignments()
    loadJobs()
    print("Console ready. Type 'help' for commands.")

    local dispatchTimer = os.startTimer(CFG.DISPATCH_INTERVAL)
    local healthTimer   = os.startTimer(CFG.HEARTBEAT_TIMEOUT)
    local bridgeTimer   = os.startTimer(CFG.BRIDGE_INTERVAL)

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

            elseif p1 == bridgeTimer then
                -- PERF #55: wrap push in a parallel timeout so a slow/hung bridge
                -- cannot stall the main event loop indefinitely.
                parallel.waitForAny(
                    function() pcall(pushToBridge) end,
                    function() sleep(5) end   -- abandon push if it takes >5s
                )
                bridgeTimer = os.startTimer(CFG.BRIDGE_INTERVAL)

                -- Run updater AFTER the parallel context exits so it is not
                -- killed by the 5s timeout above.
                if pendingUpdate then
                    pendingUpdate = false
                    logWarn("UPDATE_ALL — updating server in 3s...")
                    sleep(3)
                    if fs.exists("updater.lua") then shell.run("updater") else os.reboot() end
                end

            end

        elseif event == "char" then
            -- OPT #64: pcall so a throw from handleConsoleChar can't kill server.run
            pcall(handleConsoleChar, p1)

        elseif event == "key" then
            -- p1 = key code; 28 = Enter, 14 = Backspace
            -- OPT #64: pcall so a throw from handleConsoleEnter can't kill server.run
            if p1 == keys.enter then
                pcall(handleConsoleEnter)
            elseif p1 == keys.backspace then
                if #consoleBuffer > 0 then
                    consoleBuffer = consoleBuffer:sub(1, -2)
                end
            end
        end
    end
end

server.run()
