-- W3, 2026-11-15: T2 shakeout-side-c (pin 360d551) gridlocked behind a booking the ATC kept for a turtle that was home.
-- node_208 came up the arrivals hole and drove home along the red lane during a radio loss; its ATC_LEAVE / ATC_CANCEL
-- were lost, so R2-R5 stayed booked to it. Docked, it got a new job and asked for a departure every two seconds -- and
-- every message a turtle sends keeps ALL its bookings alive, so the stale one was never swept. Its departure waited
-- "after an older request": the returns queued for R2-R5, which were its own. 12 of 20 jammed for 45 minutes.
--
-- Here: the small fleet with the ATC; the first delivery's ATC_LEAVE and ATC_CANCEL are dropped from the moment it is
-- called up from its holding slot until it has docked, so it docks holding its way home. Deliveries keep being ordered.
-- CHECKS: the first delivery docked while every release it sent was lost (evidence); the ATC let its booking go on its
-- own reports (since 2026-11-17, T2 shakeout-side-h s002: a report says where a turtle stands, and one out of the base
-- says so -- before, it docked still holding its way home, and this scenario's evidence was that stale booking); every
-- delivery ordered completed; nobody waited over 900 s to be let in; at the end the ATC holds no section.
-- On 360d551 the stale booking stays and the returns queue behind it.
local DESTS = { { x = 118, z = -2830 }, { x = 124, z = -2830 }, { x = 196, z = -2761 }, { x = 130, z = -2830 } }

return {
  world = "synthetic",
  seed = 1,
  miners = 1,
  atc = true,
  preset_docks = true,
  steps = function(sim)
    local dispatched = sim:capture_log("Dispatched job_")
    local done = sim:capture_log("Job complete: job_")
    local called = sim:capture_log("Called up from holding slot")
    local docked = sim:capture_log("Docked at bay")
    local healed = sim:capture_log("reports from")
    local waits = sim:capture_log("Still waiting")
    local summary = sim:capture_log("section(s) held")
    sim:storage_set("minecraft:cobblestone", 1000000)
    sim:storage_set("minecraft:chest", 100000)
    sim:run_for(180000)

    local nextDest, ordered = 0, 0
    local function order()
      local d = DESTS[nextDest % #DESTS + 1]
      nextDest = nextDest + 1
      sim:dispatch{ type = "ORDER_DELIVERY", params = { items = { { name = "minecraft:cobblestone", count = 33 } },
        destination = { x = d.x, y = 67, z = d.z } } }
      ordered = ordered + 1
      sim:run_for(2)
    end
    local function deliveriesDone()
      local deliver, seen, n = {}, {}, 0
      for _, l in ipairs(dispatched.lines) do local j = l:match("Dispatched (job_%d+) %[DELIVER%]"); if j then deliver[j] = true end end
      for _, l in ipairs(done.lines) do
        local j = l:match("Job complete: (job_%d+)")
        if j and deliver[j] and not seen[j] then seen[j] = true; n = n + 1 end
      end
      return n
    end

    -- Three in flight from the start and all the way through, so returns queue for the red lane while the first one is
    -- home, and it is given a new job as soon as it is free (node_208 asked for a departure from its dock at once).
    local function feed(ms)
      local stop = sim.clock:now() + ms
      while sim.clock:now() < stop do
        while ordered - deliveriesDone() < 3 and ordered < 16 do order() end
        sim:run_for(10000)
      end
    end
    for _ = 1, 3 do order() end
    sim:run_until(function() return #dispatched.lines >= 1 end, 120000)
    local first = (dispatched.lines[1] or ""):match("%[DELIVER%] %-> (node_%d+)")
    sim:expect(first ~= nil, "the first delivery was dispatched (" .. tostring(first) .. ")")
    if not first then return end
    local function mine(lines, from)
      local out = {}
      for i = from or 1, #lines do if lines[i]:find(first .. "#", 1, true) then out[#out + 1] = lines[i] end end
      return out
    end
    local t0 = sim.clock:now()
    while #mine(called.lines) == 0 and sim.clock:now() - t0 < 3 * 3600000 do feed(10000) end
    -- THE FAULT: its releases are lost from here until it is home.
    local now = sim.clock:now()
    local rules = {
      sim.sched.radio:add_rule{ drop_rate = 1, type = "ATC_LEAVE", from = first, from_ms = now, until_ms = now + 20 * 60000 },
      sim.sched.radio:add_rule{ drop_rate = 1, type = "ATC_CANCEL", from = first, from_ms = now, until_ms = now + 20 * 60000 },
    }
    local dockedBefore = #mine(docked.lines)
    local t1 = sim.clock:now()
    while #mine(docked.lines) <= dockedBefore and sim.clock:now() - t1 < 20 * 60000 do feed(10000) end
    for _, id in ipairs(rules) do if type(id) == "number" then sim.sched.radio:remove_rule(id) end end
    feed(70000)
    sim:expect(#mine(docked.lines) > dockedBefore, first .. " docked while every ATC_LEAVE and ATC_CANCEL it sent was lost, "
      .. "so the checks below have something to judge")
    local own = {}
    for _, l in ipairs(healed.lines) do if l:find(first .. " reports from", 1, true) then own[#own + 1] = l end end
    local held = summary.lines[#summary.lines] or ""
    sim:expect(#own >= 1 and held:find(first, 1, true) == nil, "the ATC let its booking go on its own reports ("
      .. tostring((own[#own] or "none"):sub(-90)) .. "; now: " .. held:sub(-80) .. ")")

    local waitsFrom = #waits.lines
    feed(60 * 60000)
    sim:run_until(function() return deliveriesDone() >= ordered end, 2 * 3600000)
    sim:run_for(10 * 60000)

    sim:expect(deliveriesDone() >= ordered, string.format("every delivery ordered completed (%d of %d)", deliveriesDone(), ordered))
    local worst = 0
    for i = waitsFrom + 1, #waits.lines do
      local l = waits.lines[i]
      local s = tonumber(l:match("Still waiting (%d+)s")) or 0
      if l:find("ATC:", 1, true) and s > worst then worst = s end
    end
    sim:expect(worst <= 900, "nobody waited over 900 s to be let in (worst " .. worst .. " s)")
    local last = summary.lines[#summary.lines] or ""
    sim:expect(last:find(" 0 section(s) held", 1, true) ~= nil, "at the end the ATC holds no section (" .. last:sub(-110) .. ")")
  end,
}
