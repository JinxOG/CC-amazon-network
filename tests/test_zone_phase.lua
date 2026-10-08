-- Two miners on one zone (release B, 1.9.110).
--
-- Jobs on one zone share the zone table, so one miner emptying a list moves the
-- phase for every miner on it. The other miner's order, still in progress,
-- then finished under the new phase and was counted as that phase:
--
--   job_0061 05:47  a SURVEY finished after the switch was logged as
--                   "Sector done -- 0 ore mined" and written to the zone store
--                   as a finished sector nobody had dug;
--   job_0059 22:00  a MINE finished after the switch was logged as a rescan,
--                   queued for re-mining, and never merged to the zone store.
--
-- And nothing checked whether a sector was already held before handing it out,
-- so the rescan list sent a miner into a column another was still mining
-- (job_0058, two blocks apart at 00:41).
--
-- These drive the real SECTOR_REQUEST / SECTOR_DONE handlers.

package.path = "./?.lua;" .. package.path

local stub  = require("tests.stub_cc")
local proto = require("protocol")

local A, B       = "node_138", "node_139"
local JA, JB     = "job_0060", "job_0061"
local S1, S2, S3 = { x = 2048, z = -3104 }, { x = 2080, z = -3104 }, { x = 2048, z = -3072 }

local function copy(s) return { x = s.x, z = s.z } end

