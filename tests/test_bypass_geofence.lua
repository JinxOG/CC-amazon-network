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
    return base
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
}
