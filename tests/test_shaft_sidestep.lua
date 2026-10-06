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

    -- A recall mid-flight (2026-09-22): node_119 was recalled at 08:59 and flew
    -- 1,700 blocks on regardless. An abort predicate stops move.to at the next
    -- block; it is set only around the outbound flight.
    ["a flight with an abort set stops at the next block once it fires"] =
    function(assert_eq)
        local base, c = fresh({ pos = { x = 0, y = 60, z = 0, facing = 0 } })
        local steps = 0
        base.setMoveAbort(function() steps = steps + 1; return steps > 3 end)
        local ok, why = base.move.to(20, 60, 0)
        base.setMoveAbort(nil)
        local p = base.getPos()
        assert_eq(ok, false)
        assert_eq(why, "aborted")
        assert_eq(p.x, 3, "three blocks flown, then it stopped -- not twenty")
    end,

    ["with no abort set, a flight is exactly what it was"] =
    function(assert_eq)
        local base, c = fresh({ pos = { x = 0, y = 60, z = 0, facing = 0 } })
        local ok = base.move.to(5, 62, -4)
        local p = base.getPos()
        assert_eq(ok, true)
        assert_eq(p.x .. "," .. p.y .. "," .. p.z, "5,62,-4")
    end,

    ["the abort is checked on every axis, climbing included"] =
    function(assert_eq)
        local base, c = fresh({ pos = { x = 0, y = 60, z = 0, facing = 0 } })
        base.setMoveAbort(function() return true end)
        local okUp   = base.move.to(0, 70, 0)
        local okDown = base.move.to(0, 50, 0)
        local okZ    = base.move.to(0, 60, 9)
        base.setMoveAbort(nil)
        local p = base.getPos()
        assert_eq(okUp == false and okDown == false and okZ == false, true)
        assert_eq(p.x .. "," .. p.y .. "," .. p.z, "0,60,0", "not one block moved")
    end,

    ["the miner arms the abort for the way out only (SOURCE-ONLY, weaker)"] =
    function(assert_eq)
        local f = io.open("ore_turtle.lua", "r"); local src = f:read("a"); f:close()
        local armAt   = src:find("base.setMoveAbort(base.isRecalled)", 1, true)
        local moveAt  = armAt and src:find("local mOk, mErr = base.move.to(standX, travelY, standZ)", armAt, true)
        local clearAt = moveAt and src:find("base.setMoveAbort(nil)", moveAt, true)
        local turnAt  = clearAt and src:find("recallReturn()", clearAt, true)
        local failAt  = clearAt and src:find("if not mOk then", clearAt, true)
        assert_eq(armAt ~= nil and moveAt ~= nil and clearAt ~= nil, true,
            "armed before the outbound flight, cleared after it")
        assert_eq(turnAt ~= nil and failAt ~= nil and turnAt < failAt, true,
            "a recall is answered before the flight is judged to have failed")
        local home = src:match("local function soloReturn%(%)(.-)reportPhase")
        assert_eq(home and home:find("base.setMoveAbort(nil)", 1, true) ~= nil, true,
            "and the trip home clears it first, whatever was left set")
    end,

    -- Never fly on a guessed position (2026-10-05): four miners booted after a
    -- world restart with no GPS fix, believed they were at 0,0,0, and flew off.
    ["a turtle with no GPS fix waits for one, standing still, then knows where and which way"] =
    function(assert_eq)
        local c = stub.install({ pos = { x = 500, y = 80, z = -300, facing = 2 } })
        local calls = 0
        gps = { locate = function()
            calls = calls + 1
            if calls <= 3 then return nil end              -- hosts still down
            return c.pos.x, c.pos.y, c.pos.z
        end }
        package.loaded["turtle_base"] = nil
        package.loaded["geofence"]    = nil
        local base = require("turtle_base")
        base.gpsSync()                                     -- fails: no fix yet
        local before = base.hasPositionFix()
        local ok = base.waitForPositionFix("test")
        local p = base.getPos()
        assert_eq(before, false, "a failed sync is not a fix")
        assert_eq(ok, true)
        assert_eq(base.hasPositionFix(), true)
        assert_eq(p.x .. "," .. p.y .. "," .. p.z, "500,80,-300",
            "the real position, not 0,0,0 -- and not one block moved while waiting")
    end,

    ["a turtle that already has a fix does not wait"] =
    function(assert_eq)
        local base, c = fresh({ pos = { x = 7, y = 70, z = 7, facing = 0 } })
        base.detectFacingForTest()                      -- position AND facing measured
        local calls = 0
        local real = gps.locate
        gps.locate = function(...) calls = calls + 1; return real(...) end
        base.waitForPositionFix("test")
        assert_eq(base.hasPositionFix(), true)
        assert_eq(calls, 0, "no GPS round trip when the fix is already there")
    end,

    ["boot recovery waits for a real position before anything else (SOURCE-ONLY, weaker)"] =
    function(assert_eq)
        local f = io.open("ore_turtle.lua", "r"); local src = f:read("a"); f:close()
        local body = src:match("local function recoverPlacedLoader%(%)(.-)\nend\n")
        assert_eq(body ~= nil, true, "recoverPlacedLoader exists")
        local waitAt  = body and body:find("base.waitForPositionFix(", 1, true)
        local depotAt = body and body:find("base.isInsideBuilding(base.getPos())", 1, true)
        local flyAt   = body and body:find("reportPhase(proto.PHASE.RETRIEVING,", 1, true)
        assert_eq(waitAt ~= nil and depotAt ~= nil and flyAt ~= nil, true)
        assert_eq(waitAt < depotAt and waitAt < flyAt, true,
            "the depot check and the flight both use the position; the fix comes first")
    end,

    -- A guessed facing (2026-10-06): node_182 logged "GPS lost during facing
    -- detection. Assuming north." and flew ~1,000 blocks the wrong way.
    ["a facing that could not be measured is unknown, and the wait measures it before moving"] =
    function(assert_eq)
        local c = stub.install({ pos = { x = 40, y = 120, z = 40, facing = 1 } })   -- really east
        local calls = 0
        gps = { locate = function()
            calls = calls + 1
            -- 1: gpsSync, 2: detection's first fix, 3: its second fix -- lost
            -- there, mid-detection, as on node_182.
            if calls == 3 then return nil end
            return c.pos.x, c.pos.y, c.pos.z
        end }
        package.loaded["turtle_base"] = nil
        package.loaded["geofence"]    = nil
        local base = require("turtle_base")
        base.gpsSync()
        base.detectFacingForTest()
        local before = base.hasPositionFix()
        base.waitForPositionFix("test")
        local after = base.hasPositionFix()
        base.move.forward()
        local p = base.getPos()
        assert_eq(before, false, "a facing lost mid-detection is not a facing")
        assert_eq(after, true, "measured before anything moves")
        assert_eq(p.x .. "," .. p.z, "41,40", "and a step forward goes where the turtle thinks: east")
    end,

    ["a turtle boxed in on all sides does not claim a facing"] =
    function(assert_eq)
        local base, c = fresh({
            pos   = { x = 0, y = 60, z = 0, facing = 0 },
            world = { [key(1, 60, 0)] = "minecraft:stone", [key(-1, 60, 0)] = "minecraft:stone",
                      [key(0, 60, 1)] = "minecraft:stone", [key(0, 60, -1)] = "minecraft:stone" },
        })
        local ok = base.detectFacingForTest()
        assert_eq(ok, false, "no step, no measurement")
        assert_eq(base.hasPositionFix(), false)
    end,

    ["a miner rebooted outside the base with nothing to recover flies home (SOURCE-ONLY, weaker)"] =
    function(assert_eq)
        local f = io.open("ore_turtle.lua", "r"); local src = f:read("a"); f:close()
        local scanAt = src:find("local sok, serr = pcall(recoverPlacedScanner)", 1, true)
        local homeAt = src:find('base.waitForPositionFix("rebooted outside the base with no loader to recover")', 1, true)
        local flyAt  = homeAt and src:find("base.returnToDockFromSky()", homeAt, true)
        local runAt  = src:find("local ok, err = pcall(base.run, mineJob)", 1, true)
        assert_eq(scanAt ~= nil and homeAt ~= nil and flyAt ~= nil and runAt ~= nil, true)
        assert_eq(scanAt < homeAt and flyAt < runAt, true,
            "after both recoveries, before any job is taken")
        local guard = src:sub(scanAt, homeAt)
        assert_eq(guard:find("if loader_state.hasPlaced() then return end", 1, true) ~= nil, true,
            "a standing loader is boot recovery's job, not this")
        assert_eq(guard:find("if base.isInsideBuilding(base.getPos()) then return end", 1, true) ~= nil, true)
    end,
}
