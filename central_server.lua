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
    -- Minimum fuel a MINER must have before it will be dispatched.
    -- Prevents turtles from being assigned when they can't complete departure.
    MIN_DISPATCH_FUEL = 500,
    -- Web dashboard bridge
    BRIDGE_URL        = "http://127.0.0.1:3000/update",
    BRIDGE_INTERVAL   = 3,      -- seconds between state pushes
}

-- ─── State ───────────────────────────────────────────────────────────────────

local state = {
    registry        = {},    -- [id] = turtle entry
    jobs            = {},    -- [jobId] = job entry
    log             = {},
    jobCounter      = 0,
    modem           = nil,
    lastDispatchTime = 0,   -- epoch ms of last successful pair dispatch
    miningZones     = {},   -- [jobId] = { pending={sectors}, total=n, done=n, scanY=n }
    persistentZones = {},   -- [zoneKey] = { bounds, total, doneSectors, oreFound, oreMined, … }
    turtleLogs      = {},   -- [id] = ring buffer of {ts, msg} entries from TURTLE_LOG messages
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
    local reSendJob    = nil
    local reSendSector = nil
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
                -- If a MINE sector was in-flight, replay SECTOR_ASSIGN so the miner
                -- doesn't time out waiting for it and needlessly return to surface.
                if job.type == proto.JOB.MINE then
                    local mz = state.miningZones[job.id]
                    local la = mz and mz.lastAssignments and mz.lastAssignments[id]
                    if la then
                        reSendSector = { jobId = job.id, x = la.x, z = la.z,
                                         isSurvey = la.isSurvey }
                    end
                end
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

    return dock, reSendJob, reSendSector
end

function registry.update(id, status, fuel, position, jobId, version)
    local t = state.registry[id]
    if not t then logWarn("Heartbeat from unknown turtle: " .. id) return end
    -- Guard: if the server has an ASSIGNED/IN_PROGRESS job for this turtle, don't
    -- let a stale IDLE heartbeat (sent before JOB_ASSIGN is received) overwrite
    -- the server-side assignment and re-open the turtle for a second dispatch.
    local activeJob = t.jobId and state.jobs[t.jobId]
    local serverHasActive = activeJob and
        (activeJob.status == "ASSIGNED" or activeJob.status == "IN_PROGRESS")
    if serverHasActive then
        if status == proto.STATUS.IDLE then status = nil end  -- keep server status
        if jobId  == nil              then jobId  = t.jobId end  -- keep server jobId
    end
    t.status   = status   or t.status
    t.fuel     = fuel     or t.fuel
    t.position = position or t.position
    t.jobId    = jobId
    t.lastSeen = os.epoch("utc")
    t.online   = true
    t.offlineSince = nil   -- back online via heartbeat — don't prune
    if version then t.version = version end
end

function registry.getIdle(role)
    local result = {}
    for _, t in pairs(state.registry) do
        local fuelOk = (t.fuel or 0) > 0
        -- MINER turtles need enough fuel to actually depart; exclude low-fuel miners
        -- so they don't get dispatched and fail immediately at the departure check.
        if t.role == proto.ROLE.MINER and (t.fuel or 0) < CFG.MIN_DISPATCH_FUEL then
            fuelOk = false
        end
        if t.online and t.status == proto.STATUS.IDLE
                    and (role == nil or t.role == role)
                    and fuelOk then
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
            local pruneAfter = (t.role == proto.ROLE.MINER or t.role == proto.ROLE.SUPPORT) and 1800 or 300
            if (now / 1000) - t.offlineSince > pruneAfter then
                state.registry[id] = nil
                logInfo("Pruned stale offline turtle: " .. id)
            end
        end
    end
end

-- ─── Persistence ─────────────────────────────────────────────────────────────

local JOB_SAVE_FILE        = "jobs.dat"
local ZONE_SAVE_FILE       = "mine_zones.dat"
local ACTIVE_ZONES_FILE    = "active_zones.dat"
local ORE_THRESHOLDS_FILE  = "ore_thresholds.dat"
local oreThresholds = {}  -- [name] = minimum_count

local function loadOreThresholds()
    if not fs.exists(ORE_THRESHOLDS_FILE) then return end
    local f = fs.open(ORE_THRESHOLDS_FILE, "r")
    if not f then return end
    local raw = f.readAll(); f.close()
    if raw == "" then return end
    local data = textutils.unserialise(raw)
    if type(data) == "table" then
        oreThresholds = data
        local n = 0; for _ in pairs(data) do n = n + 1 end
        if n > 0 then logInfo(string.format("Loaded %d ore threshold(s)", n)) end
    end
end

local function saveOreThresholds()
    local f = fs.open(ORE_THRESHOLDS_FILE, "w")
    if not f then logWarn("saveOreThresholds: could not open file"); return end
    f.write(textutils.serialise(oreThresholds)); f.close()
end

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
        -- Keep a backup of the previous good file so a crash between delete and
        -- move can't destroy both copies simultaneously.
        if fs.exists(JOB_SAVE_FILE) then
            if fs.exists(JOB_SAVE_FILE .. ".bak") then fs.delete(JOB_SAVE_FILE .. ".bak") end
            fs.copy(JOB_SAVE_FILE, JOB_SAVE_FILE .. ".bak")
            fs.delete(JOB_SAVE_FILE)
        end
        fs.move("jobs.tmp", JOB_SAVE_FILE)
    end)
    if not ok then logWarn("saveJobs failed: " .. tostring(err)) end
end

local function loadJobs()
    local raw = ""
    if fs.exists(JOB_SAVE_FILE) then
        local f = fs.open(JOB_SAVE_FILE, "r")
        if f then raw = f.readAll(); f.close() end
    elseif fs.exists(JOB_SAVE_FILE .. ".bak") then
        logWarn("loadJobs: " .. JOB_SAVE_FILE .. " missing — loading from backup")
        local f = fs.open(JOB_SAVE_FILE .. ".bak", "r")
        if f then raw = f.readAll(); f.close() end
    else
        return
    end
    if raw == "" then return end
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
            -- Job was queued but not yet assigned — dispatch fresh.
            -- MINE jobs are included so SECTOR_REQUEST can re-link the zone.
            job.status = "PENDING"
            state.jobs[id] = job
            nRestored = nRestored + 1
            logInfo(string.format("Restored job %s [%s] as PENDING (was unassigned)", id, job.type))
        end
    end
    if nRestored > 0 then
        logInfo(string.format("Loaded %d job(s) from disk", nRestored))
        -- Apply dispatch stagger on restart: prevents fresh pairs from going out
        -- before turtles have had time to re-register and re-link to their jobs.
        state.lastDispatchTime = os.epoch("utc")
        logInfo(string.format("Startup stagger active — no new dispatch for %ds", CFG.DISPATCH_STAGGER))
    end
end

-- ─── Persistent Mine Zone Store ──────────────────────────────────────────────
-- Keyed by grid-snapped bounds string "bx1,bz1,bx2,bz2".
-- Survives server restarts; re-dispatching the same physical area resumes from
-- where it left off (skipping sectors that already completed).

local function computeZoneKey(bx1, bz1, bx2, bz2)
    return string.format("%d,%d,%d,%d", bx1, bz1, bx2, bz2)
end

local function savePersistentZones()
    local ok, err = pcall(function()
        local data = textutils.serialise(state.persistentZones)
        local f = fs.open("zones.tmp", "w")
        if not f then error("could not open zones.tmp for writing") end
        f.write(data); f.close()
        if fs.exists(ZONE_SAVE_FILE) then
            if fs.exists(ZONE_SAVE_FILE .. ".bak") then fs.delete(ZONE_SAVE_FILE .. ".bak") end
            fs.copy(ZONE_SAVE_FILE, ZONE_SAVE_FILE .. ".bak")
            fs.delete(ZONE_SAVE_FILE)
        end
        fs.move("zones.tmp", ZONE_SAVE_FILE)
    end)
    if not ok then logWarn("savePersistentZones failed: " .. tostring(err)) end
end

local function loadPersistentZones()
    local raw = ""
    if fs.exists(ZONE_SAVE_FILE) then
        local f = fs.open(ZONE_SAVE_FILE, "r")
        if f then raw = f.readAll(); f.close() end
    elseif fs.exists(ZONE_SAVE_FILE .. ".bak") then
        logWarn("loadPersistentZones: " .. ZONE_SAVE_FILE .. " missing — loading from backup")
        local f = fs.open(ZONE_SAVE_FILE .. ".bak", "r")
        if f then raw = f.readAll(); f.close() end
    else
        return
    end
    if raw == "" then return end
    local data = textutils.unserialise(raw)
    if type(data) ~= "table" then return end
    state.persistentZones = data
    local n = 0
    for _ in pairs(data) do n = n + 1 end
    if n > 0 then logInfo(string.format("Loaded %d persistent mine zone(s)", n)) end
end

-- ─── Active Mining Zone Persistence ──────────────────────────────────────────
-- Saves the runtime state.miningZones to disk so that a server restart can
-- replay SECTOR_ASSIGN to reconnecting mid-job miners.

local function saveMiningZones()
    local ok, err = pcall(function()
        local data = textutils.serialise(state.miningZones)
        local f = fs.open("active_zones.tmp", "w")
        if not f then error("could not open active_zones.tmp for writing") end
        f.write(data); f.close()
        if fs.exists(ACTIVE_ZONES_FILE) then
            if fs.exists(ACTIVE_ZONES_FILE .. ".bak") then fs.delete(ACTIVE_ZONES_FILE .. ".bak") end
            fs.copy(ACTIVE_ZONES_FILE, ACTIVE_ZONES_FILE .. ".bak")
            fs.delete(ACTIVE_ZONES_FILE)
        end
        fs.move("active_zones.tmp", ACTIVE_ZONES_FILE)
    end)
    if not ok then logWarn("saveMiningZones failed: " .. tostring(err)) end
end

