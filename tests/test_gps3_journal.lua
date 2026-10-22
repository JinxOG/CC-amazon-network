-- GPS 3, release A (rulings 2026-10-22): the fuel journal and the facing restored at boot.
--
-- Every physical move and turn writes its intent to journal.dat first. After a
-- reboot WITH a GPS fix, a journal that agrees with the fix gives the facing
-- back, so the turtle does not step out and back to measure it. "No move
-- without GPS" is unchanged: without a fix nothing is restored and the boot
-- guard waits as before. A restored facing is provisional until the first
-- horizontal step agrees with GPS -- the journal cannot tell a crash from a
-- turtle picked up and put back in the same block, turned (node_182, 10-06).
--
-- A "reboot" here is a reload of turtle_base over the same stub disk: the
-- module's memory is gone, journal.dat is not.
local stub = require("tests.stub_cc")

sleep = function() end
os.epoch = os.epoch or function() return os.time() * 1000 end

local JOURNAL, TMP = "journal.dat", "journal.tmp"

local function load()
    package.loaded["turtle_base"] = nil
    package.loaded["geofence"]    = nil
    return require("turtle_base")
end

local function world(pos, facing, extra)
    local opts = extra or {}
    opts.pos = { x = pos[1], y = pos[2], z = pos[3], facing = facing }
    local c = stub.install(opts)
    gps = { locate = function() return c.pos.x, c.pos.y, c.pos.z end }
    return c
end

-- A turtle that booted with GPS and measured its facing, then did some work.
local function working(pos, facing, extra)
    local c = world(pos, facing, extra)
    local base = load()
    base.initPositionForTest()
    return base, c
end

-- Counts physical horizontal steps from now on. turtle_base resolves turtle[dir]
-- at call time, so wrapping after the load is seen.
local function countSteps()
    local n = 0
    for _, d in ipairs({ "forward", "back" }) do
        local raw = turtle[d]
        turtle[d] = function(...) n = n + 1; return raw(...) end
    end
    return function() return n end
end

