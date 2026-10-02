-- Room at the instant of every dig on the way somewhere (1.9.125).
--
-- turtle.dig() with no room for the drop breaks the block anyway and throws the
-- item on the ground. The miner checked its pack only before setting off for
-- each ore, so a long dig through stone filled it mid-trip and every block after
-- that landed on the floor of the mining zone -- item piles that never despawn
-- in an unloaded chunk, and the lag the user reported on 2026-10-01.
--
-- stub_cc's dig() REFUSES when there is no room, where the real one breaks the
-- block and drops the item. So these tests cannot watch a drop happen; they pin
-- the thing that prevents it: the role's room hook runs before the dig, while
-- the block is still standing.
local stub = require("tests.stub_cc")

sleep = function() end
os.epoch = os.epoch or function() return os.time() * 1000 end

local PICK = "minecraft:diamond_pickaxe"

-- A miner facing north at 0,60,0 with stone ahead, and its pack as given.
local function fresh(inv)
    local c = stub.install({
        pos      = { x = 0, y = 60, z = 0, facing = 0 },
        world    = { ["0,60,-1"] = "minecraft:stone" },
        equipped = { left = PICK },
        inv      = inv or {},
    })
    gps = { locate = function() return c.pos.x, c.pos.y, c.pos.z end }
    package.loaded["turtle_base"] = nil
    package.loaded["geofence"]    = nil
    local base = require("turtle_base")
    base.gpsSync()
    return base, c
end

-- Every slot taken by a different item: the next dig has nowhere to go.
local function fullPack()
    local inv = {}
    for s = 1, 16 do inv[s] = { name = "test:item_" .. s, count = 64 } end
    return inv
end