local function loadMiningZones()
    local raw = ""
    if fs.exists(ACTIVE_ZONES_FILE) then
        local f = fs.open(ACTIVE_ZONES_FILE, "r")
        if f then raw = f.readAll(); f.close() end
    elseif fs.exists(ACTIVE_ZONES_FILE .. ".bak") then
        logWarn("loadMiningZones: " .. ACTIVE_ZONES_FILE .. " missing — loading from backup")
        local f = fs.open(ACTIVE_ZONES_FILE .. ".bak", "r")
        if f then raw = f.readAll(); f.close() end
    else
        return
    end
    if raw == "" then return end
    local data = textutils.unserialise(raw)
    if type(data) ~= "table" then return end

    local n = 0
    for jobId, zone in pairs(data) do
        if state.jobs[jobId] then
            state.miningZones[jobId] = zone
            n = n + 1
        end
    end

    -- Re-share zones with the same persistentKey so multi-miner pairs pop from
    -- one atomic pending queue (serialisation creates separate copies).
    local keyToZone = {}
    for jobId, zone in pairs(state.miningZones) do
        if keyToZone[zone.persistentKey] then
            state.miningZones[jobId] = keyToZone[zone.persistentKey]
        else
            keyToZone[zone.persistentKey] = zone
        end
    end

    if n > 0 then logInfo(string.format("Restored %d active mining zone(s)", n)) end
end

-- Called after SECTOR_DONE: snapshot the runtime zone's accumulated ore totals
-- and record which sector just finished, then save to disk.
local function mergeToPersistentZone(jobId, sx, sz, foundOres)
    local zone = state.miningZones[jobId]
    if not zone or not zone.persistentKey then return end
    local pz = state.persistentZones[zone.persistentKey]
    if not pz then return end
    local alreadyDone = false
    for _, s in ipairs(pz.doneSectors) do
        if s.x == sx and s.z == sz then alreadyDone = true; break end
    end
    if alreadyDone then return end
    table.insert(pz.doneSectors, { x = sx, z = sz })
    -- Per-sector ore map: lets targeted mine skip sectors without desired ore
    if foundOres and next(foundOres) then
        pz.sectorOreMap = pz.sectorOreMap or {}
        pz.sectorOreMap[sx .. "," .. sz] = foundOres
    end
    pz.oreFound = {}
    for k, v in pairs(zone.oreFound) do pz.oreFound[k] = v end
    pz.oreMined = {}
    for k, v in pairs(zone.oreMined) do pz.oreMined[k] = v end
    pz.lastActivity = os.epoch("utc")
    savePersistentZones()
end

local function orePct(oreFound, oreMined)
    local found, mined = 0, 0
    for _, v in pairs(oreFound  or {}) do found = found + v end
    for _, v in pairs(oreMined  or {}) do mined = mined + v end
    if found == 0 then return nil end
    return math.min(100, math.floor(mined / found * 100))
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

-- Detect jobs that are IN_PROGRESS/ASSIGNED but whose turtle has moved on to a
-- different job (or is idle).  These are orphaned by crash-recovery cycles where
-- the server dispatched a fresh job before the old one was properly closed.
-- A 30-second grace window avoids false positives during normal job transitions.
function jobQueue.checkGhosts()
    local nowSec = os.epoch("utc") / 1000
    for jobId, job in pairs(state.jobs) do
        if (job.status == JOB_STATUS.ASSIGNED or job.status == JOB_STATUS.IN_PROGRESS)
           and job.assignedTo then
            local t = state.registry[job.assignedTo]
            -- Case 1: turtle moved on to a different job (classic ghost)
            local isGhost = t and t.online and t.jobId ~= jobId
            if isGhost then
                job.ghostSince = job.ghostSince or nowSec
                if nowSec - job.ghostSince > 30 then
                    logWarn(string.format(
                        "Ghost job %s: assigned to %s but turtle is on %s — auto-cancelling",
                        jobId, job.assignedTo, t.jobId or "nothing"))
                    server.cancelJob(jobId)
                end
            else
                job.ghostSince = nil
            end

            -- Case 2: miner reports IDLE while server still has this MINE job active.
            -- Means JOB_COMPLETE or JOB_FAILED was lost during a server crash.
            -- Miners never report IDLE while actively mining, so IDLE = job truly done.
            local isIdleStuck = not isGhost
                and t and t.online
                and t.status == proto.STATUS.IDLE
                and t.jobId == jobId
                and job.type == proto.JOB.MINE
            if isIdleStuck then
                job.idleSince = job.idleSince or nowSec
                if nowSec - job.idleSince > 60 then
                    logWarn(string.format(
                        "Idle-stuck MINE job %s: %s is IDLE but job is %s — re-queuing",
                        jobId, job.assignedTo, job.status))
                    jobQueue.fail(jobId, "idle_stuck_after_crash", true)
                end
            else
                job.idleSince = nil
            end
        end
    end
end

-- Returns true if the support job is actively held by a turtle.
-- Checks both the server-side job status AND the turtle registry directly —
-- after a server restart the job record may be PENDING or missing even though
-- a support turtle is online and working it (server–disk race on assign).
local function isSupportWorking(supportJobId)
    if not supportJobId then return false end
    local sj = state.jobs[supportJobId]
    if sj and (sj.status == JOB_STATUS.IN_PROGRESS or sj.status == JOB_STATUS.ASSIGNED) then
        return true
    end
    for _, t in pairs(state.registry) do
        if t.online and t.jobId == supportJobId then return true end
    end
    return false
end

-- Orphaned miner watchdog: if a MINE job is active but its support job is
-- gone/complete, the miner is underground without a chunk-loader. Recall it
-- after 2 minutes so it can surface safely rather than staying stranded.
local function checkOrphanedMiners()
    local nowSec = os.epoch("utc") / 1000
    for jobId, job in pairs(state.jobs) do
        if job.type == proto.JOB.MINE
                and (job.status == JOB_STATUS.IN_PROGRESS or job.status == JOB_STATUS.ASSIGNED) then
            local supportActive = isSupportWorking(job.linkedJob)
            if not supportActive then
                job.orphanSince = job.orphanSince or nowSec
                if nowSec - job.orphanSince > 120 then
                    local miner = job.assignedTo and state.registry[job.assignedTo]
                    if miner and miner.online then
                        logWarn(string.format(
                            "Orphaned miner %s (job %s): no support for 2min — recalling",
                            job.assignedTo, jobId))
                        sendTo(job.assignedTo, proto.MSG.RECALL,
                            proto.payloadRecall("support_abandoned"))
                        job.orphanSince = nowSec + 3600  -- suppress re-recall for 1h
                    end
                end
            else
                job.orphanSince = nil
            end
        end
    end
end

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
    state.miningZones[jobId] = nil
    saveJobs()
end

function jobQueue.fail(jobId, reason, recoverable)
    local job = state.jobs[jobId]
    if not job then return end
    job.updatedAt = os.epoch("utc")
    jobQueue._hist(jobId, "failed", reason or "unknown")

    local t = state.registry[job.assignedTo or ""]
    if t then t.status = proto.STATUS.IDLE; t.jobId = nil end

    -- Track sector fail count before clearing the zone.
    -- After 3 failures the sector is blacklisted in ensureMineZone.
    local zone = state.miningZones[jobId]
    if zone and zone.persistentKey and job.assignedTo then
        local la = zone.lastAssignments and zone.lastAssignments[job.assignedTo]
        if la then
            local pz   = state.persistentZones[zone.persistentKey]
            local sKey = la.x .. "," .. la.z
            if pz then
                pz.sectorFailCount = pz.sectorFailCount or {}
                pz.sectorFailCount[sKey] = (pz.sectorFailCount[sKey] or 0) + 1
                if pz.sectorFailCount[sKey] >= 3 then
                    logWarn(string.format(
                        "Sector (%d,%d) blacklisted after %d failures",
                        la.x, la.z, pz.sectorFailCount[sKey]))
                end
                savePersistentZones()
            end
            -- Return the in-flight sector to pending so it isn't permanently lost.
            -- Only skip if the sector is blacklisted (>=3 failures on this sector).
            local failCount = (pz and pz.sectorFailCount and pz.sectorFailCount[sKey]) or 0
            if failCount < 3 then
                local alreadyPending = false
                for _, s in ipairs(zone.pending or {}) do
                    if s.x == la.x and s.z == la.z then alreadyPending = true; break end
                end
                if not alreadyPending then
                    table.insert(zone.pending, 1, { x = la.x, z = la.z, isSurvey = la.isSurvey or false })
                    logInfo(string.format("Sector (%d,%d) returned to pending after %s failure",
                        la.x, la.z, jobId))
                end
            end
        end
    end

    if recoverable and job.retries < CFG.MAX_JOB_RETRIES then
        job.retries    = job.retries + 1
        job.status     = JOB_STATUS.PENDING
        job.assignedTo = nil
        logWarn(string.format("Job %s retry %d/%d: %s", jobId, job.retries, CFG.MAX_JOB_RETRIES, reason or "?"))
    else
        job.status = JOB_STATUS.FAILED
        logError("Job permanently failed: " .. jobId .. " (" .. (reason or "?") .. ")")
    end
    -- Only cancel the partner job on permanent failure. On retry (status=PENDING)
    -- each turtle handles its own recovery: the miner sends MINE_RECALL before
    -- calling sendFailed, so the support is already returning. Cancelling here
    -- would mark the miner's job CANCELLED right before it re-registers and tries
    -- to reclaim its reSendJob — leaving it stranded at "Ready." with no work.
    if job.status == JOB_STATUS.FAILED and job.linkedJob then
        local linked = state.jobs[job.linkedJob]
        if linked
           and linked.status ~= JOB_STATUS.COMPLETE
           and linked.status ~= JOB_STATUS.CANCELLED
           and linked.status ~= JOB_STATUS.FAILED then
            server.cancelJob(job.linkedJob)
        end
    end
    -- Auto-respawn: if this zone is now orphaned (no other pending/active MINE
    -- jobs covering it) but still has sectors remaining, queue one replacement.
    if job.status == JOB_STATUS.FAILED and zone and zone.persistentKey then
        local remaining = zone.pending and #zone.pending or 0
        if remaining > 0 then
            local otherActive = 0
            for jid2, j2 in pairs(state.jobs) do
                if jid2 ~= jobId and j2.type == proto.JOB.MINE then
                    local s = j2.status
                    if s == JOB_STATUS.PENDING or s == JOB_STATUS.ASSIGNED or s == JOB_STATUS.IN_PROGRESS then
                        local j2zone = state.miningZones[jid2]
                        local j2key  = (j2.params and j2.params.sharedZoneKey)
                                    or (j2zone and j2zone.persistentKey)
                        if j2key == zone.persistentKey then
                            otherActive = otherActive + 1
                        end
                    end
                end
            end
            if otherActive == 0 then
                local p = job.params or {}
                local newId = server.submitJob(proto.JOB.MINE, {
                    x1 = p.x1, z1 = p.z1, x2 = p.x2, z2 = p.z2,
                    sharedZoneKey = zone.persistentKey,
                }, job.priority or 5)
                logInfo(string.format(
                    "Auto-respawn: %s → zone %s (%d sectors remain, replaced %s)",
                    newId, zone.persistentKey, remaining, jobId))
            end
        end
    end
    state.miningZones[jobId] = nil
    saveJobs()
