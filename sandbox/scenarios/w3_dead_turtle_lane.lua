-- W3, 2026-11-17 (T2 shakeout-side-f, the card "A turtle killed by CC's timeout stays off where it stands"): CC's timeout
-- terminated #210 in the base's departure lane; a terminated computer stays OFF where it stands, so nothing ever moved it,
-- and node_211 bumped into it 323 times. A turtle next to another computer can turn it on (it is a peripheral: turnOn /
-- isOn), so a turtle stopped by a turtle that is OFF turns it back on; it boots, recovers like any rebooted turtle, and
-- moves on.
--
-- Here: one pair goes out; the moment its delivery is in the departure lane (W1), its computer is shut down, as CC's
-- timeout does. A second order is placed; its pair must come past it.
-- CHECKS: the dead delivery was in the lane (evidence); a turtle that met it turned it back on; the second order was
-- delivered; every delivery and support ends on a dock; the ATC holds nothing.
-- Before the fix the second pair is stopped behind it for good.
local function atDock(p)
  if not p or p.y ~= 67 then return false end
  for _, row in ipairs({ -2806, -2810, -2797, -2793 }) do
    if p.z == row then
      for b = 0, 4 do
        local dx = p.x - (157 + 14 * b)
        if dx ~= 0 and dx >= -4 and dx <= 4 then return true end
      end
    end
  end
  return false
end

return {
  world = "synthetic",
  seed = 1,
  miners = 1,
  atc = true,
  preset_docks = true,
  steps = function(sim)
    local dispatched = sim:capture_log("Dispatched job_")
    local revived = sim:capture_log("turned it back on")
    local done = sim:capture_log("Job complete: job_")
    local summary = sim:capture_log("section(s) held")
    sim:storage_set("minecraft:cobblestone", 100000)
    sim:storage_set("minecraft:chest", 10000)
    sim:run_for(180000)
    sim:dispatch{ type = "ORDER_DELIVERY", params = { items = { { name = "minecraft:cobblestone", count = 33 } },
      destination = { x = 124, y = 67, z = -2824 } } }
    sim:run_until(function() return #dispatched.lines >= 1 end, 120000)
    local job1, d1, s1 = (dispatched.lines[1] or ""):match("Dispatched (job_%d+) %[DELIVER%] %-> (node_%d+)%s+support job_%d+ %-> (node_%d+)")
    sim:expect(job1 ~= nil, "the first pair was dispatched")
    if not job1 then return end
    local comps = {}
    for _, c in ipairs(sim.sched.computers) do comps[c.name] = c end
    local Wl = assert(loadfile(sim.sched.code_dir .. "/waypoints.lua", "t",
      setmetatable({ fs = { exists = function() return false end } }, { __index = _G })))()
    local inLane = sim:run_until(function()
      local p = comps[d1].pos
      return p and p.x and Wl.atcSection(p.x, p.y, p.z) == "W1"
    end, 10 * 60000)
    sim:expect(inLane, d1 .. " was in the departure lane (W1)")
    if not inLane then return end
    local deadAt = string.format("%d,%d,%d", comps[d1].pos.x, comps[d1].pos.y, comps[d1].pos.z)
    comps[d1]:shutdown()                                  -- THE FAULT: terminated where it stands, as CC's timeout does
    sim:run_for(5000)
    sim:dispatch{ type = "ORDER_DELIVERY", params = { items = { { name = "minecraft:cobblestone", count = 33 } },
      destination = { x = 130, y = 67, z = -2824 } } }
    local function second()
      for _, l in ipairs(dispatched.lines) do
        local j = l:match("Dispatched (job_%d+) %[DELIVER%]")
        if j and j ~= job1 then return j end
      end
    end
    local function serverDone(j)
      for _, l in ipairs(done.lines) do if l:find("server#", 1, true) and l:find(j .. "$") then return true end end
      return false
    end
    sim:run_until(function() local j = second(); return j ~= nil and serverDone(j) end, 2 * 3600000)
    sim:run_for(20 * 60000)

    sim:expect(true, d1 .. " was shut down in the lane at " .. deadAt .. ": the checks below have something to judge")
    sim:expect(#revived.lines >= 1, "a turtle that met it turned it back on (" .. tostring((revived.lines[1] or "none"):sub(1, 140)) .. ")")
    local j2 = second()
    sim:expect(j2 ~= nil and serverDone(j2), "the second order was delivered (" .. tostring(j2) .. ")")
    local off = {}
    for _, c in ipairs(sim.sched.computers) do
      if c.kind == "turtle" and not c.carried and (c.role == "delivery" or c.role == "support") and not atDock(c.pos) then
        off[#off + 1] = string.format("%s@%s,%s,%s", c.name, tostring(c.pos and c.pos.x), tostring(c.pos and c.pos.y), tostring(c.pos and c.pos.z))
      end
    end
    sim:expect(#off == 0, "every delivery and support turtle is on a dock at the end (" .. table.concat(off, " ") .. ")")
    local last = summary.lines[#summary.lines] or ""
    sim:expect(last:find(" 0 section(s) held", 1, true) ~= nil, "the ATC holds nothing at the end (" .. last:sub(-110) .. ")")
  end,
}