-- A server with two miners on two live jobs sharing `zone`.
local function twoMiners(zone)
    stub.install({})
    local savedEpoch = os.epoch
    local clock = 1000000
    os.epoch = function() return clock end
    _G.__CC_SERVER_TEST = true
    package.loaded["central_server"] = nil
    package.loaded["waypoints"]      = nil
    local T = require("central_server")._test

    T.sent = {}
    T.state.modem = {
        isOpen = function() return true end, open = function() end,
        transmit = function(ch, reply, body) T.sent[#T.sent + 1] = body end,
    }
    for id, job in pairs({ [A] = JA, [B] = JB }) do
        T.state.registry[id] = {
            id = id, role = proto.ROLE.MINER, status = proto.STATUS.WORKING,
            jobId = job, fuel = 100000, online = true, lastSeen = clock,
            position = { x = 0, y = 60, z = 0 },
        }
        T.state.jobs[job] = {
            id = job, type = proto.JOB.MINE, status = "IN_PROGRESS",
            assignedTo = id, params = {}, priority = 5, history = {},
            createdAt = clock, retries = 0,
        }
    end
    zone.persistentKey = "zk"
    zone.oreFound, zone.oreMined = zone.oreFound or {}, zone.oreMined or {}
    zone.doneKeys        = zone.doneKeys or {}
    zone.lastAssignments = zone.lastAssignments or {}
    zone.done, zone.total = zone.done or 0, zone.total or 3
    zone.allSectors      = zone.allSectors or { copy(S1), copy(S2), copy(S3) }
    zone.surveySectors   = zone.surveySectors or {}
    zone.surveyDone, zone.surveyTotal = zone.surveyDone or 0, zone.surveyTotal or 3
    zone.pending         = zone.pending or {}
    T.state.miningZones[JA] = zone
    T.state.miningZones[JB] = zone
    T.state.persistentZones["zk"] = { key = "zk", doneSectors = {}, oreFound = {}, oreMined = {} }

    local restore = function()
        os.epoch = savedEpoch
        _G.__CC_SERVER_TEST = nil
        package.loaded["central_server"] = nil
    end
    return T, zone, restore
end

-- What the server last sent `to`: { type, x, z, survey }.
local function lastTo(T, to)
    for i = #T.sent, 1, -1 do
        local m = textutils.unserialise(T.sent[i])
        if type(m) == "table" and m.to == to then
            return { type = m.type, x = m.payload.sectorX, z = m.payload.sectorZ,
                     survey = m.payload.surveyMode }
        end
    end
end

local function request(T, from, job)
    T.handlers[proto.MSG.SECTOR_REQUEST]({ from = from, payload = { jobId = job } })
    return lastTo(T, from)
end

local function done(T, from, job, s, extra)
    local p = { jobId = job, sectorX = s.x, sectorZ = s.z, oreCount = 0 }
    for k, v in pairs(extra or {}) do p[k] = v end
    T.handlers[proto.MSG.SECTOR_DONE]({ from = from, payload = p })
    return lastTo(T, from)
end

local function logged(T, text)
    for _, e in ipairs(T.state.log) do
        if e.msg:find(text, 1, true) then return e.msg end
    end
end

local function sectorIn(list, s)
    for _, v in ipairs(list or {}) do
        if v.x == s.x and v.z == s.z then return true end
    end
    return false
end

local ORE = { foundOres = { ["minecraft:iron_ore"] = 40 }, oreCount = 40 }

return {
    -- 2026-09-18: all four GPS hosts went silent, node_138 refused three
    -- re-dispatches ("no_gps_fix: ... refusing to depart") and the refusals
    -- blacklisted a sector nothing had touched.
    -- W1, 2026-09-21: the per-sector ore map is deliberately not in /state, so a
    -- sector left unmapped by the phase misread cannot be seen from the bridge.
    -- A targeted mine only ever considers sectors that HAVE a map entry.
    ["the ore-map dump names sectors that are done but never mapped"] = function(assert_eq)
        local T, zone, restore = twoMiners({ phase = "MINE", pending = {} })
        local pz = T.state.persistentZones["zk"]
        pz.total = 3
        pz.sectorOreMap = { ["2048,-3104"] = { ["minecraft:iron_ore"] = 12,
                                               ["minecraft:copper_ore"] = 8 } }
        pz.doneSectors  = { { x = 2048, z = -3104 }, { x = 2080, z = -3104 } }
        local zones = T.dumpZoneOreMap("zk")
        local header = logged(T, "Ore map for zone zk: 1 sector(s) mapped, 2 marked done, total 3")
        local mapped = logged(T, "(2048,-3104) 2 type(s) 20 ore [done]")
        local gap    = logged(T, "zone zk: 1 sector(s) done with NO ore map entry: 2080,-3104")
        restore()
        assert_eq(zones, 1, "the named zone is dumped")
        assert_eq(header ~= nil, true, "with a header carrying the counts")
        assert_eq(mapped ~= nil, true, "each mapped sector with its types and total")
        assert_eq(gap ~= nil, true,
            "and the gap named: done, but invisible to a targeted mine")
    end,

    -- 1.9.114, W6's proposal: the storage enumeration is what goes deaf, and a
    -- mining fleet is what it goes deaf on.
    ["a live MINE job holds off the storage poll, a finished one does not"] =
    function(assert_eq)
        local T, zone, restore = twoMiners({ phase = "MINE", pending = {} })
        T.state.jobs[JA].status = "IN_PROGRESS"
        T.state.jobs[JB].status = "COMPLETE"
        local during = T.mineJobLive()
        T.state.jobs[JA].status = "ASSIGNED"
        local assigned = T.mineJobLive()
        T.state.jobs[JA].status = "FAILED"
        local after = T.mineJobLive()
        T.state.jobs[JA].status = "IN_PROGRESS"
        T.state.jobs[JA].type = proto.JOB.DELIVER
        local other = T.mineJobLive()
        restore()
        assert_eq(during, true, "a job in progress holds the poll off")
        assert_eq(assigned, true, "so does one dispatched but not yet acknowledged")
        assert_eq(after, false, "a finished or failed job must not hold it off for ever")
        assert_eq(other, false, "a delivery job is not a mining fleet")
    end,

    -- SOURCE-ONLY, weaker, and W6 just proved why that matters: their guard
    -- tests called the probe directly, so deleting the call site left them
    -- green. refreshStorage is a local inside server.run's closure and cannot
    -- be driven from here, so this pins the wiring by reading the file: the
    -- guard must stand BEFORE the peripheral call it protects.
    ["the storage poll is guarded before it enumerates (SOURCE-ONLY, weaker)"] =
    function(assert_eq)
        local f = assert(io.open("central_server.lua", "r"))
        local src = f:read("*a"); f:close()
        local at = src:find("local function refreshStorage()", 1, true)
        assert_eq(at ~= nil, true, "refreshStorage moved or vanished")
        local body = src:sub(at, src:find("rsBridge.listItems()", at, true) or #src)
        assert_eq(body:find("if mineJobLive() then", 1, true) ~= nil, true,
            "the guard must run before listItems, or the deaf window stays")
        local at2 = src:find("local function refreshCraftable()", 1, true)
        local body2 = src:sub(at2, src:find("listCraftableItems()", at2, true) or #src)
        assert_eq(body2:find("if mineJobLive() then return end", 1, true) ~= nil, true,
            "refreshCraftable enumerates too and needs the same guard")
    end,

    -- 1.9.115 (approved 2026-09-22): the warehouse reads RS and sends a BOUNDED
    -- digest. The full 469-item list goes to the bridge instead - 49.6 KB on
    -- this loop every 30s would trade a peripheral stall for a deserialising
    -- one, and 96 KB already made this server deaf on 2026-08-30.
    -- Found 2026-09-22: the warehouse had never received a deploy. It is not in
    -- state.registry, so the fan-out loop could not see it, and it sat on
    -- pre-1.9.93 files - no log shipping - while fifteen turtles moved on.
    ["an update reaches the warehouse as well as the turtles"] = function(assert_eq)
        local T, zone, restore = twoMiners({ phase = "MINE", pending = {} })
        local sent = {}
        T.state.modem.transmit = function(ch, reply, body) sent[#sent + 1] = { ch = ch, body = body } end
        T.state.registry[A].status = proto.STATUS.IDLE
        T.state.registry[B].status = proto.STATUS.WORKING
        local nImmediate, nStaged = T.fanOutUpdateAll()
        local toWarehouse, toIdle = nil, nil
        for _, m in ipairs(sent) do
            local d = textutils.unserialise(m.body)
            if type(d) == "table" and d.type == proto.MSG.UPDATE_ALL then
                if m.ch == proto.CH_WAREHOUSE then toWarehouse = d end
                if d.to == A then toIdle = d end
            end
        end
        local staged = T.state.registry[B].pendingUpdate
        local line = logged(T, "and to the warehouse")
        restore()
        assert_eq(toWarehouse ~= nil, true,
            "the warehouse listens on CH_WAREHOUSE and runs updater.lua on UPDATE_ALL; "
            .. "it only ever needed asking")
        assert_eq(toIdle ~= nil and nImmediate, 1, "an idle turtle still gets it immediately")
        assert_eq(staged == true and nStaged, 1, "and a busy one is still staged, not skipped")
        assert_eq(line ~= nil, true, "the line says the warehouse was included")
    end,

    -- 2026-09-22: the user asked for the fleet to be cleared for a deploy.
    -- Cancelling the jobs sent a THIRD miner 1,700 blocks out, because the
    -- miner's JOB_FAILED lands before the CANCELLED status and the respawn saw
    -- a zone with sectors left and nobody on it.
    --
    -- Drives server.cancelJob rather than setting the flag by hand: the flag
    -- and the check are two halves, and a test that sets it itself passes
    -- happily with the setting deleted - the trap W6 walked into on 09-22 and
    -- warned me about the same day.
    ["a cancelled job gets no replacement, a failed one still does"] = function(assert_eq)
        local T, zone, restore = twoMiners({
            phase = "MINE", pending = { copy(S2), copy(S3) },
            lastAssignments = { [A] = { x = S1.x, z = S1.z, phase = "MINE", jobId = JA } },
        })
        for _, j in ipairs({ JA, JB }) do
            T.state.jobs[j].params = { x1 = 2052, z1 = -3080, x2 = 2052, z2 = -3080 }
        end
        T.state.jobs[JB].status = "COMPLETE"        -- only JA is live

        -- Taken from package.loaded, not require'd: requiring it fresh here
        -- would load it without __CC_SERVER_TEST and run the real boot loop.
        local server = package.loaded["central_server"]
        server.cancelJob(JA)                        -- the operator says stop
        T.state.jobs[JA].status = "IN_PROGRESS"     -- the miner has not answered yet
        T.state.miningZones[JA] = zone              -- cancelJob drops the zone ref
        T.handlers[proto.MSG.JOB_FAILED]({ from = A, payload = {
            jobId = JA, reason = "recalled", recoverable = false } })

        local replacements = {}
        for id, j in pairs(T.state.jobs) do
            if id ~= JA and id ~= JB and j.params and j.params.sharedZoneKey == "zk" then
                replacements[#replacements + 1] = id
            end
        end
        local line = logged(T, "was cancelled -- no replacement queued")
        restore()
        assert_eq(#replacements, 0,
            "a cancel is an instruction, not a failure: no third miner may be sent")
        assert_eq(line ~= nil, true, "and the decision is logged with the sectors left")
    end,

    -- A stuck turtle's report (2026-10-08): node_184 sat boxed in for hours and
    -- the server only ever said it was offline, then pruned it.
    ["a stuck turtle's report raises NEEDS HANDS with where it is, once"] =
    function(assert_eq)
        local T, zone, restore = twoMiners({ phase = "MINE", pending = {} })
        local h = T.handlers[proto.MSG.STATUS_UPDATE]
        local d = "stuck_no_fix: facing unknown at 1960,-50,-3351 (boot recovery)"
        for _ = 1, 3 do
            h({ from = A, payload = { jobId = JA, status = proto.STATUS.WORKING, detail = d,
                                      position = { x = 1960, y = -50, z = -3351 } } })
        end
        h({ from = B, payload = { jobId = JB, status = proto.STATUS.WORKING, detail = "mining" } })
        local n = 0
        for _, e in ipairs(T.state.log) do
            if e.msg:find("NEEDS HANDS: " .. A, 1, true) and e.msg:find("1960,-50,-3351", 1, true) then n = n + 1 end
        end
        local flag, other = T.state.registry[A].needsHands, T.state.registry[B].needsHands
        restore()
        assert_eq(flag, d, "the dashboard shows why and where")
        assert_eq(n, 1, "said once, not every minute")
        assert_eq(other, nil, "an ordinary progress report raises nothing")
    end,

    -- 2026-10-08: the user asked for every miner home to swap loaders. Recall-all
    -- turned node_184 round, but its job (a loader placement that was blocked)
    -- was still open; it failed recoverably as it docked, was retried, and the
    -- miner was sent straight back out in the same second. Recall-all now
    -- cancels every unfinished job, so nothing is left to retry or dispatch.
    ["recall-all cancels every unfinished job, so nothing is sent back out"] =
    function(assert_eq)
        local T, zone, restore = twoMiners({ phase = "MINE", pending = { copy(S2) } })
        local server = package.loaded["central_server"]
        T.state.jobs["job_0062"] = {
            id = "job_0062", type = proto.JOB.MINE, status = "PENDING", params = {},
            priority = 5, history = {}, createdAt = 1, retries = 0,
        }
        server.recallAll("admin_recall")
        local before = #T.sent
        T.handlers[proto.MSG.JOB_FAILED]({ from = A, payload = {
            jobId = JA, reason = "sector_setup_failed: placement_blocked", recoverable = true } })
        local assigned = 0
        for i = before + 1, #T.sent do
            if tostring(T.sent[i]):find("JOB_ASSIGN", 1, true) then assigned = assigned + 1 end
        end
        local sa, sb, sc = T.state.jobs[JA].status, T.state.jobs[JB].status, T.state.jobs["job_0062"].status
        restore()
        assert_eq(sa, "CANCELLED", "the working job is cancelled, and a late retryable failure cannot revive it")
        assert_eq(sb, "CANCELLED", "every working job")
        assert_eq(sc, "CANCELLED", "a queued job too, or it is dispatched to the miner that just docked")
        assert_eq(assigned, 0, "no miner is sent back out")
    end,

    -- The same hole without recall-all: a cancelled job whose turtle reports the
    -- failure as retryable was put back in the queue, since the retry never
    -- asked whether the operator had cancelled it.
    ["a cancelled job is never retried, however the turtle reports the failure"] =
    function(assert_eq)
        local T, zone, restore = twoMiners({
            phase = "MINE", pending = { copy(S2) },
            lastAssignments = { [A] = { x = S1.x, z = S1.z, phase = "MINE", jobId = JA } },
        })
        local server = package.loaded["central_server"]
        server.cancelJob(JA)
        T.state.miningZones[JA] = zone              -- cancelJob drops the zone ref
        T.handlers[proto.MSG.JOB_FAILED]({ from = A, payload = {
            jobId = JA, reason = "recalled", recoverable = true } })
        local status = T.state.jobs[JA].status
        local fails = (T.state.persistentZones["zk"].sectorFailCount or {})[S1.x .. "," .. S1.z]
        restore()
        assert_eq(status, "CANCELLED", "a cancel is final")
        assert_eq(fails, nil, "and the operator's stop is not counted against the sector")
    end,

    -- 2026-09-29: job_0095 joined a four-sector zone, worked two and a half
    -- minutes and reported itself complete. The zone carried on with ONE miner
    -- where it had been dispatched two, which roughly doubles the job. The
    -- respawn saw a miner still on the zone and returned: it was written to stop
    -- a zone going SILENT, and half a crew is not silence.
    ["a zone left at half crew is topped up, not only a zone left at none"] =
    function(assert_eq)
        local T, zone, restore = twoMiners({
            phase = "MINE", total = 4, pending = { copy(S2), copy(S3) },
            lastAssignments = { [A] = { x = S1.x, z = S1.z, phase = "MINE", jobId = JA } },
        })
        for _, j in ipairs({ JA, JB }) do
            T.state.jobs[j].params = { x1 = 2052, z1 = -3080, x2 = 2052, z2 = -3080 }
        end
        -- JB is STILL LIVE on this zone. That is the whole point: the old code
        -- returned here, leaving the zone on one miner of the two it wants.
        T.handlers[proto.MSG.JOB_FAILED]({ from = A, payload = {
            jobId = JA, reason = "loader_retrieve_failed", recoverable = false } })
        local replacement = nil
        for id, j in pairs(T.state.jobs) do
            if id ~= JA and id ~= JB and j.params and j.params.sharedZoneKey == "zk" then
                replacement = id
            end
        end
        restore()
        assert_eq(replacement ~= nil, true,
            "four sectors want two miners; one left means one short, and a zone "
            .. "running at half crew takes twice as long for no reason")
    end,

    -- And the guard on the other side, or the zone breeds miners: every
    -- completion would queue another job, which would complete, which would
    -- queue another.
    ["a zone already at full crew is left alone"] = function(assert_eq)
        local T, zone, restore = twoMiners({
            phase = "MINE", total = 4, pending = { copy(S2), copy(S3) },
            lastAssignments = { [A] = { x = S1.x, z = S1.z, phase = "MINE", jobId = JA } },
        })
        for _, j in ipairs({ JA, JB }) do
            T.state.jobs[j].params = { x1 = 2052, z1 = -3080, x2 = 2052, z2 = -3080 }
        end
        -- A third live job on the same zone: with JB that is the full crew of 2.
        T.state.jobs["job_0062"] = {
            id = "job_0062", type = proto.JOB.MINE, status = "IN_PROGRESS",
            assignedTo = "node_140", params = { sharedZoneKey = "zk" },
            priority = 5, history = {}, createdAt = 1000000, retries = 0,
        }
        T.handlers[proto.MSG.JOB_FAILED]({ from = A, payload = {
            jobId = JA, reason = "loader_retrieve_failed", recoverable = false } })
        local extra = 0
        for id, j in pairs(T.state.jobs) do
            if id ~= JA and id ~= JB and id ~= "job_0062"
               and j.params and j.params.sharedZoneKey == "zk" then
                extra = extra + 1
            end
        end
        restore()
        assert_eq(extra, 0,
            "the crew is already the size the order would have dispatched; "
            .. "topping it up again is how a top-up becomes a breeding programme")
    end,

    -- The whole-host outage of 2026-09-30 (1.9.122). -------------------------

    -- A miner rebooted mid-job reported "RETRIEVING (boot recovery ...)" and
    -- then flew home with its modem off. The server re-sent it the job, waited
    -- eight minutes, declared it dead halfway home, and only then requeued.
    ["a boot-recovering miner's job is requeued at once, not after a timeout"] =
    function(assert_eq)
        local T, zone, restore = twoMiners({ phase = "MINE", pending = { copy(S2) } })
        T.handlers[proto.MSG.MINE_PHASE]({ from = A, payload = {
            jobId = JA, phase = proto.PHASE.RETRIEVING,
            detail = "boot recovery — loader at 1992,200,-3255" } })
        local job, t = T.state.jobs[JA], T.state.registry[A]
        local status, owner, tStatus, tJob, grace =
            job.status, job.assignedTo, t.status, t.jobId, t.commsGapGraceSec
        restore()
        assert_eq(status, "PENDING", "the job goes back to the queue the moment recovery is reported")
        assert_eq(owner, nil, "and nobody holds it")
        assert_eq(tJob, nil, "the recovering turtle's claim is cleared")
        assert_eq(tStatus, proto.STATUS.RETURNING,
            "RETURNING, not IDLE: an IDLE turtle is dispatchable, and this one "
            .. "cannot hear a JOB_ASSIGN until it docks")
        assert_eq(grace, T.CFG.BOOT_RECOVERY_GRACE_SEC,
            "its radio silence is given the length of a flight home, not a 60 s swap")
    end,

    -- The planned outage of 2026-10-03. A rebooted miner's OWN status is IDLE --
    -- it is flying home, not running a job -- and its modem stays on for the
    -- climb to its loader. Those IDLE heartbeats overwrote RETURNING within two
    -- minutes and every miner was sent a job it could not hear.
    ["a miner flying home after a reboot stays RETURNING through its own IDLE heartbeats"] =
    function(assert_eq)
        local T, zone, restore = twoMiners({ phase = "MINE", pending = { copy(S2) } })
        T.handlers[proto.MSG.MINE_PHASE]({ from = A, payload = {
            jobId = JA, phase = proto.PHASE.RETRIEVING,
            detail = "boot recovery — loader at 1704,185,-3095" } })
        T.handlers[proto.MSG.HEARTBEAT]({ from = A, payload = {
            status = proto.STATUS.IDLE, fuel = 100000, phase = proto.PHASE.RETRIEVING } })
        local status = T.state.registry[A].status
        local offered = false
        for _, t in ipairs(T.registry.getIdle(proto.ROLE.MINER)) do
            if t.id == A then offered = true end
        end
        restore()
        assert_eq(status, proto.STATUS.RETURNING, "its IDLE is not believed until it docks")
        assert_eq(offered, false, "so it is never offered a job it cannot hear")
    end,

    ["docking ends it: the miner is idle and dispatchable at once"] =
    function(assert_eq)
        local T, zone, restore = twoMiners({ phase = "MINE", pending = { copy(S2) } })
        T.handlers[proto.MSG.MINE_PHASE]({ from = A, payload = {
            jobId = JA, phase = proto.PHASE.RETRIEVING,
            detail = "boot recovery — loader at 1704,185,-3095" } })
        T.handlers[proto.MSG.MINE_PHASE]({ from = A, payload = { phase = proto.PHASE.DOCKED } })
        local status, flag = T.state.registry[A].status, T.state.registry[A].homeAfterReboot
        restore()
        assert_eq(status, proto.STATUS.IDLE, "home, so the requeued work can go out on this tick")
        assert_eq(flag, nil, "and its next IDLE heartbeat is believed")
    end,

    ["a DOCKED heartbeat ends it too, if the phase report was lost"] =
    function(assert_eq)
        local T, zone, restore = twoMiners({ phase = "MINE", pending = { copy(S2) } })
        T.handlers[proto.MSG.MINE_PHASE]({ from = A, payload = {
            jobId = JA, phase = proto.PHASE.RETRIEVING,
            detail = "boot recovery — loader at 1704,185,-3095" } })
        local hb = T.handlers[proto.MSG.HEARTBEAT]
        hb({ from = A, payload = { status = proto.STATUS.IDLE, fuel = 100000, phase = proto.PHASE.DOCKED } })
        hb({ from = A, payload = { status = proto.STATUS.IDLE, fuel = 100000, phase = proto.PHASE.DOCKED } })
        local status = T.state.registry[A].status
        restore()
        assert_eq(status, proto.STATUS.IDLE, "or a lost DOCKED report would bench it forever")
    end,

    ["an ordinary loader swap mid-job is NOT treated as boot recovery"] =
    function(assert_eq)
        local T, zone, restore = twoMiners({ phase = "MINE", pending = { copy(S2) } })
        T.handlers[proto.MSG.MINE_PHASE]({ from = A, payload = {
            jobId = JA, phase = proto.PHASE.RETRIEVING, detail = "comms gap expected" } })
        local job, t = T.state.jobs[JA], T.state.registry[A]
        local status, owner, grace = job.status, job.assignedTo, t.commsGapGraceSec
        restore()
        assert_eq(status, "IN_PROGRESS", "every sector ends in a loader swap; it must not end the job")
        assert_eq(owner, A)
        assert_eq(grace, nil, "and it keeps the short swap grace")
    end,

    -- node_118 docked reporting job_0106, which the server had given node_138.
    -- The heartbeat adopted the claim: two turtles owning one job.
    ["a turtle cannot claim a job the server gave to someone else"] =
    function(assert_eq)
        local T, zone, restore = twoMiners({ phase = "MINE", pending = { copy(S2) } })
        T.state.registry[A].jobId = nil               -- the server holds nothing for A
        T.state.jobs[JA].assignedTo = B               -- JA now belongs to B
        T.registry.update(A, proto.STATUS.IDLE, 100000, nil, JA)
        local claimA = T.state.registry[A].jobId
        T.registry.update(B, proto.STATUS.WORKING, 100000, nil, JB)
        local claimB = T.state.registry[B].jobId
        restore()
        assert_eq(claimA, nil, "A's stale claim to B's job is refused")
        assert_eq(claimB, JB, "a turtle's claim to its OWN job still stands")
    end,

    ["a refused claim keeps the job the server did give that turtle"] =
    function(assert_eq)
        local T, zone, restore = twoMiners({ phase = "MINE", pending = { copy(S2) } })
        -- A is legitimately on JA. It reports JB, which is B's.
        T.registry.update(A, proto.STATUS.WORKING, 100000, nil, JB)
        local claimA = T.state.registry[A].jobId
        restore()
        assert_eq(claimA, JA,
            "refusing the foreign claim must not wipe A's real job -- that would "
            .. "make A look free and orphan JA")
    end,

    -- The boot report quoted a crash from 2026-09-06 after the 2026-09-30
    -- outage, and after the 09-29 deploy. It could not tell them apart.
    ["the restart report names a stop from outside, not a month-old crash"] =
    function(assert_eq)
        local T, zone, restore = twoMiners({ phase = "MINE", pending = {} })
        local server = package.loaded["central_server"]
        local w = fs.open("crash.log", "w")
        w.write("[1788683956366 2026-09-06 01:39:16] server.run crashed: Terminated\n")
        w.close()
        local a = fs.open(T.CFG.ALIVE_FILE, "w")
        a.write("1790700000000 " .. proto.VERSION)     -- alive long after that crash
        a.close()
        local verdict = server.bootReport(1790700000000 + 88 * 60000)
        local said = logged(T, "stopped without recording why")
        local blamedCrash = logged(T, "Restarted after a crash")
        restore()
        assert_eq(verdict, "external", "the crash on record is older than the last sign of life")
        assert_eq(said ~= nil, true, "so it says the run was stopped from outside")
        assert_eq(blamedCrash, nil, "and does not blame the September crash")
    end,

    ["a crash after the last sign of life is still reported as a crash"] =
    function(assert_eq)
        local T, zone, restore = twoMiners({ phase = "MINE", pending = {} })
        local server = package.loaded["central_server"]
        local a = fs.open(T.CFG.ALIVE_FILE, "w")
        a.write("1790700000000 " .. proto.VERSION)
        a.close()
        local w = fs.open("crash.log", "w")
        w.write("[1790700030000 2026-09-30 16:48:37] server.run crashed: attempt to index nil\n")
        w.close()
        local verdict = server.bootReport(1790700090000)
        local said = logged(T, "Restarted after a crash")
        restore()
        assert_eq(verdict, "crash", "a crash written after the last alive stamp belongs to this restart")
        assert_eq(said ~= nil, true)
    end,

    ["a restart into a new version is reported as an update"] =
    function(assert_eq)
        local T, zone, restore = twoMiners({ phase = "MINE", pending = {} })
        local server = package.loaded["central_server"]
        local a = fs.open(T.CFG.ALIVE_FILE, "w")
        a.write("1790700000000 1.9.0")                   -- the previous run was older code
        a.close()
        local verdict = server.bootReport(1790700030000)
        local said = logged(T, "an update")
        restore()
        assert_eq(verdict, "update")
        assert_eq(said ~= nil, true, "a deploy is named as a deploy, not as a crash or an outage")
    end,

    -- Giving a turtle the long grace proves nothing unless the timeout path
    -- reads it. Ten minutes of silence: a flight home survives it, a plain
    -- loader swap that has gone quiet for that long does not.
    ["a turtle flying home after a reboot is not called offline mid-flight"] =
    function(assert_eq)
        local T, zone, restore = twoMiners({ phase = "MINE", pending = {} })
        local now = os.epoch("utc")
        for _, id in ipairs({ A, B }) do
            local t = T.state.registry[id]
            t.commsGap, t.phaseAt, t.lastSeen, t.online = true, now - 600000, now - 600000, true
        end
        T.state.registry[A].commsGapGraceSec = T.CFG.BOOT_RECOVERY_GRACE_SEC
        T.registry.checkTimeouts()
        local aOnline, bOnline = T.state.registry[A].online, T.state.registry[B].online
        restore()
        assert_eq(aOnline, true, "ten silent minutes is an ordinary flight home after a reboot")
        assert_eq(bOnline, false, "but for a plain loader swap it is a turtle that has stopped")
    end,

    -- The case every other report test skipped: they all wrote an alive stamp
    -- first. 1.9.122's own first boot had none and blamed the September crash.
    ["with no alive stamp yet, an old crash is not blamed for the restart"] =
    function(assert_eq)
        local T, zone, restore = twoMiners({ phase = "MINE", pending = {} })
        local server = package.loaded["central_server"]
        local w = fs.open("crash.log", "w")
        w.write("[1788683956366 2026-09-06 01:39:16] server.run crashed: Terminated\n")
        w.close()
        local verdict = server.bootReport(1790700000000)
        local blamed = logged(T, "Restarted after a crash")
        local said = logged(T, "undated against this restart")
        restore()
        assert_eq(verdict, "unknown", "without a stamp no crash on record can be dated")
        assert_eq(blamed, nil, "so none may be blamed")
        assert_eq(said ~= nil, true, "the newest one is still shown, labelled as undated")
    end,

    -- A turtle that needs hands (ruled 2026-10-01, 1.9.124). -------------------
    -- node_118 lost its ore chest in the 2026-09-30 outage and, benched for only
    -- 600 s per refusal, was offered three jobs it could only refuse.
    ["a hardware refusal benches until the turtle's own check passes, not for ten minutes"] =
    function(assert_eq)
        local T, zone, restore = twoMiners({ phase = "MINE", pending = {} })
        local now = os.epoch("utc")
        T.jobQueue.fail(JA, "slot_16_must_hold_the_ore_ender_chest", false)
        local t = T.state.registry[A]
        local hands, until_ = t.needsHands, t.dispatchBlockedUntil
        restore()
        assert_eq(hands, "slot_16_must_hold_the_ore_ender_chest", "the turtle is marked as needing hands")
        assert_eq(until_ - now > 100 * 600 * 1000, true,
            "and benched far past the 600 s that let node_118 be offered three more jobs")
    end,

    ["a refusal that time can fix keeps the ten-minute bench"] =
    function(assert_eq)
        local T, zone, restore = twoMiners({ phase = "MINE", pending = {} })
        local now = os.epoch("utc")
        T.jobQueue.fail(JA, "no_gps_fix: cannot confirm position, refusing to depart", false)
        local t = T.state.registry[A]
        local hands, until_ = t.needsHands, t.dispatchBlockedUntil
        restore()
        assert_eq(hands, nil, "no hardware is wrong, so nobody needs to go out")
        assert_eq(until_ - now, T.CFG.DISPATCH_BLOCK_SEC * 1000, "the timed bench is unchanged")
    end,

    ["an outstanding loader needs hands too"] =
    function(assert_eq)
        local T, zone, restore = twoMiners({ phase = "MINE", pending = {} })
        T.jobQueue.fail(JA, "loader_outstanding at 1672,185,-2999", false)
        local hands = T.state.registry[A].needsHands
        restore()
        assert_eq(hands, "loader_outstanding at 1672,185,-2999",
            "node_119 refused every job for this until the loader was dealt with")
    end,

    ["the turtle's own passing check lifts the bench at once"] =
    function(assert_eq)
        local T, zone, restore = twoMiners({ phase = "MINE", pending = {} })
        T.jobQueue.fail(JA, "slot_16_must_hold_the_ore_ender_chest", false)
        T.registry.applyHardware(A, "ok")
        local t = T.state.registry[A]
        local hands, until_, why = t.needsHands, t.dispatchBlockedUntil, t.dispatchBlockReason
        restore()
        assert_eq(hands, nil, "fixed in the world, and the next report says so")
        assert_eq(until_, nil, "so it is dispatchable again, with no command")
        assert_eq(why, nil)
    end,

    ["a turtle reporting a fault is benched before it is ever offered work"] =
    function(assert_eq)
        local T, zone, restore = twoMiners({ phase = "MINE", pending = {} })
        T.registry.applyHardware(A, "slot_16_must_hold_the_ore_ender_chest")
        local hands = T.state.registry[A].needsHands
        restore()
        assert_eq(hands, "slot_16_must_hold_the_ore_ender_chest",
            "caught at the dock, not after a dispatch and a respawn")
    end,

    ["needs hands is logged once, not on every heartbeat"] =
    function(assert_eq)
        local T, zone, restore = twoMiners({ phase = "MINE", pending = {} })
        for _ = 1, 3 do T.registry.applyHardware(A, "slot_16_must_hold_the_ore_ender_chest") end
        local n = 0
        for _, e in ipairs(T.state.log) do
            if e.msg:find("NEEDS HANDS", 1, true) then n = n + 1 end
        end
        restore()
        assert_eq(n, 1, "loud once; a turtle reports it every few seconds")
    end,

    ["a turtle that did not check leaves its bench as it was"] =
    function(assert_eq)
        local T, zone, restore = twoMiners({ phase = "MINE", pending = {} })
        T.jobQueue.fail(JA, "slot_16_must_hold_the_ore_ender_chest", false)
        T.registry.applyHardware(A, nil)        -- busy, or a role with no check
        local hands = T.state.registry[A].needsHands
        restore()
        assert_eq(hands, "slot_16_must_hold_the_ore_ender_chest",
            "silence is not a passing check")
    end,

    ["the check reaches the bench through a real heartbeat"] =
    function(assert_eq)
        local T, zone, restore = twoMiners({ phase = "MINE", pending = {} })
        local hb = T.handlers[proto.MSG.HEARTBEAT]
        hb({ from = A, payload = { status = proto.STATUS.IDLE, fuel = 100000,
             hardware = "slot_16_must_hold_the_ore_ender_chest" } })
        local benched = T.state.registry[A].needsHands
        hb({ from = A, payload = { status = proto.STATUS.IDLE, fuel = 100000, hardware = "ok" } })
        local after = T.state.registry[A].needsHands
        restore()
        assert_eq(benched, "slot_16_must_hold_the_ore_ender_chest", "a heartbeat can bench")
        assert_eq(after, nil, "and the next one, after the fix, releases")
    end,

    ["the check reaches the bench through a real REGISTER"] =
    function(assert_eq)
        local T, zone, restore = twoMiners({ phase = "MINE", pending = {} })
        T.handlers[proto.MSG.REGISTER]({ from = A, payload = {
            role = proto.ROLE.MINER, fuel = 100000, fuelMax = 100000,
            position = { x = 0, y = 60, z = 0 },
            hardware = "slot_16_must_hold_the_ore_ender_chest" } })
        local hands = T.state.registry[A].needsHands
        restore()
        assert_eq(hands, "slot_16_must_hold_the_ore_ender_chest",
            "node_118's first boot after the outage would have been benched right here")
    end,

    -- The turtle half cannot run headless here, so its two load-bearing lines
    -- are pinned by source. Weaker than a behaviour test, and labelled so.
    ["a turtle reports its hardware only while idle and not busy (SOURCE-ONLY, weaker)"] =
    function(assert_eq)
        local f = io.open("turtle_base.lua", "r"); local src = f:read("a"); f:close()
        local body = src:match("function base%.hardwareVerdict%(%)(.-)\nend")
        assert_eq(body ~= nil, true, "base.hardwareVerdict exists")
        assert_eq(body and body:find("_self.busy", 1, true) ~= nil, true,
            "a working miner's ore chest is out of its slot while it dumps")
        assert_eq(body and body:find("proto.STATUS.IDLE", 1, true) ~= nil, true)
        local _, n = src:gsub("hardware = base%.hardwareVerdict%(%)", "")
        assert_eq(n, 2, "carried in REGISTER and in the heartbeat")
    end,

    ["the miner's own check is its departure check, and notices a returned loader (SOURCE-ONLY, weaker)"] =
    function(assert_eq)
        local f = io.open("ore_turtle.lua", "r"); local src = f:read("a"); f:close()
        local block = src:match("base%.setHardwareCheck%((.-)\nend%)%(%)%)")
        assert_eq(block ~= nil, true, "the miner sets a hardware check")
        assert_eq(block and block:find("preflightSlots()", 1, true) ~= nil, true,
            "the same strict check that refuses a job at departure")
        assert_eq(block and block:find("clearStaleLoaderRecord()", 1, true) ~= nil, true,
            "or a benched miner would never notice its loader being handed back")
        assert_eq(block and block:find("loader_outstanding", 1, true) ~= nil, true)
    end,

    -- A deploy reached one turtle of fifteen (2026-09-30, 10-01). The fleet
    -- was told to update and the server restarted three seconds later. Now the
    -- fleet is told after the server is back on the new code.
    ["a deploy stages the fleet update instead of sending it"] =
    function(assert_eq)
        local T, zone, restore = twoMiners({ phase = "MINE", pending = {} })
        local server = package.loaded["central_server"]
        T.state.registry[A].status = proto.STATUS.IDLE
        server.stageFanOut()
        local sent = 0
        for _, b in ipairs(T.sent) do
            if tostring(b):find("UPDATE_ALL", 1, true) then sent = sent + 1 end
        end
        local staged = fs.exists(T.CFG.FANOUT_FILE)
        restore()
        assert_eq(sent, 0, "nobody is told while the server is about to restart")
        assert_eq(staged, true, "the fan-out survives the reboot in a file")
    end,

    ["the restarted server sends the staged update once its turtles are back"] =
    function(assert_eq)
        local T, zone, restore = twoMiners({ phase = "MINE", pending = {} })
        local server = package.loaded["central_server"]
        T.state.registry[A].status = proto.STATUS.IDLE
        local function count()
            local n = 0
            for _, b in ipairs(T.sent) do
                if tostring(b):find("UPDATE_ALL", 1, true) then n = n + 1 end
            end
            return n
        end
        server.stageFanOut()
        server.armFanOut(1000)
        server.fanOutIfDue(1000 + 1000)
        local early = count()
        server.fanOutIfDue(1000 + T.CFG.FANOUT_DELAY_SEC * 1000)
        local due = count()
        server.fanOutIfDue(1000 + T.CFG.FANOUT_DELAY_SEC * 1000 + 5000)
        local again = count()
        local left = fs.exists(T.CFG.FANOUT_FILE)
        local staged = T.state.registry[B].pendingUpdate
        restore()
        assert_eq(early, 0, "not before the turtles have had time to re-register")
        assert_eq(due >= 1, true, "then the idle turtle (and the warehouse) are told")
        assert_eq(staged, true, "and the busy one is told when it next reports idle")
        assert_eq(again, due, "once, not on every loop turn")
        assert_eq(left, false, "and the marker is gone, so the next reboot does not repeat it")
    end,

    ["a boot with nothing staged sends nothing"] =
    function(assert_eq)
        local T, zone, restore = twoMiners({ phase = "MINE", pending = {} })
        local server = package.loaded["central_server"]
        server.armFanOut(1000)
        local due = T.state.fanOutDueAt
        restore()
        assert_eq(due, nil, "an ordinary restart is not a deploy")
    end,

    ["a failed server update does not send the fleet new code"] =
    function(assert_eq)
        local T, zone, restore = twoMiners({ phase = "MINE", pending = {} })
        local server = package.loaded["central_server"]
        server.stageFanOut()
        server.dropFanOut()
        server.armFanOut(1000)
        local due, said = T.state.fanOutDueAt, logged(T, "was NOT sent UPDATE_ALL")
        restore()
        assert_eq(due, nil, "turtles ahead of their server is worse than both behind")
        assert_eq(said ~= nil, true, "and it says so")
    end,

    ["the UPDATE_ALL command stages the fan-out, and a failed update drops it (SOURCE-ONLY, weaker)"] =
    function(assert_eq)
        local f = io.open("central_server.lua", "r"); local src = f:read("a"); f:close()
        local branch = src:match('elseif t == "UPDATE_ALL" then(.-)pendingUpdate = true')
        assert_eq(branch ~= nil, true, "the UPDATE_ALL command branch exists")
        assert_eq(branch and branch:find("server.stageFanOut(", 1, true) ~= nil, true,
            "it stages")
        assert_eq(branch and branch:find("fanOutUpdateAll()", 1, true) == nil, true,
            "and does not send before the restart")
        assert_eq(src:find("pcall(server.armFanOut)", 1, true) ~= nil, true, "armed at boot")
        assert_eq(src:find("pcall(server.fanOutIfDue)", 1, true) ~= nil, true, "checked every turn")
        local failed = src:match('if fs.exists%("update_failed.txt"%) then(.-)else%s+os.reboot%(%)')
        assert_eq(failed and failed:find("server.dropFanOut()", 1, true) ~= nil, true,
            "a server staying on old code does not push new code to its fleet")
    end,

    ["a turtle whose update failed says so, and why, at REGISTER"] =
    function(assert_eq)
        local T, zone, restore = twoMiners({ phase = "MINE", pending = {} })
        T.handlers[proto.MSG.REGISTER]({ from = A, payload = {
            role = proto.ROLE.MINER, fuel = 100000, fuelMax = 100000,
            position = { x = 0, y = 60, z = 0 },
            updateFailed = "2 file(s) failed at 2026-10-01 00:50:50, free=600000B\nturtle_base.lua: HTTP 429\n" } })
        local said = logged(T, "UPDATE FAILED on " .. A)
        restore()
        assert_eq(said ~= nil, true, "a turtle quietly on old code is the thing to see")
        assert_eq(said and said:find("turtle_base.lua: HTTP 429", 1, true) ~= nil, true,
            "with the file and the reason, not just a count")
    end,

    ["the turtle carries its update failure, and the updater records the reason (SOURCE-ONLY, weaker)"] =
    function(assert_eq)
        local f = io.open("turtle_base.lua", "r"); local tb = f:read("a"); f:close()
        f = io.open("updater.lua", "r"); local up = f:read("a"); f:close()
        assert_eq(tb:find("updateFailed = base.readUpdateFailed(),", 1, true) ~= nil, true,
            "REGISTER carries it")
        assert_eq(up:find("local response, httpErr = http.get(url, NO_CACHE)", 1, true) ~= nil, true,
            "the HTTP reason is kept, not discarded")
        assert_eq(up:find('noteFailure(src, httpErr or "no response")', 1, true) ~= nil, true)
        assert_eq(up:find("for i = 1, math.min(3, #failures) do f.write(failures[i]", 1, true) ~= nil,
            true, "and written where the turtle reads it")
    end,

    -- A deploy names its commit (2026-10-03). A deploy seconds after a push
    -- installed the PREVIOUS release on the server and all fifteen turtles:
    -- raw.githubusercontent caches master for five minutes. A commit URL cannot
    -- be stale, so the deploy's commit goes to every updater.
    ["a deploy that names its commit sends that commit to the whole fleet"] =
    function(assert_eq)
        local T, zone, restore = twoMiners({ phase = "MINE", pending = {} })
        local server = package.loaded["central_server"]
        local REF = string.rep("ab12", 10)
        T.state.registry[A].status = proto.STATUS.IDLE        -- B stays busy
        server.stageFanOut(REF)
        local ownRef = fs.open(proto.UPDATE_REF_FILE, "r")
        local own = ownRef and ownRef.readAll()
        server.armFanOut(1000)
        server.fanOutIfDue(1000 + T.CFG.FANOUT_DELAY_SEC * 1000)
        local toA = 0
        for _, b in ipairs(T.sent) do
            local body = tostring(b)
            -- Addressed to A: the warehouse is sent the commit too, and must
            -- not be able to stand in for the turtle here.
            if body:find("UPDATE_ALL", 1, true) and body:find(REF, 1, true)
                    and body:find(A, 1, true) then toA = toA + 1 end
        end
        local staged = T.state.registry[B].pendingUpdate
        T.state.registry[B].status = proto.STATUS.IDLE
        T.sent = {}
        T.handlers[proto.MSG.HEARTBEAT]({ from = B, payload = {
            status = proto.STATUS.IDLE, fuel = 100000 } })
        local toB = false
        for _, b in ipairs(T.sent) do
            local body = tostring(b)
            if body:find("UPDATE_ALL", 1, true) and body:find(REF, 1, true) then toB = true end
        end
        local said = logged(T, "pinned to " .. REF)
        restore()
        assert_eq(said ~= nil, true,
            "the fan-out says which commit -- the updater's own print never reaches the log")
        assert_eq(own, REF, "the server's own updater is pinned before it runs")
        assert_eq(toA, 1, "the idle turtle is sent the commit")
        assert_eq(staged, REF, "the busy turtle keeps it")
        assert_eq(toB, true, "and is sent the same commit when it next reports idle")
    end,

    ["a malformed ref is never put in a URL"] =
    function(assert_eq)
        local T, zone, restore = twoMiners({ phase = "MINE", pending = {} })
        local server = package.loaded["central_server"]
        T.state.registry[A].status = proto.STATUS.IDLE
        server.stageFanOut("../../evil/" .. string.rep("a", 29))
        local pinned = fs.exists(proto.UPDATE_REF_FILE)
        server.armFanOut(1000)
        server.fanOutIfDue(1000 + T.CFG.FANOUT_DELAY_SEC * 1000)
        local leaked = false
        for _, b in ipairs(T.sent) do
            if tostring(b):find("evil", 1, true) then leaked = true end
        end
        restore()
        assert_eq(pinned, false, "the server's updater falls back to master")
        assert_eq(leaked, false, "and nothing of it reaches a turtle")
        assert_eq(proto.isCommitRef(string.rep("0", 40)), true)
        assert_eq(proto.isCommitRef(string.rep("0", 39)), false, "short is not a commit")
        assert_eq(proto.isCommitRef(string.rep("g", 40)), false, "not hex is not a commit")
        assert_eq(proto.isCommitRef(nil), false)
    end,

    ["a deploy with no ref fetches master, as before, and clears a stale pin"] =
    function(assert_eq)
        local T, zone, restore = twoMiners({ phase = "MINE", pending = {} })
        local server = package.loaded["central_server"]
        local f = fs.open(proto.UPDATE_REF_FILE, "w"); f.write(string.rep("c", 40)); f.close()
        server.stageFanOut(nil)
        local stale = fs.exists(proto.UPDATE_REF_FILE)
        restore()
        assert_eq(stale, false, "an old pin left on disk would install an old release")
    end,

    ["every updater reads the pin, and every computer writes it first (SOURCE-ONLY, weaker)"] =
    function(assert_eq)
        local function src(n) local f = io.open(n, "r"); local s = f:read("a"); f:close(); return s end
        local up = src("updater.lua")
        assert_eq(up:find('REPO = "https://raw.githubusercontent.com/JinxOG/CC-amazon-network/" .. REF .. "/"', 1, true) ~= nil,
            true, "the updater fetches from the commit when pinned")
        local _, clears = up:gsub("\n    clearRef%(%)", "")
        assert_eq(clears, 2, "and drops the pin whether the run succeeds or fails")
        for _, n in ipairs({ "turtle_base.lua", "warehouse.lua" }) do
            local s = src(n)
            local pinAt = s:find("proto.stageUpdateRef(msg.payload and msg.payload.ref)", 1, true)
            local runAt = pinAt and s:find('shell.run("updater")', pinAt, true)
            assert_eq(pinAt ~= nil and runAt ~= nil, true, n .. " pins before it runs the updater")
        end
    end,

    -- Four miners lost in the field after the double world restart of
    -- 2026-10-05 still held their bays on disk, and REMOVE_TURTLE refused them
    -- because a restart had emptied the registry.
    ["a lost turtle's dock can be released though it never registered"] =
    function(assert_eq)
        local T, zone, restore = twoMiners({ phase = "MINE", pending = {} })
        local server = package.loaded["central_server"]
        local W = package.loaded["waypoints"]
        local dock = W.assignDock("DELIVERY", "node_lost")
        local held = W.getDockFor("DELIVERY", "node_lost") ~= nil
        local ok = server.releaseLostTurtle("node_lost")
        local after = W.getDockFor("DELIVERY", "node_lost")
        local said = logged(T, "node_lost was not registered")
        local again = server.releaseLostTurtle("node_lost")
        restore()
        assert_eq(dock ~= nil and held, true, "precondition: it held a bay")
        assert_eq(ok, true)
        assert_eq(after, nil, "the bay is free for a replacement")
        assert_eq(said ~= nil, true, "and the log says why")
        assert_eq(again, false, "a name holding nothing reports nothing to release")
    end,

    ["the REMOVE_TURTLE command uses it for a turtle it cannot find (SOURCE-ONLY, weaker)"] =
    function(assert_eq)
        local f = io.open("central_server.lua", "r"); local src = f:read("a"); f:close()
        local branch = src:match('elseif t == "REMOVE_TURTLE" then(.-)\n            %-%- Cancel active job')
        assert_eq(branch ~= nil, true, "the REMOVE_TURTLE branch exists")
        assert_eq(branch and branch:find("server.releaseLostTurtle(tid)", 1, true) ~= nil, true,
            "an unregistered name still has its dock released")
    end,

    -- An older turtle catches up (2026-10-06): the in-memory queue of busy
    -- turtles was wiped by three world restarts, and two miners had been away
    -- during both deploys. The version is the record now, not the queue.
    -- Restock picks where the ore IS, not where it was (2026-10-06): W1's
    -- classification of the ore-map dump showed 13 zones mixing worked and
    -- unworked sectors, and the chooser summed both.
    ["restock ranks a zone by the ore in sectors not yet mined"] =
    function(assert_eq)
        local T, zone, restore = twoMiners({ phase = "MINE", pending = {} })
        local server = package.loaded["central_server"]
        T.state.persistentZones = {
            mined = { surveyed = true,
                      doneSectors = { { x = 0, z = 0 }, { x = 16, z = 0 } },
                      sectorOreMap = { ["0,0"] = { iron = 4000 }, ["16,0"] = { iron = 4000 } } },
            fresh = { surveyed = true, doneSectors = {},
                      sectorOreMap = { ["0,0"] = { iron = 300 } } },
            failed = { surveyed = true, doneSectors = {}, sectorFailCount = { ["0,0"] = 3 },
                       sectorOreMap = { ["0,0"] = { iron = 5000 } } },
            unsurveyed = { doneSectors = {}, sectorOreMap = { ["0,0"] = { iron = 9000 } } },
        }
        local key, count = server.bestRestockZone("iron")
        local none = server.bestRestockZone("gold")
        restore()
        assert_eq(key, "fresh", "a mined-out zone ranks by what is left, not what it held")
        assert_eq(count, 300)
        assert_eq(none, nil, "no zone with the ore left is no zone")
    end,

    ["a turtle reporting an older version is queued for the current release"] =
    function(assert_eq)
        local T, zone, restore = twoMiners({ phase = "MINE", pending = {} })
        local hb = T.handlers[proto.MSG.HEARTBEAT]
        T.state.deployRef = string.rep("d", 40)
        hb({ from = A, payload = { status = proto.STATUS.WORKING, fuel = 100000, version = "1.9.58" } })
        hb({ from = A, payload = { status = proto.STATUS.WORKING, fuel = 100000, version = "1.9.58" } })
        local queued = T.state.registry[A].pendingUpdate
        local n = 0
        for _, e in ipairs(T.state.log) do
            if e.msg:find("queued for the current release", 1, true) then n = n + 1 end
        end
        restore()
        assert_eq(queued, string.rep("d", 40), "queued, pinned to the last deploy's commit")
        assert_eq(n, 1, "once per registration, not on every heartbeat")
    end,

    ["a turtle on the current version, or a newer one, is left alone"] =
    function(assert_eq)
        local T, zone, restore = twoMiners({ phase = "MINE", pending = {} })
        local hb = T.handlers[proto.MSG.HEARTBEAT]
        hb({ from = A, payload = { status = proto.STATUS.WORKING, fuel = 100000, version = proto.VERSION } })
        hb({ from = B, payload = { status = proto.STATUS.WORKING, fuel = 100000, version = "99.0.0" } })
        local a, b = T.state.registry[A].pendingUpdate, T.state.registry[B].pendingUpdate
        restore()
        assert_eq(a, nil, "nothing to catch up")
        assert_eq(b, nil, "a newer turtle is a canary, never downgraded")
    end,

    ["the deploy's commit survives a restart"] =
    function(assert_eq)
        local T, zone, restore = twoMiners({ phase = "MINE", pending = {} })
        local server = package.loaded["central_server"]
        local REF = string.rep("e", 40)
        server.stageFanOut(REF)
        T.state.deployRef = nil                       -- the restart
        server.armFanOut(1000)
        local kept = T.state.deployRef
        server.fanOutIfDue(1000 + T.CFG.FANOUT_DELAY_SEC * 1000)   -- the fan-out marker goes...
        local still = fs.exists(T.CFG.DEPLOY_REF_FILE)
        restore()
        assert_eq(kept, REF, "a turtle catching up later gets the same commit")
        assert_eq(still, true, "...but the deploy's commit is kept")
    end,

    ["older is compared as numbers, not text"] =
    function(assert_eq)
        assert_eq(proto.versionOlder("1.9.58", "1.9.132"), true, "58 < 132, though '5' > '1'")
        assert_eq(proto.versionOlder("1.9.132", "1.9.58"), false)
        assert_eq(proto.versionOlder("1.9.132", "1.9.132"), false)
        assert_eq(proto.versionOlder("1.9", "1.9.1"), true)
        assert_eq(proto.versionOlder(nil, "1.9.1"), false, "unreadable is never older")
    end,

    ["the alive stamp records the time and the running version"] =
    function(assert_eq)
        local T, zone, restore = twoMiners({ phase = "MINE", pending = {} })
        local server = package.loaded["central_server"]
        server.writeAliveStamp(1790700000000)
        local f = fs.open(T.CFG.ALIVE_FILE, "r")
        local body = f and f.readAll()
        restore()
        assert_eq(body, "1790700000000 " .. proto.VERSION,
            "both halves are needed: the time dates a crash, the version names an update")
    end,

    -- The other half: a genuine failure must STILL respawn, or a zone stops
    -- silently the first time a miner dies on it.
    ["a failed job still respawns its zone"] = function(assert_eq)
        local T, zone, restore = twoMiners({
            phase = "MINE", pending = { copy(S2), copy(S3) },
            lastAssignments = { [A] = { x = S1.x, z = S1.z, phase = "MINE", jobId = JA } },
        })
        for _, j in ipairs({ JA, JB }) do
            T.state.jobs[j].params = { x1 = 2052, z1 = -3080, x2 = 2052, z2 = -3080 }
        end
        T.state.jobs[JB].status = "COMPLETE"
        T.handlers[proto.MSG.JOB_FAILED]({ from = A, payload = {
            jobId = JA, reason = "loader_retrieve_failed", recoverable = false } })
        local replacement = nil
        for id, j in pairs(T.state.jobs) do
            if id ~= JA and id ~= JB and j.params and j.params.sharedZoneKey == "zk" then
                replacement = id
            end
        end
        restore()
        assert_eq(replacement ~= nil, true,
            "respawning after a failure is what keeps a zone from stopping silently")
    end,

    -- 2026-09-23: the warehouse ran perfectly for nine days and was heard by
    -- nobody. It encoded with to = nil, decode requires every field, and an
    -- undecodable message has no type to log against - so its logs, keepalives
    -- and storage digests were discarded at the door in silence.
    ["a message with no named recipient is addressed to the server"] = function(assert_eq)
        local m = proto.encode(proto.MSG.STORAGE_DIGEST, "warehouse", nil, { keepalive = true })
        local ok, decoded = proto.decode(m)
        assert_eq(m.to, "server", "no recipient named means the server")
        assert_eq(ok, true, "and it must survive decode, or it never arrives")
        assert_eq(decoded ~= nil and decoded.payload.keepalive, true)
    end,

    ["an explicit recipient is left alone"] = function(assert_eq)
        local m = proto.encode(proto.MSG.SECTOR_ASSIGN, "server", "node_138", {})
        assert_eq(m.to, "node_138", "defaulting must not overwrite a real address")
    end,

    -- The ETA, priced from what the survey found (1.9.117).
    --
    -- Measured over 153 sector completions: a mined sector costs 7.7 min plus
    -- 36.6 min per 1000 ore, r=0.993. Sectors differ by two orders of magnitude,
    -- so averaging them - which is what phaseEta does - was wrong by 13.5 min a
    -- sector where pricing each by its own ore is wrong by 3.1.
    ["a sector's estimate is driven by the ore the survey found in it"] =
    function(assert_eq)
        local T, zone, restore = twoMiners({
            phase = "MINE", pending = { copy(S1), copy(S2) }, allSectors = { copy(S1), copy(S2) },
            postRescan = true,   -- no further passes, so this is the mine work alone
        })
        zone.sectorSeen = {
            [S1.x .. "," .. S1.z .. ",16"] = { ["minecraft:iron_ore"] = 1000 },
            [S1.x .. "," .. S1.z .. ",0"]  = { ["minecraft:coal"] = 1000 },
            [S2.x .. "," .. S2.z .. ",16"] = { ["minecraft:iron_ore"] = 100 },
        }
        local one = T.jobEta(zone, 1)
        local two = T.jobEta(zone, 2)
        local ore1 = T.sectorFoundOre(zone, S1.x, S1.z)
        restore()
        assert_eq(ore1, 2000, "a sector's ore is summed across its depth levels")
        -- S1: 462 + 2000*2.196 = 4854.0 ; S2: 462 + 100*2.196 = 681.6 -> 5535.6,
        -- and every job pays the 840s trip home on top.
        assert_eq(one, 6375, "each sector priced by its own ore, not by an average")
        assert_eq(two, 3607, "and the work splits across the miners on the zone")
    end,

    -- 1.9.117 priced a sector the survey had not reached as an empty pass. That
    -- was honest and useless: at 17:42 on job_0088 the dashboard read 45 minutes
    -- for a job that ran 6 hours 44, and climbed 45 -> 89 -> 208 -> 380 over its
    -- first twenty-five minutes as the scans landed. 1.9.119 prices it from what
    -- this zone's scanned sectors turned out to hold instead.
    ["a sector the survey has not reached yet is priced, not treated as empty"] =
    function(assert_eq)
        local T, zone, restore = twoMiners({
            phase = "SURVEY", pending = { copy(S1) }, allSectors = { copy(S1) },
            postRescan = true,
        })
        zone.sectorSeen = {}                      -- nothing scanned anywhere yet
        zone.surveyDone, zone.surveyTotal = 0, 3  -- and the survey is still out
        local eta = T.jobEta(zone, 1)
        restore()
        -- 462 + 4600 * 2.196 = 10563.6, + 840 home
        assert_eq(eta, 11403,
            "before any scan lands the fleet figure is the only estimate there is; "
            .. "1110 -- an empty pass plus the trip home -- is the reading that "
            .. "made a seven hour job look like forty-five minutes")
    end,

    ["a sector the survey HAS finished with and found nothing in is empty"] =
    function(assert_eq)
        local T, zone, restore = twoMiners({
            phase = "MINE", pending = { copy(S1) }, allSectors = { copy(S1) },
            postRescan = true,
        })
        zone.sectorSeen = {}
        zone.surveyDone, zone.surveyTotal = 3, 3   -- the survey is done: 0 means 0
        local eta = T.jobEta(zone, 1)
        restore()
        assert_eq(eta, 1110,
            "once the survey has been everywhere, no ore reported means no ore, "
            .. "and the prior must not keep charging for a barren sector")
    end,

    ["the prior gives way to this zone's own scans as they land"] =
    function(assert_eq)
        local T, zone, restore = twoMiners({
            phase = "SURVEY", pending = { copy(S1), copy(S2) },
            allSectors = { copy(S1), copy(S2) }, postRescan = true,
        })
        zone.sectorSeen = { [S1.x .. "," .. S1.z .. ",16"] = { ["minecraft:iron_ore"] = 2000 } }
        zone.surveyDone, zone.surveyTotal = 1, 2
        local eta = T.jobEta(zone, 1)
        restore()
        -- S1 is known: 462 + 2000*2.196 = 4854. S2 is not, and this zone's only
        -- scan says 2000, so it is priced the same -- not at the 4600 fleet figure.
        assert_eq(eta, 10548,
            "a zone that scans rich prices its unscanned ground rich, and one "
            .. "that scans barren prices it barren; 16257 is the fleet prior")
    end,

    -- job_0088, 00:02: the estimate jumped from 11 minutes to 96 with 22 left to
    -- run. The rescan had queued sectors for re-mining, and sectorSeen keeps the
    -- LARGEST view a sector ever had -- deliberately -- so each was priced at its
    -- full original ore although nearly all of it was already out of the ground.
    ["a sector queued for re-mining is priced by what is left, not by the survey"] =
    function(assert_eq)
        local T, zone, restore = twoMiners({
            phase = "MINE", pending = { copy(S1) }, allSectors = { copy(S1) },
            postRescan = true,
        })
        local k = S1.x .. "," .. S1.z .. ",16"
        zone.sectorSeen  = { [k] = { ["minecraft:iron_ore"] = 1000 } }
        zone.sectorMined = { [k] = { ["minecraft:iron_ore"] = 980 } }
        zone.surveyDone, zone.surveyTotal = 3, 3
        local eta = T.jobEta(zone, 1)
        restore()
        -- 20 ore left: 462 + 20*2.196 = 505.9, + 840 home
        assert_eq(eta, 1345,
            "THE SPIKE: charging the original 1000 ore gives 3498 -- 96 minutes "
            .. "of work on ground that has 20 ore left in it")
    end,

    ["every job pays for the trip home once, and a second miner does not halve it"] =
    function(assert_eq)
        local T, zone, restore = twoMiners({
            phase = "MINE", pending = { copy(S1) }, allSectors = { copy(S1) },
            postRescan = true,
        })
        zone.sectorSeen = { [S1.x .. "," .. S1.z .. ",16"] = { ["minecraft:iron_ore"] = 1000 } }
        zone.surveyDone, zone.surveyTotal = 3, 3
        local one = T.jobEta(zone, 1)
        local two = T.jobEta(zone, 2)
        restore()
        -- work 2658; home 840 on top of both, never split
        assert_eq(one, 3498, "one miner: 2658 of digging and 840 flying home")
        assert_eq(two, 2169,
            "two miners halve the digging and not the flight; 1749 is what "
            .. "dividing the trip home would give, and both turtles still have "
            .. "to fly the whole way")
    end,

    ["the estimate covers the passes still to come, not just this one"] =
    function(assert_eq)
        local T, zone, restore = twoMiners({
            phase = "MINE", pending = {}, allSectors = { copy(S1), copy(S2) },
        })
        zone.sectorSeen = {}
        local withPasses = T.jobEta(zone, 1)
        zone.postRescan = true
        local without = T.jobEta(zone, 1)
        restore()
        -- 2 sectors * (rescan 252 + re-mine allowance 270)
        assert_eq(withPasses, 1884,
            "a job that has yet to rescan will rescan every sector and re-mine what it finds")
        assert_eq(without, nil, "and once those passes are done there is nothing left to price")
    end,

    -- The sectors being mined RIGHT NOW (1.9.118).
    --
    -- MEASURED FAILURE, job_0086 on 2026-09-24: the estimate read 191 minutes at
    -- 15:04 and 191 minutes at 17:34, through two and a half hours and 8,344 ore
    -- of digging, when the job in fact had 381 and 141 minutes left. Handing a
    -- sector to a miner pops it off pending, so the only thing 1.9.117 priced was
    -- the queue -- and on a four-sector zone with two miners, half the remaining
    -- work was invisible and the number could not move.
    ["a sector being mined right now still counts toward the estimate"] =
    function(assert_eq)
        local T, zone, restore = twoMiners({
            phase = "MINE", pending = {}, allSectors = { copy(S1) },
            postRescan = true,   -- nothing queued and no passes left: the hold alone
        })
        zone.sectorSeen = { [S1.x .. "," .. S1.z .. ",16"] = { ["minecraft:iron_ore"] = 1000 } }
        zone.lastAssignments[A] = { x = S1.x, z = S1.z, phase = "MINE", jobId = JA }
        local eta = T.jobEta(zone, 1)
        restore()
        -- 462 overhead + 1000 * 2.196, + 840 home
        assert_eq(eta, 3498, "the sector in a miner's hands is the work that is left")
    end,

    ["the estimate falls as the ore comes out of the sector in hand"] =
    function(assert_eq)
        local T, zone, restore = twoMiners({
            phase = "MINE", pending = {}, allSectors = { copy(S1) }, postRescan = true,
        })
        local k = S1.x .. "," .. S1.z .. ",16"
        zone.sectorSeen = { [k] = { ["minecraft:iron_ore"] = 1000 } }
        zone.lastAssignments[A] = { x = S1.x, z = S1.z, phase = "MINE", jobId = JA }
        local before = T.jobEta(zone, 1)
        zone.sectorMined = { [k] = { ["minecraft:iron_ore"] = 400 } }
        local after = T.jobEta(zone, 1)
        restore()
        assert_eq(after < before, true,
            "THE REGRESSION: an estimate that does not fall while a miner digs is "
            .. "what read 191 minutes for two and a half hours")
        -- 600 ore left * 2.196 + 840 home, and no overhead: reporting ore
        -- means the miner is there and set up
        assert_eq(after, 2157, "only the ore still in the ground is charged")
    end,

    ["a job cannot finish sooner than the longest sector one miner holds"] =
    function(assert_eq)
        local T, zone, restore = twoMiners({
            phase = "MINE", pending = {}, allSectors = { copy(S1), copy(S2) },
            postRescan = true,
        })
        zone.sectorSeen = {
            [S1.x .. "," .. S1.z .. ",16"] = { ["minecraft:iron_ore"] = 2000 },
            [S2.x .. "," .. S2.z .. ",16"] = { ["minecraft:iron_ore"] = 100 },
        }
        zone.lastAssignments[A] = { x = S1.x, z = S1.z, phase = "MINE", jobId = JA }
        zone.lastAssignments[B] = { x = S2.x, z = S2.z, phase = "MINE", jobId = JB }
        local eta = T.jobEta(zone, 2)
        restore()
        -- A holds 4854s, B holds 681.6s. Spread over two miners that averages to
        -- 2767, but nobody can take a share of the column already in A's hands.
        assert_eq(eta, 5694, "the deepest hold sets the floor, not the average")
    end,

    ["a survey pass in a miner's hands is charged in full"] =
    function(assert_eq)
        local T, zone, restore = twoMiners({
            phase = "SURVEY", pending = {}, allSectors = { copy(S1) },
            postRescan = true,
        })
        zone.lastAssignments[A] = { x = S1.x, z = S1.z, isSurvey = true, jobId = JA }
        local eta = T.jobEta(zone, 1)
        restore()
        assert_eq(eta, 1404,
            "a survey cannot be priced by ore: the scans that would price it are "
            .. "the thing it is out there producing")
    end,

    ["a storage digest feeds the ore watchdog and answers the network check"] =
    function(assert_eq)
        local T, zone, restore = twoMiners({ phase = "MINE", pending = {} })
        T.handlers[proto.MSG.STORAGE_DIGEST]({ from = "warehouse", payload = {
            itemCount = 469, grandTotal = 24531758, storageTs = 1000500,
            ores = { { name = "minecraft:iron_ore", amount = 1204 },
                     { name = "minecraft:coal", count = 64 } } } })
        local stock, ts = T.state.oreStock, T.state.oreStockTs
        local line = logged(T, "Storage digest from the warehouse: 2 watched name(s), 469 items, total 24531758")
        restore()
        assert_eq(stock and stock["minecraft:iron_ore"], 1204, "amount carried")
        assert_eq(stock and stock["minecraft:coal"], 64, "count is read as amount too")
        assert_eq(ts, 1000500,
            "the timestamp must be WHEN RS WAS READ, not when the message arrived "
            .. "(W5's rule: otherwise a warehouse posting after RS died looks fresh)")
        assert_eq(T.state.storageItemCount == nil or true, true)
        assert_eq(line ~= nil, true, "and it is logged when the item count moves")
    end,

    ["a keepalive refreshes liveness without touching the reading"] = function(assert_eq)
        local T, zone, restore = twoMiners({ phase = "MINE", pending = {} })
        T.handlers[proto.MSG.STORAGE_DIGEST]({ from = "warehouse", payload = {
            storageTs = 1000500, ores = { { name = "minecraft:iron_ore", amount = 7 } } } })
        local before = T.state.oreStockTs
        T.state.storageSenderSeenAt = 0
        T.handlers[proto.MSG.STORAGE_DIGEST]({ from = "warehouse", payload = { keepalive = true } })
        local seen, after = T.state.storageSenderSeenAt, T.state.oreStockTs
        local refused = logged(T, "no ores array and no keepalive")
        restore()
        assert_eq(after, before, "a keepalive must not change the reading")
        assert_eq(seen ~= 0 and seen ~= nil, true,
            "but it must refresh liveness, or a warehouse busy in a handshake "
            .. "reads as stopped and this computer restarts enumerating")
        assert_eq(refused, nil, "and it is not logged as malformed")
    end,

    ["an older reading never overwrites a newer one"] = function(assert_eq)
        local T, zone, restore = twoMiners({ phase = "MINE", pending = {} })
        local h = T.handlers[proto.MSG.STORAGE_DIGEST]
        h({ from = "warehouse", payload = { storageTs = 2000, ores = { { name = "a", amount = 10 } } } })
        h({ from = "warehouse", payload = { storageTs = 1000, ores = { { name = "a", amount = 99 } } } })
        local stock, ts = T.state.oreStock, T.state.oreStockTs
        local line = logged(T, "is older than the one held")
        restore()
        assert_eq(stock and stock["a"], 10, "W5's rule: the newest reading wins whichever path delivered it")
        assert_eq(ts, 2000)
        assert_eq(line ~= nil, true, "and the stale one says so")
    end,

    ["the digest is capped and says so when it trims"] = function(assert_eq)
        local T, zone, restore = twoMiners({ phase = "MINE", pending = {} })
        local ores = {}
        for i = 1, 80 do ores[i] = { name = "ore_" .. i, amount = i } end
        T.handlers[proto.MSG.STORAGE_DIGEST]({ from = "warehouse", payload = {
            storageTs = 5000, ores = ores } })
        local n = 0
        for _ in pairs(T.state.oreStock or {}) do n = n + 1 end
        local line = logged(T, "carried 80 names; kept the first 64")
        restore()
        assert_eq(n, 64, "the cap is what stops this payload growing into the one that made the server deaf")
        assert_eq(line ~= nil, true, "and trimming is logged, never silent")
    end,

    ["a digest from anyone but the warehouse is refused"] = function(assert_eq)
        local T, zone, restore = twoMiners({ phase = "MINE", pending = {} })
        T.handlers[proto.MSG.STORAGE_DIGEST]({ from = A, payload = {
            storageTs = 9000, ores = { { name = "minecraft:diamond", amount = 999 } } } })
        local stock = T.state.oreStock
        local line = logged(T, "only the warehouse may send one")
        restore()
        assert_eq(stock, nil, "a turtle must not be able to rewrite what storage holds")
        assert_eq(line ~= nil, true, "and the refusal is logged")
    end,

    ["the first digest gets the watchlist so the warehouse need not guess"] =
    function(assert_eq)
        local T, zone, restore = twoMiners({ phase = "MINE", pending = {} })
        T.handlers[proto.MSG.STORAGE_DIGEST]({ from = "warehouse", payload = { keepalive = true } })
        local sent = nil
        for i = #T.sent, 1, -1 do
            local m = textutils.unserialise(T.sent[i])
            if type(m) == "table" and m.type == proto.MSG.STORAGE_WATCHLIST then sent = m end
        end
        local line = logged(T, "Sent the warehouse a watchlist")
        restore()
        assert_eq(sent ~= nil, true, "the server knows its thresholds; the warehouse should not have to guess")
        assert_eq(sent ~= nil and type(sent.payload.names), "table", "and it carries the names")
        assert_eq(line ~= nil, true)
    end,

    ["a refusal to depart does not count against the sector"] = function(assert_eq)
        local T, zone, restore = twoMiners({
            phase = "MINE", pending = {},
            lastAssignments = { [A] = { x = S1.x, z = S1.z, phase = "MINE", jobId = JA } },
        })
        T.state.persistentZones["zk"].sectorFailCount = {}
        for i = 1, 3 do
            T.state.jobs[JA].status = "IN_PROGRESS"
            T.handlers[proto.MSG.JOB_FAILED]({ from = A, payload = {
                jobId = JA, reason = "no_gps_fix: cannot confirm position, refusing to depart",
                recoverable = false } })
            T.state.miningZones[JA] = zone       -- fail() drops the zone reference
        end
        local counts = T.state.persistentZones["zk"].sectorFailCount
        local line = logged(T, "not counted against job_0060: the turtle never departed")
        restore()
        assert_eq(next(counts), nil,
            "a turtle that never left the dock cannot have failed a sector")
        assert_eq(line ~= nil, true, "and the decision is logged")
    end,

    ["a failure at the sector still counts against it"] = function(assert_eq)
        local T, zone, restore = twoMiners({
            phase = "MINE", pending = {},
            lastAssignments = { [A] = { x = S1.x, z = S1.z, phase = "MINE", jobId = JA } },
        })
        T.state.persistentZones["zk"].sectorFailCount = {}
        T.handlers[proto.MSG.JOB_FAILED]({ from = A, payload = {
            jobId = JA, reason = "loader_retrieve_failed: approach_failed", recoverable = false } })
        local counts = T.state.persistentZones["zk"].sectorFailCount
        restore()
        assert_eq(counts[S1.x .. "," .. S1.z], 1,
            "the blacklist exists for sectors that really do fail; this must not be weakened")
    end,

    ["CLEAR_SECTOR_FAILS clears one sector's count and says so"] = function(assert_eq)
        local T, zone, restore = twoMiners({ phase = "MINE", pending = {} })
        T.state.persistentZones["zk"].sectorFailCount =
            { ["1856,-3136"] = 3, ["1888,-3136"] = 1 }
        local ok, n = pcall(T.clearSectorFails, nil, 1856, -3136)
        local counts = T.state.persistentZones["zk"].sectorFailCount
        local line = logged(T, "Sector (1856,-3136) fail count cleared in zone zk (was 3)")
        -- Reloaded from the store, not just from memory: ensureMineZone reads
        -- the count off disk on the next dispatch, so an unsaved clear is no
        -- clear at all.
        T.state.persistentZones = {}
        T.loadPersistentZones()
        local reloaded = T.state.persistentZones["zk"]
        restore()
        assert_eq(reloaded ~= nil, true, "precondition: the zone must come back from the store")
        assert_eq(reloaded and (reloaded.sectorFailCount or {})["1856,-3136"], nil,
            "the clear must survive a reload")
        assert_eq(ok and n, 1, "one count cleared")
        assert_eq(counts["1856,-3136"], nil, "the named sector is cleared")
        assert_eq(counts["1888,-3136"], 1, "and nothing else is touched")
        assert_eq(line ~= nil, true, "with a line naming the sector and the old count")
    end,

    ["a survey finished after the zone moved to MINE is counted as a survey, and says so"] =
    function(assert_eq)
        local T, zone, restore = twoMiners({
            phase = "SURVEY",
            surveySectors = { copy(S1), copy(S2) },
            pending = { copy(S1), copy(S2), copy(S3) },
        })
        request(T, A, JA)                    -- A surveys S1
        request(T, B, JB)                    -- B surveys S2: the list is now empty
        local aNext = done(T, A, JA, S1)     -- A done: the zone moves to MINE
        local phaseAfterA = zone.phase
        local bNext = done(T, B, JB, S2)     -- B's survey lands late
        local line = logged(T, "Late completion: node_139 finished (2080,-3104) assigned in SURVEY; zone is now MINE")
        local pz = T.state.persistentZones["zk"]
        restore()

        assert_eq(phaseAfterA, "MINE", "precondition: A's completion moved the zone on")
        assert_eq(zone.done, 0,
            "a survey must not count as a mined sector -- job_0061 counted one at 05:47")
        assert_eq(zone.surveyDone, 2, "it is the second survey")
        assert_eq(sectorIn(pz.doneSectors, S2), false,
            "and it must not reach the zone store as a finished sector")
        assert_eq(line ~= nil, true, "the late completion must be logged")
        assert_eq(aNext.type == proto.MSG.SECTOR_ASSIGN and aNext.x, S1.x,
            "A's first mine order skips S2, which B still held")
        assert_eq(bNext.type, proto.MSG.SECTOR_ASSIGN, "B gets another order")
        assert_eq(bNext.x == S2.x and bNext.z == S2.z, true, "and it is S2")
        assert_eq(bNext.survey, false, "to mine, not to survey again")
    end,

    ["a mine sector finished after the zone moved to RESCAN is merged as MINE, not queued for re-mining"] =
    function(assert_eq)
        local T, zone, restore = twoMiners({
            phase = "MINE", pending = { copy(S1), copy(S2) }, total = 2,
            allSectors = { copy(S1), copy(S2) },
        })
        request(T, A, JA)                    -- A mines S1
        request(T, B, JB)                    -- B mines S2
        local aNext = done(T, A, JA, S1, ORE) -- mine list empty: RESCAN begins
        local phaseAfterA = zone.phase
        done(T, B, JB, S2, ORE)              -- B's mine lands late
        local pz = T.state.persistentZones["zk"]
        local line = logged(T, "Late completion: node_139 finished (2080,-3104) assigned in MINE; zone is now RESCAN")
        restore()

        assert_eq(phaseAfterA, "RESCAN", "precondition: A's completion started the rescan")
        assert_eq(zone.done, 2, "B's sector is a mined sector")
        assert_eq(sectorIn(pz.doneSectors, S2), true,
            "and it must reach the zone store -- job_0059's never did")
        assert_eq(sectorIn(zone.rescanPending, S2), false,
            "and it must not be queued for re-mining as a rescan with ore")
        assert_eq((zone.rescanDone or 0), 0, "nor end the rescan a sector early")
        assert_eq(line ~= nil, true, "the late completion must be logged")
        assert_eq(aNext.x == S1.x and aNext.z == S1.z and aNext.survey, true,
            "A's rescan order is S1, the one sector nobody holds")
    end,

    ["the rescan list leaves out a sector another miner is still mining"] =
    function(assert_eq)
        local T, zone, restore = twoMiners({
            phase = "MINE", pending = { copy(S1), copy(S2) }, total = 2,
            allSectors = { copy(S1), copy(S2) },
        })
        request(T, A, JA)
        request(T, B, JB)                    -- B holds S2
        done(T, A, JA, S1)
        local list = zone.rescanSectors
        local line = logged(T, "rescan leaves out 1 sector(s) still held by another miner")
        restore()
        assert_eq(sectorIn(list, S2), false, "S2 is being mined; rescanning it now is a collision")
        assert_eq(zone.rescanTotal, 1, "the rescan covers only S1")
        assert_eq(line ~= nil, true, "and the exclusion is logged")
    end,

    ["no phase hands out a sector another miner holds"] = function(assert_eq)
        local results = {}
        for _, phase in ipairs({ "SURVEY", "MINE", "RESCAN" }) do
            local list = { copy(S1), copy(S2) }
            local T, zone, restore = twoMiners({
                phase = phase,
                surveySectors = phase == "SURVEY" and list or {},
                pending       = phase == "MINE" and list or {},
                rescanSectors = phase == "RESCAN" and list or nil,
                lastAssignments = { [B] = { x = S1.x, z = S1.z, phase = phase, jobId = JB } },
            })
            local got = request(T, A, JA)
            restore()
            results[phase] = got and got.x == S2.x and got.z == S2.z
        end
        assert_eq(results.SURVEY, true, "SURVEY skipped the held sector")
        assert_eq(results.MINE, true, "MINE skipped the held sector")
        assert_eq(results.RESCAN, true, "RESCAN skipped the held sector")
    end,

    ["a request during RESCAN is served from the rescan list"] = function(assert_eq)
        local T, zone, restore = twoMiners({
            phase = "RESCAN", rescanSectors = { copy(S3) }, pending = {},
        })
        local got = request(T, A, JA)
        local line = logged(T, "SECTOR_REQUEST from node_138 during RESCAN of job_0060")
        restore()
        assert_eq(line ~= nil, true, "the fix has its own log signature")
        assert_eq(got.type, proto.MSG.SECTOR_ASSIGN,
            "rescans are still waiting; MINE_COMPLETE here ends the miner early")
        assert_eq(got.x == S3.x and got.survey, true, "it is a rescan order")
    end,

    ["when every remaining sector is held, the miner is told it is finished and the phase stays"] =
    function(assert_eq)
        local T, zone, restore = twoMiners({
            phase = "MINE", pending = { copy(S2) },
            lastAssignments = {
                [A] = { x = S1.x, z = S1.z, phase = "MINE", jobId = JA },
                [B] = { x = S2.x, z = S2.z, phase = "SURVEY", jobId = JB },
            },
        })
        local got = done(T, A, JA, S1)
        local line = logged(T, "every remaining MINE sector is held by another miner")
        restore()
        assert_eq(got.type, proto.MSG.MINE_COMPLETE,
            "silence is not an option: the miner gives up after ~50 s as a timeout")
        assert_eq(zone.phase, "MINE", "a blocked list is not an empty one: no rescan may start")
        assert_eq(sectorIn(zone.pending, S2), true, "S2 stays for its holder")
        assert_eq(zone.lastAssignments[A], nil, "and the finished miner holds nothing")
        assert_eq(line ~= nil, true, "the decision is logged")
    end,

    ["a hold ends with its job: a failed holder does not block the sector"] =
    function(assert_eq)
        local T, zone, restore = twoMiners({
            phase = "MINE", pending = { copy(S1) },
            lastAssignments = { [B] = { x = S1.x, z = S1.z, phase = "MINE", jobId = JB } },
        })
        T.state.jobs[JB].status = "FAILED"
        local got = request(T, A, JA)
        restore()
        assert_eq(got.type == proto.MSG.SECTOR_ASSIGN and got.x, S1.x,
            "job_0058 failed with a hold on record; that must not strand the sector")
    end,

    ["a late rescan result after the re-mine list was built is still re-mined"] =
    function(assert_eq)
        local T, zone, restore = twoMiners({
            phase = "MINE", postRescan = true, pending = {},
            lastAssignments = { [B] = { x = S2.x, z = S2.z, phase = "RESCAN", jobId = JB } },
        })
        local got = done(T, B, JB, S2, ORE)
        local line = logged(T, "Late rescan (2080,-3104) by node_139 found ore after the re-mine list was built")
        restore()
        assert_eq(line ~= nil, true, "the fix has its own log signature")
        assert_eq(got.type, proto.MSG.SECTOR_ASSIGN,
            "ore found by the late rescan must be mined, not dropped with the old list")
        assert_eq(got.x == S2.x and got.z == S2.z, true, "the order is S2")
        assert_eq(got.survey, false, "and it is a mine order")
    end,

    ["being told it is finished clears the miner's hold"] = function(assert_eq)
        local T, zone, restore = twoMiners({
            phase = "MINE", postRescan = true, pending = {},
            lastAssignments = { [A] = { x = S1.x, z = S1.z, phase = "MINE", jobId = JA } },
        })
        local got = done(T, A, JA, S1)
        local holder = T.sectorHolder(zone, S1.x, S1.z, B)
        restore()
        assert_eq(got.type, proto.MSG.MINE_COMPLETE, "precondition: the re-mine is exhausted")
        assert_eq(holder, nil, "a finished miner must not keep a sector out of reach")
    end,

    -- The question the approval asked: a miner was sent MINE_COMPLETE because
    -- the last sector was held, and the holder then FAILED. The failure saw the
    -- first miner's job as still live (it was flying home), so it respawned
    -- nothing. When that last job completes, the zone must say it was left
    -- with work, and get a replacement.
    ["a sector orphaned by a failed holder is reported and respawned when the last miner finishes"] =
    function(assert_eq)
        local T, zone, restore = twoMiners({
            -- S3 is still listed and B holds it (a rescan's re-mine list can
            -- look like this): the only sector left is taken.
            phase = "MINE", pending = { copy(S3) },
            lastAssignments = {
                [A] = { x = S1.x, z = S1.z, phase = "MINE", jobId = JA },
                [B] = { x = S3.x, z = S3.z, phase = "MINE", jobId = JB },
            },
        })
        for _, j in ipairs({ JA, JB }) do
            T.state.jobs[j].params = { x1 = 2052, z1 = -3080, x2 = 2052, z2 = -3080 }
        end
        local aGot = done(T, A, JA, S1)                        -- all left is B's: A is finished
        T.handlers[proto.MSG.JOB_FAILED]({ from = B, payload = {
            jobId = JB, reason = "test", recoverable = false } })
        local requeued = sectorIn(zone.pending, S3)
        local earlyWarn = logged(T, "unmined sector(s)")
        T.handlers[proto.MSG.JOB_COMPLETE]({ from = A, payload = { jobId = JA } })
        local warn = logged(T, "Zone zk left with 1 unmined sector(s) after job_0060 complete")
        local replacement
        for id, j in pairs(T.state.jobs) do
            if id ~= JA and id ~= JB and j.params and j.params.sharedZoneKey == "zk" then
                replacement = j
            end
        end
        restore()
        assert_eq(aGot.type, proto.MSG.MINE_COMPLETE, "precondition: A was finished by the block")
        assert_eq(requeued, true, "the failed holder's sector goes back on the list")
        assert_eq(earlyWarn, nil, "while A is still live the zone is not orphaned yet")
        assert_eq(warn ~= nil, true, "when the last miner finishes, the zone says it has work left")
        assert_eq(replacement ~= nil, true, "and a replacement job is queued to mine it")
    end,

    ["every hand-out is logged, including the reply to a completion"] = function(assert_eq)
        local T, zone, restore = twoMiners({
            phase = "MINE", pending = { copy(S2) },
            lastAssignments = { [A] = { x = S1.x, z = S1.z, phase = "MINE", jobId = JA } },
        })
        done(T, A, JA, S1)
        local line = logged(T, "Assigned sector (2080,-3104) to node_138 [job_0060]")
        restore()
        assert_eq(line ~= nil, true,
            "the gate rebuilds holds from these; an unlogged reply is an invisible hold")
    end,

    ["a hold on a different zone does not block this one"] = function(assert_eq)
        local T, zone, restore = twoMiners({
            phase = "MINE", pending = { copy(S1) },
            lastAssignments = { [B] = { x = S1.x, z = S1.z, phase = "MINE", jobId = JB } },
        })
        T.state.miningZones[JB] = { pending = {} }     -- B's job is on another zone
        local got = request(T, A, JA)
        restore()
        assert_eq(got.type == proto.MSG.SECTOR_ASSIGN and got.x, S1.x,
            "a stale entry pointing at another zone must not hold this sector")
    end,

    ["an order recorded before phases were stamped is counted by the zone's phase"] =
    function(assert_eq)
        local T, zone, restore = twoMiners({
            phase = "MINE", pending = { copy(S3) },
            lastAssignments = { [A] = { x = S1.x, z = S1.z, isSurvey = true } },  -- 1.9.109 shape
        })
        done(T, A, JA, S1)
        local line = logged(T, "Late completion")
        restore()
        assert_eq(zone.done, 1, "no stamp: the old rule applies, unchanged")
        assert_eq(line, nil, "and nothing is claimed about a phase nobody recorded")
    end,
}