end

function jobQueue.reassign(jobId, fromId, reason)
    local job = state.jobs[jobId]
    if not job then return end
    -- Reset the dead turtle's registry entry so it doesn't stay stuck at
    -- TRAVELLING/RETURNING and get excluded from future idle-turtle selection.
    local t = state.registry[fromId or ""]
    if t then t.status = proto.STATUS.IDLE; t.jobId = nil end
    -- Cancel the linked support job so it doesn't orphan indefinitely.
    -- Same guard as jobQueue.fail() — support jobs have no linkedJob so no recursion.
    if job.linkedJob then
        local linked = state.jobs[job.linkedJob]
        if linked
           and linked.status ~= JOB_STATUS.COMPLETE
           and linked.status ~= JOB_STATUS.CANCELLED
           and linked.status ~= JOB_STATUS.FAILED then
            server.cancelJob(job.linkedJob)
        end
    end
    job.status     = JOB_STATUS.PENDING
    job.assignedTo = nil
    job.updatedAt  = os.epoch("utc")
    -- Drop the runtime zone so it shows HISTORICAL while job waits for a new turtle.
    -- ensureMineZone will rebuild cleanly from persistentZones on next dispatch.
    state.miningZones[jobId] = nil
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
            -- Don't re-queue while the turtle may still be travelling —
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

-- ─── Mining Zone Manager ─────────────────────────────────────────────────────

local SECTOR_STEP = 32   -- geo scanner radius=16, step=32 → adjacent sectors don't overlap

local SCAN_RADIUS = 16  -- must match ore_turtle.lua SCAN_RADIUS

-- Build a flat list of {x,z} sector centres covering the rectangle x1,z1 → x2,z2.
-- Also returns the true covered bounds (sector centres snapped to grid ± scan radius)
-- so the dashboard overlay exactly matches where the miner will work.
local function buildSectorGrid(x1, z1, x2, z2)
    local sectors = {}
    local minX = math.floor(math.min(x1, x2) / SECTOR_STEP) * SECTOR_STEP
    local maxX = math.ceil( math.max(x1, x2) / SECTOR_STEP) * SECTOR_STEP
    local minZ = math.floor(math.min(z1, z2) / SECTOR_STEP) * SECTOR_STEP
    local maxZ = math.ceil( math.max(z1, z2) / SECTOR_STEP) * SECTOR_STEP
    for sx = minX, maxX, SECTOR_STEP do
        for sz = minZ, maxZ, SECTOR_STEP do
            table.insert(sectors, { x = sx, z = sz })
        end
    end
    -- Extend by scan radius so the overlay covers the full geo-scanned area
    return sectors, minX - SCAN_RADIUS, minZ - SCAN_RADIUS, maxX + SCAN_RADIUS, maxZ + SCAN_RADIUS
end