-- Capture what turtle_base logs, by swapping the global print it calls.
--
-- turtle_base must be LOADED BEFORE this runs, never inside it. Loading it runs
-- logship, which keeps a private copy of whatever print is in force at that
-- moment; loaded inside a capture, it keeps the capture, and every line printed
-- afterwards -- the runner's own FAIL lines included -- disappears into this
-- table. That happened while these tests were written: the mutation harness
-- read the silence as four survivors.
--
-- Restored even when fn throws, for the same reason.
local function captured(fn)
    local lines, saved = {}, print
    print = function(...)
        local t = {}
        for i = 1, select("#", ...) do t[#t + 1] = tostring(select(i, ...)) end
        lines[#lines + 1] = table.concat(t, " ")
    end
    local ok, err = pcall(fn)
    print = saved
    if not ok then error(err, 0) end
    return lines
end

local function count(lines, needle)
    local n = 0
    for _, l in ipairs(lines) do
        if l:find(needle, 1, true) then n = n + 1 end
    end
    return n
end

return {
    ["the role's room hook runs before a move digs, while the block still stands"] =
    function(assert_eq)
        local base, c = fresh(fullPack())
        local calls, standing = 0, nil
        base.setDigRoomFn(function()
            calls = calls + 1
            standing = c.world["0,60,-1"]
            for s = 5, 13 do c.inv[s] = nil end      -- bank the payload
        end)
        local ok = base.move.forward()
        base.setDigRoomFn(nil)
        assert_eq(calls >= 1, true, "the hook must be given the chance to make room")
        assert_eq(standing, "minecraft:stone",
            "it must run BEFORE the dig, or the drop is already on the ground")
        assert_eq(ok, true, "and the move goes through")
        local got = false
        for s = 1, 16 do
            if c.inv[s] and c.inv[s].name == "minecraft:stone" then got = true end
        end
        assert_eq(got, true, "the dug stone is in the pack, not on the floor")
    end,

    ["a dig going up asks for room too"] =
    function(assert_eq)
        local base, c = fresh({})
        c.world["0,61,0"] = "minecraft:stone"
        local calls = 0
        base.setDigRoomFn(function() calls = calls + 1 end)
        base.move.up()
        base.setDigRoomFn(nil)
        assert_eq(calls >= 1, true, "a climb digs as much stone as a walk does")
    end,

    ["a move that digs nothing does not ask for room"] =
    function(assert_eq)
        local base, c = fresh({})
        c.world["0,60,-1"] = nil
        local calls = 0
        base.setDigRoomFn(function() calls = calls + 1 end)
        local ok = base.move.forward()
        base.setDigRoomFn(nil)
        assert_eq(ok, true)
        assert_eq(calls, 0, "banking costs seconds; only a dig needs the room")
    end,

    ["with no hook set, a move is exactly what it was"] =
    function(assert_eq)
        local base, c = fresh({})
        local ok = base.move.forward()
        assert_eq(ok, true, "delivery and support set no hook and must not notice")
        assert_eq(c.pos.z, -1)
    end,

    ["a hook that fails does not stop the move"] =
    function(assert_eq)
        local ok
        local base = fresh({})
        local lines = captured(function()
            base.setDigRoomFn(function() error("chest missing") end)
            ok = base.move.forward()
            base.setDigRoomFn(nil)
        end)
        assert_eq(ok, true, "a turtle that cannot bank must still be able to move")
        assert_eq(count(lines, "Dig make-room hook failed"), 1, "and it says so")
    end,

    ["making room cannot recurse into making room"] =
    function(assert_eq)
        local base, c = fresh({})
        local calls = 0
        base.setDigRoomFn(function()
            calls = calls + 1
            base.makeRoomBeforeDig()        -- the dump digs to place its chest
        end)
        base.move.forward()
        base.setDigRoomFn(nil)
        assert_eq(calls, 1, "the inner request is ignored, not followed down")
    end,

    ["a dig with nowhere for the drop is logged, once a minute"] =
    function(assert_eq)
        local base = fresh(fullPack())
        local lines = captured(function()
            base.setDigRoomFn(function() end)   -- a hook that could not make room
            for _ = 1, 3 do base.makeRoomBeforeDig() end
            base.setDigRoomFn(nil)
        end)
        assert_eq(count(lines, "Digging with no empty slot at 0,60,0"), 1,
            "the residual spill is measured, without burying the log")
    end,

    ["a dig with room is not logged"] =
    function(assert_eq)
        local base = fresh({})
        local lines = captured(function()
            base.setDigRoomFn(function() end)
            base.makeRoomBeforeDig()
            base.setDigRoomFn(nil)
        end)
        assert_eq(count(lines, "Digging with no empty slot"), 0,
            "or the count means nothing")
    end,

    -- ore_turtle self-executes and cannot be loaded headlessly, so its half is
    -- pinned by source. Weaker than a behaviour test, and labelled so.
    ["the miner banks before a dig when under two slots are free (SOURCE-ONLY, weaker)"] =
    function(assert_eq)
        local f = io.open("ore_turtle.lua", "r"); local src = f:read("a"); f:close()
        local block = src:match("base%.setDigRoomFn%(function%(%)(.-)\nend%)")
        assert_eq(block ~= nil, true, "the miner installs a dig room hook")
        assert_eq(block and block:find('dumpIfInventoryTight("digging a path", 2, true)', 1, true) ~= nil,
            true, "two free slots, and quiet")
        assert_eq(block and block:find("base.isInsideBuilding", 1, true) ~= nil, true,
            "never in the depot, where the dump would dig the floor")
        assert_eq(src:find("if not quiet then reportPhase(proto.PHASE.DUMPING) end", 1, true) ~= nil,
            true, "a quiet dump must not clear the comms-gap flag of a silent flight home")
        assert_eq(src:find("if free >= (minFree or REFUEL_FREE_SLOTS) then return end", 1, true) ~= nil,
            true, "the threshold is the caller's")
        assert_eq(src:find("    dumpOres(quiet)\nend", 1, true) ~= nil
            or src:find("    dumpOres(quiet)\r\nend", 1, true) ~= nil, true,
            "quiet reaches the dump")
    end,
}
