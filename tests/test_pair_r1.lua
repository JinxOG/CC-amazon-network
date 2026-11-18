-- R1 of docs/superpowers/specs/2026-11-17-delivery-pair-and-hole-design.md (W3, 2026-11-17): a pair is formed only
-- from two docked turtles, and both accept before either moves; a refusal by either half cancels both and the job is
-- re-paired. T2 shakeout-side-e jam 1: node_218, still out in the world, was paired 23 ms after its job ended,
-- refused, its half was requeued alone and never paired again, and the delivery held the dispatch hole 600 s.
package.path = "./?.lua;" .. package.path
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
    local function turtle(id, role, dock, pos, status)
        T.state.registry[id] = { id = id, role = role, status = status or proto.STATUS.IDLE, fuel = 100000,
            online = true, lastSeen = clock, dock = dock, position = pos }
    end
    local restore = function() os.epoch = savedEpoch; _G.__CC_SERVER_TEST = nil; package.loaded["central_server"] = nil end
    return T, turtle, restore
end

local function sentTo(T, mtype, to)
    local n = 0
    for _, m in ipairs(T.sent) do
        local ok, d = pcall(textutils.unserialise, m.body)
        if ok and type(d) == "table" and d.type == mtype and (to == nil or d.to == to) then n = n + 1 end
    end
    return n
end

local DOCK_D = { x = 153, z = -2806, bay = 1, row = "A" }
local DOCK_S = { x = 153, z = -2797, bay = 1, row = "A" }

-- A dispatched pair as the server records it: the delivery's job and its support's, linked.
local function pair(T)
    T.state.jobs["job_0010"] = { id = "job_0010", type = proto.JOB.DELIVER, status = "ASSIGNED", assignedTo = "node_d",
        params = { partnerId = "node_s" }, priority = 5, history = {}, createdAt = 1, retries = 0,
        linkedJob = "job_0011", pair = { support = "job_0011", acked = {} } }
    T.state.jobs["job_0011"] = { id = "job_0011", type = proto.JOB.SUPPORT_FOLLOW, status = "ASSIGNED", assignedTo = "node_s",
        params = { partnerId = "node_d", masterJobId = "job_0010" }, priority = 5, history = {}, createdAt = 1, retries = 0 }
    T.state.registry["node_d"].jobId = "job_0010"
    T.state.registry["node_s"].jobId = "job_0011"
end

