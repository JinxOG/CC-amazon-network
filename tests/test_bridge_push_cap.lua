-- The bridge update's size ceiling (W3, 2026-11-12; SPEC-OWNER's ruling of the same day).
--
-- T2 run shakeout-faults-a: the bridge restarted for the bridge_slow fault, the server saw its new boot id, cleared
-- every log acknowledgement and replayed every source's ring at up to 40 lines each. With 160 turtles that one update
-- was over the bridge's 1 MB express.json limit. The bridge refused it (413, 1,032 times), a refused update is never
-- acknowledged, so the next one was the same size: the server's updates and its own log never reached the bridge
-- again. The 40-line cap was per source; nothing capped the update as a whole.
--
-- The bars: no update over half the bridge's limit (512 KB) however many sources there are; the replay drains over
-- later updates and loses no line, in order per source; after a refusal the next update is smaller, not identical.
package.path = "./?.lua;" .. package.path

local stub = require("tests.stub_cc")

local CAP = 512 * 1024

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

-- A line long enough that 200 sources x 40 lines is about 2.6 MB: five times the cap. Each carries a marker the test
-- reads back out of the JSON itself, so what was delivered is measured from the bytes, not from the server's say-so.
local PAD = string.rep("x", 260)
local function fillRings(T, sources, lines)
    T.state.turtleLogs = {}
    for s = 1, sources do
        local ring = {}
        for i = 1, lines do
            ring[i] = { ts = 1794540000000 + i, level = "INFO", seq = i, bootId = 7,
                        msg = string.format("[node_%d] M%d_%dE %s", s, s, i, PAD) }
        end
        T.state.turtleLogs["node_" .. s] = ring
    end
    T.state.log = {}
    for i = 1, 100 do
        T.state.log[i] = { ts = 1794540000000 + i, level = "INFO", seq = i, bootId = 9,
                           msg = string.format("server line S%dE %s", i, PAD) }
    end
    T.state.logAck = {}
end

-- One update: the logs fitted beside `rest` bytes of everything else, as buildBridgePayload sends them.
local function update(server, rest)
    local s, t = server.bridgeLogs(rest)
    return s, t, rest + #',"serverLog":' + #s + #',"turtleLogs":' + #t + 1
end

-- The bridge's side: everything in the update is written, and each source's highest seq is acknowledged.
local function ack(T, s, t, seen, order)
    for src, seq in t:gmatch("M(%d+)_(%d+)E") do
        local key = "node_" .. src
        seq = tonumber(seq)
        seen[key .. ":" .. seq] = (seen[key .. ":" .. seq] or 0) + 1
        order[key] = order[key] or {}
        table.insert(order[key], seq)
        local a = T.state.logAck[key]
        if not a or seq > a.seq then T.state.logAck[key] = { bootId = 7, seq = seq } end
    end
    for seq in s:gmatch("S(%d+)E") do
        seq = tonumber(seq)
        seen["server:" .. seq] = (seen["server:" .. seq] or 0) + 1
        local a = T.state.logAck["server"]
        if not a or seq > a.seq then T.state.logAck["server"] = { bootId = 9, seq = seq } end
    end
end

