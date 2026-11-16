-- A turtle that cannot dig gets home the way it came (W3, 2026-11-14; the user's ruling: the stranded supports are fixed
-- before the 24 h run). A support follows its delivery's tunnel out; alone, its way home by the holding line meets rock
-- (6 of 8 supports in the side-test sim, node_141 on the real game). turtle_base keeps the cells it has stood in since it
-- left the building's floor, and home.retrace walks them back: up the dispatch shaft and home inside.
package.path = "./?.lua;" .. package.path

local stub = require("tests.stub_cc")

sleep = function() end
os.epoch = os.epoch or function() return os.time() * 1000 end

local HOLE = { x = 143, y = 67, z = -2813 }

local function supportAt(pos, world)
    stub.install({})
    package.loaded["waypoints"] = nil
    local proto = require("protocol")
    local dock = require("waypoints").assignDock(proto.ROLE.SUPPORT, "node_retrace_test")
    local c = stub.install({ pos = { x = pos.x, y = pos.y, z = pos.z, facing = 0 }, world = world or {} })
    gps = { locate = function() return c.pos.x, c.pos.y, c.pos.z end }
    package.loaded["turtle_base"] = nil
    package.loaded["geofence"] = nil
    local base = require("turtle_base")
    local sent = {}
    peripheral.find = function()
        return { transmit = function(ch, rr, body) sent[#sent + 1] = tostring(body) end,
                 open = function() end, isOpen = function() return true end, close = function() end }
    end
    base.recoverModem()
    base.setRoleForTest(proto.ROLE.SUPPORT)
    base.setCanDig(false)
    base.setDockForTest(dock)
    base.gpsSync(); base.detectFacingForTest()
    local dug = 0
    for _, f in ipairs({ "dig", "digUp", "digDown" }) do
        local real = turtle[f]
        turtle[f] = function(...) dug = dug + 1; return real(...) end
    end
    local moves = 0
    for _, f in ipairs({ "forward", "back", "up", "down" }) do
        local real = turtle[f]
        turtle[f] = function(...)
            moves = moves + 1
            if moves > 3000 then error("runaway", 0) end
            return real(...)
        end
    end
    return { base = base, c = c, dock = dock, dug = function() return dug end, sent = sent }
end

-- Out of the building through the dispatch hole and five blocks along the tunnel, west.
local function goOut(r)
    local m = r.base.move
    assert(m.to(HOLE.x, 60, HOLE.z))
    assert(m.to(HOLE.x - 5, 60, HOLE.z))
end

return {
    ["the way it came is kept as a simple path from the building's floor"] = function(assert_eq)
        local r = supportAt(HOLE)
        goOut(r)
        local n = #r.base.trailForTest()
        r.base.move.to(HOLE.x - 3, 60, HOLE.z)        -- two steps back along it
        local back = #r.base.trailForTest()
        local first = r.base.trailForTest()[1]
        assert_eq(n, 13, "the hole's top, seven down the shaft, five along the tunnel (" .. n .. " cells)")
        assert_eq(back, 11, "a step back onto an earlier cell cuts the loop off")
        assert_eq(first.x .. "," .. first.y .. "," .. first.z, "143,67,-2813", "it begins where it left the floor")
    end,

    ["a turtle that cannot dig, its way home shut by rock, goes back the way it came and home inside"] = function(assert_eq)
        local world = {}
        -- Rock all along the tunnel's row east of the shaft and below it: every way to the arrivals hole is shut.
        for x = HOLE.x + 1, 240 do world[x .. ",60," .. HOLE.z] = "minecraft:stone" end
        for y = 40, 59 do world[(HOLE.x - 5) .. "," .. y .. "," .. HOLE.z] = "minecraft:stone" end
        local r = supportAt(HOLE, world)
        assert_eq(r.base.isInsideBuilding(HOLE), true, "the hole's top is on the building's floor (the case under test)")
        goOut(r)
        local ok, why = pcall(r.base.returnToDock)
        local p = r.c.pos
        assert_eq(ok, true, tostring(why))
        assert_eq(p.x == r.dock.x and p.z == r.dock.z and p.y == 67, true,
            string.format("it is home on its dock (%d,%d,%d; dock %d,%d)", p.x, p.y, p.z, r.dock.x, r.dock.z))
        assert_eq(r.dug(), 0, "without digging a block")
    end,

    ["with no way back known, it says so rather than wandering"] = function(assert_eq)
        local world = {}
        for x = 131, 240 do world[x .. ",60,-2829"] = "minecraft:stone" end   -- its way east, to the arrivals hole
        local r = supportAt({ x = 130, y = 60, z = -2829 }, world)   -- rebooted out here: the trail is empty
        local ok, a, b = pcall(r.base.returnToDock)
        assert_eq(ok, true, tostring(a))
        assert_eq(a, false, "it does not claim to be home")
        assert_eq(tostring(b):find("no way back is known", 1, true) ~= nil or tostring(b):find("could not reach", 1, true) ~= nil,
            true, "and says why (" .. tostring(b) .. ")")
    end,

    -- The other half: a delivery whose job fails out in the world brings its support home before it says so. Sent at
    -- once, the JOB_ABORT sent the support home alone through rock.
    ["a delivery whose job fails out in the world holds the failure back while its support is with it"] = function(assert_eq)
        local r = supportAt({ x = 130, y = 60, z = -2829 })
        local proto = require("protocol")
        r.base.setRoleForTest(proto.ROLE.DELIVERY)
        r.base.setPartnerId("node_support")
        r.base.setStatus(proto.STATUS.WORKING, "job_0042")
        local before = #r.sent
        r.base.sendFailed("warehouse_chest_timeout", true)
        local held = true
        for i = before + 1, #r.sent do
            if r.sent[i]:find("JOB_FAILED", 1, true) or r.sent[i]:find("JOB_ABORT", 1, true) then held = false end
        end
        assert_eq(held, true, "no JOB_FAILED or JOB_ABORT yet: the support is still out with it")
        assert_eq(r.base.getPartnerId(), "node_support", "and it keeps its support, to bring it home")
    end,

    ["inside the building a failed job is said at once"] = function(assert_eq)
        local r = supportAt(HOLE)
        local proto = require("protocol")
        r.base.setRoleForTest(proto.ROLE.DELIVERY)
        r.base.setPartnerId("node_support")
        r.base.setStatus(proto.STATUS.WORKING, "job_0043")
        r.base.sendFailed("departure_failed: x", true)
        local failed = false
        for _, b in ipairs(r.sent) do if b:find("JOB_FAILED", 1, true) then failed = true end end
        assert_eq(failed, true, "JOB_FAILED is sent straight away")
    end,

    -- Sim w3_side_atc (2026-11-14): a support that missed HOLE_READY in a radio loss gave up and sent JOB_ABORT; its
    -- delivery, already out at the destination, took it as the end of the job ("job_aborted_at_destination", not
    -- recoverable): the order failed for good. Out in the world a delivery does not need its support.
    ["out in the world a delivery carries on when its support gives up; the warehouse's abort still counts"] = function(assert_eq)
        local r = supportAt({ x = 130, y = 67, z = -2829 })
        local proto = require("protocol")
        r.base.setRoleForTest(proto.ROLE.DELIVERY)
        r.base.setPartnerId("node_support")
        local fromSupport = proto.encode(proto.MSG.JOB_ABORT, "node_support", "x", { reason = "no_hole_ready_from_delivery" })
        local passed = r.base._firstSight(fromSupport)
        local partner = r.base.getPartnerId()
        local fromWarehouse = proto.encode(proto.MSG.JOB_ABORT, "warehouse", "x", { reason = "unknown job" })
        local whPassed = r.base._firstSight(fromWarehouse)
        assert_eq(passed, false, "the support's JOB_ABORT does not reach the job")
        assert_eq(partner, nil, "and the delivery goes on without a support")
        assert_eq(whPassed, true, "the warehouse's JOB_ABORT is passed on as before")
    end,

    ["inside the building a support's JOB_ABORT reaches the delivery as before"] = function(assert_eq)
        local r = supportAt(HOLE)
        local proto = require("protocol")
        r.base.setRoleForTest(proto.ROLE.DELIVERY)
        r.base.setPartnerId("node_support")
        local m = proto.encode(proto.MSG.JOB_ABORT, "node_support", "x", { reason = "no_hole_ready_from_delivery" })
        assert_eq(r.base._firstSight(m), true, "at the hole it still tells the delivery its support gave up (it then goes home: never out alone)")
    end,

    -- 2026-11-16 (sim w3_depart_off_dock on 17d6b30): back in the building, a support measured its facing and went on
    -- believing it stood one block from where GPS had just put it: it drove home one cell off, into the next turtle's
    -- dock, and reported STUCK. A facing check measures the position too, and keeps it.
    ["measuring its facing, a turtle also takes the position it measured"] = function(assert_eq)
        local r = supportAt(HOLE)
        local before = r.base.getPos()
        r.base.setPosForTest({ x = HOLE.x - 1, y = HOLE.y, z = HOLE.z })   -- what it believed: one block off
        r.base.detectFacingForTest()
        local p = r.base.getPos()
        assert_eq(before.x .. "," .. before.z, HOLE.x .. "," .. HOLE.z, "it really stands at the hole's top (the case under test)")
        assert_eq(p.x .. "," .. p.y .. "," .. p.z, HOLE.x .. "," .. HOLE.y .. "," .. HOLE.z, "after measuring it believes where GPS put it")
    end,
}
