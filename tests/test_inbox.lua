-- The shared inbox Invariant G has always required, and never had.
--
-- On 2026-09-02 the fleet spent 11.8 hours doing nothing but re-introducing
-- itself. proto.receive returns the FIRST message addressed to this turtle of
-- ANY type; register() wants a REGISTER_ACK, so a HEARTBEAT_ACK arriving first
-- came back instead, failed the type test, and was discarded along with the
-- attempt. The real ACK then arrived with nothing waiting for it and went the
-- same way. Retries added traffic, which made the next collision likelier.
--
-- The server was answering correctly the whole time -- it logged "Re-registered"
-- for every attempt, a line that only exists on the success path. The loss was
-- entirely receiver-side, which is what Invariant G means by ACK loops making
-- loss visible rather than absent.
--
-- These drive base.receive/receiveCtrl directly rather than standing up
-- parallel.waitForAny: the property under test is that nothing is discarded,
-- and that is a property of the queues.

package.path = "./?.lua;" .. package.path

local stub  = require("tests.stub_cc")
local proto = require("protocol")

local function fresh()
    local c = stub.install({})
    local modem = { open = function() end, isOpen = function() return true end,
                    transmit = function() end }
    peripheral = { find = function(k) return k == "modem" and modem or nil end,
                   getType = function() return nil end, wrap = function() return nil end }
    gps = { locate = function() return 0, 64, 0 end }
    package.loaded["turtle_base"] = nil
    package.loaded["geofence"]    = nil
    local base = require("turtle_base")
    return base, c
end

-- Hand a decoded message straight to the router, as the control loop does.
local function deliver(base, msgType, from)
    base.routeMessage({ type = msgType, from = from or "server",
                        to = "node_1", payload = { ok = true } })
end

return {
    -- The storm, reduced to its essentials. A HEARTBEAT_ACK arrives while the
    -- turtle is waiting for its REGISTER_ACK. Under the old code that ACK came
    -- back from proto.receive, failed the type test and was destroyed. Here it
    -- must be held, and the REGISTER_ACK must still be found.
    ["a heartbeat ACK arriving first does not eat the registration ACK"] =
    function(assert_eq)
        local base = fresh()
        deliver(base, proto.MSG.HEARTBEAT_ACK)
        deliver(base, proto.MSG.REGISTER_ACK)

        local reply = base.receiveCtrl(0, proto.MSG.REGISTER_ACK)
        local ctrl  = select(1, base.inboxSizes())

        assert_eq(reply ~= nil and reply.type, proto.MSG.REGISTER_ACK,
            "the registration ACK must be found even though it arrived second")
        assert_eq(ctrl, 1,
            "and the heartbeat ACK must still be queued, not discarded — "
            .. "destroying it is what tripped serverDown 15s later")
    end,

    -- Order must not matter. The ACK can equally arrive first and sit waiting.
    ["a registration ACK that arrives before anyone waits is still there"] =
    function(assert_eq)
        local base = fresh()
        deliver(base, proto.MSG.REGISTER_ACK)
        local reply = base.receiveCtrl(0, proto.MSG.REGISTER_ACK)
        assert_eq(reply ~= nil, true,
            "a message arriving before its reader asks must not be lost")
    end,

    -- Control and job traffic must not be able to eat each other. If a job
    -- handler absorbed a HEARTBEAT_ACK, _missedHeartbeats would climb to
    -- MAX_MISSED, serverDown would trip and tryMove would freeze all movement --
    -- presenting as a fleet-wide freeze rather than a messaging fault.
    ["control traffic is never returned to a job receive"] = function(assert_eq)
        local base = fresh()
        deliver(base, proto.MSG.HEARTBEAT_ACK)
        deliver(base, proto.MSG.SUPPORT_STAGED, "node_2")

        local job = base.receive(0)
        local ctrl, jobs = base.inboxSizes()

        assert_eq(job ~= nil and job.type, proto.MSG.SUPPORT_STAGED,
            "a job receive must return job traffic")
        assert_eq(ctrl, 1, "and must leave the heartbeat ACK in the control queue")
        assert_eq(jobs, 0)
    end,

    -- Hold, never push back inline. Everything not matched must survive the scan
    -- in its original order; re-queuing inline would have the loop re-pop what it
    -- just queued and spin without ever blocking.
    ["unmatched messages are held and re-queued in order"] = function(assert_eq)
        local base = fresh()
        deliver(base, proto.MSG.POSITION_UPDATE, "node_2")
        deliver(base, proto.MSG.HOLE_READY,      "node_2")
        deliver(base, proto.MSG.SUPPORT_STAGED,  "node_2")

        local got = base.receive(0, proto.MSG.SUPPORT_STAGED)
        local first  = base.receive(0)
        local second = base.receive(0)

        assert_eq(got ~= nil and got.type, proto.MSG.SUPPORT_STAGED,
            "the requested type must be pulled out of the middle")
        assert_eq(first ~= nil and first.type, proto.MSG.POSITION_UPDATE,
            "and the others must come back in arrival order")
        assert_eq(second ~= nil and second.type, proto.MSG.HOLE_READY)
    end,

    -- A caller waiting on several types gets any of them, and anything outside
    -- the set stays queued rather than being filtered away by the caller.
    ["a set of wanted types matches any member and holds the rest"] =
    function(assert_eq)
        local base = fresh()
        deliver(base, proto.MSG.POSITION_UPDATE, "node_2")
        deliver(base, proto.MSG.HOLE_READY,      "node_2")

        local set = { [proto.MSG.HOLE_READY] = true }
        local got = base.receive(0, set)
        local _, jobs = base.inboxSizes()

        assert_eq(got ~= nil and got.type, proto.MSG.HOLE_READY)
        assert_eq(jobs, 1, "the unwanted message must remain queued")
    end,

    -- An empty queue with a zero timeout must return nil rather than blocking or
    -- raising. register() depends on this to count a failed attempt.
    ["an empty inbox times out cleanly"] = function(assert_eq)
        local base = fresh()
        assert_eq(base.receive(0), nil)
        assert_eq(base.receiveCtrl(0, proto.MSG.REGISTER_ACK), nil)
    end,

    -- A worker that stops draining must not grow a queue without limit on a
    -- 1 MB computer. Dropping the oldest is deliberate: a superseded assignment
    -- is worth less than the message that just arrived.
    ["an inbox is bounded and drops the oldest first"] = function(assert_eq)
        local base = fresh()
        for i = 1, 200 do
            base.routeMessage({ type = proto.MSG.POSITION_UPDATE, from = "node_2",
                                to = "node_1", payload = { n = i } })
        end
        local _, jobs = base.inboxSizes()
        local oldest = base.receive(0)

        assert_eq(jobs <= 64, true,
            string.format("the queue must stay bounded, got %d", jobs))
        assert_eq(oldest.payload.n > 1, true,
            "the survivors must be the newest, not the first sixty-four")
    end,
}
