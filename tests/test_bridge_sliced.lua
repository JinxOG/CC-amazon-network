-- The bridge payload built in slices (W3, 2026-11-18; SPEC-OWNER's ruling after T2 shakeout-24h-b). At 150 turtles
-- buildBridgePayload took 2307 ms in one go, and the server, which cannot hear the radio while it runs, logged 1362
-- LOOP STALLs in ~3 h, deaf 22-58% of every 10 minutes. The build now runs as a sliced task: server.slice() hands
-- control back to the main loop, which handles every waiting event and then steps the task again. Never deaf for
-- longer than one slice, whatever the fleet.
package.path = "./?.lua;" .. package.path
local stub = require("tests.stub_cc")

local function freshServer()
    stub.install({})
    local savedEpoch, savedPeripheral = os.epoch, peripheral
    os.epoch = function() return 1000000 end
    peripheral = { find = function() return nil end }
    package.loaded["cloudstore"] = nil
    _G.__CC_SERVER_TEST = true
    package.loaded["central_server"] = nil
    package.loaded["waypoints"] = nil
    local server = require("central_server")
    local restore = function()
        os.epoch, peripheral = savedEpoch, savedPeripheral
        _G.__CC_SERVER_TEST = nil
        package.loaded["central_server"] = nil
        package.loaded["cloudstore"] = nil
    end
    return server, server._test, restore
end

return {
    ["a sliced task runs in steps, and gives what it gives run straight through"] = function(assert_eq)
        local server, _, restore = freshServer()
        local function work()
            local out = {}
            for i = 1, 5 do out[#out + 1] = i; server.slice() end
            return table.concat(out, ",")
        end
        local straight = work()                                   -- outside a task: slice() does nothing
        local task = server.slicedStart(work)
        local steps, done, result = 0, false, nil
        repeat steps = steps + 1; done, result = server.slicedStep(task) until done ~= false or steps > 50
        restore()
        assert_eq(straight, "1,2,3,4,5", "outside a task slice() is a no-op")
        assert_eq(done, true, "the task finished")
        assert_eq(result, "1,2,3,4,5", "with the same result")
        assert_eq(steps, 6, "one step per slice, and one to finish")
    end,

    ["a sliced task that yields anything else is abandoned, not stepped on"] = function(assert_eq)
        local server, _, restore = freshServer()
        local task = server.slicedStart(function() coroutine.yield("modem_message"); return "never" end)
        local done, err = server.slicedStep(task)
        restore()
        assert_eq(done, nil, "abandoned")
        assert_eq(tostring(err):find("yielded", 1, true) ~= nil, true, "and says why: " .. tostring(err))
    end,

    ["the log section is the same built in slices as in one go"] = function(assert_eq)
        local server, T, restore = freshServer()
        T.state.turtleLogs = {}
        for s = 1, 30 do
            local ring = {}
            for i = 1, 12 do ring[i] = { ts = 1794540000000 + i, level = "INFO", seq = i, bootId = 7, msg = "n" .. s .. " l" .. i } end
            T.state.turtleLogs["node_" .. s] = ring
        end
        T.state.log = {}
        for i = 1, 20 do T.state.log[i] = { ts = 1794540000000 + i, level = "INFO", seq = i, bootId = 9, msg = "s" .. i } end
        local s1, t1 = server.bridgeLogs(1000)
        T.state.logFitCursor = 0
        for _, ring in pairs(T.state.turtleLogs) do for _, e in ipairs(ring) do e.sentAt = nil end end
        local task = server.slicedStart(function() return { server.bridgeLogs(1000) } end)
        local steps, done, r = 0, false, nil
        repeat steps = steps + 1; done, r = server.slicedStep(task) until done ~= false or steps > 500
        restore()
        assert_eq(done, true, "the sliced build finished")
        assert_eq(steps > 1, true, "in more than one step (" .. steps .. ")")
        assert_eq(r and r[1] == s1 and r[2] == t1, true, "and byte for byte the same")
    end,

    -- 2026-11-18 (SPEC-OWNER's ruling; sim w3_depart_off_dock on the sliced build): an RS peripheral call waits for its
    -- task_complete and CC throws away every other event arriving meanwhile -- 270 modem_messages in one sim run, a
    -- one-shot JOB_FAILED among them. server.keepEvents runs such a call pumping the events itself: the ones the call
    -- waits for go to it, every other one is kept and queued again, in order, once the call returns.
    ["a call that waits for its event keeps every other event, in order, for the loop"] = function(assert_eq)
        local server, _, restore = freshServer()
        local feed = {
            { "modem_message", "top", 1, 1, "hello", 5 },
            { "timer", 42 },
            { "task_complete", 7, true, "items" },
        }
        local queued = {}
        local savedPull, savedQueue = os.pullEventRaw, os.queueEvent
        os.pullEventRaw = function() return table.unpack(table.remove(feed, 1)) end
        os.queueEvent = function(...) queued[#queued + 1] = { ... } end
        local result = server.keepEvents(function()
            local ev = { coroutine.yield("task_complete") }
            return ev[4]
        end)
        os.pullEventRaw, os.queueEvent = savedPull, savedQueue
        local kept = server.keptEventsForTest and server.keptEventsForTest() or nil
        restore()
        assert_eq(result, "items", "the call gets its own event and returns its result")
        assert_eq(#queued, 2, "the two other events are queued again")
        assert_eq(queued[1] and queued[1][1], "modem_message", "in order: the radio message first")
        assert_eq(queued[1] and queued[1][5], "hello", "with all its arguments")
        assert_eq(queued[2] and queued[2][1] .. ":" .. tostring(queued[2][2]), "timer:42", "then the timer, its id kept")
    end,
}
