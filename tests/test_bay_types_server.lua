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

-- pos / midJob: what the turtle reports (default: 158,67,-2806, which is no
-- dock any of these tests uses, and not mid-job).
local function register(T, id, role, pos, midJob)
    T.handlers[proto.MSG.REGISTER]({
        type = proto.MSG.REGISTER, from = id, to = "server",
        payload = { role = role, fuel = 100000, fuelMax = 100000,
                    position = pos or { x = 158, y = 67, z = -2806 }, midJob = midJob or false },
    })
end

-- The message types sent to id, in order.
local function sentTypes(T, id)
    local out = {}
    for _, s in ipairs(T.sent) do
        local ok, m = pcall(textutils.unserialise, s.body)
        if ok and type(m) == "table" and m.to == id then out[#out + 1] = m.type end
    end
    return out
end
local function countOf(list, v)
    local n = 0
    for _, x in ipairs(list) do if x == v then n = n + 1 end end
    return n
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

-- An idle heartbeat from id at pos, at time ms (os.epoch is the clock).
local function heartbeat(T, id, pos, ms)
    os.epoch = function() return ms end
    T.handlers[proto.MSG.HEARTBEAT]({ type = proto.MSG.HEARTBEAT, from = id, to = "server",
        payload = { status = proto.STATUS.IDLE, fuel = 100000, position = pos } })
end

-- A miner on DELIVERY[1], idle, moved by its REGISTER at t = 1,000,000 ms.
local function movedOnOldCell()
    local srv, T, W, restore = server('{ DELIVERY = { [ 1 ] = "node_118" } }')
    local old = W.docks.DELIVERY[1]
    local oldPos = { x = old.x, y = old.y, z = old.z }
    register(T, "node_118", proto.ROLE.MINER, oldPos, false)
    return srv, T, W, restore, old, oldPos
end

-- The waypoints module as it was before per-bay types (d4b2ae8), loaded from
-- git, on the same (stub) disk. It is the real old reader, not a copy of it.
local function oldWaypoints()
    local null = package.config:sub(1, 1) == "\\" and "NUL" or "/dev/null"
    local p = io.popen("git show d4b2ae8:waypoints.lua 2>" .. null, "r")
    local text = p and p:read("*a") or ""
    if p then p:close() end
    assert(#text > 1000, "could not read d4b2ae8:waypoints.lua with git")
    return assert(load(text, "=waypoints@d4b2ae8"))()
end

local function at(d) return d and (d.x .. "," .. d.z) or "none" end

return {
    -- FINAL REVIEW I2 (2026-11-11): a rollback past per-bay types must leave
    -- every turtle on its physical dock. The file used to carry the typed lists,
    -- so DELIVERY held bay 1 only and the old server called every miner dockless.
    ["old_server_reads_the_new_file_with_every_turtle_on_its_dock"] = function(assert_eq)
        local _, T, W, restore = server(nil)
        local want = {}
        for i = 1, 66 do   -- 64 fill the worker-side miner bays, 2 land on the support side
            local d = W.assignDock("MINER", "m" .. i); want["m" .. i] = d
        end
        want.d1 = W.assignDock("DELIVERY", "d1")
        want.s1 = W.assignDock("SUPPORT", "s1")
        local old = oldWaypoints()
        old.loadDockAssignments()
        local wrong, worker, support = "", 0, 0
        for id, d in pairs(want) do
            -- the old server looks for every worker-side turtle in DELIVERY and
            -- every support-side one in SUPPORT (the side lists of its day)
            local southSide = d.z < W.WHITE_Z
            local o = old.getDockFor(southSide and "DELIVERY" or "SUPPORT", id)
            if at(o) ~= at(d) then wrong = wrong .. id .. " " .. at(d) .. " -> " .. at(o) .. "; " end
            if southSide then worker = worker + 1 else support = support + 1 end
        end
        restore()
        assert_eq(worker, 65, "turtles checked on the worker side")
        assert_eq(support, 3, "turtles checked on the support side")
        assert_eq(wrong, "", "turtles the old server puts on another dock")
    end,

    ["a_file_an_old_server_rewrote_is_read_from_its_legacy_lists"] = function(assert_eq)
        local _, T, W, restore = server(nil)
        local m1 = W.assignDock("MINER", "m1")       -- worker bay 2
        local d1 = W.assignDock("DELIVERY", "d1")    -- worker bay 1
        -- roll back: the old server loads the file, moves m1 to bay 3, saves
        local old = oldWaypoints()
        old.loadDockAssignments()
        local moved = old.assignDockAt("DELIVERY", "m1", 3)
        -- roll forward: a fresh new server reads the same disk
        package.loaded["waypoints"] = nil
        local W2 = require("waypoints")
        local said = {}
        W2.loadDockAssignments(function(m) said[#said + 1] = m end, function(m) said[#said + 1] = m end)
        local m1b, d1b = W2.getDockFor("MINER", "m1"), W2.getDockFor("DELIVERY", "d1")
        local f = fs.open("dock_assignments.dat", "r"); local text = f.readAll(); f.close()
        restore()
        assert_eq(moved ~= nil and moved.bay, 3, "precondition: the old server moved m1 to bay 3")
        assert_eq(textutils.unserialise(text).byPos ~= nil, true, "precondition: the old server kept the stale byPos")
        assert_eq(at(m1b), at(moved), "the new server finds m1 where the old one put it, not in the stale byPos")
        assert_eq(at(m1b) ~= at(m1), true, "and not on its pre-rollback dock")
        assert_eq(at(d1b), at(d1), "d1 is untouched")
        assert_eq(#said >= 1 and said[1]:find("older server", 1, true) ~= nil, true, "the load says why: " .. tostring(said[1]))
    end,

    ["a_file_the_new_server_wrote_is_read_by_position"] = function(assert_eq)
        -- the legacy lists agree with byPos: byPos is used, nothing is said
        local _, T, W, restore = server(nil)
        local m1 = W.assignDock("MINER", "m1")
        package.loaded["waypoints"] = nil
        local W2 = require("waypoints")
        local said = 0
        W2.loadDockAssignments(function() said = said + 1 end, function() said = said + 1 end)
        local m1b = W2.getDockFor("MINER", "m1")
        restore()
        assert_eq(at(m1b), at(m1), "the miner keeps its dock")
        assert_eq(said, 0, "a file this server wrote loads silently")
    end,

    -- FINAL REVIEW I1 (2026-11-11): the old cell used to be released at the
    -- move. A lost REBOOT left the miner on a cell the server called free.
    ["lost_reboot_is_resent_and_the_old_cell_is_never_given_away"] = function(assert_eq)
        local _, T, W, restore, old, oldPos = movedOnOldCell()
        local first = countOf(sentTypes(T, "node_118"), proto.MSG.REBOOT)
        local delFree = W.freeDocks("DELIVERY")
        -- 16 delivery turtles arrive: none may be given the miner's old cell
        local ids = { "node_118" }
        for i = 1, 16 do register(T, "d" .. i, proto.ROLE.DELIVERY); ids[#ids + 1] = "d" .. i end
        local holders = holdersAt(W, old.x, old.z, ids)
        T.sent = {}
        heartbeat(T, "node_118", oldPos, 1000000 + 30000)   -- REBOOT lost: still there, 30 s on
        local at30 = countOf(sentTypes(T, "node_118"), proto.MSG.REBOOT)
        heartbeat(T, "node_118", oldPos, 1000000 + 61000)   -- 61 s on
        local at61 = countOf(sentTypes(T, "node_118"), proto.MSG.REBOOT)
        heartbeat(T, "node_118", oldPos, 1000000 + 90000)
        local at90 = countOf(sentTypes(T, "node_118"), proto.MSG.REBOOT)
        local stillHeld = W.getDockFor("DELIVERY", "node_118")
        restore()
        assert_eq(first, 1, "the first REBOOT goes with the move")
        assert_eq(delFree, 15, "the old cell is not free while the miner stands on it")
        assert_eq(#holders == 1 and holders[1], "node_118", "no delivery turtle is given the old cell")
        assert_eq(at30, 0, "no re-send inside 60 s")
        assert_eq(at61, 1, "the REBOOT is re-sent once 60 s have passed")
        assert_eq(at90, 1, "and not again for another 60 s")
        assert_eq(stillHeld, old, "the old cell stays reserved meanwhile")
    end,

    ["old_cell_is_released_once_the_turtle_is_seen_at_its_new_dock"] = function(assert_eq)
        local _, T, W, restore, old, oldPos = movedOnOldCell()
        local new = W.getDockFor("MINER", "node_118")
        -- the REBOOT worked: it boots and re-registers still on the old cell (it
        -- registers before it drives) -- no second REBOOT, the cell stays reserved
        T.sent = {}
        os.epoch = function() return 1000000 + 5000 end
        register(T, "node_118", proto.ROLE.MINER, oldPos, false)
        local onReRegister = countOf(sentTypes(T, "node_118"), proto.MSG.REBOOT)
        local heldAfterReReg = W.getDockFor("DELIVERY", "node_118")
        -- it drives home: heartbeats from its new dock
        heartbeat(T, "node_118", { x = new.x, y = new.y, z = new.z }, 1000000 + 40000)
        local released = W.getDockFor("DELIVERY", "node_118")
        local said = count(T, "Dock released: node_118 is off bay 1 row A (DELIVERY)")
        local delFree = W.freeDocks("DELIVERY")
        T.sent = {}
        heartbeat(T, "node_118", { x = new.x, y = new.y, z = new.z }, 1000000 + 400000)
        local later = countOf(sentTypes(T, "node_118"), proto.MSG.REBOOT)
        restore()
        assert_eq(onReRegister, 0, "a REGISTER from the old cell sends no REBOOT (no reboot loop)")
        assert_eq(heldAfterReReg, old, "the cell is still reserved after that REGISTER")
        assert_eq(released, nil, "seen at its new dock, the old cell is let go")
        assert_eq(said, 1, "and that is logged once")
        assert_eq(delFree, 16, "every DELIVERY dock is free again")
        assert_eq(later, 0, "nothing more is sent")
    end,

    ["registering_at_the_new_dock_releases_the_old_cell"] = function(assert_eq)
        local _, T, W, restore, old = movedOnOldCell()
        local new = W.getDockFor("MINER", "node_118")
        register(T, "node_118", proto.ROLE.MINER, { x = new.x, y = new.y, z = new.z }, false)
        local held = W.getDockFor("DELIVERY", "node_118")
        restore()
        assert_eq(held, nil, "a REGISTER from its new dock lets the old cell go")
    end,

    ["the_re_sends_are_bounded_then_the_cell_is_released_with_a_warn"] = function(assert_eq)
        local _, T, W, restore, old, oldPos = movedOnOldCell()
        T.sent = {}
        for i = 1, 20 do heartbeat(T, "node_118", oldPos, 1000000 + i * 61000) end
        local resent = countOf(sentTypes(T, "node_118"), proto.MSG.REBOOT)
        local warned = count(T, "node_118 never left bay 1 row A (DELIVERY)", "WARN")
        local held = W.getDockFor("DELIVERY", "node_118")
        local miner = W.getDockFor("MINER", "node_118")
        restore()
        assert_eq(resent, 5, "five re-sends after the first, no more")
        assert_eq(warned, 1, "one WARN says it never moved")
        assert_eq(held, nil, "the old record is let go")
        assert_eq(miner ~= nil, true, "it keeps its new MINER dock")
    end,

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
        local aKept = W.getDockFor("MINER", "a")
        restore()
        -- a fixed order (DELIVERY before MINER), so the same entry wins on every load
        assert_eq(aKept, d, "the DELIVERY entry, read first, keeps the dock")
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

    -- FIX ROUND 1 (review, 2026-11-10): a move changes the records, not the
    -- turtle. One that re-registers without rebooting, standing on the dock it
    -- just lost, must be rebooted so its boot homing drives it to the new one.
    ["moved_idle_miner_is_rebooted_once"] = function(assert_eq)
        local _, T, W, restore = server('{ DELIVERY = { [ 1 ] = "node_118" } }')
        local old = W.docks.DELIVERY[1]
        register(T, "node_118", proto.ROLE.MINER, { x = old.x, y = old.y, z = old.z }, false)
        local first = sentTypes(T, "node_118")
        local said = count(T, "Rebooting node_118 so it drives to its new dock")
        T.sent = {}
        register(T, "node_118", proto.ROLE.MINER, { x = old.x, y = old.y, z = old.z }, false)
        local second = sentTypes(T, "node_118")
        restore()
        assert_eq(countOf(first, proto.MSG.REBOOT), 1, "one REBOOT to the moved miner (" .. table.concat(first, " ") .. ")")
        assert_eq(first[1], proto.MSG.REGISTER_ACK, "the ACK goes first, so it reboots knowing its new dock")
        assert_eq(said, 1, "and the log says why")
        assert_eq(countOf(second, proto.MSG.REBOOT), 0, "a second register sends none (" .. table.concat(second, " ") .. ")")
    end,

    ["moved_midjob_miner_is_not_rebooted"] = function(assert_eq)
        local _, T, W, restore = server('{ DELIVERY = { [ 1 ] = "node_118" } }')
        local old = W.docks.DELIVERY[1]
        register(T, "node_118", proto.ROLE.MINER, { x = old.x, y = old.y, z = old.z }, true)
        local sent = sentTypes(T, "node_118")
        local moved = count(T, "Dock moved: node_118 ")
        restore()
        assert_eq(moved, 1, "precondition: it was moved")
        assert_eq(countOf(sent, proto.MSG.REBOOT), 0, "a mid-job turtle is not rebooted: it goes home to _self.dock, the new dock")
    end,

    ["moved_miner_away_from_its_old_dock_is_not_rebooted"] = function(assert_eq)
        -- e.g. booted out in the field: homeAfterBoot / its job handler bring it to the new dock
        local _, T, W, restore = server('{ DELIVERY = { [ 1 ] = "node_118" } }')
        register(T, "node_118", proto.ROLE.MINER, { x = 1500, y = 40, z = -2700 }, false)
        local sent = sentTypes(T, "node_118")
        restore()
        assert_eq(countOf(sent, proto.MSG.REBOOT), 0, "not standing on the old cell: no reboot")
    end,

    ["a_turtle_holding_two_docks_keeps_one"] = function(assert_eq)
        -- Minor 2: a file saved between a move's assign and its release reloads with both.
        local _, T, W, restore = server(nil)
        local mine = W.assignDock("MINER", "node_118")
        local del = W.assignDock("DELIVERY", "node_118")
        register(T, "node_118", proto.ROLE.MINER)
        local keeps = W.getDockFor("MINER", "node_118")
        local stillDel = W.getDockFor("DELIVERY", "node_118")
        local said = count(T, "Dock released: node_118 also held bay " .. del.bay .. " row " .. del.row .. " (DELIVERY)")
        T.sent = {}
        register(T, "node_118", proto.ROLE.MINER)
        local again = count(T, "Dock released:")
        restore()
        assert_eq(keeps, mine, "it keeps the dock of its own type")
        assert_eq(stillDel, nil, "the other is released")
        assert_eq(said, 1, "and that is logged")
        assert_eq(again, 1, "once")
    end,
}