-- After the LAST load in a test (logship wraps print at load; see the memory
-- note "Logship swallows test output").
local function captureLog()
    local lines, prev = {}, print
    print = function(s) lines[#lines + 1] = tostring(s) end
    return function(needle)
        for _, l in ipairs(lines) do if l:find(needle, 1, true) then return true end end
        return false
    end, function() print = prev end
end

local function readJournal()
    local h = fs.open(JOURNAL, "r")
    if not h then return nil end
    local s = h.readAll(); h.close()
    return textutils.unserialise(s)
end

local function writeFile(path, s)
    local h = fs.open(path, "w"); h.write(s); h.close()
end

local function at(c) return c.pos.x .. "," .. c.pos.y .. "," .. c.pos.z end
local function pos(base) local p = base.getPos(); return p.x .. "," .. p.y .. "," .. p.z end

-- Crash in the middle of a raw call: `after` true means the move had happened.
local function crashDuring(dir, after, c, fuelDrop)
    local raw = turtle[dir]
    turtle[dir] = function()
        if after then raw(); c.fuel = c.fuel - (fuelDrop or 1) end
        error("power cut", 0)
    end
    return function() turtle[dir] = raw end
end

return {
    -- ── Restore ─────────────────────────────────────────────────────────────

    ["a reboot with GPS up takes the facing from the journal and takes no step to measure it"] =
    function(assert_eq)
        local base, c = working({ 10, 70, 10 }, 1)
        base.move.forward(); base.move.forward(); base.move.turnRight()
        local b2 = load()
        local steps = countSteps()
        b2.initPositionForTest()
        assert_eq(steps(), 0, "no step out and back")
        assert_eq(b2.hasPositionFix(), true)
        assert_eq(b2.getFacing(), c.pos.facing, "the facing it really has (south)")
        b2.move.forward()
        assert_eq(pos(b2), at(c), "and the next step goes where it thinks")
    end,

    ["without a journal it measures facing as before (the control)"] =
    function(assert_eq)
        local _, c = working({ 10, 70, 10 }, 1)
        fs.delete(JOURNAL); fs.delete(TMP)
        local b2 = load()
        local steps = countSteps()
        b2.initPositionForTest()
        assert_eq(steps(), 2, "out and back")
        assert_eq(b2.hasPositionFix(), true)
        assert_eq(b2.getFacing(), c.pos.facing)
    end,

    ["a journal more than 1 block from GPS is logged loudly and the facing is measured"] =
    function(assert_eq)
        local base, c = working({ 10, 70, 10 }, 1)
        base.move.forward()
        c.pos.x = c.pos.x + 5                               -- moved by hand
        local b2 = load()
        local said, restore = captureLog()
        local steps = countSteps()
        b2.initPositionForTest()
        restore()
        assert_eq(said("JOURNAL DISAGREES WITH GPS by 5"), true)
        assert_eq(steps(), 2, "measured, not restored")
        assert_eq(pos(b2), at(c))
    end,

    ["exactly 1 block from GPS measures the facing without the loud line"] =
    function(assert_eq)
        local base, c = working({ 10, 70, 10 }, 1)
        base.move.forward()
        c.pos.y = c.pos.y + 1
        local b2 = load()
        local said, restore = captureLog()
        local steps = countSteps()
        b2.initPositionForTest()
        restore()
        assert_eq(said("JOURNAL DISAGREES"), false)
        assert_eq(said("Journal: 1 block from GPS"), true)
        assert_eq(steps(), 2)
    end,

    ["a crash after a move landed (fuel one lower) restores the moved position"] =
    function(assert_eq)
        local base, c = working({ 10, 70, 10 }, 2)
        local undo = crashDuring("forward", true, c)
        pcall(base.move.forward)
        undo()
        local b2 = load()
        local said, restore = captureLog()
        local steps = countSteps()
        b2.initPositionForTest()
        restore()
        assert_eq(steps(), 0)
        assert_eq(said("agrees with GPS"), true)
        assert_eq(pos(b2), "10,70,11")
    end,

    ["a crash before the move (fuel unchanged) restores the old position"] =
    function(assert_eq)
        local base, c = working({ 10, 70, 10 }, 2)
        local undo = crashDuring("forward", false, c)
        pcall(base.move.forward)
        undo()
        local b2 = load()
        local steps = countSteps()
        b2.initPositionForTest()
        assert_eq(steps(), 0)
        assert_eq(pos(b2), "10,70,10")
    end,

    ["a refuel after the crash (fuel higher) still means the move did not happen"] =
    function(assert_eq)
        local base, c = working({ 10, 70, 10 }, 2)
        local undo = crashDuring("forward", false, c)
        pcall(base.move.forward)
        undo()
        c.fuel = c.fuel + 800
        local b2 = load()
        local steps = countSteps()
        b2.initPositionForTest()
        assert_eq(steps(), 0)
        assert_eq(pos(b2), "10,70,10")
    end,

    ["an impossible fuel drop (two for one move) restores nothing"] =
    function(assert_eq)
        local base, c = working({ 10, 70, 10 }, 2)
        local undo = crashDuring("forward", true, c, 2)
        pcall(base.move.forward)
        undo()
        local b2 = load()
        local steps = countSteps()
        b2.initPositionForTest()
        assert_eq(steps(), 2, "measured")
        assert_eq(b2.getFacing(), c.pos.facing)
    end,

    ["unlimited fuel cannot settle a pending move, so nothing is restored"] =
    function(assert_eq)
        local base, c = working({ 10, 70, 10 }, 2)
        local undo = crashDuring("forward", true, c)
        pcall(base.move.forward)
        undo()
        c.fuel = "unlimited"
        local b2 = load()
        local steps = countSteps()
        b2.initPositionForTest()
        assert_eq(steps(), 2)
    end,

    ["a crash mid-turn leaves the facing unknown: measured, never guessed"] =
    function(assert_eq)
        local base, c = working({ 10, 70, 10 }, 0)
        local undo = crashDuring("turnRight", true, c, 0)
        pcall(base.move.turnRight)
        undo()
        local b2 = load()
        local steps = countSteps()
        b2.initPositionForTest()
        assert_eq(steps(), 2, "measured")
        assert_eq(b2.getFacing(), c.pos.facing)
    end,

    ["a crash during facing detection restores nothing (the facing was unknown)"] =
    function(assert_eq)
        local b1, c = working({ 10, 70, 10 }, 1)          -- known, then re-measured
        local undo = crashDuring("forward", true, c)
        pcall(b1.detectFacingForTest)
        undo()
        local b2 = load()
        local steps = countSteps()
        b2.initPositionForTest()
        assert_eq(steps(), 2)
        assert_eq(b2.getFacing(), c.pos.facing)
    end,

    ["a journal written without a GPS fix restores nothing"] =
    function(assert_eq)
        local base, c = working({ 10, 70, 10 }, 1)
        base.move.forward()
        local j = readJournal(); j.posFixed = false
        writeFile(JOURNAL, textutils.serialise(j))
        local b2 = load()
        local steps = countSteps()
        b2.initPositionForTest()
        assert_eq(steps(), 2)
    end,

    ["no GPS at boot: nothing restored, no fix, no step -- the boot guard waits as today"] =
    function(assert_eq)
        local base, c = working({ 10, 70, 10 }, 1)
        base.move.forward()
        gps = { locate = function() return nil end }
        local b2 = load()
        local steps = countSteps()
        b2.initPositionForTest()
        assert_eq(steps(), 0)
        assert_eq(b2.hasPositionFix(), false, "a journal is never a fix")
    end,

    ["GPS back after a no-fix boot: the wait restores the facing instead of measuring"] =
    function(assert_eq)
        local base, c = working({ 10, 70, 10 }, 1)
        base.move.forward()
        local real = gps.locate
        gps = { locate = function() return nil end }
        local b2 = load()
        b2.initPositionForTest()
        gps = { locate = real }
        local steps = countSteps()
        b2.waitForPositionFix("test")
        assert_eq(steps(), 0)
        assert_eq(b2.hasPositionFix(), true)
        assert_eq(b2.getFacing(), c.pos.facing)
    end,

    ["a turn made before GPS came back makes the boot journal stale: measured, not restored"] =
    function(assert_eq)
        local base, c = working({ 10, 70, 10 }, 1)
        base.move.forward()
        local real = gps.locate
        gps = { locate = function() return nil end }
        local b2 = load()
        b2.initPositionForTest()
        b2.move.turnRight()                                 -- as base.init's move.face does
        gps = { locate = real }
        local steps = countSteps()
        b2.waitForPositionFix("test")
        assert_eq(steps(), 2, "measured")
        assert_eq(b2.getFacing(), c.pos.facing, "the facing it really has after the turn")
    end,

    -- ── The file ────────────────────────────────────────────────────────────

    ["an unreadable journal is no journal"] =
    function(assert_eq)
        local _, c = working({ 10, 70, 10 }, 1)
        writeFile(JOURNAL, "{ x = 10, y = ")
        local b2 = load()
        local steps = countSteps()
        local ok = pcall(b2.initPositionForTest)
        assert_eq(ok, true)
        assert_eq(steps(), 2)
        assert_eq(b2.getFacing(), c.pos.facing)
    end,

    ["a well-formed table with a missing field is no journal"] =
    function(assert_eq)
        local base, c = working({ 10, 70, 10 }, 1)
        base.move.forward()
        local j = readJournal(); j.facing = nil
        writeFile(JOURNAL, textutils.serialise(j))
        local b2 = load()
        local steps = countSteps()
        b2.initPositionForTest()
        assert_eq(steps(), 2)
    end,

    ["a partial temp file (crash during the write) loses to the journal"] =
    function(assert_eq)
        local base, c = working({ 10, 70, 10 }, 1)
        base.move.forward()
        writeFile(TMP, "{ x = 99, y = ")
        local b2 = load()
        local steps = countSteps()
        b2.initPositionForTest()
        assert_eq(steps(), 0, "the journal itself is exact")
        assert_eq(pos(b2), at(c))
    end,

    ["a complete temp file with no journal (crash between delete and move) is used"] =
    function(assert_eq)
        local base, c = working({ 10, 70, 10 }, 1)
        base.move.forward()
        local h = fs.open(JOURNAL, "r"); local s = h.readAll(); h.close()
        fs.delete(JOURNAL); writeFile(TMP, s)
        local b2 = load()
        local steps = countSteps()
        b2.initPositionForTest()
        assert_eq(steps(), 0)
        assert_eq(pos(b2), at(c))
    end,

    ["a journal that cannot be written never stops a move"] =
    function(assert_eq)
        local base, c = working({ 10, 70, 10 }, 1)
        local open = fs.open
        fs.open = function(p, m)
            if m == "w" then error("Out of space", 0) end
            return open(p, m)
        end
        local ok, moved = pcall(base.move.forward)
        fs.open = open
        assert_eq(ok, true)
        assert_eq(moved, true)
        assert_eq(pos(base), at(c))
    end,

    -- ── Writes ──────────────────────────────────────────────────────────────

    ["the intent is on disk before the turtle moves"] =
    function(assert_eq)
        local base, c = working({ 10, 70, 10 }, 1)
        local seen
        local raw = turtle.forward
        turtle.forward = function()
            local j = readJournal()
            seen = j and (j.pending .. "@" .. j.x .. "," .. j.y .. "," .. j.z .. " fuel " .. j.fuel)
            return raw()
        end
        base.move.forward()
        turtle.forward = raw
        assert_eq(seen, "forward@10,70,10 fuel " .. c.fuel)
    end,

    ["after a move the journal is settled at the new position"] =
    function(assert_eq)
        local base = working({ 10, 70, 10 }, 1)
        base.move.forward(); base.move.up()
        local j = readJournal()
        assert_eq(j.pending, nil)
        assert_eq(j.x .. "," .. j.y .. "," .. j.z, "11,71,10")
        assert_eq(j.facingKnown and j.posFixed, true)
    end,

    ["after a turn the journal holds the new facing"] =
    function(assert_eq)
        local base = working({ 10, 70, 10 }, 1)
        base.move.turnLeft()
        local j = readJournal()
        assert_eq(j.pending, nil)
        assert_eq(j.facing, 0)
    end,

    ["a blocked move settles the journal where the turtle still is"] =
    function(assert_eq)
        -- Facing east; the block behind is stone, and back never digs.
        local base = working({ 10, 70, 10 }, 1, { world = { ["9,70,10"] = "minecraft:stone" } })
        local ok = base.move.back()
        local j = readJournal()
        assert_eq(ok, false)
        assert_eq(j.pending, nil)
        assert_eq(j.x, 10)
    end,

    ["facing detection marks the facing unknown before its first step"] =
    function(assert_eq)
        -- From a KNOWN facing: a fresh boot is unknown already and proves nothing.
        local b1 = working({ 10, 70, 10 }, 1)
        assert_eq(b1.hasPositionFix(), true, "known before the re-measure")
        local known
        local raw = turtle.forward
        turtle.forward = function()
            local j = readJournal()
            if known == nil then known = j and j.facingKnown end
            return raw()
        end
        b1.detectFacingForTest()
        turtle.forward = raw
        assert_eq(known, false)
    end,

    -- ── First step ──────────────────────────────────────────────────────────

    ["put back in the same block, turned: the first step finds out and corrects"] =
    function(assert_eq)
        local base, c = working({ 10, 70, 10 }, 1)
        base.move.forward()
        c.pos.facing = 3                                    -- picked up, put back facing west
        local b2 = load()
        local said, restore = captureLog()
        b2.initPositionForTest()
        local restoredFacing = b2.getFacing()
        b2.move.forward()
        local afterFirst = pos(b2)
        b2.move.forward()
        restore()
        assert_eq(restoredFacing, 1, "the journal's facing (it cannot know)")
        assert_eq(said("RESTORED FACING WAS WRONG"), true)
        assert_eq(afterFirst, "10,70,10", "one block west of 11,70,10: corrected to GPS")
        assert_eq(b2.getFacing(), 3)
        assert_eq(pos(b2), at(c), "the second step goes where it thinks")
    end,

    ["a restored facing that agrees costs one GPS call on the first step, none after"] =
    function(assert_eq)
        local base, c = working({ 10, 70, 10 }, 1)
        base.move.forward()
        local b2 = load()
        b2.initPositionForTest()
        local calls = 0
        local real = gps.locate
        gps.locate = function(...) calls = calls + 1; return real(...) end
        b2.move.up()                                        -- vertical: says nothing about facing
        local afterUp = calls
        b2.move.forward(); b2.move.forward()
        assert_eq(afterUp, 0)
        assert_eq(calls, 1)
        assert_eq(pos(b2), at(c))
    end,

    ["no GPS on the first step: the facing becomes unknown and the guard holds"] =
    function(assert_eq)
        local base, c = working({ 10, 70, 10 }, 1)
        base.move.forward()
        local b2 = load()
        b2.initPositionForTest()
        gps.locate = function() return nil end
        b2.move.forward()
        assert_eq(b2.hasPositionFix(), false)
    end,

    -- ── Source pin: every fleet file ────────────────────────────────────────

    ["no raw turtle move or turn outside jMove and jTurn, in any fleet file"] =
    function(assert_eq)
        local RAW = "turtle%s*%.%s*(%a+)"
        local MOVES = { forward = 1, back = 1, up = 1, down = 1, turnLeft = 1, turnRight = 1 }
        local function offenders(src)
            -- The two wrappers are the only bodies allowed a raw call.
            src = src:gsub("\nlocal function jMove%(.-\nend\n", "\n")
                     :gsub("\nlocal function jTurn%(.-\nend\n", "\n")
            local found = {}
            for line in (src .. "\n"):gmatch("(.-)\n") do
                local code = line:gsub("%-%-.*$", "")
                for name in code:gmatch(RAW) do
                    if MOVES[name] then found[#found + 1] = line end
                end
                if code:find("turtle%s*%[") then found[#found + 1] = line end
            end
            return found
        end
        -- Self-test: the pin must be able to fail.
        assert_eq(#offenders("\nlocal x = turtle.forward()\n"), 1)
        assert_eq(#offenders("\nlocal m = isUp and turtle.up or turtle.down\n"), 2)
        assert_eq(#offenders("\nlocal ok = turtle[dir]()\n"), 1)
        assert_eq(#offenders("\n-- turtle.forward() in a comment\n"), 0)

        -- Every file the updater ships to any machine: that IS the fleet.
        local f = assert(io.open("updater.lua", "r")); local manifest = f:read("a"); f:close()
        local names, seen = {}, {}
        for n in manifest:gmatch('"([%w_]+%.lua)"') do
            if not seen[n] then seen[n] = true; names[#names + 1] = n end
        end
        local checked, bad = {}, {}
        for _, n in ipairs(names) do
            local h = io.open(n, "r")
            if h then
                local src = h:read("a"); h:close()
                checked[n] = true
                for _, l in ipairs(offenders(src)) do bad[#bad + 1] = n .. ": " .. l end
            end
        end
        for _, must in ipairs({ "turtle_base.lua", "ore_turtle.lua", "delivery_turtle.lua",
                                "support_turtle.lua", "loader_turtle.lua", "mine_flow.lua" }) do
            assert_eq(checked[must], true, must .. " is in the manifest and was read")
        end
        assert_eq(table.concat(bad, "\n"), "")
    end,
}
