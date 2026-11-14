-- W3, the card "SHAKEOUT blocker - 1x side test: the base gridlocks at the ATC after an ATC crash and after radio loss"
-- (2026-11-14). T2 shakeout-side-a: node_208 timed out waiting for the warehouse AT ITS DESTINATION (196,67,-2761); the
-- server gave the job straight back to it, and it began the job again with a departure from where it stood. The
-- departure route assumes the dock: it drove north through the support rows into node_216 parked on its dock and held
-- the whole outbound route (N1 R0 W1 S1 J1 DH) for 50 minutes, every departure in the base behind it. node_210 was given
-- its job back inside the dispatch shaft and drove up it into its own support coming down: the second gridlock.
--
-- Here: one delivery to 196,67,-2761, and the warehouse computer switched off as it leaves, so the delivery times out (warehouse_chest_timeout) and the server gives the job back; then the warehouse is switched
-- on again.
-- CHECKS: the job came back while the delivery was away from its dock (evidence: a second 'Dispatched' line for the job);
-- the delivery went home before departing again; it was never stuck behind a turtle; the job completed; no turtle
-- reported STUCK. On the code before the fix the delivery drives from the destination into the parked rows.
return {
  world = "synthetic",
  seed = 1,
  miners = 1,
  atc = true,
  preset_docks = true,
  steps = function(sim)
    local dispatched = sim:capture_log("Dispatched job_")
    local waiting = sim:capture_log("[WH] Waiting for warehouse")
    local timeout = sim:capture_log("warehouse_chest_timeout")
    local homeFirst = sim:capture_log("going home first")
    local homeAfter = sim:capture_log("away from my dock")   -- either way home: after the failed job, or before departing
    local docked = sim:capture_log("Docked at bay")
    local blocked = sim:capture_log("a turtle is blocking")
    local stuck = sim:capture_log("STUCK ")
    local done = sim:capture_log("Job complete: job_")
    sim:storage_set("minecraft:cobblestone", 100000)
    sim:storage_set("minecraft:chest", 10000)
    sim:run_for(180000)
    local wh
    for _, c in ipairs(sim.sched.computers) do if c.role == "warehouse" then wh = c end end
    sim:expect(wh ~= nil, "found the warehouse computer")
    if not wh then return end

    sim:dispatch{ type = "ORDER_DELIVERY", params = { items = { { name = "minecraft:cobblestone", count = 33 } },
      destination = { x = 196, y = 67, z = -2761 } } }
    sim:run_until(function() return #dispatched.lines >= 1 end, 120000)
    local dname = (dispatched.lines[1] or ""):match("%[DELIVER%] %-> (node_%d+)")
    sim:expect(dname ~= nil, "a delivery was dispatched (" .. tostring(dname) .. ")")
    if not dname then return end
    local function mine(lines, from)
      local out = {}
      for i = from or 1, #lines do
        local l = lines[i]
        if l:find("[" .. dname .. "]", 1, true) or l:find(dname .. "#", 1, true) then out[#out + 1] = l end
      end
      return out
    end

    -- Every other delivery held, so the job can only come back to this one (in the side test there were only eight).
    for name, t in pairs(((sim.sched.standin.state or {}).turtles) or {}) do
      if t.role == "DELIVERY" and name ~= dname then
        sim:dispatch{ type = "HOLD_TURTLE", params = { turtleId = name, reason = "w3_depart_off_dock" } }
        sim:run_for(2)
      end
    end
    wh:shutdown()                                     -- THE FAULT: the warehouse is gone when the delivery gets there
    local before = #dispatched.lines
    local blockedBefore, dockedBefore = #blocked.lines, #docked.lines
    sim:run_until(function() return #dispatched.lines > before end, 1800000)
    local again = dispatched.lines[before + 1] or ""
    local back = again:find("-> " .. dname .. " ", 1, true) ~= nil
    sim:expect(#waiting.lines >= 1, dname .. " reached its destination and waited for the warehouse (" .. #waiting.lines .. ")")
    sim:expect(back and #timeout.lines >= 1, "the job came back to the delivery while it was away from its dock ("
      .. #timeout.lines .. " timeout line(s), " .. tostring(again:sub(1, 120)) .. ")")
    wh:boot()
    sim:run_until(function() return #done.lines >= 1 end, 3 * 3600000)
    sim:run_for(10 * 60000)

    sim:expect(#mine(homeAfter.lines) >= 1, dname .. " went home before departing again (when its job failed, or when it "
      .. "was given it back: " .. tostring((mine(homeAfter.lines)[1] or "nothing"):sub(1, 140)) .. ")")
    sim:expect(#mine(docked.lines, dockedBefore + 1) >= 1, "and docked on the way (" .. #mine(docked.lines, dockedBefore + 1) .. ")")
    local b = mine(blocked.lines, blockedBefore + 1)
    sim:expect(#b == 0, dname .. " was never held up by a turtle after the job came back (" .. #b .. "; "
      .. tostring((b[1] or ""):sub(1, 140)) .. ")")
    sim:expect(#done.lines >= 1, "the job completed (" .. #done.lines .. ")")
    sim:expect(#stuck.lines == 0, "nobody reported STUCK (" .. #stuck.lines .. ")")
  end,
}
