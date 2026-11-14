-- W3, the card "SHAKEOUT blocker - 1x side test: the base gridlocks at the ATC after an ATC crash and after radio loss"
-- (2026-11-14), the side test's ATC faults on the small fleet in the sim. T2 shakeout-side-a ended with 10 of 20 turtles
-- stuck: the base gridlocked after its ATC crash and again after its radio loss, both times behind a turtle that had
-- been given a job back away from its dock (sandbox/scenarios/w3_depart_off_dock.lua is that mechanism on its own).
--
-- Here: the small fleet with the ATC, deliveries ordered three at a time to four destinations (one of them the side
-- test's, south of the base) and one mine job; then, as in the side test, an ATC crash (down 2 min), a radio loss at
-- 50% (5 min) and a total radio blackout (5 min), 20 minutes apart; then the orders stop and the base drains.
-- CHECKS (each with its evidence count): the faults fired; every delivery ordered completed; nobody waited over 900 s
-- to be let in, or was held by a turtle over 300 s, after the last fault; nobody reported STUCK after it; at the end
-- the ATC holds no section and every turtle is on a dock.
local DESTS = { { x = 118, z = -2830 }, { x = 124, z = -2830 }, { x = 196, z = -2761 }, { x = 130, z = -2830 } }

return {
  world = "synthetic",
  seed = 1,
  miners = 1,
  atc = true,
  preset_docks = true,
  steps = function(sim)
    local done = sim:capture_log("Job complete: job_")
    local dispatched = sim:capture_log("Dispatched job_")
    local stuck = sim:capture_log("STUCK ")
    local waits = sim:capture_log("Still waiting")
    local summary = sim:capture_log("section(s) held")
    local online = sim:capture_log("ATC online")
    local offDock = sim:capture_log("going home first")
    sim:storage_set("minecraft:cobblestone", 1000000)
    sim:storage_set("minecraft:chest", 100000)
    sim:run_for(180000)
    sim:dispatch{ type = "ORDER_MINE", params = { x1 = 512, z1 = -2176, x2 = 512, z2 = -2176, minerCount = 1 } }

    local ordered, nextDest = 0, 0
    local function order()
      local d = DESTS[nextDest % #DESTS + 1]
      nextDest = nextDest + 1
      sim:dispatch{ type = "ORDER_DELIVERY", params = { items = { { name = "minecraft:cobblestone", count = 33 } },
        destination = { x = d.x, y = 67, z = d.z } } }
      ordered = ordered + 1
      sim:run_for(2)
    end
    local function deliveriesDone()
      local deliver, n = {}, 0
      for _, l in ipairs(dispatched.lines) do
        local j = l:match("Dispatched (job_%d+) %[DELIVER%]")
        if j then deliver[j] = true end
      end
      local seen = {}
      for _, l in ipairs(done.lines) do
        local j = l:match("Job complete: (job_%d+)")
        if j and deliver[j] and not seen[j] then seen[j] = true; n = n + 1 end
      end
      return n
    end
    local function feed(minutes)
      for _ = 1, minutes do
        while ordered - deliveriesDone() < 3 do order() end
        sim:run_for(60000)
      end
    end

    local t = function() return sim.clock:now() - sim.t0 end
    feed(20)
    local onlineBefore = #online.lines
    sim:atc_crash(t() + 1000, 120000)                 -- the ATC down 2 minutes
    feed(20)
    sim:radio_loss(t() + 1000, 5 * 60000, 0.5)        -- a radio loss burst
    feed(20)
    sim:radio_loss(t() + 1000, 5 * 60000, 1.0)        -- a total radio blackout
    feed(10)
    local waitsFrom, stuckFrom = #waits.lines, #stuck.lines   -- from here on: after the last fault
    feed(30)
    local afterMs = t()
    -- drain: no more orders
    sim:run_until(function() return deliveriesDone() >= ordered end, 3 * 3600000)
    sim:run_for(20 * 60000)

    sim:expect(#online.lines > onlineBefore, "the ATC came back after its crash (" .. #online.lines .. " 'ATC online')")
    sim:expect(deliveriesDone() >= ordered, string.format("every delivery ordered completed (%d of %d)", deliveriesDone(), ordered))
    local worstLet, worstHeld = 0, 0
    for i = waitsFrom + 1, #waits.lines do
      local l = waits.lines[i]
      local s = tonumber(l:match("Still waiting (%d+)s")) or 0
      do
        if l:find("ATC:", 1, true) and s > worstLet then worstLet = s end
        if l:find("a turtle is blocking", 1, true) and s > worstHeld then worstHeld = s end
      end
    end
    sim:expect(worstLet <= 900, "after the blackout nobody waited over 900 s to be let in (worst " .. worstLet .. " s)")
    sim:expect(worstHeld <= 300, "after the blackout nobody was held by a turtle over 300 s (worst " .. worstHeld .. " s)")
    local late = #stuck.lines - stuckFrom
    sim:expect(late == 0, "nobody reported STUCK after the blackout (" .. late .. " of " .. #stuck.lines .. " in the run)")
    local last = summary.lines[#summary.lines] or ""
    sim:expect(last:find("] 0 section(s) held", 1, true) ~= nil or last:find(" 0 section(s) held", 1, true) ~= nil,
      "at the end the ATC holds no section (" .. last:sub(-110) .. ")")
    local off, seen, offNames = 0, 0, {}
    for name, tt in pairs(((sim.sched.standin.state or {}).turtles) or {}) do
      if tt.role ~= "LOADER" and tt.dockX then
        seen = seen + 1
        if not (tt.x == tt.dockX and tt.z == tt.dockZ) then off = off + 1; offNames[#offNames + 1] = name end
      end
    end
    sim:expect(seen > 0 and off == 0, "every turtle ends on its dock (" .. off .. " of " .. seen .. " not: "
      .. table.concat(offNames, " ") .. ")")
    sim:expect(true, string.format("NOTE: %d order(s), %d dispatch line(s), %d 'going home first' line(s), %d ms",
      ordered, #dispatched.lines, #offDock.lines, afterMs))
  end,
}
