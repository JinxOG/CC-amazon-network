-- T2 shakeout-payload-h (2026-11-24): after the restart burst -- five server kills with no save -- two physical turtles
-- carried computer id 397. They transmitted at the same moment with their own seq counters (07:54:59.199: seq 21 from
-- 238,200,-2780 and seq 11 from 239,200,-2780), the ATC held the whole arrivals chain for them, and two docked turtles
-- beside N2 waited to the end of the run. The Head Engineer's ruling: detect it at the server -- two seq streams both
-- advancing, interleaved; a reboot resets seq but its old stream stops -- and raise NEEDS HANDS (a player has to remove
-- one copy); hold the id from work, tell both copies to park, and have the ATC drop and refuse the id.
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
    T.state.registry["node_9"] = { id = "node_9", role = proto.ROLE.MINER, status = proto.STATUS.IDLE, fuel = 100000,
        online = true, lastSeen = clock }
    local function at(ms) clock = 1000000 + ms end
    local restore = function() os.epoch = savedEpoch; _G.__CC_SERVER_TEST = nil; package.loaded["central_server"] = nil end
    return T, at, restore
end

local function msg(seq, pos)
    return { type = proto.MSG.HEARTBEAT, from = "node_9", to = "server", seq = seq, ts = 0,
             payload = { position = pos } }
end

local function sent(T, mtype, ch)
    local n = 0
    for _, m in ipairs(T.sent) do
        local ok, d = pcall(textutils.unserialise, m.body)
        if ok and type(d) == "table" and d.type == mtype and (ch == nil or m.channel == ch) then n = n + 1 end
    end
    return n
end

local A = { x = 238, y = 200, z = -2780 }
local B = { x = 239, y = 200, z = -2780 }

return {
    ["two seq streams from one id, both advancing, interleaved, are a duplicated turtle"] = function(assert_eq)
        local T, at, restore = server()
        local ok, err = pcall(function()
            for k = 0, 9 do
                at(k * 600)
                T.registry.dupCheck(msg(21 + k, A))
                at(k * 600 + 50)
                T.registry.dupCheck(msg(11 + k, B))
            end
        end)
        local t = T.state.registry["node_9"]
        local held = T.state.operatorHolds and T.state.operatorHolds["node_9"]
        local park, ban = sent(T, proto.MSG.PARK), sent(T, proto.MSG.ATC_BAN, proto.CH_ATC)
        restore()
        assert_eq(ok, true, tostring(err))
        assert_eq(tostring(t.needsHands), "duplicate_id: node_9 heard at 238,200,-2780 and 239,200,-2780",
            "NEEDS HANDS with its own code and both places")
        assert_eq(held, true, "held from work")
        assert_eq(park >= 1, true, "both copies are told to park (" .. park .. ")")
        assert_eq(ban, 1, "and the ATC is told, once (" .. ban .. ")")
    end,

    -- T2 shakeout-payload-i: the restart burst at 11:57 left node_215 as THREE turtles, at 191, 207 and 223,67,-2801,
    -- each with its own seq (at 12:44:08, seq 3960 and 3943 still interleaving). Two streams are not the only case.
    ["three seq streams from one id, interleaved, are a duplicated turtle"] = function(assert_eq)
        local T, at, restore = server()
        local C = { x = 223, y = 67, z = -2801 }
        local ok, err = pcall(function()
            for k = 0, 9 do
                at(k * 600);       T.registry.dupCheck(msg(6 + k, A))
                at(k * 600 + 200); T.registry.dupCheck(msg(17 + k, B))
                at(k * 600 + 400); T.registry.dupCheck(msg(40 + k, C))
            end
        end)
        local t = T.state.registry["node_9"]
        local ban = sent(T, proto.MSG.ATC_BAN, proto.CH_ATC)
        restore()
        assert_eq(ok, true, tostring(err))
        assert_eq(tostring(t.needsHands):find("^duplicate_id: node_9 heard at ") ~= nil, true,
            "NEEDS HANDS duplicate_id (" .. tostring(t.needsHands) .. ")")
        assert_eq(ban, 1, "and the ATC is told, once (" .. ban .. ")")
    end,

    ["a reboot starts the seq again, and is not a duplicate"] = function(assert_eq)
        local T, at, restore = server()
        for k = 0, 9 do at(k * 600); T.registry.dupCheck(msg(500 + k, A)) end
        for k = 0, 19 do at(8000 + k * 600); T.registry.dupCheck(msg(1 + k, A)) end   -- rebooted: from 1, the old stream stops
        local t = T.state.registry["node_9"]
        local park = sent(T, proto.MSG.PARK)
        restore()
        assert_eq(t.needsHands, nil, "no duplicate_id (" .. tostring(t.needsHands) .. ")")
        assert_eq(park, 0, "nobody told to park")
    end,

    ["one turtle's own stream is never a duplicate"] = function(assert_eq)
        local T, at, restore = server()
        for k = 0, 40 do at(k * 300); T.registry.dupCheck(msg(1 + k, k % 2 == 0 and A or B)) end
        local t = T.state.registry["node_9"]
        restore()
        assert_eq(t.needsHands, nil, "no duplicate_id (" .. tostring(t.needsHands) .. ")")
    end,
}
