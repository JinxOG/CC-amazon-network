-- W3, 2026-11-23 (T2 shakeout-payload-e, pin d57e43e): node_239 and node_235, supports out in the tunnel with their
-- deliveries, were rebooted there; given holding slots behind rock they logged "no way back is known (trail empty)"
-- -- the way they came was in memory only -- and stood in the lane to the end of the run. 10 supports following
-- their deliveries out bumped into them for 120 s and gave up ("Gave up after 120s blocked by a turtle").
--
-- Here: one pair out to 196,67,-2761 (the destination south of the base, the run's geometry); once the support is
-- out under the base in the tunnel, the support and its delivery both reboot (as in the restart burst), and a
-- second pair is sent out the same way behind them.
-- CHECKS: the support rebooted out in the tunnel (evidence); it found the way it came after the reboot; it never
-- said "trail empty"; nobody gave up blocked by a turtle; all four turtles end on a dock.
-- Before the fix: "no way back is known (trail empty)" and the support stays in the tunnel.
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

local DEST = { x = 196, y = 67, z = -2761 }

return {
  world = "synthetic",
  seed = 1,
  miners = 1,
  atc = true,
  preset_docks = true,
  steps = function(sim)
    local dispatched = sim:capture_log("Dispatched job_")
    local kept = sim:capture_log("kept from before the reboot")
    local empty = sim:capture_log("trail empty")
    local gaveUp = sim:capture_log("Gave up after 120s blocked by a turtle")
    sim:storage_set("minecraft:cobblestone", 100000)
    sim:run_for(180000)
    local function order()
      sim:dispatch{ type = "ORDER_DELIVERY", params = { items = { { name = "minecraft:cobblestone", count = 33 } },
        destination = DEST } }
    end
    order()
    sim:run_until(function() return #dispatched.lines >= 1 end, 120000)
    local job, d, s = (dispatched.lines[1] or ""):match("Dispatched (job_%d+) %[DELIVER%] %-> (node_%d+)%s+support job_%d+ %-> (node_%d+)")
    sim:expect(job ~= nil, "a pair was dispatched")
    if not job then return end
    local comps = {}
    for _, c in ipairs(sim.sched.computers) do comps[c.name] = c end
    local function mine(cap, who)
      for _, l in ipairs(cap.lines) do if l:find(who .. "#", 1, true) or l:find("[" .. who .. "]", 1, true) then return l end end
      return nil
    end
    -- THE FAULT: both reboot once the support is out in the tunnel, under the base and heading south.
    local where
    sim:watch(function()
      local p = comps[s].pos
      return p and p.y == 60 and p.z >= -2790
    end, function(x)
      local p = comps[s].pos
      where = string.format("%d,%d,%d", p.x, p.y, p.z)
      x:reboot(s); x:reboot(d)
    end)
    local out = sim:run_until(function() return where ~= nil end, 30 * 60000)
    sim:expect(out, s .. " reached the tunnel south of the base")
    if not out then return end
    sim:expect(true, s .. " rebooted out in the tunnel at " .. where .. ": the checks below have something to judge")
    order()   -- a second pair out the same way, behind it
    sim:run_until(function() return #dispatched.lines >= 2 end, 10 * 60000)
    local _, d2, s2 = (dispatched.lines[2] or ""):match("Dispatched (job_%d+) %[DELIVER%] %-> (node_%d+)%s+support job_%d+ %-> (node_%d+)")
    local all = { d, s, d2, s2 }
    local function home()
      for _, n in ipairs(all) do if n and not atDock(comps[n] and comps[n].pos) then return false end end
      return true
    end
    sim:run_for(5 * 60000)
    sim:run_until(home, 2 * 3600000)
    sim:expect(mine(kept, s) ~= nil, s .. " found the way it came after the reboot (" .. tostring((mine(kept, s) or "it did not"):sub(-80)) .. ")")
    sim:expect(mine(empty, s) == nil, s .. " never had no way back (" .. tostring((mine(empty, s) or "none"):sub(-100)) .. ")")
    sim:expect(#gaveUp.lines == 0, "nobody gave up blocked by a turtle (" .. #gaveUp.lines .. ": " .. tostring((gaveUp.lines[1] or ""):sub(-90)) .. ")")
    for _, n in ipairs(all) do
      if n then
        local p = comps[n] and comps[n].pos
        sim:expect(atDock(p), n .. " ends on a dock (" .. (p and string.format("%d,%d,%d", p.x, p.y, p.z) or "?") .. ")")
      end
    end
  end,
}