return {
    ["a delivery or support out in the world is not idle, whatever its status says"] = function(assert_eq)
        local T, turtle, restore = server()
        turtle("node_s", proto.ROLE.SUPPORT, DOCK_S, { x = 226, y = 61, z = -2781 })   -- side-e's node_218, IDLE, away
        local away = #T.registry.getIdle(proto.ROLE.SUPPORT)
        T.registry.update("node_s", proto.STATUS.IDLE, 100000, { x = 153, y = 67, z = -2797 }, nil)   -- home, on its dock
        local home = #T.registry.getIdle(proto.ROLE.SUPPORT)
        restore()
        assert_eq(away, 0, "IDLE but 200 blocks from its dock: not offered work")
        assert_eq(home, 1, "on its dock: offered")
    end,

    ["a turtle given a job is not idle again until it reports from its dock"] = function(assert_eq)
        local T, turtle, restore = server()
        turtle("node_s", proto.ROLE.SUPPORT, DOCK_S, { x = 153, y = 67, z = -2797 })
        T.registry.update("node_s", proto.STATUS.IDLE, 100000, { x = 153, y = 67, z = -2797 }, nil)
        T.state.jobs["job_0011"] = { id = "job_0011", type = proto.JOB.SUPPORT_FOLLOW, status = "PENDING", params = {}, history = {}, retries = 0 }
        T.jobQueue.assign("job_0011", "node_s")
        T.state.jobs["job_0011"].status = "COMPLETE"
        local t = T.state.registry["node_s"]
        t.status, t.jobId = proto.STATUS.IDLE, nil          -- its job over; it has not reported since
        local before = #T.registry.getIdle(proto.ROLE.SUPPORT)
        T.registry.update("node_s", proto.STATUS.IDLE, 100000, { x = 153, y = 67, z = -2797 }, nil)
        local after = #T.registry.getIdle(proto.ROLE.SUPPORT)
        restore()
        assert_eq(before, 0, "its job just ended: not docked since")
        assert_eq(after, 1, "it reported from its dock: idle")
    end,

    ["the delivery is told to go only once both halves have accepted"] = function(assert_eq)
        local T, turtle, restore = server()
        turtle("node_d", proto.ROLE.DELIVERY, DOCK_D, { x = 153, y = 67, z = -2806 }, proto.STATUS.TRAVELLING)
        turtle("node_s", proto.ROLE.SUPPORT, DOCK_S, { x = 153, y = 67, z = -2797 }, proto.STATUS.TRAVELLING)
        pair(T)
        T.jobQueue.acknowledge("job_0010", "node_d", true)
        local afterOne = sentTo(T, proto.MSG.PAIR_GO, "node_d")
        T.jobQueue.acknowledge("job_0011", "node_s", true)
        local afterBoth = sentTo(T, proto.MSG.PAIR_GO, "node_d")
        restore()
        assert_eq(afterOne, 0, "the delivery alone has accepted: no go")
        assert_eq(afterBoth, 1, "both have: go, once")
    end,

    ["a support that refuses cancels the pair: the delivery is told and the job is re-paired, not the support's half alone"] = function(assert_eq)
        local T, turtle, restore = server()
        turtle("node_d", proto.ROLE.DELIVERY, DOCK_D, { x = 153, y = 67, z = -2806 }, proto.STATUS.TRAVELLING)
        turtle("node_s", proto.ROLE.SUPPORT, DOCK_S, { x = 153, y = 67, z = -2797 }, proto.STATUS.TRAVELLING)
        pair(T)
        T.jobQueue.acknowledge("job_0010", "node_d", true)
        T.sent = {}
        T.jobQueue.acknowledge("job_0011", "node_s", false, "busy")
        local master, support = T.state.jobs["job_0010"], T.state.jobs["job_0011"]
        local told = sentTo(T, proto.MSG.PAIR_CANCEL, "node_d")
        local warehouse = sentTo(T, proto.MSG.JOB_ABORT, "warehouse")
        restore()
        assert_eq(master.status, "PENDING", "the delivery's job goes back to be paired again")
        assert_eq(master.assignedTo, nil, "with nobody on it")
        assert_eq(support.status ~= "PENDING", true, "the support's half is not left in the queue alone (" .. tostring(support.status) .. ")")
        assert_eq(told, 1, "the delivery is told the pair is off")
        assert_eq(warehouse, 1, "and the warehouse lets the job go")
    end,

    ["asked, the server says go, cancel, or nothing yet"] = function(assert_eq)
        local T, turtle, restore = server()
        turtle("node_d", proto.ROLE.DELIVERY, DOCK_D, { x = 153, y = 67, z = -2806 }, proto.STATUS.TRAVELLING)
        turtle("node_s", proto.ROLE.SUPPORT, DOCK_S, { x = 153, y = 67, z = -2797 }, proto.STATUS.TRAVELLING)
        pair(T)
        local function ask() T.sent = {}; T.handlers[proto.MSG.PAIR_ASK]({ from = "node_d", payload = { jobId = "job_0010" } }) end
        ask()
        local pending = sentTo(T, proto.MSG.PAIR_GO) + sentTo(T, proto.MSG.PAIR_CANCEL)
        T.jobQueue.acknowledge("job_0010", "node_d", true)
        T.jobQueue.acknowledge("job_0011", "node_s", true)
        ask()
        local go = sentTo(T, proto.MSG.PAIR_GO, "node_d")
        turtle("node_x", proto.ROLE.DELIVERY, DOCK_D, { x = 153, y = 67, z = -2806 })
        T.handlers[proto.MSG.PAIR_ASK]({ from = "node_x", payload = { jobId = "job_0010" } })
        local notYours = sentTo(T, proto.MSG.PAIR_CANCEL, "node_x")
        restore()
        assert_eq(pending, 0, "neither yet")
        assert_eq(go, 1, "go once both accepted")
        assert_eq(notYours, 1, "a turtle the job is not assigned to is told it is off")
    end,

    -- 2026-11-17 (sim w3_side_atc on R4): a delivery rebooted mid-job was sent its job again with no partner -- the
    -- dispatch adds it to its own copy of the params only -- went down the hole alone, and the order failed for good.
    ["a delivery's job sent again after a reboot names its support"] = function(assert_eq)
        local T, turtle, restore = server()
        turtle("node_d", proto.ROLE.DELIVERY, DOCK_D, { x = 153, y = 67, z = -2806 }, proto.STATUS.TRAVELLING)
        turtle("node_s", proto.ROLE.SUPPORT, DOCK_S, { x = 153, y = 67, z = -2797 }, proto.STATUS.TRAVELLING)
        pair(T)
        T.state.jobs["job_0010"].status = "IN_PROGRESS"
        T.state.jobs["job_0011"].status = "IN_PROGRESS"
        T.state.jobs["job_0010"].params = { destination = { x = 124, y = 67, z = -2824 } }   -- as a real dispatch stores it
        T.state.registry["node_d"].reSendJobId = "job_0010"
        T.sent = {}
        T.registry.reSendOnHeartbeat("node_d", proto.STATUS.IDLE)
        local partner
        for _, m in ipairs(T.sent) do
            local ok, d = pcall(textutils.unserialise, m.body)
            if ok and type(d) == "table" and d.type == proto.MSG.JOB_ASSIGN and d.to == "node_d" then
                partner = d.payload and d.payload.params and d.payload.params.partnerId
            end
        end
        restore()
        assert_eq(partner, "node_s", "the job sent again carries its support")
    end,

    -- R4, 2026-11-17 (sim w3_side_atc): the warehouse recalled a delivery already on its way home; its job went back,
    -- and the server recalled its support as "stale" -- out in the world, alone, it could not get home (it cannot dig).
    -- A support whose delivery is still out is brought home by it; it is recalled only once its delivery is home.
    ["a support whose delivery is still out is not recalled as stale; once the delivery is home it is"] = function(assert_eq)
        local T, turtle, restore = server()
        turtle("node_d", proto.ROLE.DELIVERY, DOCK_D, { x = 254, y = 60, z = -2780 }, proto.STATUS.RETURNING)
        turtle("node_s", proto.ROLE.SUPPORT, DOCK_S, { x = 254, y = 60, z = -2781 }, proto.STATUS.TRAVELLING)
        pair(T)
        T.state.jobs["job_0010"].status = "PENDING"          -- the delivery's job went back (a warehouse recall)
        T.state.jobs["job_0010"].assignedTo = nil
        T.state.jobs["job_0011"].status = "IN_PROGRESS"
        T.checkStaleSupports()
        local whileOut = T.state.jobs["job_0011"].status
        T.state.registry["node_d"].position = { x = 153, y = 67, z = -2806 }   -- home
        T.checkStaleSupports()
        local whenHome = T.state.jobs["job_0011"].status
        restore()
        assert_eq(whileOut, "IN_PROGRESS", "its delivery is out, bringing it home: it is left with it")
        assert_eq(whenHome ~= "IN_PROGRESS", true, "its delivery home: the stale support job ends (" .. tostring(whenHome) .. ")")
    end,

    -- 2026-11-17 (sim w3_side_atc, job_0035): both halves accepted, then the server went down; the support's wait to
    -- be let out with its delivery gave up (departure_failed, recoverable) and jobQueue.fail requeued its half ALONE.
    -- The delivery, still on its dock, asked the ATC "waiting for partner" for 4 h, and as the oldest waiter held the
    -- whole return line. A support half that fails goes the way of reassign: the pair is off, the delivery is told.
    ["a support half that fails while its delivery is on its dock calls the pair off; its half is not requeued alone"] = function(assert_eq)
        local T, turtle, restore = server()
        turtle("node_d", proto.ROLE.DELIVERY, DOCK_D, { x = 153, y = 67, z = -2806 }, proto.STATUS.TRAVELLING)
        turtle("node_s", proto.ROLE.SUPPORT, DOCK_S, { x = 153, y = 67, z = -2797 }, proto.STATUS.TRAVELLING)
        pair(T)
        T.jobQueue.acknowledge("job_0010", "node_d", true)
        T.jobQueue.acknowledge("job_0011", "node_s", true)
        T.sent = {}
        T.jobQueue.fail("job_0011", "departure_failed: no_word_from_delivery", true)
        local master, support = T.state.jobs["job_0010"], T.state.jobs["job_0011"]
        local told = sentTo(T, proto.MSG.PAIR_CANCEL, "node_d")
        restore()
        assert_eq(support.status ~= "PENDING", true, "the support's half is not left in the queue alone (" .. tostring(support.status) .. ")")
        assert_eq(told, 1, "the delivery is told the pair is off")
        assert_eq(master.status, "PENDING", "the delivery's job goes back to be paired again")
    end,

    -- 2026-11-18 (SPEC-OWNER's ruling; sim w3_depart_off_dock): a delivery's JOB_FAILED was sent once and thrown away in
    -- an RS-poll wait; the job never came back. A JOB_FAILED is now repeated until the server acknowledges it
    -- (JOB_FAILED_ACK); the server acknowledges every one, and one it has already taken (by its failId) is not
    -- counted again.
    ["the server acknowledges a JOB_FAILED, and the same one repeated is not counted twice"] = function(assert_eq)
        local T, turtle, restore = server()
        turtle("node_d", proto.ROLE.DELIVERY, DOCK_D, { x = 153, y = 67, z = -2806 }, proto.STATUS.TRAVELLING)
        turtle("node_s", proto.ROLE.SUPPORT, DOCK_S, { x = 153, y = 67, z = -2797 }, proto.STATUS.TRAVELLING)
        pair(T)
        T.state.jobs["job_0010"].status = "IN_PROGRESS"
        local msg = { from = "node_d", payload = { jobId = "job_0010", reason = "warehouse_chest_timeout", recoverable = true,
                                                   failId = "node_d:1:1" } }
        T.sent = {}
        T.handlers[proto.MSG.JOB_FAILED](msg)
        local acked = sentTo(T, proto.MSG.JOB_FAILED_ACK, "node_d")
        local after1 = T.state.jobs["job_0010"].retries
        T.state.jobs["job_0010"].assignedTo = "node_d"            -- sent out again to the same delivery
        T.handlers[proto.MSG.JOB_FAILED](msg)                     -- its repeat of the first one
        local after2 = T.state.jobs["job_0010"].retries
        local acked2 = sentTo(T, proto.MSG.JOB_FAILED_ACK, "node_d")
        restore()
        assert_eq(acked, 1, "acknowledged")
        assert_eq(after1, 1, "counted once")
        assert_eq(after2, 1, "the repeat is not counted again")
        assert_eq(acked2, 2, "and the repeat is acknowledged too")
    end,
}
