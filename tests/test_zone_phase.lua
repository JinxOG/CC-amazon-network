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