return {
    ["a full replay to 200 sources drains under the cap, every line once and in order"] = function(assert_eq)
        local server, T, restore = freshServer()
        fillRings(T, 200, 40)
        local rest = 200 * 1024            -- turtles, jobs, zones, storage: about what shakeout-faults-a carried
        local seen, order, worst, pushes = {}, {}, 0, 0
        for _ = 1, 200 do
            local s, t, size = update(server, rest)
            if s == "[]" and t == "{}" then break end
            pushes = pushes + 1
            if size > worst then worst = size end
            ack(T, s, t, seen, order)
        end
        restore()

        local missing, twice = 0, 0
        for src = 1, 200 do
            for i = 1, 40 do
                local n = seen["node_" .. src .. ":" .. i] or 0
                if n == 0 then missing = missing + 1 elseif n > 1 then twice = twice + 1 end
            end
        end
        for i = 1, 100 do
            local n = seen["server:" .. i] or 0
            if n == 0 then missing = missing + 1 elseif n > 1 then twice = twice + 1 end
        end
        local outOfOrder = 0
        for _, list in pairs(order) do
            for i = 2, #list do if list[i] <= list[i - 1] then outOfOrder = outOfOrder + 1 end end
        end
        assert_eq(pushes > 1, true, "the replay is bigger than one update, so the check below has something to judge ("
            .. pushes .. " updates)")
        assert_eq(worst <= CAP, true, string.format("no update over %d bytes (the largest was %d)", CAP, worst))
        assert_eq(missing, 0, "every line delivered (8,100 lines)")
        assert_eq(twice, 0, "no line delivered twice")
        assert_eq(outOfOrder, 0, "each source's lines arrive in order")
    end,

    ["a backlog over the cap is said once, and again only after it has drained"] = function(assert_eq)
        local server, T, restore = freshServer()
        fillRings(T, 200, 40)
        local function said()
            local n = 0
            for _, e in ipairs(T.state.log) do if tostring(e.msg):find("at its 512 KB cap", 1, true) then n = n + 1 end end
            return n
        end
        local seen, order = {}, {}
        local s, t = update(server, 200 * 1024)
        ack(T, s, t, seen, order)
        local once = said()
        s, t = update(server, 200 * 1024)
        ack(T, s, t, seen, order)
        local stillOnce = said()
        for _ = 1, 50 do
            s, t = update(server, 200 * 1024)
            if s == "[]" and t == "{}" then break end
            ack(T, s, t, seen, order)
        end
        fillRings(T, 200, 40)
        update(server, 200 * 1024)
        local again = said()
        restore()
        assert_eq(once, 1, "the first update at the cap says so")
        assert_eq(stillOnce, 1, "the next one, still at the cap, does not say it again")
        assert_eq(again, 1, "a fresh backlog after a drained one says it once more (the ring was refilled, so the "
            .. "earlier line is gone from it; one line now)")
    end,

    ["the cap holds however many sources there are"] = function(assert_eq)
        local server, T, restore = freshServer()
        fillRings(T, 600, 40)
        local _, _, size = update(server, 200 * 1024)
        restore()
        assert_eq(size <= CAP, true, string.format("600 sources: the update is %d bytes, at most %d", size, CAP))
        assert_eq(size > CAP * 0.9, true, "and it is filled, not starved (" .. size .. ")")
    end,

    ["after a refused update the next one is smaller, and acceptance restores it"] = function(assert_eq)
        local server, T, restore = freshServer()
        fillRings(T, 200, 40)
        local _, _, first = update(server, 200 * 1024)
        server.noteBridgeRefused()
        local _, _, second = update(server, 200 * 1024)
        server.noteBridgeRefused()
        local _, _, third = update(server, 200 * 1024)
        for _ = 1, 10 do server.noteBridgeAccepted() end
        local _, _, back = update(server, 200 * 1024)
        restore()
        assert_eq(second < first, true, string.format("refused once: %d bytes after %d", second, first))
        assert_eq(third < second, true, string.format("refused twice: %d bytes after %d", third, second))
        -- Not byte-equal: the next update starts at a different source, so its lines differ by a few bytes.
        assert_eq(back > first * 0.99 and back <= CAP, true,
            string.format("accepted again, the full share comes back (%d bytes; the first was %d)", back, first))
    end,

    ["when everything else already fills the cap, the logs wait rather than break it"] = function(assert_eq)
        local server, T, restore = freshServer()
        fillRings(T, 10, 40)
        local s, t = server.bridgeLogs(CAP)
        restore()
        assert_eq(s .. t, "[]{}", "no log lines when the rest of the update is already at the cap")
    end,

    ["an acknowledged fleet costs nothing"] = function(assert_eq)
        local server, T, restore = freshServer()
        fillRings(T, 5, 3)
        for s = 1, 5 do T.state.logAck["node_" .. s] = { bootId = 7, seq = 3 } end
        T.state.logAck["server"] = { bootId = 9, seq = 100 }
        local s, t = server.bridgeLogs(1000)
        restore()
        assert_eq(s .. t, "[]{}", "nothing unacknowledged, nothing sent")
    end,
}
