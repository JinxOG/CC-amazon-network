-- The turtle's half of the base ATC (turtle_base.lua, base.atc), without an ATC.
-- docs/superpowers/specs/2026-11-03-base-atc-design.md
local stub = require("tests.stub_cc")

local function fresh()
    local c = stub.install({ pos = { x = 0, y = 67, z = 0, facing = 0 } })
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
    return base, sent
end

-- A docked turtle whose facing check the ATC refuses at boot (T2 shakeout-payload-g, 01:44: 9 docked turtles raised
-- NEEDS HANDS on the first refusal, after the restart, and were granted 3-4 s later). Hands do not help a turtle the
-- ATC holds: a refusal still standing a minute on says "atc_wait", never stuck_no_fix (Head Engineer, 2026-11-24).
local function refusedAtBoot(grantAfterNaps)
    -- bay 4 row A's dock (node_441's): in no section, N4 beside it
    local c = stub.install({ pos = { x = 197, y = 67, z = -2797, facing = 0 } })
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
    local atc = base.atc
    atc.ENABLED = true
    atc.ensure = function() return true end
    base.gpsSync()
    base.setFacingUnknownForTest()
    local naps, savedSleep, savedAsk = 0, sleep, atc.ask
    sleep = function() naps = naps + 1 end
    atc.ask = function(t, payload)
        if naps < grantAfterNaps then return { ok = false, why = "busy at S1" } end
        return { ok = true }
    end
    base.waitForPositionFix("test")
    sleep, atc.ask = savedSleep, savedAsk
    local function count(needle)
        local n = 0
        for _, b in ipairs(sent) do if b:find(needle, 1, true) then n = n + 1 end end
        return n
    end
    return count
end

-- A turtle on the return row (R3, 191,67,-2801) asks the ATC for its way home, refused every time, for 120 s of
-- wall clock (sleep moves it 3 s). Returns how many recovery_wait reports reached the server, and whether the
-- refusal's "Still waiting" log line was shipped.
local function waitInRecovery(running)
    local base, sent = fresh()
    local atc = base.atc
    atc.ENABLED = true
    atc.ensure = function() return true end
    base.setPosForTest({ x = 191, y = 67, z = -2801 })
    base.setRunningForTest(running)
    local savedAsk, savedSleep, savedEpoch, savedClock = atc.ask, sleep, os.epoch, os.clock
    local clock, calls = 5000000, 0
    os.epoch = function() return clock end
    os.clock = function() return clock / 1000 end
    atc.ask = function() return { ok = false, why = "busy at R3 (node_451)" } end
    sleep = function(s) clock = clock + 3000 end
    local ok, err = pcall(atc.book, { { x = 150, y = 67, z = -2801 } }, "route home",
        function() calls = calls + 1; return calls > 40 and "test over" or nil end)
    atc.ask, sleep, os.epoch, os.clock = savedAsk, savedSleep, savedEpoch, savedClock
    assert(ok, tostring(err))
    local n, shipped = 0, false
    for _, b in ipairs(sent) do
        if b:find("recovery_wait: ", 1, true) and b:find("STATUS_UPDATE", 1, true) then n = n + 1 end
        if b:find("Still waiting", 1, true) and b:find("LOG", 1, true) then shipped = true end
    end
    return n, shipped
end

