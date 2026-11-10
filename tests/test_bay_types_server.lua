-- Bay types, the server half (shakeout stress test, Task 2): the server picks a
-- dock of the turtle's own type, and moves a turtle it finds on a dock of the
-- wrong type -- a live miner on a DELIVERY dock, say -- exactly once.
-- docs/superpowers/specs/2026-11-09-shakeout-stress-test-design.md section 4.
--
-- It also pins what an OLD dock_assignments.dat means. Before per-bay types the
-- file said DELIVERY[i] = the i-th dock of the worker side and SUPPORT[i] = the
-- i-th dock of the support side. Those indices now name other docks (DELIVERY
-- holds only worker bay 1), so read naively a turtle in worker bay 2 would point
-- at no dock at all. Every entry must still name the dock it named before.
--
-- Run: lua tests/run.lua tests.test_bay_types_server
package.path = "./?.lua;" .. package.path

local stub  = require("tests.stub_cc")
local proto = require("protocol")

-- A server with nothing registered, a recording modem, and (optionally) a
-- dock_assignments.dat on disk that the server reads exactly as server.run does.
local function server(fileText)
    stub.install({})
    local savedEpoch = os.epoch
    os.epoch = function() return 1000000 end
    _G.__CC_SERVER_TEST = true
    package.loaded["central_server"] = nil
    package.loaded["waypoints"]      = nil
    local srv = require("central_server")
    local T = srv._test
    T.sent = {}
    T.state.modem = {
        isOpen   = function() return true end,
        open     = function() end,
        transmit = function(ch, reply, body) T.sent[#T.sent + 1] = { channel = ch, body = body } end,
    }
    local W = package.loaded["waypoints"]
    if fileText then
        local f = fs.open("dock_assignments.dat", "w"); f.write(fileText); f.close()
    end
    -- T.loadDocks is what server.run calls (with the server's loggers); fall back
    -- to the bare loader so this file fails on assertions, not on the seam, on older code.
    if T.loadDocks then T.loadDocks() else W.loadDockAssignments() end
    local restore = function()
        os.epoch = savedEpoch
        _G.__CC_SERVER_TEST = nil
        package.loaded["central_server"] = nil
    end
    return srv, T, W, restore
end

local function register(T, id, role)
    T.handlers[proto.MSG.REGISTER]({
        type = proto.MSG.REGISTER, from = id, to = "server",
        payload = { role = role, fuel = 100000, fuelMax = 100000,
                    position = { x = 158, y = 67, z = -2806 }, midJob = false },
    })
end

local function count(T, needle, level)
    local n = 0
    for _, e in ipairs(T.state.log) do
        if e.msg:find(needle, 1, true) and (not level or e.level == level) then n = n + 1 end
    end
    return n
end

-- The dock the last REGISTER_ACK to this id carried.
local function ackDock(T, id)
    local dock
    for _, s in ipairs(T.sent) do
        local ok, m = pcall(textutils.unserialise, s.body)
        if ok and type(m) == "table" and m.type == proto.MSG.REGISTER_ACK and m.to == id then
            dock = m.payload and m.payload.dock
        end
    end
    return dock
end

-- Who holds the dock at x,z, across all three types. Two names = double-booked.
local function holdersAt(W, x, z, ids)
    local out = {}
    for _, id in ipairs(ids) do
        for _, t in ipairs({ "DELIVERY", "SUPPORT", "MINER" }) do
            local d = W.getDockFor(t, id)
            if d and d.x == x and d.z == z then out[#out + 1] = id end
        end
    end
    return out
end

return {
    ["misplaced_miner_moves_once"] = function(assert_eq)
        -- The live fleet today: a miner in worker bay 1, which is now a DELIVERY bay.
        local _, T, W, restore = server('{ DELIVERY = { [ 1 ] = "node_118" } }')
        local old = W.docks.DELIVERY[1]
        assert_eq(W.getDockFor("DELIVERY", "node_118"), old, "precondition: the miner holds a DELIVERY dock")

        register(T, "node_118", proto.ROLE.MINER)
        local d = W.getDockFor("MINER", "node_118")
        local ack = ackDock(T, "node_118")
        local moved = count(T, "Dock moved: node_118 from bay 1 row A (DELIVERY) to bay "
            .. (d and d.bay or "?") .. " row " .. (d and d.row or "?") .. " (MINER) -- per-bay types")
        local delFree = W.freeDocks("DELIVERY")
        local delHeld = W.getDockFor("DELIVERY", "node_118")
        local regDock = T.state.registry["node_118"].dock

        T.sent = {}
        register(T, "node_118", proto.ROLE.MINER)
        local movedAgain = count(T, "Dock moved:")
        local d2 = W.getDockFor("MINER", "node_118")
        restore()

        assert_eq(d ~= nil and d.role, "MINER", "the miner holds a MINER dock")
        assert_eq(regDock, d, "the registry records the new dock")
        assert_eq(ack ~= nil and ack.x == d.x and ack.z == d.z, true, "REGISTER_ACK tells the turtle its new dock")
        assert_eq(delHeld, nil, "it no longer holds the DELIVERY dock")
        assert_eq(delFree, 16, "the DELIVERY dock is free")
        assert_eq(moved, 1, "the move is logged exactly once")
        assert_eq(movedAgain, 1, "a second register moves nothing and logs nothing")
        assert_eq(d2, d, "and keeps the same MINER dock")
    end,

    ["no_free_miner_dock_keeps_old"] = function(assert_eq)
        local _, T, W, restore = server('{ DELIVERY = { [ 1 ] = "node_118" } }')
        for i = 1, W.totalDocks("MINER") do W.assignDock("MINER", "filler_" .. i) end
        assert_eq(W.freeDocks("MINER"), 0, "precondition: every MINER dock is full")

        register(T, "node_118", proto.ROLE.MINER)
        local held = W.getDockFor("DELIVERY", "node_118")
        local regDock = T.state.registry["node_118"].dock
        local ack = ackDock(T, "node_118")
        local warned = count(T, "node_118", "WARN")
        local moved = count(T, "Dock moved:")
        restore()

        assert_eq(held, W.docks.DELIVERY[1], "it keeps its old dock")
        assert_eq(regDock, held, "the registry has it on that dock, not dockless")
        assert_eq(ack ~= nil and ack.x == held.x and ack.z == held.z, true, "and the ACK still names a dock")
        assert_eq(warned >= 1, true, "a WARN says it could not be moved")
        assert_eq(moved, 0, "no move is claimed")
    end,

    ["miner_gets_a_miner_dock"] = function(assert_eq)
        -- Gap 1: every non-SUPPORT role used to be sent to DELIVERY. There are 16
        -- of those now, so the 17th miner would have had no dock at all.
        local _, T, W, restore = server(nil)
        for i = 1, 20 do register(T, "m" .. i, proto.ROLE.MINER) end
        register(T, "d1", proto.ROLE.DELIVERY)
        register(T, "s1", proto.ROLE.SUPPORT)
        local miners, dockless = 0, 0
        for i = 1, 20 do
            local d = T.state.registry["m" .. i].dock
            if d == nil then dockless = dockless + 1 elseif d.role == "MINER" then miners = miners + 1 end
        end
        local dd, sd = T.state.registry["d1"].dock, T.state.registry["s1"].dock
        restore()
        assert_eq(miners, 20, "every miner holds a MINER dock")
        assert_eq(dockless, 0, "no miner is dockless")
        assert_eq(dd and dd.role, "DELIVERY", "delivery holds a DELIVERY dock")
        assert_eq(sd and sd.role, "SUPPORT", "support holds a SUPPORT dock")
    end,

    ["loader_has_no_dock_and_does_not_error"] = function(assert_eq)
        local _, T, W, restore = server(nil)
        local ok, err = pcall(register, T, "loader_1", proto.ROLE.LOADER)
        local d = T.state.registry["loader_1"] and T.state.registry["loader_1"].dock
        local okAt, errAt = pcall(W.assignDockAt, nil, "loader_1", 2)
        restore()
        assert_eq(ok, true, "register LOADER: " .. tostring(err))
        assert_eq(d, nil, "a loader holds no dock")
        assert_eq(okAt, true, "assignDockAt with no dock type: " .. tostring(errAt))
    end,

    ["old_file_keeps_every_physical_dock"] = function(assert_eq)
        -- A file written before per-bay types. Worker-side index 20 is bay 2's
        -- 4th dock (dx -3, row B): x 171-3 = 168, z -2810. Support-side index 17
        -- is support bay 2's first dock (dx -4, row A): x 167, z -2797.
        local _, T, W, restore = server(
            '{ DELIVERY = { [ 1 ] = "node_96", [ 20 ] = "node_118" },'
            .. ' SUPPORT = { [ 1 ] = "node_104", [ 17 ] = "node_105" } }')
        local d96, m118 = W.getDockFor("DELIVERY", "node_96"), W.getDockFor("MINER", "node_118")
        local s104, m105 = W.getDockFor("SUPPORT", "node_104"), W.getDockFor("MINER", "node_105")
        local freeM = W.freeDocks("MINER")
        restore()
        assert_eq(d96 and (d96.x .. "," .. d96.z), "153,-2806", "worker index 1 is still bay 1's first dock")
        assert_eq(m118 and (m118.x .. "," .. m118.z), "168,-2810", "worker index 20 is the same physical dock")
        assert_eq(s104 and (s104.x .. "," .. s104.z), "153,-2797", "support index 1 is still support bay 1's first dock")
        assert_eq(m105 and (m105.x .. "," .. m105.z), "167,-2797", "support index 17 is the same physical dock")
        assert_eq(freeM, 126, "both now-MINER docks are counted as taken")
    end,

    ["misplaced_support_moves_off_a_miner_dock"] = function(assert_eq)
        -- Support bay 2 is a MINER bay now; a SUPPORT turtle there moves to a SUPPORT dock.
        local _, T, W, restore = server('{ SUPPORT = { [ 17 ] = "node_105" } }')
        register(T, "node_105", proto.ROLE.SUPPORT)
        local d = W.getDockFor("SUPPORT", "node_105")
        local stillMiner = W.getDockFor("MINER", "node_105")
        local moved = count(T, "Dock moved: node_105 from bay 2 row A (MINER) to bay 1 row A (SUPPORT) -- per-bay types")
        restore()
        assert_eq(d and d.role, "SUPPORT", "it holds a SUPPORT dock")
        assert_eq(stillMiner, nil, "the MINER dock is released")
        assert_eq(moved, 1, "the move is logged once")
    end,

    ["new_file_round_trips_by_position"] = function(assert_eq)
        local _, T, W, restore = server(nil)
        register(T, "m1", proto.ROLE.MINER)
        register(T, "d1", proto.ROLE.DELIVERY)
        local m1, d1 = W.getDockFor("MINER", "m1"), W.getDockFor("DELIVERY", "d1")
        local f = fs.open("dock_assignments.dat", "r"); local text = f.readAll(); f.close()
        -- a fresh server on the same disk (the stub fs survives: only the modules are reloaded)
        package.loaded["waypoints"] = nil
        local W2 = require("waypoints")
        W2.loadDockAssignments()
        local m1b, d1b = W2.getDockFor("MINER", "m1"), W2.getDockFor("DELIVERY", "d1")
        restore()
        local data = textutils.unserialise(text)
        assert_eq(type(data) == "table" and type(data.byPos), "table", "the file records docks by position")
        assert_eq(m1b and (m1b.x .. "," .. m1b.z), m1.x .. "," .. m1.z, "the miner's dock survives a restart")
        assert_eq(d1b and (d1b.x .. "," .. d1b.z), d1.x .. "," .. d1.z, "the delivery dock survives a restart")
    end,

    ["a_clash_on_load_never_double_books"] = function(assert_eq)
        -- Worker-side index 17 (an old-style DELIVERY entry) and MINER index 1 are
        -- the same physical dock: worker bay 2's first. Only one may hold it.
        local _, T, W, restore = server('{ DELIVERY = { [ 17 ] = "a" }, MINER = { [ 1 ] = "b" } }')
        local d = W.docks.MINER[1]
        local before = #holdersAt(W, d.x, d.z, { "a", "b" })
        register(T, "a", proto.ROLE.MINER)
        register(T, "b", proto.ROLE.MINER)
        local after = #holdersAt(W, d.x, d.z, { "a", "b" })
        local da, db = T.state.registry["a"].dock, T.state.registry["b"].dock
        local warned = count(T, "dock_assignments.dat", "WARN")
        restore()
        assert_eq(before, 1, "one holder on load")
        assert_eq(after, 1, "one holder after both register")
        assert_eq(da ~= nil and db ~= nil, true, "neither is dockless")
        assert_eq(da ~= db, true, "they hold different docks")
        assert_eq(warned, 1, "the clash is said")
    end,

    ["lost_miner_dock_is_released"] = function(assert_eq)
        -- Gap 2: releaseLostTurtle searched only DELIVERY and SUPPORT.
        local srv, T, W, restore = server(nil)
        W.assignDock("MINER", "node_lost")
        local ok = srv.releaseLostTurtle("node_lost")
        local after = W.getDockFor("MINER", "node_lost")
        restore()
        assert_eq(ok, true, "it reports a dock released")
        assert_eq(after, nil, "the MINER dock is free")
    end,

    ["reassign_to_a_full_bay_keeps_the_old_dock"] = function(assert_eq)
        -- assignDockAt released first and searched second, so asking for a bay
        -- with no free slot left the turtle holding nothing.
        local _, T, W, restore = server(nil)
        local d = W.assignDock("MINER", "m1")
        local none = W.assignDockAt("MINER", "m1", 99)
        local still = W.getDockFor("MINER", "m1")
        local moved = W.assignDockAt("MINER", "m1", 3)
        local now = W.getDockFor("MINER", "m1")
        local free = W.freeDocks("MINER")
        restore()
        assert_eq(none, nil, "no bay 99")
        assert_eq(still, d, "the old dock is kept")
        assert_eq(moved ~= nil and moved.bay, 3, "a bay with room moves it")
        assert_eq(now, moved, "and it holds the new one")
        assert_eq(free, W.totalDocks("MINER") - 1, "exactly one dock held")
    end,
}
