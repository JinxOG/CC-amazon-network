-- GPS 3, release A (rulings 2026-10-22, revised after the sandbox): the fuel journal, checked at boot.
--
-- Every physical move and turn writes its intent to journal.dat first. At boot
-- the turtle measures its facing exactly as before, then CHECKS the journal
-- against GPS and that measurement and logs one line. The journal never changes
-- what the turtle uses: it cannot tell a crash from a turtle picked up and put
-- back in the same block, turned (sandbox w3_gps3_journal_restore, 2026-10-22:
-- trusting it left a loader behind and parked a miner with no modem).
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


-- Reboot over the same disk: the new module, its log, and a step counter.
local function reboot()
    local b2 = load()
    local said, restore = captureLog()
    local steps = countSteps()
    -- A boot that raises must hand print back first, or the runner's FAIL line
    -- is swallowed by the capture and the test reads as green.
    local ok, err = pcall(b2.initPositionForTest)
    if not ok then restore(); error(err, 0) end
    return b2, said, restore, steps
end

return {
    -- ── The boot check ──────────────────────────────────────────────────────

    ["a reboot with GPS up still measures facing, and the journal agrees"] =
    function(assert_eq)
        local base, c = working({ 10, 70, 10 }, 1)
        base.move.forward(); base.move.forward(); base.move.turnRight()
        local b2, said, restore, steps = reboot()
        restore()
        assert_eq(steps(), 2, "measured as before: out and back")
        assert_eq(said("Journal: agrees with GPS at 12,70,10, facing south"), true)
        assert_eq(b2.getFacing(), c.pos.facing)
    end,

    ["without a journal: measured, and nothing to check"] =
    function(assert_eq)
        local _, c = working({ 10, 70, 10 }, 1)
        fs.delete(JOURNAL); fs.delete(TMP)
        local b2, said, restore, steps = reboot()
        restore()
        assert_eq(steps(), 2)
        assert_eq(said("Journal: nothing to check (no readable journal)"), true)
        assert_eq(b2.getFacing(), c.pos.facing)
    end,

    ["a journal more than 1 block from GPS is logged loudly"] =
    function(assert_eq)
        local base, c = working({ 10, 70, 10 }, 1)
        base.move.forward()
        c.pos.x = c.pos.x + 5                               -- moved by hand
        local b2, said, restore = reboot()
        restore()
        assert_eq(said("JOURNAL DISAGREES WITH GPS by 5"), true)
        assert_eq(said("Journal: agrees"), false)
        assert_eq(pos(b2), at(c), "GPS is what it uses")
    end,

    ["exactly 1 block from GPS is a warning, not the loud line"] =
    function(assert_eq)
        local base, c = working({ 10, 70, 10 }, 1)
        base.move.forward()
        c.pos.y = c.pos.y + 1
        local _, said, restore = reboot()
        restore()
        assert_eq(said("JOURNAL DISAGREES"), false)
        assert_eq(said("Journal: 1 block from GPS"), true)
        assert_eq(said("Journal: agrees"), false)
    end,

    ["put back in the same block, turned: the measured facing is used and the difference is logged"] =
    function(assert_eq)
        local base, c = working({ 10, 70, 10 }, 1)
        base.move.forward()
        c.pos.facing = 3                                    -- picked up, put back facing west
        local b2, said, restore = reboot()
        restore()
        assert_eq(said("JOURNAL FACING DIFFERS: journal east, measured west"), true)
        assert_eq(b2.getFacing(), 3, "the measured facing, never the journal's")
        b2.move.forward()
        assert_eq(pos(b2), at(c), "and the next step goes where it thinks")
    end,

    ["a crash after a move landed (fuel one lower) agrees at the moved position"] =
    function(assert_eq)
        local base, c = working({ 10, 70, 10 }, 2)
        local undo = crashDuring("forward", true, c)
        pcall(base.move.forward)
        undo()
        local _, said, restore = reboot()
        restore()
        assert_eq(said("Journal: agrees with GPS at 10,70,11"), true)
    end,

    ["a crash before the move (fuel unchanged) agrees at the old position"] =
    function(assert_eq)
        local base, c = working({ 10, 70, 10 }, 2)
        local undo = crashDuring("forward", false, c)
        pcall(base.move.forward)
        undo()
        local _, said, restore = reboot()
        restore()
        assert_eq(said("Journal: agrees with GPS at 10,70,10"), true)
    end,

    ["a refuel after the crash (fuel higher) still means the move did not happen"] =
    function(assert_eq)
        local base, c = working({ 10, 70, 10 }, 2)
        local undo = crashDuring("forward", false, c)
        pcall(base.move.forward)
        undo()
        c.fuel = c.fuel + 800
        local _, said, restore = reboot()
        restore()
        assert_eq(said("Journal: agrees with GPS at 10,70,10"), true)
    end,

    ["an impossible fuel drop (two for one move) has nothing to check"] =
    function(assert_eq)
        local base, c = working({ 10, 70, 10 }, 2)
        local undo = crashDuring("forward", true, c, 2)
        pcall(base.move.forward)
        undo()
        local _, said, restore = reboot()
        restore()
        assert_eq(said("Journal: nothing to check (fuel is"), true)
    end,

    ["unlimited fuel cannot settle a pending move, so there is nothing to check"] =
    function(assert_eq)
        local base, c = working({ 10, 70, 10 }, 2)
        local undo = crashDuring("forward", true, c)
        pcall(base.move.forward)
        undo()
        c.fuel = "unlimited"
        local _, said, restore = reboot()
        restore()
        assert_eq(said("Journal: nothing to check (fuel cannot settle the last move)"), true)
    end,

    ["a crash mid-turn checks the position and not the facing"] =
    function(assert_eq)
        local base, c = working({ 10, 70, 10 }, 0)
        local undo = crashDuring("turnRight", true, c, 0)
        pcall(base.move.turnRight)
        undo()
        local b2, said, restore = reboot()
        restore()
        assert_eq(said("Journal: agrees with GPS at 10,70,10, facing not journaled (mid-turn)"), true)
        assert_eq(said("JOURNAL FACING DIFFERS"), false, "the turn happened; the journal could not know")
        assert_eq(b2.getFacing(), c.pos.facing)
    end,

    ["a crash during facing detection has nothing to check"] =
    function(assert_eq)
        local b1, c = working({ 10, 70, 10 }, 1)          -- known, then re-measured
        local undo = crashDuring("forward", true, c)
        pcall(b1.detectFacingForTest)
        undo()
        local b2, said, restore = reboot()
        restore()
        assert_eq(said("Journal: nothing to check"), true)
        assert_eq(b2.getFacing(), c.pos.facing)
    end,

    ["a journal written without a GPS fix has nothing to check"] =
    function(assert_eq)
        local base = working({ 10, 70, 10 }, 1)
        base.move.forward()
        local j = readJournal(); j.posFixed = false
        writeFile(JOURNAL, textutils.serialise(j))
        local _, said, restore = reboot()
        restore()
        assert_eq(said("Journal: nothing to check (it was written without a GPS fix)"), true)
    end,

    ["no GPS at boot: no check, no fix, no step -- the boot guard waits as today"] =
    function(assert_eq)
        local base = working({ 10, 70, 10 }, 1)
        base.move.forward()
        gps = { locate = function() return nil end }
        local b2, said, restore, steps = reboot()
        restore()
        assert_eq(steps(), 0)
        assert_eq(b2.hasPositionFix(), false, "a journal is never a fix")
        assert_eq(said("Journal:") or said("JOURNAL"), false, "no check of any kind without a fix")
    end,

    -- ── The file ────────────────────────────────────────────────────────────

    ["an unreadable journal is no journal"] =
    function(assert_eq)
        local _, c = working({ 10, 70, 10 }, 1)
        writeFile(JOURNAL, "{ x = 10, y = ")
        local b2, said, restore = reboot()
        restore()
        assert_eq(said("Journal: nothing to check (no readable journal)"), true)
        assert_eq(b2.getFacing(), c.pos.facing)
    end,

    ["a well-formed table with a missing field is no journal"] =
    function(assert_eq)
        local base = working({ 10, 70, 10 }, 1)
        base.move.forward()
        local j = readJournal(); j.facing = nil
        writeFile(JOURNAL, textutils.serialise(j))
        local _, said, restore = reboot()
        restore()
        assert_eq(said("Journal: nothing to check (no readable journal)"), true)
    end,

    ["a partial temp file (crash during the write) loses to the journal"] =
    function(assert_eq)
        local base = working({ 10, 70, 10 }, 1)
        base.move.forward()
        writeFile(TMP, "{ x = 99, y = ")
        local _, said, restore = reboot()
        restore()
        assert_eq(said("Journal: agrees with GPS at 11,70,10"), true, "the journal itself is exact")
    end,

    ["a complete temp file with no journal (crash between delete and move) is used"] =
    function(assert_eq)
        local base = working({ 10, 70, 10 }, 1)
        base.move.forward()
        local h = fs.open(JOURNAL, "r"); local s = h.readAll(); h.close()
        fs.delete(JOURNAL); writeFile(TMP, s)
        local _, said, restore = reboot()
        restore()
        assert_eq(said("Journal: agrees with GPS at 11,70,10"), true)
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