return {
    -- T2 shakeout-payload-g (2026-11-24): the ATC admitted pair node_225 + node_221 at 02:53:05; the server then dropped
    -- out and node_221 paused on its dock ("Server unreachable -- pausing") -- a dock is in no section, so the
    -- server-down hold applied -- while its booking held DH J1 N1 W1 and every departure behind it for 10 minutes.
    -- A turtle holding an admitted booking does not pause for the server: the ATC is the authority in the base
    -- (ATC card, requirement 7), as it already is for a turtle standing in a section.
    ["a turtle holding an admitted booking does not pause on its dock while the server is down"] = function(assert_eq)
        local base = fresh()
        local atc = base.atc
        atc.ENABLED = true
        base.setPosForTest({ x = 153, y = 67, z = -2806 })        -- its dock: in no section
        base.setServerDownForTest(true)
        atc.route = { "S1", "J1", "W1", "DH" }                       -- admitted
        local savedAsk = atc.ask
        atc.ask = function() return { ok = true } end                -- the ATC lets each step in
        local naps, savedSleep = 0, sleep
        sleep = function() naps = naps + 1; if naps > 50 then error("paused for the server", 0) end end
        local ok, err = pcall(base.move.forward)
        sleep, atc.ask = savedSleep, savedAsk
        assert_eq(ok, true, "it moved (" .. tostring(err) .. ")")
        assert_eq(naps < 5, true, "without pausing (" .. naps .. " naps)")
    end,

    ["with no booking, a docked turtle still pauses while the server is down"] = function(assert_eq)
        local base = fresh()
        local atc = base.atc
        atc.ENABLED = true
        base.setPosForTest({ x = 153, y = 67, z = -2806 })
        base.setServerDownForTest(true)
        atc.route = nil
        local naps, savedSleep = 0, sleep
        sleep = function() naps = naps + 1; if naps > 10 then error("paused for the server", 0) end end
        local ok, err = pcall(base.move.forward)
        sleep = savedSleep
        assert_eq(ok, false, "it holds")
        assert_eq(tostring(err):find("paused for the server", 1, true) ~= nil, true, "for the server (" .. tostring(err) .. ")")
    end,

    -- Sim w3_side_atc on 0c1b875: working through a server outage now, node_35 finished job_0050 with the server
    -- down; its JOB_COMPLETE, sent once, was lost; the server re-linked it to the job, which stayed open for good and
    -- held its destination: two later orders there were never sent. A JOB_COMPLETE is repeated until acknowledged,
    -- as a JOB_FAILED is.
    ["a JOB_COMPLETE is repeated until the server acknowledges it"] = function(assert_eq)
        local base, sent = fresh()
        local proto = require("protocol")
        base.setStatus(proto.STATUS.WORKING, "job_0050")
        base.sendComplete({})
        local function count()
            local n = 0
            for _, b in ipairs(sent) do if b:find('type = "JOB_COMPLETE"', 1, true) or b:find('type="JOB_COMPLETE"', 1, true) then n = n + 1 end end
            return n
        end
        local first = count()
        local t0 = os.epoch("utc")
        base.keepFails(t0 + 11000)
        local again = count()
        base._firstSight(proto.encode(proto.MSG.JOB_COMPLETE_ACK, "server", "x", { jobId = "job_0050" }))
        base.keepFails(t0 + 22000)
        local after = count()
        assert_eq(first, 1, "sent once")
        assert_eq(again, 2, "sent again 10 s on, unanswered")
        assert_eq(after, 2, "and no more once acknowledged")
    end,

    -- T2 shakeout-payload-h: two physical turtles carried id 397 (a kill-restart with no save). The server tells that
    -- id PARK (duplicate_id); both copies hear it, and neither takes another step until a person has seen to it.
    ["a turtle told PARK takes no step"] = function(assert_eq)
        local base, sent = fresh()
        local proto = require("protocol")
        base._firstSight(proto.encode(proto.MSG.PARK, "server", base.getSelfId(),
            { reason = "duplicate_id: node_9 heard at 238,200,-2780 and 239,200,-2780" }))
        local naps, savedSleep = 0, sleep
        sleep = function() naps = naps + 1; if naps > 20 then error("still parked", 0) end end
        local ok, err = pcall(base.move.forward)
        sleep = savedSleep
        base.flushLogs()
        local warned = 0
        for _, b in ipairs(sent) do if b:find("PARKED: duplicate_id", 1, true) then warned = warned + 1 end end
        assert_eq(ok, false, "it did not move")
        assert_eq(tostring(err), "still parked", "it waits, parked (" .. tostring(err) .. ")")
        assert_eq(warned >= 1, true, "and says so (" .. warned .. ")")
    end,

    -- T2 shakeout-payload-i: three copies of node_215 waited 46 min in boot recovery's ATC booking loop, before base.run,
    -- and sent the server nothing -- no report, no log line: the server pruned node_215 as offline and its duplicate
    -- check never saw the copies. A wait before the control loop runs tells the server, every 20 s, and ships its log.
    ["a wait before the control loop runs reports to the server"] = function(assert_eq)
        local n, quiet = waitInRecovery(false)
        assert_eq(n >= 4, true, "it says so every 20 s (" .. n .. " reports in 120 s)")
        assert_eq(quiet, true, "and its log lines are shipped")
    end,

    ["a wait with the control loop running leaves reporting to the heartbeat"] = function(assert_eq)
        local n = waitInRecovery(true)
        assert_eq(n, 0, "no extra reports (" .. n .. ")")
    end,

    -- Sim w3_side_atc on 4d2617c (2026-11-24): node_56's support job was cancelled in a radio blackout it never heard;
    -- carrying on, it timed out and sent its old partner node_34 a JOB_ABORT. node_34, on another job with another
    -- support (node_55), took it and ended job_0041 at its destination. A JOB_ABORT from a turtle is taken only from
    -- its current partner.
    ["a JOB_ABORT from a turtle that is not its partner is not taken"] = function(assert_eq)
        local base = fresh()
        local proto = require("protocol")
        base.setPartnerId("node_55")
        base.setStatus(proto.STATUS.WORKING, "job_0041")
        local stale   = base._firstSight(proto.encode(proto.MSG.JOB_ABORT, "node_56", base.getSelfId(), { reason = "no_hole_ready_from_delivery" }))
        local partner = base._firstSight(proto.encode(proto.MSG.JOB_ABORT, "node_55", base.getSelfId(), { reason = "x" }))
        local server  = base._firstSight(proto.encode(proto.MSG.JOB_ABORT, "server", base.getSelfId(), { jobId = "job_0041" }))
        local wh      = base._firstSight(proto.encode(proto.MSG.JOB_ABORT, "warehouse", base.getSelfId(), { jobId = "job_0041" }))
        assert_eq(stale, false, "an old partner's abort is dropped")
        assert_eq(partner, true, "its partner's is taken")
        assert_eq(server, true, "the server's is taken")
        assert_eq(wh, true, "the warehouse's is taken")
    end,

    -- The Head Engineer's ruling: about its CURRENT job. The pair's job id rides a partner's abort.
    ["a JOB_ABORT about another job is not taken, from anyone"] = function(assert_eq)
        local base = fresh()
        local proto = require("protocol")
        base.setPartnerId("node_55", "job_0041")
        base.setStatus(proto.STATUS.WORKING, "job_0041")
        local function take(from, jobId)
            return base._firstSight(proto.encode(proto.MSG.JOB_ABORT, from, base.getSelfId(), { reason = "x", jobId = jobId }))
        end
        assert_eq(take("node_55", "job_0039"), false, "its partner's, about an old pair's job")
        assert_eq(take("server", "job_0039"), false, "the server's, about another job")
        assert_eq(take("node_55", "job_0041"), true, "its partner's, about this pair's job")
        assert_eq(take("server", "job_0041"), true, "the server's, about this job")
    end,

    ["a support takes its delivery's abort about the pair's job"] = function(assert_eq)
        local base = fresh()
        local proto = require("protocol")
        base.setPartnerId("node_34", "job_0041")            -- its delivery, and the delivery's job
        base.setStatus(proto.STATUS.WORKING, "job_0045")    -- its own half
        local ok = base._firstSight(proto.encode(proto.MSG.JOB_ABORT, "node_34", base.getSelfId(), { reason = "x", jobId = "job_0041" }))
        assert_eq(ok, true, "taken")
    end,

    ["a failing turtle's abort to its partner carries the pair's job id"] = function(assert_eq)
        local base, sent = fresh()
        local proto = require("protocol")
        base.setPartnerId("node_34", "job_0039")
        base.setStatus(proto.STATUS.WORKING, "job_0042")
        pcall(base.sendFailed, "no_hole_ready_from_delivery", true)
        local carried = false
        for _, b in ipairs(sent) do
            if b:find("JOB_ABORT", 1, true) and b:find("job_0039", 1, true) then carried = true end
        end
        assert_eq(carried, true, "JOB_ABORT with jobId job_0039")
    end,

    -- Sim w3_side_atc on 8cc17b2 (2026-11-24): in the 300 s radio blackout node_35 waited at a chunk's edge for its
    -- support node_54 and, 5 s before the radio came back, took it for gone and went home -- saying nothing to it.
    -- node_54, alive at the dispatch hole's foot, waited 315 s for a partner that had stopped talking to it, standing
    -- in node_35's way home (held 313 s). Taking its support for gone, a delivery calls it home, again and again.
    ["a delivery that takes its silent support for gone calls it home, repeatedly"] = function(assert_eq)
        local base, sent = fresh()
        local proto = require("protocol")
        base.setPartnerId("node_54", "job_0049")
        base.setPosForTest({ x = 128, y = 60, z = -2813 })
        local savedEpoch, savedReceive = os.epoch, base.receive
        local clock = 7000000
        os.epoch = function() return clock end
        base.receive = function() clock = clock + 1000; return nil end
        local ok, r = pcall(base.awaitSupportInChunk, "stepping into chunk 7,-176")
        local gone = #sent
        for i = 1, 3 do clock = clock + 10000; base.atc.keepPair(clock) end
        os.epoch, base.receive = savedEpoch, savedReceive
        local calls = 0
        for i, b in ipairs(sent) do
            if i > 0 and b:find("RETURN_TO_DOCK", 1, true) and b:find("node_54", 1, true) then calls = calls + 1 end
        end
        assert_eq(ok, true, tostring(r))
        assert_eq(r, false, "it went on without its support")
        assert_eq(calls >= 3, true, "and called it home, and again (" .. calls .. " RETURN_TO_DOCK)")
    end,

    ["a parked turtle told UNPARK moves again"] = function(assert_eq)
        local base = fresh()
        local proto = require("protocol")
        base._firstSight(proto.encode(proto.MSG.PARK, "server", base.getSelfId(), { reason = "duplicate_id: x" }))
        base._firstSight(proto.encode(proto.MSG.UNPARK, "server", base.getSelfId(), {}))
        local naps, savedSleep = 0, sleep
        sleep = function() naps = naps + 1; if naps > 20 then error("still parked", 0) end end
        local ok, err = pcall(base.move.forward)
        sleep = savedSleep
        assert_eq(ok, true, "it moves (" .. tostring(err) .. ")")
    end,

    -- T2 shakeout-payload-j (f32b0dd, 2026-11-24): 239 "Server unreachable -- pausing" in the climb shaft (143,68-210,
    -- -2813) by 34 miners; 11 ended stacked at 143,98-108, each blocked by the one above, 53 give-ups. Inside a
    -- single-wide shared column a turtle never pauses for the server: it finishes the traversal (Head Engineer, from
    -- the user's rule -- logic, not a timer).
    ["a turtle in the dispatch hole's column does not pause for the server"] = function(assert_eq)
        local base = fresh()
        base.setPosForTest({ x = 143, y = 105, z = -2813 })
        base.setServerDownForTest(true)
        local naps, savedSleep = 0, sleep
        sleep = function() naps = naps + 1; if naps > 10 then error("paused for the server", 0) end end
        local ok, err = pcall(base.move.up)
        sleep = savedSleep
        assert_eq(ok, true, "it moved (" .. tostring(err) .. ")")
        assert_eq(naps < 3, true, "without pausing (" .. naps .. " naps)")
    end,

    ["a turtle in the arrivals hole's column does not pause for the server"] = function(assert_eq)
        local base = fresh()
        base.setPosForTest({ x = 228, y = 120, z = -2782 })
        base.setServerDownForTest(true)
        local naps, savedSleep = 0, sleep
        sleep = function() naps = naps + 1; if naps > 10 then error("paused for the server", 0) end end
        local ok, err = pcall(base.move.down)
        sleep = savedSleep
        assert_eq(ok, true, "it moved (" .. tostring(err) .. ")")
    end,

    ["out of the columns, a turtle still pauses for the server"] = function(assert_eq)
        local base = fresh()
        base.setPosForTest({ x = 144, y = 105, z = -2813 })
        base.setServerDownForTest(true)
        local naps, savedSleep = 0, sleep
        sleep = function() naps = naps + 1; if naps > 10 then error("paused for the server", 0) end end
        local ok, err = pcall(base.move.up)
        sleep = savedSleep
        assert_eq(ok, false, "it holds")
        assert_eq(tostring(err), "paused for the server", "for the server (" .. tostring(err) .. ")")
    end,

    -- T2 w3-duplicate-id-a (2026-11-24): a homing delivery went through the cell where the ATC computer stood, and the
    -- ATC went silent from that moment; the dig guard refused only turtles. A turtle never digs a ComputerCraft block
    -- (a computer, a monitor, a modem, a disk drive): the ATC, a GPS host, the server (Head Engineer ruling).
    ["a turtle never digs a computer in its way"] = function(assert_eq)
        local c = stub.install({ pos = { x = 0, y = 70, z = 0, facing = 0 },
            world = { ["0,70,-1"] = "computercraft:computer_advanced" },
            equipped = { left = "minecraft:diamond_pickaxe" } })
        gps = { locate = function() return c.pos.x, c.pos.y, c.pos.z end }
        package.loaded["turtle_base"] = nil
        package.loaded["geofence"] = nil
        local base = require("turtle_base")
        base.setCanDig(true)
        local savedSleep = sleep
        sleep = function() end
        local ok, moved, why = pcall(base.move.forward)
        sleep = savedSleep
        assert_eq(ok, true, tostring(moved))
        assert_eq(moved, false, "it did not go through")
        assert_eq(tostring(why):find("would_dig_computer", 1, true) ~= nil, true, "and says why (" .. tostring(why) .. ")")
        assert_eq(c.world["0,70,-1"], "computercraft:computer_advanced", "the computer is still there")
    end,

    -- W1's point (2026-11-24): a guard is only as good as the digs that go through it. The vertical bypass's advance
    -- called turtle.dig() itself after checking only for a turtle, so it would have dug a computer. No navigation dig in
    -- turtle_base calls turtle.dig/digUp/digDown directly: every one goes through digGuarded (or tryMove's guarded branch).
    ["no direct turtle.dig() call in turtle_base: every dig is guarded"] = function(assert_eq)
        local f = io.open("turtle_base.lua", "r")
        local src = f:read("a"); f:close()
        local raw = {}
        local n = 0
        for line in (src .. "\n"):gmatch("([^\n]*)\n") do
            n = n + 1
            local code = line:gsub("%-%-.*$", "")
            if code:find("turtle%.dig%a*%s*%(") then raw[#raw + 1] = n end
        end
        assert_eq(#raw, 0, "direct dig calls at line(s) " .. table.concat(raw, ", "))
    end,

    ["a turtle still digs stone in its way"] = function(assert_eq)
        local c = stub.install({ pos = { x = 0, y = 70, z = 0, facing = 0 },
            world = { ["0,70,-1"] = "minecraft:stone" },
            equipped = { left = "minecraft:diamond_pickaxe" } })
        gps = { locate = function() return c.pos.x, c.pos.y, c.pos.z end }
        package.loaded["turtle_base"] = nil
        package.loaded["geofence"] = nil
        local base = require("turtle_base")
        base.setCanDig(true)
        local savedSleep = sleep
        sleep = function() end
        local ok, moved = pcall(base.move.forward)
        sleep = savedSleep
        assert_eq(ok and moved, true, "it dug through and moved (" .. tostring(moved) .. ")")
    end,

    ["a turtle not told PARK moves"] = function(assert_eq)
        local base = fresh()
        local proto = require("protocol")
        base._firstSight(proto.encode(proto.MSG.PARK, "node_fake", base.getSelfId(), { reason = "x" }))
        local naps, savedSleep = 0, sleep
        sleep = function() naps = naps + 1; if naps > 20 then error("still parked", 0) end end
        local ok, err = pcall(base.move.forward)
        sleep = savedSleep
        assert_eq(ok, true, "a PARK from anyone but the server is ignored (" .. tostring(err) .. ")")
    end,

    ["a refusal from the ATC at boot that clears in seconds raises nothing"] = function(assert_eq)
        local count = refusedAtBoot(2)
        assert_eq(count("stuck_no_fix"), 0, "no stuck_no_fix")
        assert_eq(count("atc_wait"), 0, "and no atc_wait")
    end,

    ["a refusal from the ATC still standing a minute on says atc_wait, never stuck_no_fix"] = function(assert_eq)
        local count = refusedAtBoot(14)
        assert_eq(count("stuck_no_fix"), 0, "no stuck_no_fix: hands do not help a turtle the ATC holds")
        assert_eq(count("atc_wait: facing unknown at 197,67,-2797 (waiting for the ATC to grant the cells around it: busy at S1)") >= 1,
            true, "atc_wait, with where and the ATC's why (" .. count("atc_wait") .. ")")
        assert_eq(count("measured:"), 1, "and that it measured, once it could")
    end,

    -- 15 docked turtles in the 150-turtle boot rush (sim, 2026-11-03) were marked STUCK while they waited, and
    -- stayed ERROR -- which the server never dispatches -- after they were moving again.
    ["a turtle that reported STUCK goes back to its status once it moves again"] = function(assert_eq)
        local base, sent = fresh()
        local proto = require("protocol")
        base.setStatus(proto.STATUS.IDLE)
        base.atc.stallAt = os.clock() - base.atc.STUCK_S - 1
        base.atc.stalled("a test")
        assert_eq(base.statusForTest(), proto.STATUS.ERROR, "stuck past the bound: ERROR, so it is not dispatched")
        base.atc.progressed()
        assert_eq(base.statusForTest(), proto.STATUS.IDLE, "moving again: back to IDLE")
        local said = false
        for _, b in ipairs(sent) do if b:find("moving again", 1, true) then said = true end end
        assert_eq(said, true, "and the server is told")
    end,

    -- The 150-turtle week (sim 20261104-183352, 2026-09-23 06:52): a delivery aborted outside the depot went straight
    -- to holding slot 11, digging; its support, which cannot dig, lagged on the tunnel row at 160,60,-2813 when the
    -- delivery said "hold", was given slot 12 in turn -- through rock -- and was stranded in the departure tunnel.
    -- Every later departure piled up behind it: 105 deliveries waiting by hour 105.
    ["a support left behind on its delivery's path asks for its delivery's slot"] = function(assert_eq)
        local base, sent = fresh()
        local proto = require("protocol")
        base.setPartnerId("node_3060")
        local off = { x = 160, y = 60, z = -2813 }            -- on the tunnel row, in no slot's column
        local before = base.atc.preferSlot(off)
        local msg = proto.encode(proto.MSG.ASCENDING, "node_3060", "broadcast", { slot = 11 })
        os.queueEvent("modem_message", "top", 1, 1, msg, 5)
        base.receive(5)
        assert_eq(before, nil, "nothing to go on before the delivery says where it is")
        assert_eq(base.atc.preferSlot(off), 11, "the delivery's slot: the way there is the path it dug")
        base.setPartnerId("node_9")
        assert_eq(base.atc.preferSlot(off), nil, "a new partner forgets the last one's slot")
    end,

    ["a slot named by some other turtle is ignored"] = function(assert_eq)
        local base = fresh()
        local proto = require("protocol")
        base.setPartnerId("node_3060")
        local msg = proto.encode(proto.MSG.RETURN_TO_DOCK, "node_77", "broadcast", { slot = 4 })
        os.queueEvent("modem_message", "top", 1, 1, msg, 5)
        base.receive(5)
        assert_eq(base.atc.preferSlot({ x = 160, y = 60, z = -2813 }), nil)
    end,

    ["the delivery's hold and come-home signals carry its slot"] = function(assert_eq)
        local base, sent = fresh()
        local proto = require("protocol")
        base.atc.signalSupport(proto.MSG.ASCENDING, "node_93", 11)
        local body = sent[#sent] or ""
        assert_eq(body:find("ASCENDING", 1, true) ~= nil, true, "the signal went out (" .. body:sub(1, 80) .. ")")
        assert_eq(body:find("slot = 11", 1, true) ~= nil, true, "with the slot in it")
    end,

    -- The shakeout's per-bay 150 sim (w3_bay_types150, 2026-11-11): a delivery gave up waiting for its support and
    -- went down alone; the support went down after it anyway, ended at "Delivery ascending - holding position" and
    -- held the dispatch hole (DH) for the rest of the run. A support whose delivery has left must stand down.
    ["a support told its delivery has left gives up waiting to be let in"] = function(assert_eq)
        local c = stub.install({ pos = { x = 158, y = 67, z = -2806, facing = 0 } })
        gps = { locate = function() return c.pos.x, c.pos.y, c.pos.z end }
        package.loaded["turtle_base"] = nil
        package.loaded["geofence"] = nil
        local base = require("turtle_base")
        local proto = require("protocol")
        sleep = function() end
        base.initPositionForTest()
        base.setPartnerId("node_37")
        local asked = 0
        base.atc.ensure = function() return true end
        base.atc.ask = function()
            asked = asked + 1
            if asked > 50 then error("never gave up", 0) end
            if asked == 3 then
                os.queueEvent("modem_message", "top", 1, 1,
                    proto.encode(proto.MSG.PARTNER_LEFT, "node_37", "broadcast", {}), 5)
                base.receive(1)
            end
            return { ok = false, why = "after an older request" }
        end
        local ok, why = base.atc.book({ { x = 158, y = 67, z = -2811 }, { x = 143, y = 67, z = -2811 } }, "departure",
            function() return base.partnerLeft() and "partner_left" end)
        assert_eq(ok, false, "it gave up once its delivery said it had left")
        assert_eq(tostring(why):find("partner_left", 1, true) ~= nil, true, tostring(why))
        assert_eq(asked <= 4, true, "and promptly (" .. asked .. " asks)")
        base.setPartnerId("node_9")
        assert_eq(base.partnerLeft(), false, "a new partner starts with a clean slate")
    end,

    ["a word from some other turtle that it left does not stand a support down"] = function(assert_eq)
        local base = fresh()
        local proto = require("protocol")
        base.setPartnerId("node_37")
        os.queueEvent("modem_message", "top", 1, 1, proto.encode(proto.MSG.PARTNER_LEFT, "node_77", "broadcast", {}), 5)
        base.receive(1)
        assert_eq(base.partnerLeft(), false)
    end,

    ["a stall under the bound reports nothing"] = function(assert_eq)
        local base = fresh()
        local proto = require("protocol")
        base.setStatus(proto.STATUS.IDLE)
        base.atc.stallAt = os.clock() - 10
        base.atc.stalled("a short wait")
        assert_eq(base.statusForTest(), proto.STATUS.IDLE)
    end,

    -- 2026-11-16 (sim w3_side_atc on 17d6b30): a support back in the building by the way it came stood in the dispatch
    -- corner waiting, with no GPS, to measure its facing -- and said nothing to the ATC. At 183 s the ATC took it for
    -- dead and let its section go; a delivery was let into the next one, and the two met head-on, each in the section
    -- the other needed. In side test d the support blocked by its delivery went silent the same way (181 s).
    ["a turtle waiting in the base to measure its facing keeps telling the ATC where it stands"] = function(assert_eq)
        local c = stub.install({ pos = { x = 143, y = 67, z = -2810, facing = 0 } })
        local fixes = 0
        gps = { locate = function() fixes = fixes + 1; if fixes == 1 then return c.pos.x, c.pos.y, c.pos.z end end }
        package.loaded["turtle_base"] = nil
        package.loaded["geofence"] = nil
        local base = require("turtle_base")
        local sent = {}
        peripheral.find = function()
            return { transmit = function(ch, rr, body) sent[#sent + 1] = tostring(body) end,
                     open = function() end, isOpen = function() return true end, close = function() end }
        end
        base.recoverModem()
        base.gpsSync()
        base.atc.ENABLED = true
        local savedEpoch, savedSleep, now, sleeps = os.epoch, sleep, 1700000000000, 0
        os.epoch = function() return now end
        sleep = function(s) now = now + math.floor((s or 0) * 1000); sleeps = sleeps + 1
            if sleeps > 40 then error("__enough__", 0) end end
        local here = base.atc.here()
        local ok, err = pcall(base.waitForPositionFix, "a test")
        os.epoch, sleep = savedEpoch, savedSleep
        local reports = 0
        for _, b in ipairs(sent) do if b:find("ATC_REPORT", 1, true) then reports = reports + 1 end end
        local waited = (now - 1700000000000) / 1000
        assert_eq(here ~= nil, true, "it stands in a section of the base (the case under test)")
        assert_eq(ok == false and err == "__enough__", true, "it was still waiting when the test stopped it (" .. tostring(err) .. ")")
        assert_eq(reports >= math.floor(waited / 60), true, string.format("an ATC_REPORT at least once a minute (%d in %d s)", reports, waited))
    end,

    -- 2026-11-17 (T2 w3-pair-dropout-b): a blackout lost node_96's HOLE_READY; its support gave up and node_96 turned
    -- for home from the hole -- asking the ATC still as half of the pair (atc.pair was never cleared). The ATC lets a
    -- pair in only when both halves ask, so it waited "homing inside the base ... (waiting for partner)" for good,
    -- holding DH. The pair tag is for ONE admission: the next request is the turtle's alone.
    ["a request made as half of a pair does not make the next one a pair's"] = function(assert_eq)
        local base = fresh()
        local asks = {}
        base.atc.ensure = function() return true end
        base.atc.ask = function(_, payload) asks[#asks + 1] = payload; return { ok = true } end
        base.atc.pair = "node_94"
        base.atc.book({ { x = 158, y = 67, z = -2811 }, { x = 143, y = 67, z = -2811 } }, "departure")
        base.atc.book({ { x = 143, y = 67, z = -2811 }, { x = 158, y = 67, z = -2811 } }, "homing")
        assert_eq(asks[1] and asks[1].pair, "node_94", "the departure asked as half of the pair")
        assert_eq(asks[2] and asks[2].pair, nil, "the way home after it is its own (" .. tostring(asks[2] and asks[2].pair) .. ")")
    end,

    -- 2026-11-17 (sim w3_side_atc): node_31 waited at the dispatch hole for SUPPORT_STAGED and said nothing to the ATC;
    -- at 180 s it was taken for dead, DH "it had entered" was dropped, and the next pair was let into the hole it stood
    -- in -- a head-on in the dispatch corner that held the base for 4 h. Standing in the base, or holding a booking, a
    -- turtle's control loop tells the ATC it is there (atc.keepInBase), whatever else it is waiting for.
    ["a turtle standing in the base tells the ATC it is there, whatever it waits for; a docked one says nothing"] = function(assert_eq)
        local base, sent = fresh()
        local atc = base.atc
        atc.ENABLED = true
        base.setPosForTest({ x = 143, y = 67, z = -2813 })        -- the dispatch hole: DH
        local function reports()
            local n = 0
            for _, b in ipairs(sent) do if b:find("ATC_REPORT", 1, true) then n = n + 1 end end
            return n
        end
        atc.aliveAt = nil
        atc.route = nil
        atc.keepInBase()
        local inHole = reports()
        for k in pairs(sent) do sent[k] = nil end
        base.setPosForTest({ x = 153, y = 67, z = -2806 })        -- its dock: in no section
        atc.aliveAt, atc.route = nil, nil
        atc.keepInBase()
        local docked = reports()
        assert_eq(inHole, 1, "standing in DH: it says it is there")
        assert_eq(docked, 0, "on its dock with nothing booked: nothing to say")
    end,

    -- The card "A turtle that handed its job back on STUCK carries on with the job when it can move again" (sim
    -- w3_side_atc, 2026-11-14 and 2026-11-17). Blocked in the base, node_36 said STUCK and handed job_0035 back -- and
    -- went on waiting to move forward, for a job that was no longer its own, telling its support "still coming" for
    -- 4 h. Its job handed back, a turtle in the base gives way: the trip ends here, and it goes home.
    ["a turtle that handed its job back while blocked in the base gives way instead of waiting on for it"] = function(assert_eq)
        local c = stub.install({ pos = { x = 150, y = 67, z = -2803, facing = 1 },
            world = { ["151,67,-2803"] = "computercraft:turtle_normal" } })     -- W1, a turtle ahead in the lane
        gps = { locate = function() return c.pos.x, c.pos.y, c.pos.z end }
        package.loaded["turtle_base"] = nil
        package.loaded["geofence"] = nil
        local base = require("turtle_base")
        peripheral.find = function()
            return { transmit = function() end, open = function() end, isOpen = function() return true end, close = function() end }
        end
        base.recoverModem()
        local proto = require("protocol")
        local savedSleep = sleep
        local tries = 0
        sleep = function() tries = tries + 1; if tries > 200 then error("never gave way", 0) end end
        base.setPosForTest({ x = 150, y = 67, z = -2803 })
        base.setStatus(proto.STATUS.TRAVELLING, "job_0035")
        base.atc.ENABLED = true
        base.atc.stallAt = os.clock() - base.atc.STUCK_S - 1     -- blocked long enough: the stuck rule fires now
        local ok, moved, why = pcall(base.move.forward)
        sleep = savedSleep
        assert_eq(ok, true, "it did not wait on for ever (" .. tostring(moved) .. ")")
        assert_eq(moved, false, "it did not move")
        assert_eq(tostring(why):find("handed", 1, true) ~= nil, true, "and says why: " .. tostring(why))
    end,

    -- T2 shakeout-payload-d, 2026-11-23: node_218, on its dock at 159,67,-2806 after the world restart, was let out
    -- (S1 J1 W1 DH), found a turtle in front of it, said STUCK and gave way -- and kept S1, the section beside its dock,
    -- 45 min to the end: nothing gave the booking back, it never stepped into the base to step out of it, and its
    -- keep-alives held it. A step from outside the base that ends in giving way gives back what it was let into.
    ["a turtle on its dock that gives way before its first step gives its booking back, and says it is out"] = function(assert_eq)
        local c = stub.install({ pos = { x = 159, y = 67, z = -2806, facing = 0 },
            world = { ["159,67,-2807"] = "computercraft:turtle_normal" } })     -- S1, a turtle in front of the dock
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
        local proto = require("protocol")
        local savedSleep = sleep
        local tries = 0
        sleep = function() tries = tries + 1; if tries > 200 then error("never gave way", 0) end end
        base.gpsSync()                                             -- a measured position
        base.setPosForTest({ x = 159, y = 67, z = -2806 })
        base.setStatus(proto.STATUS.TRAVELLING, "job_0359")
        base.atc.ENABLED = true
        local savedAsk = base.atc.ask
        base.atc.ask = function() return { ok = true } end                    -- let into S1
        base.atc.route = { "S1", "J1", "W1", "DH" }
        base.atc.stallAt = os.clock() - base.atc.STUCK_S - 1
        local ok, moved = pcall(base.move.forward)
        sleep = savedSleep
        base.atc.ask = savedAsk
        local function count(what)
            local n = 0
            for _, b in ipairs(sent) do if b:find(what, 1, true) then n = n + 1 end end
            return n
        end
        local cancels = count("ATC_CANCEL")
        local route = base.atc.route
        local outs0 = count("ATC_REPORT")
        base.atc.aliveAt = nil
        base.atc.keepInBase()
        local outs = count("ATC_REPORT") - outs0
        assert_eq(ok and moved == false, true, "it gave way and did not move (" .. tostring(moved) .. ")")
        assert_eq(cancels >= 1, true, "it gives its booking back (" .. cancels .. " ATC_CANCEL)")
        assert_eq(route, nil, "and holds no route")
        assert_eq(outs, 1, "and says it is out, in case the cancel is lost")
    end,

    -- 2026-11-17 (sim w3_side_atc): node_56 dropped out of its pair in a blackout; the server called the pair off and
    -- told node_36 ONCE, and the blackout lost it. node_36 waited 39 min on its dock to be let out with a support that
    -- had a new job, then went to the hole alone and waited 600 s for it ("never staged"). Waiting to be let out with
    -- its support, a delivery asks the server whether its pair is still on (PAIR_ASK, every 10 s): the answer is
    -- PAIR_CANCEL when it is not, so one lost word is asked again.
    ["a delivery waiting on its dock asks whether its pair is still on, and stops when told it is off"] = function(assert_eq)
        local base, sent = fresh()
        local proto = require("protocol")
        base.setRoleForTest(proto.ROLE.DELIVERY)
        base.setStatus(proto.STATUS.TRAVELLING, "job_0035")
        base.setPartnerId("node_56")
        local function asks()
            local n = 0
            for _, b in ipairs(sent) do if b:find("PAIR_ASK", 1, true) then n = n + 1 end end
            return n
        end
        local first = base.atc.pairStillOn()
        local again = base.atc.pairStillOn()
        local askedOnce = asks()
        os.queueEvent("modem_message", "top", 1, 1, proto.encode(proto.MSG.PAIR_CANCEL, "server", "broadcast", { jobId = "job_0035" }), 5)
        pcall(base.receive, 1)     -- noted on sight; the receive then waits for more
        local after = base.atc.pairStillOn()
        assert_eq(first, nil, "nothing heard yet: it waits on")
        assert_eq(again, nil)
        assert_eq(askedOnce, 1, "it asked, and not again within 10 s")
        assert_eq(after, "pair_cancelled", "told the pair is off: it stops waiting")
    end,

    -- 2026-11-17 (T2 shakeout-side-h, node_211 and node_219): at its holding slot a delivery sent its support the hold
    -- notice (ASCENDING: its slot and its path) ONCE; lost, the support stood 8.5 min in another pair's path, not
    -- knowing where its delivery went. The notice is repeated every 10 s while the delivery holds, as R3 repeats the
    -- come-home, and the come-home (which carries the path too) replaces it.
    ["a delivery in its holding slot repeats its hold notice until it calls its support home"] = function(assert_eq)
        local base, sent = fresh()
        local proto = require("protocol")
        base.setRoleForTest(proto.ROLE.DELIVERY)
        base.setStatus(proto.STATUS.TRAVELLING, "job_0229")
        local trail = { { x = 226, y = 60, z = -2783 }, { x = 226, y = 60, z = -2782 } }
        local function count(kind)
            local n, withTrail = 0, 0
            for _, b in ipairs(sent) do
                if b:find(kind, 1, true) then n = n + 1; if b:find("trail", 1, true) and b:find("2782", 1, true) then withTrail = withTrail + 1 end end
            end
            return n, withTrail
        end
        local t0 = os.epoch("utc")
        base.atc.startHoldNotice("node_219", 11, trail)
        local firstAsc = count("ASCENDING")
        base.atc.keepPair(t0 + 11000)
        base.atc.keepPair(t0 + 22000)
        local asc, ascTrail = count("ASCENDING")
        base.atc.callSupportHome("node_219", 11)
        base.atc.keepPair(t0 + 40000)
        local asc2 = count("ASCENDING")
        local home, homeTrail = count("RETURN_TO_DOCK")
        assert_eq(firstAsc, 1, "the notice is sent at once")
        assert_eq(asc, 3, "and again every 10 s while it holds")
        assert_eq(ascTrail, 3, "each naming its path")
        assert_eq(asc2, 3, "called home: the hold notice stops")
        assert_eq(home >= 1 and homeTrail == home, true, "and the come-home carries its path (" .. home .. "/" .. homeTrail .. ")")
    end,

    -- 2026-11-17 (T2 shakeout-side-h, node_217 at 21:43:52): standing behind its delivery's slot, it asked for that slot
    -- while the ATC computer was down -- "no answer from the ATC" for 120 s -- and its 120 s bound took it for a refusal:
    -- it retraced 192 steps the long way round. A silent ATC is a pause, not a refusal: only refusals count.
    ["a support waiting for its slot counts only the ATC's refusals, not its silence"] = function(assert_eq)
        local base = fresh()
        local atc = base.atc
        local savedClock, savedSleep = os.clock, sleep
        local t = 0
        os.clock = function() return t end
        sleep = function(sec) t = t + (sec or 0) end
        local asks = 0
        atc.ask = function() asks = asks + 1; if asks <= 100 then return nil end; return { ok = true, slot = 6 } end
        local gotAfterSilence = atc.holdSlot("tunnel", 6, 120)
        t, asks = 0, 0
        atc.ask = function() asks = asks + 1; if asks > 500 then error("never gave up", 0) end; return { ok = false, why = "slot 6 is node_9's" } end
        local refused = atc.holdSlot("tunnel", 6, 120)
        local tRefused = t
        os.clock, sleep = savedClock, savedSleep
        assert_eq(gotAfterSilence, 6, "300 s of silence, then the ATC answers: it gets its slot")
        assert_eq(refused, nil, "refused 120 s: it gives up as before")
        assert_eq(tRefused >= 120 and tRefused < 130, true, "after about 120 s of refusals (" .. tRefused .. ")")
    end,

    -- 2026-11-18 (T2 shakeout-24h-b): miner node_481 rebooted at 04:16 while the server was deaf. A turtle learned its
    -- dock only from REGISTER_ACK and kept it nowhere, so it flew home not knowing where home was, logged "No dock
    -- assigned, staying put" in the arrivals column at 228,200,-2782 -- and held ARR 38 min. A turtle keeps the dock it
    -- was given (dock.dat) and starts from it after a reboot; the server's next assignment replaces it.
    ["a turtle keeps its dock on disk and knows it again after a reboot, before it registers"] = function(assert_eq)
        local base = fresh()
        base.saveDock({ x = 214, y = 67, z = -2797, bay = 5, row = "A" })
        package.loaded["turtle_base"] = nil
        local again = require("turtle_base")
        local loaded = again.loadSavedDock()
        local d = again.getDock()
        assert_eq(loaded, true, "the saved dock is read back")
        assert_eq(d and (d.x .. "," .. d.z .. " bay " .. d.bay .. d.row), "214,-2797 bay 5A", "the same dock")
        local f = assert(io.open("turtle_base.lua", "r")); local src = f:read("*a"); f:close()
        local initAt = src:find("function base.init(", 1, true)
        local loadAt = src:find("loadSavedDock()", initAt, true)
        local regAt = src:find("register(role", initAt, true)
        assert_eq(loadAt ~= nil and regAt ~= nil and loadAt < regAt, true, "base.init reads it before it registers and homes")
    end,

    -- 2026-11-18 (SPEC-OWNER's ruling; sim w3_depart_off_dock): a JOB_FAILED sent once was lost and the job never came
    -- back. A turtle repeats its JOB_FAILED every 10 s until the server's JOB_FAILED_ACK for it arrives.
    ["a JOB_FAILED is repeated until the server acknowledges it"] = function(assert_eq)
        local base, sent = fresh()
        local proto = require("protocol")
        local function fails()
            local n = 0
            for _, b in ipairs(sent) do if b:find("JOB_FAILED", 1, true) and not b:find("JOB_FAILED_ACK", 1, true) then n = n + 1 end end
            return n
        end
        local t0 = os.epoch("utc")
        local failId = base.reportFailed("job_0010", "warehouse_chest_timeout", true)
        local first = fails()
        base.keepFails(t0 + 5000)
        local early = fails()
        base.keepFails(t0 + 11000)
        local again = fails()
        os.queueEvent("modem_message", "top", 1, 1, proto.encode(proto.MSG.JOB_FAILED_ACK, "server", "broadcast",
            { jobId = "job_0010", failId = failId }), 5)
        pcall(base.receive, 1)
        base.keepFails(t0 + 30000)
        local after = fails()
        assert_eq(first, 1, "sent at once")
        assert_eq(early, 1, "not again within 10 s")
        assert_eq(again, 2, "again after 10 s")
        assert_eq(after, 2, "acknowledged: no more")
    end,

    -- 2026-11-17 (T2 shakeout-side-h, s002): out of the base into the tunnel, node_215's ATC_LEAVE for DH was lost and
    -- DH stayed booked, empty, until the 180 s sweep. Having stepped out of the base, a turtle says so (a report with
    -- out) every 10 s for a while, so the first one heard lets its booking go; asking for a new route ends that.
    ["a turtle that stepped out of the base says so until it asks for a new route"] = function(assert_eq)
        local base, sent = fresh()
        local atc = base.atc
        atc.ENABLED = true
        base.gpsSync()                                             -- a measured position
        base.setPosForTest({ x = 144, y = 60, z = -2813 })        -- the tunnel, one block past the shaft's foot
        local function outs()
            local n = 0
            for _, b in ipairs(sent) do if b:find("ATC_REPORT", 1, true) and b:find("out", 1, true) then n = n + 1 end end
            return n
        end
        atc.route, atc.aliveAt = nil, nil
        atc.steppedOut()
        atc.keepInBase()
        local first = outs()
        atc.ask = function() return { ok = true } end
        atc.book({ { x = 144, y = 60, z = -2813 } }, "anything")
        atc.route, atc.aliveAt = nil, nil
        atc.keepInBase()
        assert_eq(first, 1, "out of the base: it says so")
        assert_eq(outs(), 1, "asking for a new route ends it")
    end,

    -- 2026-11-18 (T2 shakeout-payload-c): node_453's release of the sections it claimed to measure its facing was one
    -- ATC_LEAVE, lost; the claim stood for good. Having let them go, a turtle says it is out, as after stepping out of
    -- the base -- but not while it still holds them to measure.
    ["after releasing what it claimed to measure its facing, a turtle says it is out; not while it holds them"] = function(assert_eq)
        local base, sent = fresh()
        local atc = base.atc
        atc.ENABLED = true
        base.gpsSync()
        base.setPosForTest({ x = 153, y = 67, z = -2797 })        -- on a dock: in no section
        local function outs()
            local n = 0
            for _, b in ipairs(sent) do if b:find("ATC_REPORT", 1, true) and b:find("out", 1, true) then n = n + 1 end end
            return n
        end
        atc.route, atc.aliveAt, atc.owesUntil = nil, nil, nil
        atc.claiming = true
        atc.keepInBase()
        local holding = outs()
        atc.releaseAround({ "N1" })
        atc.aliveAt = nil
        atc.keepInBase()
        assert_eq(holding, 0, "while it holds what it claimed: no 'out'")
        assert_eq(outs(), 1, "released: it says it is out")
    end,
}
