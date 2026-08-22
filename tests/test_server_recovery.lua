-- The server's job-recovery sweep: does a miner that finished its job ever get
-- freed when the JOB_COMPLETE that says so is lost?
--
-- Observed 2026-08-22 (W1): node_118 mined all 15 sectors of job_0726, flew
-- home, docked, and then sat at its own bay for FOUR HOURS -- full tank,
-- heartbeating normally, status stuck at RETURNING, job still IN_PROGRESS --
-- while the log repeated "Dispatch hold: job_0723 needs MINER (idle=0)" once a
-- minute. Two /state snapshots 991 seconds apart were byte-identical. A stable
-- deadlock, not slow recovery.
--
-- sendComplete is fire-and-forget, so losing it is expected and survivable by
-- design: jobQueue.checkGhosts' idle-stuck arm exists for exactly this. It never
-- fired, because registry.update's stale-IDLE guard erases the IDLE the arm is
-- waiting to see -- the recovery condition is destroyed before the recovery code
-- can read it.
--
-- This is the first suite to load central_server.lua at all. See the test seam
-- at the bottom of that file for why it could not be done before.

package.path = "./?.lua;" .. package.path

local stub  = require("tests.stub_cc")
local proto = require("protocol")

-- A server with one MINER registered and one MINE job IN_PROGRESS assigned to
-- it -- the state node_118 was in the moment its JOB_COMPLETE went missing.
local function serverWithMinerOnJob()
    stub.install({})
    local savedEpoch = os.epoch
    local clock = 1000000            -- ms; advanced by the tests
    os.epoch = function() return clock end

    _G.__CC_SERVER_TEST = true
    package.loaded["central_server"] = nil
    package.loaded["waypoints"]      = nil
    local server = require("central_server")
    local T = server._test

    T.state.registry["node_118"] = {
        id       = "node_118",
        role     = proto.ROLE.MINER,
        status   = proto.STATUS.WORKING,
        jobId    = "job_0726",
        fuel     = 100000,
        online   = true,
        lastSeen = clock,
        position = { x = 158, y = 67, z = -2810 },
    }
    -- Shape mirrors what jobQueue.add builds, history included: jobQueue._hist
    -- does table.insert(job.history, ...) with no guard, so a fixture missing it
    -- fails inside the code under test rather than in the assertion.
    T.state.jobs["job_0726"] = {
        id         = "job_0726",
        type       = proto.JOB.MINE,
        status     = "IN_PROGRESS",
        assignedTo = "node_118",
        params     = {},
        priority   = 5,
        history    = {},
        createdAt  = clock,
        retries    = 0,
    }

    local restore = function()
        os.epoch = savedEpoch
        _G.__CC_SERVER_TEST = nil
        package.loaded["central_server"] = nil
    end
    -- advance(sec) moves the clock so the sweep's debounce windows can elapse.
    local advance = function(sec) clock = clock + (sec * 1000) end
    return server, T, advance, restore, function() return clock end
end

-- One heartbeat exactly as a finished miner sends it: its own state, which is
-- IDLE with no job, because from its point of view the work is done.
local function heartbeatAsFinished(T)
    T.registry.update("node_118", proto.STATUS.IDLE, 100000,
                      { x = 158, y = 67, z = -2810 }, nil, proto.VERSION)
end

return {
    -- The precondition, asserted so the test below cannot pass for the wrong
    -- reason. The guard is deliberate and stays: it is what stops a stale IDLE
    -- (sent before JOB_ASSIGN lands) re-opening a turtle for a second dispatch.
    ["the stale-IDLE guard keeps the server's own view of an active job"] =
    function(assert_eq)
        local server, T, advance, restore = serverWithMinerOnJob()
        heartbeatAsFinished(T)
        local t = T.state.registry["node_118"]
        local status, jobId = t.status, t.jobId
        restore()
        assert_eq(status ~= proto.STATUS.IDLE, true,
            "the guard must still suppress IDLE while the job is IN_PROGRESS")
        assert_eq(jobId, "job_0726", "and must keep the job pinned to the turtle")
    end,

    -- The defect. A miner that has been reporting IDLE for four hours is done,
    -- whatever the job table still says, and the sweep must eventually act on it.
    ["a finished miner whose JOB_COMPLETE was lost is recovered, not stranded"] =
    function(assert_eq)
        local server, T, advance, restore = serverWithMinerOnJob()

        -- Heartbeat, wait past the 60s idle-stuck debounce, heartbeat again --
        -- exactly what node_118 did for four hours.
        heartbeatAsFinished(T)
        jobQueue.checkGhosts()
        advance(120)
        heartbeatAsFinished(T)
        jobQueue.checkGhosts()

        local job = T.state.jobs["job_0726"]
        local status = job and job.status
        restore()

        assert_eq(status ~= "IN_PROGRESS", true,
            "the job must not still be IN_PROGRESS after two minutes of IDLE "
            .. "heartbeats -- this is the four-hour deadlock")
    end,

    -- The guard's stated rationale is the ASSIGNED window: an IDLE sent before
    -- JOB_ASSIGN arrives must not re-open the turtle. Recovery must not undo
    -- that, or one dropped packet becomes a double dispatch.
    ["a single stale IDLE during the assign window does not free the job"] =
    function(assert_eq)
        local server, T, advance, restore = serverWithMinerOnJob()
        T.state.jobs["job_0726"].status = "ASSIGNED"

        heartbeatAsFinished(T)
        jobQueue.checkGhosts()
        advance(10)                      -- well inside the 60s debounce
        jobQueue.checkGhosts()

        local status = T.state.jobs["job_0726"].status
        restore()
        assert_eq(status, "ASSIGNED",
            "a brief stale IDLE must not cancel a job that was just assigned")
    end,
}
