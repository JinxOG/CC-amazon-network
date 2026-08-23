-- Covers the gap the Task 5 review found: bypassForward() (inside
-- turtle_base.lua's tryMove) turns and calls turtle.forward() directly,
-- bypassing tryMove's own dir-based geofence guard entirely. In the solo-
-- miner design the turtle deliberately places a chunk-loader turtle one
-- block in front of itself at every sector and mines around it, so hitting
-- this exact bypass path (isTurtleBlock(dir) true) is routine, not a rare
-- collision -- it must never be able to walk the turtle out of the fence.
local stub = require("tests.stub_cc")

-- turtle_base.lua isn't written to be stub-driven directly; give it just
-- enough of the CC globals it touches outside the turtle/peripheral/os
-- surface stub_cc already provides.
sleep = function() end                                   -- no real delay in tests
os.epoch = os.epoch or function() return os.time() * 1000 end

-- turtle_base tracks its OWN dead-reckoned position (_self.pos), separate
-- from the stub's physical c.pos used for world collisions -- they only
-- agree if something GPS-syncs them together. gps.locate here reads back
-- the stub's real position so base.gpsSync() (called once below) seeds
-- _self.pos correctly; without this every test starts logically at 0,0,0
-- no matter what `pos` was passed to stub.install.
local function fresh(opts)
    local c = stub.install(opts)
    gps = { locate = function() return c.pos.x, c.pos.y, c.pos.z end }
    package.loaded["turtle_base"] = nil
    package.loaded["geofence"]    = nil
    local base = require("turtle_base")
    base.gpsSync()
    -- Second return is the stub context, so a test can read the world back and
    -- assert what is still standing. Existing call sites ignore it.
    return base, c
end

-- tryMove waits out a blocking turtle against `os.clock() + 120`. sleep is a
-- no-op here, so a permanently blocked move busy-spins for two real minutes of
-- CPU before giving up -- it completes, but it makes the suite unusable. This
-- makes the clock jump so the deadline is reached in a handful of iterations.
-- Returns a restore function; callers MUST invoke it.
local function fastClock()
    local saved = os.clock
    local t = saved()
    os.clock = function() t = t + 10; return t end
    return function() os.clock = saved end
end

return {
    -- The scenario: turtle sits at x=-16 (the fence's own minimum x
    -- boundary), facing north, with a "turtle" block directly ahead --
    -- exactly bypassForward's trigger. Turning LEFT (west) would step to
    -- x=-17, one block outside the fence; turning RIGHT (east) stays inside.
    -- Without the fix, tryStrafe tries left first and the raw turtle.
    -- forward() call succeeds (nothing physically blocks that square),
    -- silently walking the turtle out of the loaded area. With the fix, the
    -- left lane must be refused by the fence and the right lane taken
    -- instead, landing at a position the test pins down exactly.
    ["bypassForward cannot walk the turtle out of an active fence"] = function(assert_eq)
        local base = fresh({
            pos   = { x = -16, y = 60, z = 0, facing = 0 },  -- facing north
            world = { ["-16,60,-1"] = "computercraft:turtle_advanced" }, -- blocks forward
        })
        base.geofence.setAnchorChunk(0, 0, 1)  -- blocks -16..31 on both axes

        local ok = base.move.forward()

        assert_eq(ok, true, "expected the right-lane bypass to succeed")
        local p = base.getPos()
        assert_eq(base.geofence.contains(p.x, p.z), true,
            string.format("bypass ended OUTSIDE the fence at %d,%d", p.x, p.z))
        -- Pin the exact route taken: right lane (east, x=-15), one step past
        -- the obstacle (north, z=-1). The final "return to the original
        -- lane" sub-step (west, back to x=-16) lands on the very cell the
        -- obstacle occupies -- a pre-existing, fence-unrelated property of
        -- this single-obstacle geometry -- so it's tolerated exactly like
        -- any other physically-blocked forward() and the turtle parks in
        -- the side lane. What matters here: it took the right lane at all,
        -- meaning the left lane (x=-17, outside the fence) was refused.
        assert_eq(p.x, -15, "expected the right lane, not the fence-breaching left lane")
        assert_eq(p.z, -1,  "unexpected final z")
    end,

    -- Same obstacle, no anchor set: mirrors what delivery/support/warehouse
    -- experience today. bypassForward tries the LEFT lane first (tryStrafe
    -- (true) before tryStrafe(false)) and nothing there blocks it physically,
    -- so it must still take the left lane and land at x=-17 -- one block
    -- outside where the fence above would have refused it -- proving the
    -- geofence guard changes nothing when the fence is inactive.
    ["bypassForward is unaffected when no fence is active"] = function(assert_eq)
        local base = fresh({
            pos   = { x = -16, y = 60, z = 0, facing = 0 },
            world = { ["-16,60,-1"] = "computercraft:turtle_advanced" },
        })

        local ok = base.move.forward()

        assert_eq(ok, true)
        local p = base.getPos()
        assert_eq(p.x, -17, "left lane (unfenced) should be taken and reach x=-17")
        assert_eq(p.z, -1,  "unexpected final z")
    end,

    -- One miner has destroyed another. node_139 docked on 2026-08-22 carrying
    -- node_119 -- a MINER -- as an item, after a session spent diagnosing
    -- node_119 as a turtle that had simply gone missing.
    --
    -- tryMove was never the problem: it checks isTurtleBlock and waits. The
    -- BYPASS it falls through to dug blind, so the full sequence was: notice a
    -- turtle ahead, correctly decline to dig it, attempt to route around it, and
    -- dig a different turtle on the way past.
    --
    -- Boxed in on all four lanes so the only remaining route is vertical. Both
    -- vertical neighbours are turtles, so the correct outcome is to dig NOTHING
    -- and wait: a column of turtles is transient by definition, since everyone
    -- in it is trying to leave.
    ["the vertical bypass must never dig a turtle above or below"] = function(assert_eq)
        local TURTLE = "computercraft:turtle_advanced"
        local base, c = fresh({
            -- A pickaxe is not decoration here. The stub refuses every dig
            -- without one, so an unequipped fixture would pass this test whether
            -- the guard existed or not -- the digs it is meant to prevent could
            -- not have happened anyway.
            equipped = { left = "minecraft:diamond_pickaxe" },
            -- Underground: above FLOOR_Y the vertical bypass is not even tried.
            pos   = { x = 0, y = 60, z = 0, facing = 0 },
            world = {
                ["0,60,-1"] = TURTLE,             -- the blocker, ahead (north)
                ["-1,60,0"] = "minecraft:stone",  -- left lane sealed
                ["1,60,0"]  = "minecraft:stone",  -- right lane sealed
                ["0,61,0"]  = TURTLE,             -- a fleet member directly above
                ["0,59,0"]  = TURTLE,             -- and another directly below
            },
        })

        local restoreClock = fastClock()
        base.move.forward()
        restoreClock()

        assert_eq(c.world["0,61,0"], TURTLE,
            "the turtle ABOVE must still exist — digging it destroys a fleet member")
        assert_eq(c.world["0,59,0"], TURTLE,
            "the turtle BELOW must still exist")
        assert_eq(c.world["0,60,-1"], TURTLE,
            "and the original blocker must be untouched, as it always was")
    end,

    -- The guard must not turn into "never dig". Same geometry, but the vertical
    -- neighbours are stone: the bypass is expected to dig through and get past.
    -- Without this, a fix that refused every dig would pass the test above while
    -- immobilising the entire fleet underground.
    ["the vertical bypass still digs terrain out of the way"] = function(assert_eq)
        local TURTLE = "computercraft:turtle_advanced"
        local base, c = fresh({
            equipped = { left = "minecraft:diamond_pickaxe" },
            pos   = { x = 0, y = 60, z = 0, facing = 0 },
            world = {
                ["0,60,-1"] = TURTLE,
                ["-1,60,0"] = "minecraft:stone",
                ["1,60,0"]  = "minecraft:stone",
                ["0,61,0"]  = "minecraft:stone",   -- terrain, not a fleet member
            },
        })

        local restoreClock = fastClock()
        base.move.forward()
        restoreClock()

        assert_eq(c.world["0,61,0"], nil,
            "stone above must be dug — the guard is about turtles, not about digging")
    end,

    -- The second unguarded site: findFreeSpace's "surrounded" fallback, which
    -- dug down, up and forward with no inspection at all in order to make room
    -- for the fuel ender chest.
    --
    -- A turtle that finds itself surrounded AT A DOCK is surrounded by other
    -- docked turtles, by construction -- this sat in the most crowded part of
    -- the map. Boxed in by fleet members on all three axes, the correct outcome
    -- is to refuse and report, not to make room by destroying a neighbour.
    ["a surrounded turtle will not dig its way out through fleet members"] =
    function(assert_eq)
        local TURTLE = "computercraft:turtle_advanced"
        local base, c = fresh({
            equipped = { left = "minecraft:diamond_pickaxe" },
            pos   = { x = 0, y = 68, z = 0, facing = 0 },   -- at the depot floor
            world = {
                ["0,68,-1"] = TURTLE,   -- ahead
                ["0,69,0"]  = TURTLE,   -- above
                ["0,67,0"]  = TURTLE,   -- below
            },
            inv = {
                [15] = { name = "enderstorage:ender_chest", count = 1 },
                [16] = { name = "enderstorage:ender_chest", count = 1 },
            },
        })

        local ok = base.fuel.refuelFromChest()

        assert_eq(ok, false, "the refuel must fail rather than dig a way out")
        assert_eq(c.world["0,69,0"], TURTLE, "the turtle above must survive")
        assert_eq(c.world["0,67,0"], TURTLE, "the turtle below must survive")
        assert_eq(c.world["0,68,-1"], TURTLE, "the turtle ahead must survive")
    end,
}
