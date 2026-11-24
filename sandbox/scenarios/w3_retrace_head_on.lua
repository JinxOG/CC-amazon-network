-- W3, 2026-11-24 (sim w3_pair_server_crash on 8ce3b2f): support node_51, stranded out in the world after its pair
-- split, walked back the way it came along the departures' tunnel while the job's new pair came out along it.
-- node_33 dug up and over node_51, but node_51 kept walking, and node_52 following node_33 met it head-on at
-- 196,60,-2807: two turtles that cannot dig, in a one-block tunnel, going opposite ways. Both "Gave up after 120s".
-- The fix (Head Engineer ruling, 2026-11-24): the dispatch tunnel near the base is a section of its own (DT), one
-- party in it at a time; a turtle walking back books it at the zone's edge and waits there, standing still -- a
-- delivery digs round a turtle that stands still, and its support follows the detour.
--
-- Here: one pair out to 196,67,-2761; once the support is out near the destination, it reboots: its way home by
-- the holding line is rock, so it walks back the way it came. A second pair is sent out the same way as it reboots,
-- so it comes out of the dispatch hole as the support starts back.
-- CHECKS: the support walked back (evidence); a second pair went out while it did (evidence); nobody gave up blocked
-- by a turtle; the second order completed; all four end on a dock; the ATC holds nothing at the end.
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

local DEST = { x = 196, y = 67, z = -2761 }   -- inside the sim's loaded box (it ends at z -2760)

return {
  world = "synthetic",
  seed = 1,
  miners = 1,
  atc = true,
  preset_docks = true,
  steps = function(sim)
    local dispatched = sim:capture_log("Dispatched job_")
    local retracing = sim:capture_log("retracing the")
    local gaveUp = sim:capture_log("Gave up after 120s blocked by a turtle")
    local done = sim:capture_log("Job complete: job_")
    local summary = sim:capture_log("section(s) held")
    sim:storage_set("minecraft:cobblestone", 100000)
    sim:storage_set("minecraft:chest", 10000)
    sim:run_for(180000)
    -- the second one column over: the server sends one delivery at a time to a destination, and its way out is
    -- the same tunnel row the first pair dug
    local function order(dest)
      sim:dispatch{ type = "ORDER_DELIVERY", params = { items = { { name = "minecraft:cobblestone", count = 33 } },
        destination = dest or DEST } }
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
    -- THE FAULT: the support reboots out near the destination.
    local where
    sim:watch(function()
      local p = comps[s].pos
      return p and p.y == 60 and p.z >= -2766
    end, function(x)
      local p = comps[s].pos
      where = string.format("%d,%d,%d", p.x, p.y, p.z)
      x:reboot(s)
      order({ x = DEST.x + 1, y = DEST.y, z = DEST.z })   -- THE TRAFFIC: out the same way as it starts back
    end)
    sim:run_until(function() return where ~= nil end, 30 * 60000)
    sim:expect(where ~= nil, s .. " rebooted out near the destination at " .. tostring(where))
    if not where then return end
    local back = sim:run_until(function() return mine(retracing, s) ~= nil end, 20 * 60000)
    sim:expect(back, s .. " walked back the way it came (" .. tostring((mine(retracing, s) or "it did not"):sub(-90)) .. ")")
    if not back then return end
    sim:run_until(function() return #dispatched.lines >= 2 end, 10 * 60000)
    local job2, d2, s2 = (dispatched.lines[2] or ""):match("Dispatched (job_%d+) %[DELIVER%] %-> (node_%d+)%s+support job_%d+ %-> (node_%d+)")
    sim:expect(job2 ~= nil, "a second pair went out while it walked back")
    local all = { d, s, d2, s2 }
    local function home()
      for _, n in ipairs(all) do if n and not atDock(comps[n] and comps[n].pos) then return false end end
      return true
    end
    local function serverDone(j)
      for _, l in ipairs(done.lines) do if l:find("server#", 1, true) and l:find(j .. "$") then return true end end
      return false
    end
    sim:run_for(5 * 60000)
    sim:run_until(function() return home() and (not job2 or serverDone(job2)) end, 3 * 3600000)
    sim:run_for(3 * 60000)
    sim:expect(#gaveUp.lines == 0, "nobody gave up blocked by a turtle (" .. #gaveUp.lines .. ": " .. tostring((gaveUp.lines[1] or ""):sub(-100)) .. ")")
    sim:expect(job2 ~= nil and serverDone(job2), "the second order completed (" .. tostring(job2) .. ")")
    for _, n in ipairs(all) do
      if n then
        local p = comps[n] and comps[n].pos
        sim:expect(atDock(p), n .. " ends on a dock (" .. (p and string.format("%d,%d,%d", p.x, p.y, p.z) or "?") .. ")")
      end
    end
    local last = summary.lines[#summary.lines] or ""
    sim:expect(last:find("0 section%(s%) held") ~= nil, "the ATC holds nothing at the end (" .. last:sub(-80) .. ")")
  end,
}
