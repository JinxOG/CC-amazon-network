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

-- A reboot: turtle_base reloaded over the same stub disk, as support_turtle starts it (canDig off before init).
local function reboot(r)
    package.loaded["turtle_base"] = nil
    package.loaded["geofence"] = nil
    local proto = require("protocol")
    local base = require("turtle_base")
    base.recoverModem()
    base.setRoleForTest(proto.ROLE.SUPPORT)
    base.setCanDig(false)
    base.setDockForTest(r.dock)
    base.initPositionForTest()
    r.base = base
    return base
end

-- The way out of test 2: rock east of the shaft and under the tunnel's end, so the only way home is back.
local function shutWorld()
    local world = {}
    for x = HOLE.x + 1, 240 do world[x .. ",60," .. HOLE.z] = "minecraft:stone" end
    for y = 40, 59 do world[(HOLE.x - 5) .. "," .. y .. "," .. HOLE.z] = "minecraft:stone" end
    return world
end

return {
    -- T2 shakeout-payload-e (2026-11-23): node_239 and node_235, rebooted out in the tunnel by the restart burst,
    -- were given holding slots behind rock, logged "no way back is known (trail empty)" and stood in the lane to
    -- the end; 10 supports following their deliveries out bumped into them for 120 s and gave up. The way it came
    -- was in memory only. A turtle that cannot dig keeps it on disk, and finds it again after a reboot.
    ["rebooted out in the tunnel, a turtle that cannot dig still knows the way it came, and goes home by it"] = function(assert_eq)
        local r = supportAt(HOLE, shutWorld())
        goOut(r)
        local before = #r.base.trailForTest()
        reboot(r)
        local after = #r.base.trailForTest()
        local ok, why = pcall(r.base.returnToDock)
        local p = r.c.pos
        assert_eq(before, 13, "the way out, before the reboot (" .. before .. " cells)")
        assert_eq(after, before, "the same way, after it (" .. after .. " cells)")
        assert_eq(ok, true, tostring(why))
        assert_eq(p.x == r.dock.x and p.z == r.dock.z and p.y == 67, true,
            string.format("it is home on its dock (%d,%d,%d; dock %d,%d)", p.x, p.y, p.z, r.dock.x, r.dock.z))
        assert_eq(r.dug(), 0, "without digging a block")
    end,

    ["steps taken after the last corner it wrote are kept too"] = function(assert_eq)
        local r = supportAt(HOLE, shutWorld())
        goOut(r)
        r.base.move.to(HOLE.x - 2, 60, HOLE.z)          -- back three: a loop cut, the trail is 10 cells
        r.base.move.to(HOLE.x - 4, 60, HOLE.z)          -- and out two again, straight: no corner written
        local before = #r.base.trailForTest()
        reboot(r)
        local last = r.base.trailForTest()[#r.base.trailForTest()]
        assert_eq(before, 12, "the trail before the reboot (" .. before .. " cells)")
        assert_eq(#r.base.trailForTest(), before, "and after it")
        assert_eq(last.x .. "," .. last.y .. "," .. last.z, (HOLE.x - 4) .. ",60," .. HOLE.z, "ending where it stands")
    end,

    ["a kept way that does not lead to where it stands is not trusted"] = function(assert_eq)
        local r = supportAt(HOLE, shutWorld())
        goOut(r)
        r.c.pos.x, r.c.pos.z = HOLE.x - 5, HOLE.z + 4        -- carried off it, as by a player
        reboot(r)
        assert_eq(#r.base.trailForTest(), 0, "no way back is assumed (" .. #r.base.trailForTest() .. " cells)")
    end,

    -- T2 shakeout-payload-e (2026-11-23): node_217 went up and over node_235, parked in the tunnel at 196,60,-2794;
    -- its support node_237 missed the steps between (it was still moving) and planned a straight line to where its
    -- delivery had got to -- into node_235 -- and gave up after 120 s. Each step its delivery sends now carries the
    -- last cells it stood in, and the support walks those.
    ["a support that missed its delivery's steps round something in the way walks its delivery's own cells"] = function(assert_eq)
        local world = {}
        for y = 59, 62 do for z = -2800, -2788 do world["196," .. y .. "," .. z] = "minecraft:stone" end end
        local path = { { x = 196, y = 60, z = -2796 }, { x = 196, y = 60, z = -2795 }, { x = 196, y = 61, z = -2795 },
                       { x = 196, y = 61, z = -2794 }, { x = 196, y = 61, z = -2793 }, { x = 196, y = 60, z = -2793 },
                       { x = 196, y = 60, z = -2792 }, { x = 196, y = 60, z = -2791 } }
        for _, c in ipairs(path) do world[c.x .. "," .. c.y .. "," .. c.z] = nil end
        -- 196,60,-2794 stays solid: what its delivery went round (a parked turtle, live).
        local r = supportAt({ x = 196, y = 60, z = -2796 }, world)
        r.base.setPartnerId("node_d")
        local ok = r.base.followPartner({ prev = { x = 196, y = 60, z = -2792 }, tail = path })
        local p = r.c.pos
        assert_eq(p.x .. "," .. p.y .. "," .. p.z, "196,60,-2792", "it is one cell behind its delivery")
        assert_eq(ok, true, "and says it got there")
        assert_eq(r.dug(), 0, "without digging a block")
    end,

    -- Sim w3_pair_server_crash (2026-11-23): node_52 lagged eight seconds behind node_33, which had gone up and over
    -- node_51 -- further back than eight cells -- and planned a straight line into node_51 again: 120 s, gave up.
    -- The cells go as their corners, the last FOLLOW_TAIL_N of them, so a support far behind is still on them.
    ["a support far behind its delivery still finds its delivery's cells, sent as their corners"] = function(assert_eq)
        local world = {}
        for y = 59, 62 do for z = -2800, -2760 do world["196," .. y .. "," .. z] = "minecraft:stone" end end
        local path = { { x = 196, y = 60, z = -2796 }, { x = 196, y = 60, z = -2795 }, { x = 196, y = 61, z = -2795 },
                       { x = 196, y = 61, z = -2793 } }
        for z = -2793, -2770 do path[#path + 1] = { x = 196, y = 60, z = z } end
        for _, c in ipairs(path) do world[c.x .. "," .. c.y .. "," .. c.z] = nil end
        world["196,61,-2794"] = nil
        local r = supportAt({ x = 196, y = 60, z = -2796 }, world)
        r.base.setPartnerId("node_d")
        local corners = { path[1], path[2], path[3], { x = 196, y = 61, z = -2793 }, { x = 196, y = 60, z = -2793 },
                          { x = 196, y = 60, z = -2770 } }
        r.base.followPartner({ prev = { x = 196, y = 60, z = -2771 }, tail = corners })
        local p = r.c.pos
        assert_eq(p.x .. "," .. p.y .. "," .. p.z, "196,60,-2771", "it is one cell behind its delivery, 25 cells on")
        assert_eq(r.dug(), 0, "without digging a block")
    end,

    -- T2 shakeout-payload-e (2026-11-23): node_221 reached its destination 160,67,-2752, in chunk 10,-172, with its
    -- support node_234 21 blocks back in chunk z -174; the support's chunky upgrade loads only its own chunk
    -- (chunkyTurtleRadius = 0), and the delivery stopped dead there. A delivery never steps into a new chunk until
    -- its support stands in the chunk it is leaving: it asks (SUPPORT_WHERE) and goes on its support's answer.
    ["a delivery does not step into a new chunk until its support is in the chunk it is leaving"] = function(assert_eq)
        local r = supportAt({ x = 126, y = 60, z = -2829 })
        local proto = require("protocol")
        r.base.setRoleForTest(proto.ROLE.DELIVERY)
        r.base.setPartnerId("node_s")
        r.base.setFollowGate(true)
        local asks, posAtAsk, answers = 0, {}, { { x = 100, y = 60, z = -2829 }, { x = 125, y = 60, z = -2829 } }
        peripheral.find = function()
            return { open = function() end, isOpen = function() return true end, close = function() end,
                     transmit = function(ch, rr, body)
                         local m = textutils.unserialise(body)
                         if m and m.type == proto.MSG.SUPPORT_WHERE then
                             asks = asks + 1
                             if asks > 20 then error("the delivery asked 20 times", 0) end
                             posAtAsk[#posAtAsk + 1] = r.c.pos.x
                             -- answered at once where it stands (behind, chunk 6), then again from its follow loop
                             -- once it has walked up behind its delivery (chunk 7)
                             for _, a in ipairs(answers) do
                                 os.queueEvent("modem_message", "top", proto.CH_LOCAL, 0,
                                     proto.encode(proto.MSG.SUPPORT_HERE, "node_s", "node_retrace_test", a), 5)
                             end
                         end
                     end }
        end
        r.base.recoverModem()
        r.base.setIdForTest("node_retrace_test")
        local unreadAtCrossing
        local fwd = turtle.forward
        turtle.forward = function(...)
            if r.c.pos.x == 127 then           -- the step into chunk 8: how many answers are still unread?
                unreadAtCrossing = 0
                for _, ev in ipairs(r.c.events) do if ev[1] == "modem_message" then unreadAtCrossing = unreadAtCrossing + 1 end end
            end
            return fwd(...)
        end
        local ok = r.base.move.to(129, 60, -2829)            -- 127 is chunk 7's last column, 128 is chunk 8
        assert_eq(ok, true, "it gets there")
        assert_eq(r.c.pos.x, 129, "to 129")
        assert_eq(asks, 1, "one ask, gone on the answer from its chunk, not the first (" .. asks .. " asks)")
        assert_eq(posAtAsk[1], 127, "it asked standing in the last column of chunk 7, not past it")
        assert_eq(unreadAtCrossing, 0, "it stepped into chunk 8 only after the answer from chunk 7, not on the first")
    end,

    -- payload-e's node_221 case: its destination 160,67,-2752 is the first block of chunk 10,-172, so the cell behind
    -- it -- as close as its support can come in a one-block tunnel -- is in chunk 10,-173. Waiting for its support in
    -- its own chunk there waited for good. Its support in the cell behind it is as close as there is.
    ["a support in the cell right behind is close enough, in whatever chunk that cell is"] = function(assert_eq)
        local r = supportAt({ x = 126, y = 60, z = -2829 })
        local proto = require("protocol")
        r.base.setRoleForTest(proto.ROLE.DELIVERY)
        r.base.setPartnerId("node_s")
        assert(r.base.move.to(128, 60, -2829))             -- now in chunk 8's first column; 127, behind it, is chunk 7
        r.base.setFollowGate(true)
        local asks = 0
        peripheral.find = function()
            return { open = function() end, isOpen = function() return true end, close = function() end,
                     transmit = function(ch, rr, body)
                         local m = textutils.unserialise(body)
                         if m and m.type == proto.MSG.SUPPORT_WHERE then
                             asks = asks + 1
                             if asks > 20 then error("the delivery asked 20 times", 0) end
                             os.queueEvent("modem_message", "top", proto.CH_LOCAL, 0,
                                 proto.encode(proto.MSG.SUPPORT_HERE, "node_s", "node_retrace_test", { x = 127, y = 60, z = -2829 }), 5)
                         end
                     end }
        end
        r.base.recoverModem()
        r.base.setIdForTest("node_retrace_test")
        local ok = r.base.awaitSupportInChunk("before ascending")
        assert_eq(ok, true, "it goes on")
        assert_eq(asks, 1, "on the first answer (" .. asks .. " asks)")
    end,

    ["a delivery whose support gives up stops at the chunk's edge, and its move fails"] = function(assert_eq)
        local r = supportAt({ x = 126, y = 60, z = -2829 })
        local proto = require("protocol")
        r.base.setRoleForTest(proto.ROLE.DELIVERY)
        r.base.setPartnerId("node_s")
        r.base.setFollowGate(true)
        peripheral.find = function()
            return { open = function() end, isOpen = function() return true end, close = function() end,
                     transmit = function(ch, rr, body)
                         local m = textutils.unserialise(body)
                         if m and m.type == proto.MSG.SUPPORT_WHERE then
                             os.queueEvent("modem_message", "top", proto.CH_LOCAL, 0,
                                 proto.encode(proto.MSG.JOB_ABORT, "node_s", "node_retrace_test", { reason = "recalled" }), 5)
                             -- the wait's 1 s timer, which the stub never fires by itself (the next id it hands out)
                             os.queueEvent("timer", r.c.timerId + 1)
                         end
                     end }
        end
        r.base.recoverModem()
        r.base.setIdForTest("node_retrace_test")
        local ok = r.base.move.to(129, 60, -2829)
        assert_eq(ok, false, "the move fails")
        assert_eq(r.c.pos.x, 127, "at the last column of its chunk")
        assert_eq(r.base.getPartnerId(), nil, "and it has no support any more")
    end,

    ["without the gate on, a delivery crosses chunks without asking, as before"] = function(assert_eq)
        local r = supportAt({ x = 126, y = 60, z = -2829 })
        local proto = require("protocol")
        r.base.setRoleForTest(proto.ROLE.DELIVERY)
        r.base.setPartnerId("node_s")
        assert(r.base.move.to(129, 60, -2829))
        local asked = false
        for _, b in ipairs(r.sent) do if b:find("SUPPORT_WHERE", 1, true) then asked = true end end
        assert_eq(asked, false, "no SUPPORT_WHERE")
    end,

    ["with no cells of its delivery's to walk, a support goes where its delivery was, as before"] = function(assert_eq)
        local r = supportAt({ x = 130, y = 60, z = -2829 })
        r.base.followPartner({ prev = { x = 131, y = 60, z = -2829 } })
        assert_eq(r.c.pos.x .. "," .. r.c.pos.z, "131,-2829", "one step on")
    end,

    ["a delivery's step says the last cells it stood in"] = function(assert_eq)
        local r = supportAt(HOLE)
        local proto = require("protocol")
        r.base.setRoleForTest(proto.ROLE.DELIVERY)
        r.base.setPartnerId("node_s")
        assert(r.base.move.to(HOLE.x, 60, HOLE.z))
        local last
        for _, b in ipairs(r.sent) do if b:find("POSITION_UPDATE", 1, true) then last = b end end
        local m = textutils.unserialise(last)
        local tail = m and m.payload and m.payload.tail
        local t = tail and tail[#tail]
        assert_eq(type(tail), "table", "a tail is sent")
        assert_eq(t and (t.x .. "," .. t.y .. "," .. t.z), HOLE.x .. ",60," .. HOLE.z, "ending where the delivery now stands")
    end,

    ["a turtle that can dig keeps no trail on disk"] = function(assert_eq)
        local r = supportAt(HOLE, shutWorld())
        r.base.setCanDig(true)
        goOut(r)
        assert_eq(fs.exists("trail.dat"), false, "nothing written")
    end,

    -- T2 shakeout-payload-h: node_235's believed position jumped by (-19,-23,-29) in one step, standing still, and it
    -- then drove on that belief into the holding line's approach (10 give-ups behind it). A resync that moves a belief
    -- more than a block is not applied until a second fix agrees (Head Engineer ruling, 2026-11-24).
    ["one GPS fix far from where it stands is not taken; a second that agrees is"] = function(assert_eq)
        local r = supportAt({ x = 240, y = 60, z = -2784 })
        local fixes = { { 221, 37, -2813 }, { 240, 60, -2784 } }   -- a bad fix, then the true one
        local n = 0
        gps = { locate = function() n = n + 1; local f = fixes[math.min(n, #fixes)]; return f[1], f[2], f[3] end }
        r.base.gpsSync()
        local p = r.base.getPos()
        assert_eq(p.x .. "," .. p.y .. "," .. p.z, "240,60,-2784", "the bad fix is not taken")
        local r2 = supportAt({ x = 240, y = 60, z = -2784 })
        r2.base.setPosForTest({ x = 230, y = 60, z = -2784 })        -- its belief was wrong
        local m = 0
        gps = { locate = function() m = m + 1; return 240, 60, -2784 end }
        r2.base.gpsSync()
        local p2 = r2.base.getPos()
        assert_eq(p2.x .. "," .. p2.y .. "," .. p2.z, "240,60,-2784", "a far fix a second one agrees with is taken")
        assert_eq(m, 2, "after asking twice")
    end,

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

    -- R3, the return as a pair (2026-11-17, sim w3_side_atc): a support that lagged behind its delivery was told to
    -- hold where it was; told then to come home, it planned its own way to the holding slot -- through rock it cannot
    -- dig ("way home is shut"), 9 times a side run, and under R2 they piled up. Its delivery's own cells are dug: at
    -- the holding line the delivery sends the tail of its path, and the support walks it to the cell behind it.
    ["a support walks its delivery's own cells to the cell behind it, without digging"] = function(assert_eq)
        local world = {}
        -- Solid rock everywhere off the path: only the delivery's cells are open.
        for x = 120, 140 do for z = -2835, -2825 do world[x .. ",60," .. z] = "minecraft:stone" end end
        local path = {}
        for x = 122, 130 do path[#path + 1] = { x = x, y = 60, z = -2830 } end      -- east along -2830
        for z = -2829, -2826 do path[#path + 1] = { x = 130, y = 60, z = z } end   -- then south to -2826
        for _, c in ipairs(path) do world[c.x .. ",60," .. c.z] = nil end
        local r = supportAt({ x = 124, y = 60, z = -2830 }, world)                  -- lagging, on the path
        r.base.setPartnerId("node_d")
        local proto = require("protocol")
        local msg = proto.encode(proto.MSG.ASCENDING, "node_d", "x", { slot = 7, trail = path })
        r.base._firstSight(msg)
        local walked = r.base.walkPartnerTrail()
        local p = r.c.pos
        assert_eq(walked > 0, true, "it walked (" .. tostring(walked) .. " cells)")
        assert_eq(p.x .. "," .. p.z, "130,-2827", "to the cell behind its delivery (130,-2826)")
        assert_eq(r.dug(), 0, "without digging a block")
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

    -- 2026-11-17 (T2 shakeout-side-h, node_219): its delivery's hold notice (ASCENDING, with the trail) was lost, so
    -- the support never knew where it went; told to come home, it planned its own way to slot 11 from 6 cells off,
    -- was blocked at once and retraced 158 steps. RETURN_TO_DOCK carries the trail too, and walks it the same way.
    ["a support that heard only the come-home walks its delivery's cells from it"] = function(assert_eq)
        local world = {}
        for x = 120, 140 do for z = -2835, -2825 do world[x .. ",60," .. z] = "minecraft:stone" end end
        local path = {}
        for x = 122, 130 do path[#path + 1] = { x = x, y = 60, z = -2830 } end
        for z = -2829, -2826 do path[#path + 1] = { x = 130, y = 60, z = z } end
        for _, c in ipairs(path) do world[c.x .. ",60," .. c.z] = nil end
        local r = supportAt({ x = 124, y = 60, z = -2830 }, world)
        r.base.setPartnerId("node_d")
        local proto = require("protocol")
        r.base._firstSight(proto.encode(proto.MSG.RETURN_TO_DOCK, "node_d", "x", { slot = 7, trail = path }))
        local walked = r.base.walkPartnerTrail()
        assert_eq(walked > 0, true, "it walked (" .. tostring(walked) .. " cells)")
        assert_eq(r.c.pos.x .. "," .. r.c.pos.z, "130,-2827", "to the cell behind its delivery")
        assert_eq(r.dug(), 0, "without digging a block")
    end,
}
