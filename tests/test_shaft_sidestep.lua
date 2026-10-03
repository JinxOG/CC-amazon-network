-- A head-on meeting in a one-block shaft (2026-09-16, job_0058).
--
-- node_139 climbing and node_138 descending met in one column. Each waited 120 s
-- for the other, and the climber's job failed for good. A forward meeting had a
-- bypass; a vertical one had nothing. The rule now: the DESCENDING turtle steps
-- sideways after ~3 s; a climber does the same only after ~35 s, so a head-on
-- pair always resolves with the descender moving. Never near the depot, whose
-- holes are one-block shafts turtles queue in on purpose.
local stub = require("tests.stub_cc")

sleep = function() end
os.epoch = os.epoch or function() return os.time() * 1000 end

local TURTLE = "computercraft:turtle_advanced"

local function fresh(opts)
    local c = stub.install(opts)
    gps = { locate = function() return c.pos.x, c.pos.y, c.pos.z end }
    package.loaded["turtle_base"] = nil
    package.loaded["geofence"]    = nil
    local base = require("turtle_base")
    base.gpsSync()
    return base, c
end

-- tryMove waits out a turtle against os.clock() + 120 and sleep is a no-op
-- here, so the clock is made to jump. Restore is mandatory.
local function fastClock(step)
    local saved, t = os.clock, os.clock()
    os.clock = function() t = t + (step or 1); return t end
    return function() os.clock = saved end
end

local function key(x, y, z) return x .. "," .. y .. "," .. z end

return {
    ["a descending turtle steps out of a shared shaft instead of waiting it out"] =
    function(assert_eq)
        local base, c = fresh({
            pos   = { x = 0, y = 60, z = 0, facing = 0 },
            world = { [key(0, 59, 0)] = TURTLE },          -- a turtle below, climbing
        })
        local restore = fastClock(1)
        local ok = base.move.down()
        restore()
        local p = base.getPos()
        assert_eq(ok, true, "job_0058 failed permanently here instead")
        assert_eq(p.y, 60, "it moved sideways, not down")
        assert_eq(math.abs(p.x) + math.abs(p.z), 1, "exactly one block out of the column")
        assert_eq(c.world[key(0, 59, 0)], TURTLE, "and the other turtle was never dug")
    end,

    ["move.to still arrives after stepping aside"] =
    function(assert_eq)
        local base, c = fresh({
            pos   = { x = 0, y = 60, z = 0, facing = 0 },
            world = { [key(0, 59, 0)] = TURTLE },
        })
        local restore = fastClock(1)
        local ok = base.move.to(0, 55, 0)
        restore()
        local p = base.getPos()
        assert_eq(ok, true, "the descent finishes in the next column")
        assert_eq(p.x .. "," .. p.y .. "," .. p.z, "0,55,0",
            "and the horizontal pass brings it back to the target")
    end,

    ["a climber gives the descender time to move first"] =
    function(assert_eq)
        -- How long each waits before stepping aside, in clock readings (the
        -- wait loop reads the clock every time round). The two must differ by
        -- a wide margin, or a head-on pair can step aside together and meet
        -- again in the next column.
        local function readingsBeforeStep(dir)
            local above = dir == "up"
            local base, c = fresh({
                pos   = { x = 0, y = 60, z = 0, facing = 0 },
                world = { [key(0, above and 61 or 59, 0)] = TURTLE },
            })
            local n, at = 0, nil
            local saved, t = os.clock, os.clock()
            os.clock = function() n = n + 1; t = t + 1; return t end
            local step = base.sidestepOutOfColumn
            base.sidestepOutOfColumn = function() at = at or n; return step() end
            if above then base.move.up() else base.move.down() end
            os.clock = saved
            return at
        end
        local down, up = readingsBeforeStep("down"), readingsBeforeStep("up")
        assert_eq(down ~= nil and up ~= nil, true, "both do step aside in the end")
        assert_eq(up >= 3 * down, true, string.format(
            "the climber waits far longer (%s vs %s readings)", tostring(up), tostring(down)))
    end,

    ["a climber under something that never moves still gets out"] =
    function(assert_eq)
        local base, c = fresh({
            pos   = { x = 0, y = 60, z = 0, facing = 0 },
            world = { [key(0, 61, 0)] = TURTLE },          -- e.g. a standing loader
        })
        local restore = fastClock(1)
        local ok = base.move.up()
        restore()
        local p = base.getPos()
        assert_eq(ok, true)
        assert_eq(math.abs(p.x) + math.abs(p.z), 1, "out of the column")
    end,

    ["no turtle steps sideways near the depot, where the holes are shared on purpose"] =
    function(assert_eq)
        local base, c = fresh({
            pos   = { x = 228, y = 120, z = -2782, facing = 0 },   -- over the arrivals hole
            world = { [key(228, 119, -2782)] = TURTLE },
        })
        local restore = fastClock(10)
        local ok = base.move.down()
        restore()
        local p = base.getPos()
        assert_eq(ok, false, "it waits its turn in the queue")
        assert_eq(p.x .. "," .. p.z, "228,-2782", "and never digs sideways into the building")
    end,

    ["a turtle boxed in by turtles does not step anywhere"] =
    function(assert_eq)
        -- WITH a pickaxe. Without one this passed whatever the guards did: the
        -- stub cannot dig with no tool, so nothing could ever be dug. The
        -- side-step's two turtle guards are what this is about, so the tool
        -- that could defeat them has to be there.
        local base, c = fresh({
            equipped = { left = "minecraft:diamond_pickaxe" },
            pos   = { x = 0, y = 60, z = 0, facing = 0 },
            world = {
                [key(0, 59, 0)] = TURTLE,
                [key(1, 60, 0)] = TURTLE, [key(-1, 60, 0)] = TURTLE,
                [key(0, 60, 1)] = TURTLE, [key(0, 60, -1)] = TURTLE,
            },
        })
        local restore = fastClock(10)
        local ok = base.move.down()
        restore()
        local p = base.getPos()
        assert_eq(ok, false)
        assert_eq(p.x .. "," .. p.y .. "," .. p.z, "0,60,0", "no turtle is ever dug to make a way")
        for _, k in ipairs({ key(1, 60, 0), key(-1, 60, 0), key(0, 60, 1), key(0, 60, -1) }) do
            assert_eq(c.world[k], TURTLE, "neighbour at " .. k .. " untouched")
        end
    end,
}