-- Initialise a zone for a freshly dispatched MINE job (idempotent).
-- If a persistent zone with matching bounds exists, pre-populates ore data and
-- removes already-completed sectors so the miner resumes from where it left off.
local function ensureMineZone(jobId, params)
    if state.miningZones[jobId] then return end
    -- Multi-miner: secondary jobs share the zone object of the primary job.
    -- Lua tables are references; both miners pop from the same atomic queue.
    if params.sharedZoneKey then
        for _, z in pairs(state.miningZones) do
            if z.persistentKey == params.sharedZoneKey then
                state.miningZones[jobId] = z
                logInfo(string.format("Mine zone %s joined shared zone %s", jobId, params.sharedZoneKey))
                return
            end
        end
        -- First caller for this sharedZoneKey — fall through to create zone normally.
    end
    -- Targeted mine: ore-filtered sector queue from surveyed zone
    local oreFilter = params.oreFilter
    if oreFilter and type(oreFilter) == "table" and #oreFilter > 0 then
        local allS, bx1, bz1, bx2, bz2 = buildSectorGrid(params.x1, params.z1, params.x2, params.z2)
        local key = computeZoneKey(bx1, bz1, bx2, bz2)
        local pz  = state.persistentZones[key]
        if not pz or not pz.surveyed then
            logWarn(string.format(
                "ensureMineZone: targeted mine for unsurveyed zone %s — aborting", key))
            return
        end
        -- Build ore set for fast lookup
        local oreSet  = {}
        for _, name in ipairs(oreFilter) do oreSet[name] = true end
        -- Only include sectors that have the ore AND are not done AND not blacklisted
        local doneSet = {}
        for _, s in ipairs(pz.doneSectors or {}) do doneSet[s.x..","..s.z] = true end
        local targeted = {}
        for sKey, oreMap in pairs(pz.sectorOreMap or {}) do
            if not doneSet[sKey] then
                local hasOre = false
                for name in pairs(oreMap) do
                    if oreSet[name] then hasOre = true; break end
                end
                if hasOre then
                    local fc = (pz.sectorFailCount or {})[sKey] or 0
                    if fc < 3 then
                        local sx, sz = sKey:match("^(-?%d+),(-?%d+)$")
                        if sx then
                            table.insert(targeted, { x = tonumber(sx), z = tonumber(sz) })
                        end
                    end
                end
            end
        end
        -- Shuffle
        for i = #targeted, 2, -1 do
            local j = math.random(1, i)
            targeted[i], targeted[j] = targeted[j], targeted[i]
        end
        -- Patch rawBounds for old zones that predate it
        local rb = pz.rawBounds
        if not rb and pz.bounds then
            rb = { x1 = pz.bounds.x1 + SCAN_RADIUS, z1 = pz.bounds.z1 + SCAN_RADIUS,
                   x2 = pz.bounds.x2 - SCAN_RADIUS, z2 = pz.bounds.z2 - SCAN_RADIUS }
            pz.rawBounds = rb
            savePersistentZones()
        end
        state.miningZones[jobId] = {
            pending         = targeted,
            allSectors      = targeted,
            total           = #targeted,
            done            = 0,
            oreFound        = {},
            oreMined        = {},
            startTime       = os.epoch("utc"),
            bounds          = pz.bounds,
            rawBounds       = rb,
            persistentKey   = key,
            phase           = "MINE",
            surveyOnly      = false,
            targeted        = true,
            oreFilter       = oreFilter,
            surveySectors   = {},
            surveyDone      = 0,
            surveyTotal     = 0,
            lastAssignments = {},
        }
        saveMiningZones()
        logInfo(string.format("Targeted mine zone %s: %d sector(s) with [%s] (key=%s)",
            jobId, #targeted, table.concat(oreFilter, ","), key))
        return
    end
    local allSectors, bx1, bz1, bx2, bz2 = buildSectorGrid(params.x1, params.z1, params.x2, params.z2)
    local key = computeZoneKey(bx1, bz1, bx2, bz2)
    local pz  = state.persistentZones[key]

    -- Filter out sectors that already completed in a previous run
    local sectors = allSectors
    if pz and pz.doneSectors and #pz.doneSectors > 0 then
        local doneSet = {}
        for _, s in ipairs(pz.doneSectors) do
            doneSet[s.x .. "," .. s.z] = true
        end
        local remaining = {}
        for _, s in ipairs(allSectors) do
            if not doneSet[s.x .. "," .. s.z] then table.insert(remaining, s) end
        end
        sectors = remaining
    end

    -- Skip sectors that failed 3+ times (corrupted chunk protection)
    if pz and pz.sectorFailCount then
        local healthy = {}
        for _, s in ipairs(sectors) do
            local fc = pz.sectorFailCount[s.x .. "," .. s.z] or 0
            if fc < 3 then
                table.insert(healthy, s)
            else
                logWarn(string.format(
                    "ensureMineZone: skipping blacklisted sector (%d,%d) [%d failures]",
                    s.x, s.z, fc))
            end
        end
        sectors = healthy
    end

    -- Shuffle remaining sectors
    for i = #sectors, 2, -1 do
        local j = math.random(1, i)
        sectors[i], sectors[j] = sectors[j], sectors[i]
    end

    local preDone = pz and pz.doneSectors and #pz.doneSectors or 0
    local total   = (pz and pz.total) or (#sectors + preDone)

    -- Inherit cumulative ore data from all previous runs on this zone
    local oreFound, oreMined = {}, {}
    if pz then
        for k, v in pairs(pz.oreFound or {}) do oreFound[k] = v end
        for k, v in pairs(pz.oreMined or {}) do oreMined[k] = v end
    end

    -- Survey pass only for fresh zones; resumed zones (preDone>0) go straight to mine.
    -- surveySectors is an independent copy so the mine pass still has its own order.
    local phase        = preDone > 0 and "MINE" or "SURVEY"
    local surveySectors = {}
    if phase == "SURVEY" then
        for _, s in ipairs(sectors) do table.insert(surveySectors, { x=s.x, z=s.z }) end
        for i = #surveySectors, 2, -1 do
            local j = math.random(1, i)
            surveySectors[i], surveySectors[j] = surveySectors[j], surveySectors[i]
        end
    end

    -- rawBounds = sector-grid bounds without SCAN_RADIUS padding.
    -- Stored so redeploy can pass them back without the bounds expanding each time.
    local rawBounds = { x1 = bx1 + SCAN_RADIUS, z1 = bz1 + SCAN_RADIUS,
                        x2 = bx2 - SCAN_RADIUS, z2 = bz2 - SCAN_RADIUS }

    -- allSectors (full grid, never depleted) used to build rescan lists
    local allSectorsCopy = {}
    for _, s in ipairs(allSectors) do table.insert(allSectorsCopy, { x=s.x, z=s.z }) end

    state.miningZones[jobId] = {
        pending         = params.surveyOnly and {} or sectors,
        allSectors      = allSectorsCopy,
        total           = total,
        done            = preDone,
        oreFound        = oreFound,
        oreMined        = oreMined,
        startTime       = os.epoch("utc"),
        bounds          = { x1=bx1, z1=bz1, x2=bx2, z2=bz2 },
        rawBounds       = rawBounds,
        persistentKey   = key,
        phase           = phase,
        surveySectors   = surveySectors,
        surveyDone      = 0,
        surveyTotal     = #surveySectors,
        surveyOnly      = params.surveyOnly == true,
        lastAssignments = {},   -- [minerId] = {x, z, isSurvey}
    }

    -- Create persistent zone entry if this is the first dispatch to these bounds
    if not pz then
        state.persistentZones[key] = {
            key          = key,
            bounds       = { x1=bx1, z1=bz1, x2=bx2, z2=bz2 },
            rawBounds    = rawBounds,
            total        = total,
            doneSectors  = {},
            oreFound     = {},
            oreMined     = {},
            lastActivity = os.epoch("utc"),
        }
        savePersistentZones()
    elseif not pz.rawBounds then
        -- Backward compat: patch older on-disk zones that predate rawBounds
        pz.rawBounds = rawBounds
        savePersistentZones()
    end

    saveMiningZones()
    logInfo(string.format("Mine zone %s: %d/%d sectors remaining (%d,%d → %d,%d)%s",
        jobId, #sectors, total, params.x1, params.z1, params.x2, params.z2,
        preDone > 0 and string.format(" [resuming: %d already done]", preDone) or ""))
end

-- Pop the next unassigned sector for a turtle, or nil if all done.
local function nextSector(jobId)
    local zone = state.miningZones[jobId]
    if not zone or #zone.pending == 0 then return nil end
    return table.remove(zone.pending, 1)
end

-- ─── Role Map ────────────────────────────────────────────────────────────────

local JOB_ROLE = {
    [proto.JOB.DELIVER]        = proto.ROLE.DELIVERY,
    [proto.JOB.BUILD]          = proto.ROLE.BUILDER,
    [proto.JOB.SUPPORT_FOLLOW] = proto.ROLE.SUPPORT,
    [proto.JOB.PATROL]         = proto.ROLE.SUPPORT,
    [proto.JOB.MINE]           = proto.ROLE.MINER,
}

-- ─── Dispatcher ──────────────────────────────────────────────────────────────
-- Every tick, try to pair each pending worker job with an idle support turtle.
-- Both must be available before either gets assigned.

local dispatcher = {}
-- Throttle dispatch-hold and stagger log spam: only print once per 60s.
local lastDispatchHoldLog = 0
local lastStaggerLog      = 0

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
        if (now - lastStaggerLog) >= 60000 then
            local waitSec = math.ceil((CFG.DISPATCH_STAGGER * 1000 - msSinceLast) / 1000)
            logInfo(string.format("Dispatch stagger: next pair in %ds", waitSec))
            lastStaggerLog = now
        end
        return
    end

    for _, job in ipairs(workerJobs) do
        local isMine = job.type == proto.JOB.MINE

        -- Delivery: skip if destination already has an active job
        if not isMine and job.params and destinationBusy(job.params.destination) then
            logInfo(string.format("Skip %s — destination already has an active delivery", job.id))
            -- continue to next pending job
        else

        local role     = JOB_ROLE[job.type]
        local workers  = registry.getIdle(role)
        local supports = registry.getIdle(proto.ROLE.SUPPORT)

        if #workers > 0 and #supports > 0 then
            local worker  = workers[1]
            local support = supports[1]

            -- For MINE jobs: initialise the sector grid before dispatch
            if isMine then
                ensureMineZone(job.id, job.params)
            end

            -- Build worker params (copy job params + inject partnerId)
            local workerParams = {}
            for k, v in pairs(job.params) do workerParams[k] = v end
            workerParams.partnerId = support.id

            -- Create the paired support job
            -- MINE support gets fuelManage=true so it runs the coal-transfer loop
            local supportParams = {
                partnerId   = worker.id,
                masterJobId = job.id,
                fuelManage  = isMine,
                destination = job.params.destination,  -- nil for MINE, that's fine
            }
            local supportJobId = jobQueue.add(proto.JOB.SUPPORT_FOLLOW, supportParams, job.priority)

            -- Link the two jobs
            job.linkedJob = supportJobId
            -- NOTE: support job intentionally has no linkedJob — prevents cancelJob() back-cycle

            -- Assign worker
            jobQueue.assign(job.id, worker.id)
            sendTo(worker.id, proto.MSG.JOB_ASSIGN,
                proto.payloadJobAssign(job.id, job.type, workerParams))

            -- Assign support
            jobQueue.assign(supportJobId, support.id)
            sendTo(support.id, proto.MSG.JOB_ASSIGN,
                proto.payloadJobAssign(supportJobId, proto.JOB.SUPPORT_FOLLOW, supportParams))

            logInfo(string.format("Dispatched %s [%s] -> %s  support %s -> %s",
                job.id, job.type, worker.id, supportJobId, support.id))

            state.lastDispatchTime = os.epoch("utc")
            return
        else
            if (now - lastDispatchHoldLog) >= 60000 then
                logInfo(string.format("Dispatch hold: %s needs %s (idle=%d fuel≥%d) + SUPPORT (idle=%d)",
                    job.id, JOB_ROLE[job.type] or "?", #workers, CFG.MIN_DISPATCH_FUEL, #supports))
                lastDispatchHoldLog = now
            end
        end

        end -- destination-busy / mine else
    end
end

-- ─── Message Handlers ────────────────────────────────────────────────────────

local handlers = {}

handlers[proto.MSG.REGISTER] = function(msg)
    local p    = msg.payload
    local dock, reSendJob, reSendSector = registry.register(msg.from, p.role, p.fuel, p.fuelMax, p.position, p.midJob)
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
    -- Replay last SECTOR_ASSIGN to a mid-job miner so it doesn't time out waiting.
    if reSendSector then
        sendTo(msg.from, proto.MSG.SECTOR_ASSIGN,
            proto.payloadSectorAssign(reSendSector.jobId,
                reSendSector.x, reSendSector.z, nil, reSendSector.isSurvey))
        logInfo(string.format("Re-sent SECTOR_ASSIGN (%d,%d) to %s after crash re-link",
            reSendSector.x, reSendSector.z, msg.from))
    end
    pcall(dispatcher.tick)
end

handlers[proto.MSG.HEARTBEAT] = function(msg)
    local p = msg.payload
    local known = state.registry[msg.from] ~= nil
    if known then
        registry.update(msg.from, p.status, p.fuel, p.position, p.jobId, p.version)
        -- ACK only known turtles so their missed counter resets and they never re-register spuriously
        sendTo(msg.from, proto.MSG.HEARTBEAT_ACK, { ts = os.epoch("utc") })
        -- Deliver any staged update now that the turtle is idle
        local t = state.registry[msg.from]
        if t and t.pendingUpdate and t.status == proto.STATUS.IDLE then
            t.pendingUpdate = nil
            sendTo(msg.from, proto.MSG.UPDATE_ALL, {})
            logInfo("UPDATE_ALL: delivered to " .. msg.from .. " (now idle)")
        end
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

handlers[proto.MSG.TURTLE_LOG] = function(msg)
    local lines = msg.payload.lines
    if type(lines) ~= "table" then return end
    if not state.turtleLogs[msg.from] then state.turtleLogs[msg.from] = {} end
    local buf = state.turtleLogs[msg.from]
    for _, entry in ipairs(lines) do
        if type(entry) == "table" and entry.msg then
            table.insert(buf, entry)
        end
    end
    while #buf > 60 do table.remove(buf, 1) end
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

-- ── Mining sector handshake ───────────────────────────────────────────────────

handlers[proto.MSG.SECTOR_REQUEST] = function(msg)
    local jobId = msg.payload.jobId
    local zone  = state.miningZones[jobId]
    if not zone then
        -- miningZone is only in-memory; it is lost on server restart.
        -- Recreate from the job's params + persistent zone so the miner can
        -- resume from where it left off instead of returning with incomplete data.
        local job = state.jobs[jobId]
        if job and job.params and job.type == proto.JOB.MINE then
            logWarn(string.format("Recreating lost miningZone for %s (SECTOR_REQUEST after restart)", jobId))
            ensureMineZone(jobId, job.params)
            zone = state.miningZones[jobId]
        end
        if not zone then
            logWarn(string.format("SECTOR_REQUEST from %s — zone %s unknown, sending MINE_COMPLETE",
                msg.from, tostring(jobId)))
            sendTo(msg.from, proto.MSG.MINE_COMPLETE, { jobId = jobId })
            return
        end
    end

    -- Dispatch first sector (or after reconnect): check survey vs mine phase
    local sector, isSurvey
    if zone.phase == "SURVEY" and zone.surveySectors and #zone.surveySectors > 0 then
        sector   = table.remove(zone.surveySectors, 1)
        isSurvey = true
    else
        if zone.phase == "SURVEY" then zone.phase = "MINE" end
        sector   = nextSector(jobId)
        isSurvey = false
    end

    if not sector then
        logInfo(string.format("Zone %s exhausted (%d/%d sectors) — sending MINE_COMPLETE to %s",
            jobId, zone.done, zone.total, msg.from))
        sendTo(msg.from, proto.MSG.MINE_COMPLETE, { jobId = jobId })
    else
        logInfo(string.format("Assigned sector (%d,%d)%s to %s [%s]",
            sector.x, sector.z, isSurvey and " [SURVEY]" or "", msg.from, jobId))
        sendTo(msg.from, proto.MSG.SECTOR_ASSIGN,
            proto.payloadSectorAssign(jobId, sector.x, sector.z, nil, isSurvey))
        zone.lastAssignments = zone.lastAssignments or {}
        zone.lastAssignments[msg.from] = { x = sector.x, z = sector.z, isSurvey = isSurvey }
        saveMiningZones()
    end
end

-- SECTOR_SCAN: miner finished one depth-level scan OR mine pass — accumulate
-- foundOres and/or minedOres immediately so the dashboard updates in real time.
-- Sent twice per depth level: once after scan (foundOres), once after mine (minedOres).
handlers[proto.MSG.SECTOR_SCAN] = function(msg)
    local p    = msg.payload
    local zone = state.miningZones[p.jobId]
    if zone then
        if zone.phase ~= "RESCAN" then
            if type(p.foundOres) == "table" then
                for name, n in pairs(p.foundOres) do
                    zone.oreFound[name] = (zone.oreFound[name] or 0) + n
                end
            end
            if type(p.minedOres) == "table" then
                for name, n in pairs(p.minedOres) do
                    zone.oreMined[name] = (zone.oreMined[name] or 0) + n
                end
            end
        end
        logInfo(string.format("Sector (%d,%d) Y=%d scan by %s [%s]",
            p.sectorX, p.sectorZ, p.scanY or 0, msg.from, p.jobId))
    end
end

-- SECTOR_DONE: miner finished one sector (survey or mine).
-- CRITICAL: also dispatches the next sector immediately — the turtle is waiting
-- underground for SECTOR_ASSIGN or MINE_COMPLETE (it does NOT send a separate
-- SECTOR_REQUEST after the first one; SECTOR_DONE IS the implicit request).
handlers[proto.MSG.SECTOR_DONE] = function(msg)
    local p    = msg.payload
    local zone = state.miningZones[p.jobId]
    if not zone then
        -- miningZone lost on restart — recreate so this sector is recorded and
        -- the next sector can be dispatched without forcing a full recallReturn.
        local job = state.jobs[p.jobId]
        if job and job.params and job.type == proto.JOB.MINE then
            logWarn(string.format("Recreating lost miningZone for %s (SECTOR_DONE after restart)", p.jobId))
            ensureMineZone(p.jobId, job.params)
            zone = state.miningZones[p.jobId]
        end
        if not zone then
            -- Ghost job: both zone and job record are gone (server lost state during crash).
            -- Send MINE_COMPLETE so the miner surfaces immediately rather than timing out.
            logWarn(string.format("SECTOR_DONE from %s — ghost job %s (no zone/record) — sending MINE_COMPLETE",
                msg.from, tostring(p.jobId)))
            sendTo(msg.from, proto.MSG.MINE_COMPLETE, { jobId = p.jobId })
            return
        end
    end

    if zone.phase == "SURVEY" then
        zone.surveyDone = zone.surveyDone + 1
        logInfo(string.format("Survey (%d,%d) done by %s [%s: %d/%d surveyed]",
            p.sectorX, p.sectorZ, msg.from, p.jobId, zone.surveyDone, zone.surveyTotal))

    elseif zone.phase == "RESCAN" then
        -- Accumulate per-sector rescan results (foundOres is deduplicated in ore_turtle)
        zone.rescanFound = zone.rescanFound or {}
        if type(p.foundOres) == "table" then
            for name, n in pairs(p.foundOres) do
                zone.rescanFound[name] = (zone.rescanFound[name] or 0) + n
            end
        end
        local hasOre = type(p.foundOres) == "table" and next(p.foundOres) ~= nil
        if hasOre then
            zone.rescanPending = zone.rescanPending or {}
            table.insert(zone.rescanPending, { x = p.sectorX, z = p.sectorZ })
        end
        zone.rescanDone = (zone.rescanDone or 0) + 1
        logInfo(string.format("Rescan (%d,%d) done by %s — %s [%s: %d/%d]",
            p.sectorX, p.sectorZ, msg.from, hasOre and "ore remains" or "clean",
            p.jobId, zone.rescanDone, zone.rescanTotal or 0))

    else  -- MINE phase
        zone.done = zone.done + 1
        local job = state.jobs[p.jobId]
        if not job or job.status ~= JOB_STATUS.CANCELLED then
            mergeToPersistentZone(p.jobId, p.sectorX, p.sectorZ, p.foundOres)
        end
        logInfo(string.format("Sector (%d,%d) done by %s — %d ore mined  [%s: %d/%d sectors]",
            p.sectorX, p.sectorZ, msg.from, p.oreCount or 0,
            p.jobId, zone.done, zone.total))
    end
    jobQueue.progress(p.jobId, proto.STATUS.WORKING,
        string.format("sector (%d,%d) done — %d ore", p.sectorX, p.sectorZ, p.oreCount or 0))

    -- ── Dispatch next sector ──────────────────────────────────────────────────
    local nextSect, isNextSurvey

    if zone.phase == "SURVEY" then
        if #zone.surveySectors > 0 then
            nextSect     = table.remove(zone.surveySectors, 1)
            isNextSurvey = true
        elseif zone.surveyOnly then
            -- Survey-only mode: persist surveyed status and complete
            local pz = zone.persistentKey and state.persistentZones[zone.persistentKey]
            if pz then
                pz.surveyed = true
                savePersistentZones()
            end
            logInfo(string.format("Zone %s survey complete (survey-only) — MINE_COMPLETE", p.jobId))
            sendTo(msg.from, proto.MSG.MINE_COMPLETE, { jobId = p.jobId })
            return
        else
            -- Normal: switch to mine phase
            zone.phase     = "MINE"
            zone.startTime = os.epoch("utc")
            logInfo(string.format("Zone %s survey complete (%d sectors) — starting mine phase",
                p.jobId, zone.surveyTotal))
            nextSect     = nextSector(p.jobId)
            isNextSurvey = false
        end

    elseif zone.phase == "RESCAN" then
        if #(zone.rescanSectors or {}) > 0 then
            nextSect     = table.remove(zone.rescanSectors, 1)
            isNextSurvey = true
        else
            -- Rescan pass complete — update oreFound to reflect actual accessible ore:
            -- oreFound = what was collected + what is still in the ground
            local newOreFound = {}
            for k, v in pairs(zone.oreMined)      do newOreFound[k] = v end
            for k, v in pairs(zone.rescanFound or {}) do
                newOreFound[k] = (newOreFound[k] or 0) + v
            end
            zone.oreFound = newOreFound
            local pz = zone.persistentKey and state.persistentZones[zone.persistentKey]
            if pz then
                pz.oreFound = {}
                for k, v in pairs(newOreFound) do pz.oreFound[k] = v end
                savePersistentZones()
            end

            local remaining = zone.rescanPending or {}
            if #remaining > 0 then
                -- Re-mine sectors where ore was found
                zone.pending    = remaining
                zone.rescanPending = {}
                zone.rescanFound   = {}
                zone.phase         = "MINE"
                zone.postRescan    = true   -- one rescan pass max; mine exhaustion → complete
                logInfo(string.format("Zone %s rescan found ore in %d sector(s) — re-mining",
                    p.jobId, #remaining))
                nextSect     = nextSector(p.jobId)
                isNextSurvey = false
            else
                logInfo(string.format("Zone %s rescan clean — MINE_COMPLETE", p.jobId))
                sendTo(msg.from, proto.MSG.MINE_COMPLETE, { jobId = p.jobId })
                return
            end
        end

    else  -- MINE phase
        nextSect     = nextSector(p.jobId)
        isNextSurvey = false
    end

    if not nextSect then
        -- Targeted mine: no rescan needed — we only mined known-ore sectors
        if zone.targeted then
            logInfo(string.format(
                "Zone %s targeted mine exhausted (%d/%d) — MINE_COMPLETE to %s",
                p.jobId, zone.done, zone.total, msg.from))
            sendTo(msg.from, proto.MSG.MINE_COMPLETE, { jobId = p.jobId })
            return
        end
        -- Already did one rescan pass — don't loop
        if zone.postRescan then
            logInfo(string.format("Zone %s re-mine exhausted — MINE_COMPLETE to %s", p.jobId, msg.from))
            sendTo(msg.from, proto.MSG.MINE_COMPLETE, { jobId = p.jobId })
            return
        end
        -- Mine phase exhausted — build rescan list from the full sector grid
        local rescanSectors = {}
        for _, s in ipairs(zone.allSectors or {}) do
            table.insert(rescanSectors, { x = s.x, z = s.z })
        end
        -- Shuffle
        for i = #rescanSectors, 2, -1 do
            local j = math.random(1, i)
            rescanSectors[i], rescanSectors[j] = rescanSectors[j], rescanSectors[i]
        end
        if #rescanSectors == 0 then
            logInfo(string.format("Zone %s exhausted — sending MINE_COMPLETE to %s", p.jobId, msg.from))
            sendTo(msg.from, proto.MSG.MINE_COMPLETE, { jobId = p.jobId })
        else
            zone.phase         = "RESCAN"
            zone.rescanSectors = rescanSectors
            zone.rescanDone    = 0
            zone.rescanTotal   = #rescanSectors
            zone.rescanPending = {}
            zone.rescanFound   = {}
            logInfo(string.format("Zone %s mine complete — starting rescan of %d sectors",
                p.jobId, #rescanSectors))
            local first = table.remove(zone.rescanSectors, 1)
            sendTo(msg.from, proto.MSG.SECTOR_ASSIGN,
                proto.payloadSectorAssign(p.jobId, first.x, first.z, nil, true))
            zone.lastAssignments = zone.lastAssignments or {}
            zone.lastAssignments[msg.from] = { x = first.x, z = first.z, isSurvey = true }
            saveMiningZones()
        end
        return
    end

    sendTo(msg.from, proto.MSG.SECTOR_ASSIGN,
        proto.payloadSectorAssign(p.jobId, nextSect.x, nextSect.z, nil, isNextSurvey))
    zone.lastAssignments = zone.lastAssignments or {}
    zone.lastAssignments[msg.from] = { x = nextSect.x, z = nextSect.z, isSurvey = isNextSurvey }
    saveMiningZones()
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
    state.miningZones[jobId] = nil
    saveJobs()
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
        print("  job <x> <y> <z>           queue one delivery job")
        print("  mine <x> <z> <r> [scanY]  queue a mining operation")
        print("  stress                    queue 8 test jobs (~90 blocks out)")
        print("  fueltest                  queue job ~80 blocks out to test refueling")
        print("  recall                    recall all turtles")
        print("  jobs                      show job counts")

    elseif cmd == "mine" then
        local cx, cz, r = tonumber(parts[2]), tonumber(parts[3]), tonumber(parts[4])
        local scanY     = tonumber(parts[5]) or 56
        if not (cx and cz and r) then
            print("Usage: mine <centerX> <centerZ> <radius> [scanY]")
        else
            local id = server.submitJob(proto.JOB.MINE, {
                centerX = cx, centerZ = cz, radius = r, scanY = scanY,
            }, 5)
            print(string.format("Mine job %s queued: centre (%d,%d) radius=%d scanY=%d",
                id, cx, cz, r, scanY))
        end

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

local function checkStaleSupports()
    local cancelled = false
    for _, job in pairs(state.jobs) do
        if (job.status == JOB_STATUS.ASSIGNED or job.status == JOB_STATUS.IN_PROGRESS)
           and job.params and job.params.masterJobId then
            local master = state.jobs[job.params.masterJobId]
            local masterActive = master
                and (master.status == JOB_STATUS.ASSIGNED
                  or master.status == JOB_STATUS.IN_PROGRESS)
            if not masterActive then
                logWarn(string.format(
                    "Stale support %s — master %s inactive, recalling",
                    job.id, job.params.masterJobId))
                server.cancelJob(job.id)
                cancelled = true
            end
        end
    end
    if cancelled then saveJobs() end
end

function server.run()
    state.modem = peripheral.find("modem")
    if not state.modem then
        error("No modem found. Attach a wireless or ender modem.")
    end
    proto.openChannels(state.modem, {
        proto.CH_SERVER, proto.CH_BROADCAST, proto.CH_PRIVATE, proto.CH_WAREHOUSE,
    })

    local rsBridge = peripheral.find("rsBridge")
    if rsBridge then
        logInfo("RS Bridge found — storage features enabled")
    else
        logWarn("No RS Bridge found — attach one for storage features")
    end

    -- ── Bridge command dedup ──────────────────────────────────────────────────
    -- If the CC server's HTTP response is lost in transit, the bridge has already
    -- cleared its queue, but a re-send could double-dispatch a command. Guard with
    -- a small cache keyed on the server-assigned timestamp + command type.
    -- Declared before handleBridgeCommand so the UPDATE_ALL branch can capture
    -- it as an upvalue. Acted on in the http_success handler in the main loop.
    local pendingUpdate = false

    -- RS storage snapshot — refreshed every 5s, included in every bridge push.
    -- Craftable index is refreshed separately every 60s (listCraftableItems is slow).
    -- storageJSON is pre-serialised so buildBridgePayload never serialises 300+ items inline.
    local storageItems  = {}
    local craftableMap  = {}
    local storageJSON   = "[]"

    -- Ore demand watchdog: auto-dispatch targeted mines when storage is low
    local activeAutoMines = {}   -- [oreName] = jobId of the running auto-mine
    -- Re-attach surviving auto-mine jobs after restart so the watchdog doesn't re-dispatch
    for jobId, job in pairs(state.jobs) do
        if job.type == proto.JOB.MINE and job.params and job.params.oreFilter then
            local filter = job.params.oreFilter
            if type(filter) == "table" and #filter == 1 then
                local oreName = filter[1]
                if oreThresholds[oreName] then
                    local s = job.status or ""
                    if s == "PENDING" or s == "ASSIGNED" or s == "IN_PROGRESS" then
                        activeAutoMines[oreName] = jobId
                        logInfo(string.format(
                            "Restored active auto-mine %s → %s (post-restart)", oreName, jobId))
                    end
                end
            end
        end
    end

    local function checkOreThresholds()
        if not next(oreThresholds) then return end
        -- Build fast stock lookup from latest RS snapshot
        local stockMap = {}
        for _, item in ipairs(storageItems) do
            stockMap[item.name] = (stockMap[item.name] or 0) + item.amount
        end
        for oreName, minimum in pairs(oreThresholds) do
            -- Clear completed/failed auto-mines so we can re-dispatch
            local prevId = activeAutoMines[oreName]
            if prevId then
                local pj = state.jobs[prevId]
                if not pj
                   or pj.status == "COMPLETE" or pj.status == "FAILED"
                   or pj.status == "CANCELLED" then
                    activeAutoMines[oreName] = nil
                    prevId = nil
                end
            end
            if not prevId then
                local current = stockMap[oreName] or 0
                if current < minimum then
                    -- Find the surveyed zone with the highest count of this ore
                    local bestKey, bestCount = nil, 0
                    for key, pz in pairs(state.persistentZones) do
                        if pz.surveyed then
                            local count = 0
                            for _, oreMap in pairs(pz.sectorOreMap or {}) do
                                count = count + (oreMap[oreName] or 0)
                            end
                            if count > bestCount then
                                bestCount = count; bestKey = key
                            end
                        end
                    end
                    if bestKey then
                        local pz = state.persistentZones[bestKey]
                        local rb = pz.rawBounds
                        if not rb and pz.bounds then
                            rb = { x1=pz.bounds.x1+SCAN_RADIUS, z1=pz.bounds.z1+SCAN_RADIUS,
                                   x2=pz.bounds.x2-SCAN_RADIUS, z2=pz.bounds.z2-SCAN_RADIUS }
                        end
                        if rb then
                            local id = server.submitJob(proto.JOB.MINE, {
                                x1            = rb.x1, z1 = rb.z1,
                                x2            = rb.x2, z2 = rb.z2,
                                sharedZoneKey = bestKey,
                                oreFilter     = { oreName },
                            }, 3)   -- priority 3 = higher than manual (5) = dispatched first
                            activeAutoMines[oreName] = id
                            logInfo(string.format(
                                "Auto-mine %s: %s=%d/%d — zone %s (~%d ore)",
                                id, oreName, current, minimum, bestKey, bestCount))
                        end
                    else
                        logWarn(string.format(
                            "Ore threshold: %s at %d/%d but no surveyed zone has it — survey first",
                            oreName, current, minimum))
                    end
                end
            end
        end
    end

    local function refreshCraftable()
        if not rsBridge then return end
        local ok, craft = pcall(function() return rsBridge.listCraftableItems() end)
        if ok and type(craft) == "table" then
            craftableMap = {}
            for _, item in ipairs(craft) do
                if item.name then craftableMap[item.name] = true end
            end
        end
    end

    local function refreshStorage()
        if not rsBridge then
            rsBridge = peripheral.find("rsBridge")
            if not rsBridge then return end
            logInfo("RS Bridge re-acquired")
        end
        local ok, raw = pcall(function() return rsBridge.listItems() end)
        if not ok then
            logWarn("RS listItems failed: " .. tostring(raw))
            rsBridge = nil   -- force re-acquire next cycle
            return
        end
        if type(raw) ~= "table" then
            logWarn("RS listItems returned non-table: " .. type(raw))
            return
        end
        local result = {}
        for _, item in ipairs(raw) do
            if item.name then
                table.insert(result, {
                    name        = item.name,
                    displayName = item.displayName or item.name,
                    amount      = item.amount or item.count or 0,
                    craftable   = craftableMap[item.name] or false,
                })
            end
        end
        storageItems = result
        storageJSON  = textutils.serialiseJSON(result)
        logInfo("RS storage refreshed: " .. #storageItems .. " items")
    end

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
            -- Staged update: send immediately to IDLE turtles only.
            -- Busy turtles (miners underground, mid-delivery) are flagged and
            -- will receive UPDATE_ALL the next time they heartbeat in as IDLE.
            local nImmediate, nStaged = 0, 0
            for _, tr in pairs(state.registry) do
                if tr.online then
                    if tr.status == proto.STATUS.IDLE then
                        sendTo(tr.id, proto.MSG.UPDATE_ALL, {})
                        nImmediate = nImmediate + 1
                    else
                        tr.pendingUpdate = true
                        nStaged = nStaged + 1
                    end
                end
            end
            logInfo(string.format("UPDATE_ALL: sent to %d idle, queued for %d busy turtle(s)",
                nImmediate, nStaged))
            -- Flag for self-update; acted on in the http_success handler
            -- after the bridge response is fully processed.
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

        elseif t == "FORCE_REFUEL" then
            local tid = p.turtleId
            local tr  = tid and state.registry[tid]
            if tr then
                if tr.status == proto.STATUS.IDLE then
                    sendTo(tid, proto.MSG.FORCE_REFUEL, {})
                    logInfo("FORCE_REFUEL sent to idle turtle: " .. tid)
                else
                    -- Busy turtle: recall it so it returns to dock and auto-refuels
                    sendTo(tid, proto.MSG.RECALL, proto.payloadRecall("force_refuel"))
                    logInfo("FORCE_REFUEL → RECALL sent to busy turtle: " .. tid)
                end
            else
                logWarn("FORCE_REFUEL: turtle not found: " .. tostring(tid))
            end

        elseif t == "MOVE_ANDROID" then
            local aid = p.androidId
            local tr  = aid and state.registry[aid]
            if tr and tr.role == proto.ROLE.ANDROID then
                local tx = tonumber(p.x) or (tr.position and tr.position.x + tonumber(p.dx or 0))
                local ty = tonumber(p.y) or (tr.position and tr.position.y) or 67
                local tz = tonumber(p.z) or (tr.position and tr.position.z + tonumber(p.dz or 0))
                local jobId = "move_" .. tostring(os.epoch("utc"))
                sendTo(aid, proto.MSG.JOB_ASSIGN,
                    proto.payloadJobAssign(jobId, "MOVE", { x = tx, y = ty, z = tz }))
                logInfo(string.format("MOVE_ANDROID: %s → %.0f,%.0f,%.0f", aid, tx, ty, tz))
            else
                logWarn("MOVE_ANDROID: android not found: " .. tostring(aid))
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
                    -- also recall the paired support turtle, otherwise it
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

        elseif t == "DELETE_MINE_ZONE" then
            local key = p.key
            if not key then
                logWarn("DELETE_MINE_ZONE: missing key")
                return
            end
            -- Block deletion if a live job is currently using this zone
            for jid, z in pairs(state.miningZones) do
                if z.persistentKey == key then
                    logWarn(string.format("DELETE_MINE_ZONE: zone %s has active job %s — blocked", key, jid))
                    return
                end
            end
            if state.persistentZones[key] then
                state.persistentZones[key] = nil
                savePersistentZones()
                logInfo("Dashboard: deleted mine zone " .. key)
            else
                logWarn("DELETE_MINE_ZONE: zone not found: " .. key)
            end

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

        elseif t == "ORDER_DELIVERY" then
            local dest  = p.destination
            local items = p.items
            if not dest or not dest.x or not dest.z or not items or #items == 0 then
                logWarn("ORDER_DELIVERY: missing destination or items"); return
            end
            -- Trigger RS autocraft for items that need it
            if rsBridge then
                for _, item in ipairs(items) do
                    if item.craft then
                        local ok, res = pcall(function()
                            return rsBridge.craftItem({ name = item.name, count = item.count })
                        end)
                        if ok then
                            logInfo(string.format("Craft queued: %d × %s (%s)", item.count, item.name, tostring(res)))
                        else
                            logWarn(string.format("Craft failed: %s — %s", item.name, tostring(res)))
                        end
                    end
                end
            end
            local itemsDict = {}
            for _, item in ipairs(items) do
                if (item.count or 0) > 0 then
                    itemsDict[item.name] = (itemsDict[item.name] or 0) + item.count
                end
            end
            if next(itemsDict) == nil then
                logWarn("ORDER_DELIVERY: all items have count 0"); return
            end
            local id = server.submitJob(proto.JOB.DELIVER, {
                items       = itemsDict,
                destination = { x = dest.x, y = dest.y or 67, z = dest.z },
            }, p.priority or 5)
            logInfo(string.format("Dashboard order %s → %d,%d,%d (%d types)",
                id, dest.x, dest.y or 67, dest.z, #items))

        elseif t == "ORDER_MINE" then
            local x1 = tonumber(p.x1)
            local z1 = tonumber(p.z1)
            local x2 = tonumber(p.x2)
            local z2 = tonumber(p.z2)
            if not (x1 and z1 and x2 and z2) then
                logWarn("ORDER_MINE: missing corner coordinates (need x1,z1,x2,z2)"); return
            end
            local allSectors, bx1, bz1, bx2, bz2 = buildSectorGrid(
                math.floor(x1), math.floor(z1), math.floor(x2), math.floor(z2))
            local sectorCount = #allSectors
            local maxMiners   = math.max(1, tonumber(p.minerCount) or 4)
            local minerCount  = math.max(1, math.min(math.floor(sectorCount / 4), maxMiners))
            local zoneKey     = computeZoneKey(bx1, bz1, bx2, bz2)
            for i = 1, minerCount do
                local id = server.submitJob(proto.JOB.MINE, {
                    x1 = math.floor(x1), z1 = math.floor(z1),
                    x2 = math.floor(x2), z2 = math.floor(z2),
                    -- All jobs carry the key; first caller creates zone, rest join it
                    sharedZoneKey = zoneKey,
                }, 5)
                logInfo(string.format(
                    "Dashboard mine %s [%d/%d] → (%d,%d)→(%d,%d) sectorCount=%d",
                    id, i, minerCount, x1, z1, x2, z2, sectorCount))
            end

        elseif t == "ORDER_SURVEY" then
            local x1 = tonumber(p.x1)
            local z1 = tonumber(p.z1)
            local x2 = tonumber(p.x2)
            local z2 = tonumber(p.z2)
            if not (x1 and z1 and x2 and z2) then
                logWarn("ORDER_SURVEY: missing corner coordinates (need x1,z1,x2,z2)"); return
            end
            local id = server.submitJob(proto.JOB.MINE, {
                x1 = math.floor(x1), z1 = math.floor(z1),
                x2 = math.floor(x2), z2 = math.floor(z2),
                surveyOnly = true,
            }, 5)
            logInfo(string.format("Dashboard survey %s → (%d,%d) to (%d,%d)",
                id, x1, z1, x2, z2))

        elseif t == "ORDER_TARGETED_MINE" then
            local zoneKey   = p.zoneKey
            local oreFilter = p.oreFilter
            if not zoneKey or type(oreFilter) ~= "table" or #oreFilter == 0 then
                logWarn("ORDER_TARGETED_MINE: missing zoneKey or oreFilter"); return
            end
            local pz = state.persistentZones[zoneKey]
            if not pz or not pz.surveyed then
                logWarn("ORDER_TARGETED_MINE: zone not found or not surveyed: "
                    .. tostring(zoneKey)); return
            end
            local rb = pz.rawBounds
            if not rb and pz.bounds then
                rb = { x1=pz.bounds.x1+SCAN_RADIUS, z1=pz.bounds.z1+SCAN_RADIUS,
                       x2=pz.bounds.x2-SCAN_RADIUS, z2=pz.bounds.z2-SCAN_RADIUS }
            end
            if not rb then
                logWarn("ORDER_TARGETED_MINE: zone has no bounds: " .. tostring(zoneKey)); return
            end
            local id = server.submitJob(proto.JOB.MINE, {
                x1            = rb.x1, z1 = rb.z1,
                x2            = rb.x2, z2 = rb.z2,
                sharedZoneKey = zoneKey,
                oreFilter     = oreFilter,
            }, 5)
            logInfo(string.format("Dashboard targeted mine %s → zone %s [%s]",
                id, zoneKey, table.concat(oreFilter, ",")))

        elseif t == "SET_ORE_THRESHOLD" then
            local name    = p.name
            local minimum = tonumber(p.minimum)
            if not name or not minimum or minimum <= 0 then
                logWarn("SET_ORE_THRESHOLD: invalid name or minimum"); return
            end
            oreThresholds[name] = minimum
            saveOreThresholds()
            logInfo(string.format("Ore threshold set: %s → %d", name, minimum))

        elseif t == "REMOVE_ORE_THRESHOLD" then
            local name = p.name
            if not name then logWarn("REMOVE_ORE_THRESHOLD: missing name"); return end
            oreThresholds[name] = nil
            saveOreThresholds()
            logInfo("Ore threshold removed: " .. tostring(name))

        else
            logWarn("Unknown bridge command: " .. tostring(t))
        end
    end

    -- ── Bridge state builder ───────────────────────────────────────────────────
    -- Serialises current server state to a JSON string.
    -- HTTP is handled by startBridgePush (async) and the http_success /
    -- http_failure event handlers in the main loop — no parallel.waitForAny.
    local function buildBridgePayload()
        local turtles = {}
        for id, t in pairs(state.registry) do
            turtles[id] = {
                role    = t.role,
                status  = t.status,
                fuel    = t.fuel,
                jobId   = t.jobId,
                online  = t.online,
                version = t.version,
                dock    = t.dock and string.format("bay%d%s", t.dock.bay, t.dock.row) or nil,
                dockX   = t.dock and t.dock.x or nil,
                dockZ   = t.dock and t.dock.z or nil,
                dockJX  = t.dock and t.dock.junction and t.dock.junction.x or nil,
                x       = t.position and t.position.x or nil,
                y       = t.position and t.position.y or nil,
                z       = t.position and t.position.z or nil,
            }
        end
        -- Serialize jobs per-entry. If an individual entry fails, sanitize it
        -- field-by-field, dropping any value that is a non-serialisable table.
        local function buildJobsJSON(jobMap)
            local parts = {}
            for id, j in pairs(jobMap) do
                local supportId = nil
                if j.linkedJob and jobMap[j.linkedJob] then
                    supportId = jobMap[j.linkedJob].assignedTo
                end
                local dest = j.params and j.params.destination or nil
                local e = {
                    id          = id,
                    status      = j.status,
                    assignedTo  = j.assignedTo,
                    type        = j.type,
                    linkedJob   = j.linkedJob,
                    supportId   = supportId,
                    destination = dest,
                    zoneKey     = j.params and j.params.sharedZoneKey or nil,
                }
                local ok_e, r_e = pcall(textutils.serialiseJSON, e)
                if ok_e then
                    table.insert(parts, r_e)
                else
                    -- Per-field sanitization: drop any field whose value is a
                    -- non-serialisable table and record exactly which one it is
                    local safe = {}
                    for k, v in pairs(e) do
                        if type(v) ~= "table" then
                            safe[k] = v
                        else
                            local ok_v, _ = pcall(textutils.serialiseJSON, v)
                            if ok_v then
                                safe[k] = v
                            else
                                logWarn("Bridge: job[" .. tostring(id) .. "]." .. tostring(k) ..
                                        " has mixed keys — dropped")
                            end
                        end
                    end
                    local ok_s, r_s = pcall(textutils.serialiseJSON, safe)
                    if ok_s then table.insert(parts, r_s) end
                end
            end
            return "[" .. table.concat(parts, ",") .. "]"
        end

        -- Only send active jobs to the bridge. Completed/failed jobs accumulate
        -- unboundedly in memory; serialising all of them every few seconds grows
        -- O(n) with the number of past mining cycles and eventually blocks the
        -- event loop long enough to drop consecutive heartbeats.
        local activeJobs = {}
        for id, j in pairs(state.jobs) do
            if j.status == JOB_STATUS.PENDING
            or j.status == JOB_STATUS.ASSIGNED
            or j.status == JOB_STATUS.IN_PROGRESS then
                activeJobs[id] = j
            end
        end
        local jobs = buildJobsJSON(activeJobs)
        -- Build mineZones summary for the dashboard overlay (active + historical)
        local mineZones = {}
        -- Active zones — keyed by jobId
        -- Shallow-copy a table so serialiseJSON sees distinct objects even when
        -- multiple jobs share the same zone (Lua table reference semantics).
        local function cp(t)
            if type(t) ~= "table" then return t end
            local c = {}; for k,v in pairs(t) do c[k] = v end; return c
        end
        local activeKeys = {}
        for jid, z in pairs(state.miningZones) do
            -- Use ore-based pct during mine/rescan once oreFound is populated;
            -- fall back to sector-based during survey (no ore data yet).
            local pct
            if z.phase == "SURVEY" or not next(z.oreFound or {}) then
                pct = z.total > 0 and math.floor(z.done / z.total * 100) or 0
            else
                pct = orePct(z.oreFound, z.oreMined) or 0
            end
            -- ETA: ore-based during MINE (matches the %-display); nil during SURVEY/RESCAN.
            -- Falls back to sector-based if no ore collected yet (barren zone).
            local eta = nil
            if z.phase == "MINE" then
                local found, mined = 0, 0
                for _, v in pairs(z.oreFound  or {}) do found = found + v end
                for _, v in pairs(z.oreMined  or {}) do mined = mined + v end
                local elapsed = (os.epoch("utc") - z.startTime) / 1000
                if mined > 0 and found > mined and elapsed > 0 then
                    eta = math.floor((found - mined) / (mined / elapsed))
                elseif z.done > 0 and z.total > z.done and elapsed > 0 then
                    eta = math.floor(elapsed / z.done * (z.total - z.done))
                end
            end
            local minerId  = state.jobs[jid] and state.jobs[jid].assignedTo or nil
            local minerSt  = minerId and state.registry[minerId] and state.registry[minerId].status or nil
            mineZones[jid] = {
                bounds        = cp(z.bounds),
                rawBounds     = cp(z.rawBounds),
                total         = z.total,
                done          = z.done,
                pct           = pct,
                eta           = eta,
                oreFound      = cp(z.oreFound),
                oreMined      = cp(z.oreMined),
                minerId       = minerId,
                minerStatus   = minerSt,
                status        = "ACTIVE",
                phase         = z.phase or "MINE",
                surveyDone    = z.surveyDone or 0,
                surveyTotal   = z.surveyTotal or 0,
                rescanDone    = z.rescanDone  or 0,
                rescanTotal   = z.rescanTotal or 0,
                persistentKey = z.persistentKey or nil,
            }
            if z.persistentKey then activeKeys[z.persistentKey] = true end
        end
        -- Historical zones — persistent zones with no current active job.
        -- Include zones with 0 completed mine sectors (crashed during survey) so
        -- the user can see them and they are not silently re-dispatched from scratch.
        for key, pz in pairs(state.persistentZones) do
            if not activeKeys[key] and pz.doneSectors then
                local done = #pz.doneSectors
                -- Ore-based pct if data available; sector-based fallback for old zones
                local pct = orePct(pz.oreFound, pz.oreMined)
                           or (pz.total > 0 and math.floor(done / pz.total * 100) or 0)
                -- rawBounds may be absent on old on-disk zones; compute from visual bounds as fallback
                local rb = pz.rawBounds
                if not rb and pz.bounds then
                    rb = { x1 = pz.bounds.x1 + SCAN_RADIUS, z1 = pz.bounds.z1 + SCAN_RADIUS,
                           x2 = pz.bounds.x2 - SCAN_RADIUS, z2 = pz.bounds.z2 - SCAN_RADIUS }
                end
                mineZones["zone:" .. key] = {
                    bounds      = cp(pz.bounds),
                    rawBounds   = cp(rb),
                    total       = pz.total,
                    done        = done,
                    pct         = pct,
                    eta         = nil,
                    oreFound    = cp(pz.oreFound),
                    oreMined    = cp(pz.oreMined),
                    minerId     = nil,
                    minerStatus = nil,
                    status      = "HISTORICAL",
                    surveyed    = pz.surveyed or false,
                    -- sectorOreMap excluded: per-sector maps grow to thousands of
                    -- entries across historical zones and block the event loop when
                    -- serialised every few seconds. Totals above are sufficient.
                }
            end
        end
        -- Serialise each section independently.  If one field has a bad table
        -- (mixed integer+string keys from corrupted on-disk data or peripheral quirk)
        -- the push still succeeds with a safe fallback for that section.
        local function js(val, fallback, label)
            local ok, r = pcall(textutils.serialiseJSON, val)
            if not ok then
                logWarn("Bridge serialise[" .. label .. "] failed: " .. tostring(r))
                return fallback
            end
            return r
        end
        -- Include last 100 log lines so the bridge can expose them for monitoring.
        local logSlice = {}
        local logStart = math.max(1, #state.log - 99)
        for i = logStart, #state.log do
            table.insert(logSlice, state.log[i])
        end
        local payload = '{"turtles":'      .. js(turtles,             "{}",  "turtles") ..
                        ',"jobs":'         .. jobs ..
                        ',"version":'      .. js(proto.VERSION,        '"?"', "version") ..
                        ',"storage":'      .. storageJSON ..
                        ',"mineZones":'    .. js(mineZones,            "{}",  "mineZones") ..
                        ',"oreThresholds":' .. js(oreThresholds,       "{}",  "oreThresholds") ..
                        ',"serverLog":'    .. js(logSlice,             "[]",  "serverLog") ..
                        ',"turtleLogs":'   .. js(state.turtleLogs,     "{}",  "turtleLogs") .. '}'
        return payload
    end

    logInfo(string.format("Central server online v%s  ID: %s", proto.VERSION, proto.selfId()))
    W.loadDockAssignments()
    loadJobs()
    loadPersistentZones()
    loadMiningZones()
    loadOreThresholds()
    print("Console ready. Type 'help' for commands.")

    local dispatchTimer    = os.startTimer(CFG.DISPATCH_INTERVAL)
    local healthTimer      = os.startTimer(CFG.HEARTBEAT_TIMEOUT)
    local bridgeTimer      = os.startTimer(CFG.BRIDGE_INTERVAL)
    local staleTimer       = os.startTimer(30)
    local oreWatchdogTimer = os.startTimer(60)
    -- RS peripheral calls block the event loop for several seconds — keep them
    -- on their own timers so they never run inside the bridge push path.
    local storageTimer     = os.startTimer(30)
    local craftableTimer   = os.startTimer(60)
    pcall(refreshStorage)
    pcall(refreshCraftable)

    -- Async bridge push state.  A push is fire-and-forget: http.request returns
    -- immediately, the response arrives as http_success / http_failure in the main
    -- event loop.  No parallel.waitForAny means no event consumption side-effects.
    local bridgePending   = false
    local bridgeTimeoutId = nil

    local function startBridgePush()
        if bridgePending then return end
        local ok, payload = pcall(buildBridgePayload)
        if not ok then
            logWarn("Bridge payload build error: " .. tostring(payload))
            return
        end
        local started = http.request(CFG.BRIDGE_URL, payload, { ["Content-Type"] = "application/json" })
        if started then
            bridgePending   = true
            bridgeTimeoutId = os.startTimer(15)
        else
            logWarn("Bridge: http.request could not start")
        end
    end

    -- Push immediately on startup so bridge sees the freshly-reset registry
    -- before any turtles re-register, flushing ghost entries from before reboot.
    startBridgePush()

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

        elseif event == "http_success" then
            -- Async bridge response — process only if it's our push and we're waiting.
            if p1 == CFG.BRIDGE_URL and bridgePending then
                bridgePending = false
                if bridgeTimeoutId then os.cancelTimer(bridgeTimeoutId); bridgeTimeoutId = nil end
                local ok_r, code, body = pcall(function()
                    local c = p2.getResponseCode()
                    local b = p2.readAll()
                    p2.close()
                    return c, b
                end)
                if ok_r then
                    if code ~= 200 then
                        logWarn("Bridge HTTP " .. tostring(code) .. ": " .. (body or ""):sub(1, 60))
                    else
                        local ok2, data = pcall(textutils.unserialiseJSON, body)
                        if ok2 and type(data) == "table" and type(data.commands) == "table" then
                            for _, cmd in ipairs(data.commands) do
                                pcall(handleBridgeCommand, cmd)
                            end
                        end
                        if pendingUpdate then
                            pendingUpdate = false
                            logWarn("UPDATE_ALL — updating server in 3s...")
                            sleep(3)
                            if fs.exists("updater.lua") then shell.run("updater") end
                            -- Always reboot after update attempt: sleep() and shell.run() consume
                            -- timer events, leaving dispatchTimer/bridgeTimer/healthTimer stale.
                            -- A clean reboot is the only safe recovery.
                            os.reboot()
                        end
                    end
                else
                    logWarn("Bridge response read error: " .. tostring(code))
                    pcall(function() p2.close() end)
                end
            end

        elseif event == "http_failure" then
            if p1 == CFG.BRIDGE_URL and bridgePending then
                bridgePending = false
                if bridgeTimeoutId then os.cancelTimer(bridgeTimeoutId); bridgeTimeoutId = nil end
                logWarn("Bridge push failed: " .. tostring(p2))
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
                local ok2, err2 = pcall(jobQueue.checkGhosts)
                if not ok2 then logError("Ghost check: " .. tostring(err2)) end
                local ok3, err3 = pcall(checkOrphanedMiners)
                if not ok3 then logError("Orphan check: " .. tostring(err3)) end
                healthTimer = os.startTimer(CFG.HEARTBEAT_TIMEOUT)

            elseif p1 == bridgeTimer then
                local ok_bp, err_bp = pcall(startBridgePush)
                if not ok_bp then logError("Bridge push error: " .. tostring(err_bp)) end
                bridgeTimer = os.startTimer(CFG.BRIDGE_INTERVAL)

            elseif p1 == staleTimer then
                local ok, err = pcall(checkStaleSupports)
                if not ok then logError("Stale support check: " .. tostring(err)) end
                staleTimer = os.startTimer(30)

            elseif p1 == oreWatchdogTimer then
                local ok, err = pcall(checkOreThresholds)
                if not ok then logError("Ore watchdog: " .. tostring(err)) end
                oreWatchdogTimer = os.startTimer(60)

            elseif p1 == bridgeTimeoutId then
                bridgePending   = false
                bridgeTimeoutId = nil
                logWarn("Bridge push timed out (>15s)")

            elseif p1 == storageTimer then
                -- Runs on its own timer so the blocking peripheral scan never
                -- happens inside startBridgePush() where it would stall the event loop.
                pcall(refreshStorage)
                storageTimer = os.startTimer(30)

            elseif p1 == craftableTimer then
                pcall(refreshCraftable)
                craftableTimer = os.startTimer(60)

            end

        elseif event == "char" then
            -- pcall so a throw from handleConsoleChar can't kill server.run
            pcall(handleConsoleChar, p1)

        elseif event == "key" then
            -- p1 = key code; 28 = Enter, 14 = Backspace
            -- pcall so a throw from handleConsoleEnter can't kill server.run
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

-- Auto-reboot on crash: server.run() crashing silently leaves the bridge stale
-- forever with no log. Wrap it so any unhandled error is printed and the
-- computer reboots itself (turtles re-register when server comes back up).
while true do
    local ok, err = pcall(server.run)
    if not ok then
        print("[FATAL] server.run crashed: " .. tostring(err))
        print("Rebooting in 5 seconds...")
        sleep(5)
        os.reboot()
    end
end
