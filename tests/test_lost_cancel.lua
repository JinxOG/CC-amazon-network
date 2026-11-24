-- Sim w3_side_atc on 4d2617c (2026-11-24): in a radio blackout the server timed out node_56, cancelled its support job
-- job_0042 ("Job cancelled (inline)", a RECALL it never heard) and re-paired the delivery. After the blackout node_56
-- carried on with job_0042: it held DH J1 N1 W1 for 3 minutes, waiting for an old partner, and only its own 180 s timer
-- ended it. Every heartbeat names the turtle's job: one naming a job the server has cancelled gets the cancel again.
local stub = require("tests.stub_cc")
local proto

local function server()
    stub.install({})
    proto = require("protocol")
    local savedEpoch = os.epoch
    local clock = 1000000
    os.epoch = function() return clock end
    _G.__CC_SERVER_TEST = true
    package.loaded["central_server"] = nil
    package.loaded["waypoints"] = nil
    local T = require("central_server")._test
    T.sent = {}
    T.state.modem = { isOpen = function() return true end, open = function() end,
        transmit = function(ch, reply, body) T.sent[#T.sent + 1] = { channel = ch, body = body } end }
    T.state.registry["node_56"] = { id = "node_56", role = proto.ROLE.SUPPORT, status = proto.STATUS.WORKING, fuel = 100000,
        online = true, lastSeen = clock, jobId = "job_0042" }
    T.state.jobs["job_0042"] = { id = "job_0042", type = proto.JOB.SUPPORT_FOLLOW, status = "CANCELLED", params = {},
        history = {}, updatedAt = clock }
    T.state.jobs["job_0050"] = { id = "job_0050", type = proto.JOB.SUPPORT_FOLLOW, status = "IN_PROGRESS", params = {},
        assignedTo = "node_56", history = {}, updatedAt = clock }
    local function at(ms) clock = 1000000 + ms end
    local restore = function() os.epoch = savedEpoch; _G.__CC_SERVER_TEST = nil; package.loaded["central_server"] = nil end
    return T, at, restore
end

local function beat(T, jobId)
    T.handlers[proto.MSG.HEARTBEAT]({ type = proto.MSG.HEARTBEAT, from = "node_56", to = "server", seq = 1, ts = 0,
        payload = { status = proto.STATUS.WORKING, jobId = jobId, fuel = 100000, position = { x = 155, y = 67, z = -2793 } } })
end

local function recalls(T)
    local n = 0
    for _, m in ipairs(T.sent) do
        local ok, d = pcall(textutils.unserialise, m.body)
        if ok and type(d) == "table" and d.type == proto.MSG.RECALL and d.to == "node_56" then n = n + 1 end
    end
    return n
end

return {
    ["a heartbeat naming a cancelled job gets the cancel again"] = function(assert_eq)
        local T, at, restore = server()
        local ok, err = pcall(function()
            at(0);     beat(T, "job_0042")
            at(10000); beat(T, "job_0042")     -- 10 s on: not again yet
        end)
        local first = recalls(T)
        at(40000); pcall(beat, T, "job_0042")  -- 40 s on: again
        local later = recalls(T)
        restore()
        assert_eq(ok, true, tostring(err))
        assert_eq(first, 1, "recalled at its first heartbeat (" .. first .. ")")
        assert_eq(later, 2, "and again 30 s on while it still names it (" .. later .. ")")
    end,

    ["a heartbeat naming its live job gets no recall"] = function(assert_eq)
        local T, at, restore = server()
        pcall(beat, T, "job_0050")
        local n = recalls(T)
        restore()
        assert_eq(n, 0, "no recall (" .. n .. ")")
    end,
}
