-- W3, 2026-11-17 (T2 shakeout-side-h, pin 2272d671): after the server crash node_219 had followed its delivery to
-- 226,60,-2783; node_211 went on to holding slot 11 and sent its hold notice (ASCENDING: its slot and its path) ONCE,
-- and it was lost. node_219 never knew where its delivery went and stood 8.5 min in another pair's path (it held node_221
-- 120 s: "Gave up after 120s blocked by a turtle moving down"); told to come home it planned its own way to slot 11 from
-- 6 cells off, into rock, and retraced 158 steps to the dispatch hole. Now the delivery repeats the hold notice every
-- 10 s while it holds, and the come-home carries its path too.
--
-- Here: one pair. On its way back, once the delivery is within 40 cells of the holding line, its position updates and
-- its hold notices are lost until it stands in its slot, plus 3 s: its support lags where the loss began, off the slot,
-- and never hears the first notice.
-- CHECKS: the support lagged and the first notice was lost (evidence); the support came up behind its delivery along its
-- path ("Walked ... of my delivery's path"); it never had to find its own way home (no "way home is shut", no retrace);
-- the job completed; both on a dock; the ATC holds nothing. Before the fix the support goes the way node_219 went.
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
    local inLine = sim:capture_log("Return: ")
    local walked = sim:capture_log("of my delivery's path")
    local retrace = sim:capture_log("retracing the")
    local shut = sim:capture_log("way home is shut")
    local done = sim:capture_log("Job complete: job_")
    local summary = sim:capture_log("section(s) held")
    sim:storage_set("minecraft:cobblestone", 100000)
    sim:storage_set("minecraft:chest", 10000)
    sim:run_for(180000)
    sim:dispatch{ type = "ORDER_DELIVERY", params = { items = { { name = "minecraft:cobblestone", count = 33 } },
      destination = { x = 196, y = 67, z = -2761 } } }
    sim:run_until(function() return #dispatched.lines >= 1 end, 120000)
    local job, d, s = (dispatched.lines[1] or ""):match("Dispatched (job_%d+) %[DELIVER%] %-> (node_%d+)%s+support job_%d+ %-> (node_%d+)")
    sim:expect(job ~= nil, "a pair was dispatched")
    if not job then return end
    local comps = {}
    for _, c in ipairs(sim.sched.computers) do comps[c.name] = c end
    local function by(cap, who)
      local out = {}
      for _, l in ipairs(cap.lines) do if l:find("[" .. who .. "]", 1, true) or l:find(who .. "#", 1, true) then out[#out + 1] = l end end
      return out
    end
    -- the holding line is at x 230..256; the delivery comes back underground (y 60) from the south-west
    local near = sim:run_until(function()
      local p = comps[d].pos
      return p and p.y == 60 and p.x and p.x >= 216 and #by(inLine, d) == 0
    end, 2 * 3600000)
    sim:expect(near, d .. " came back underground within 40 cells of the holding line")
    if not near then return end
    local lagAt = string.format("%d,%d,%d", comps[s].pos.x, comps[s].pos.y, comps[s].pos.z)
    local r1 = sim:drop_radio{ type = "POSITION_UPDATE", from = d }
    local r2 = sim:drop_radio{ type = "ASCENDING", from = d }
    sim:run_until(function() return #by(inLine, d) >= 1 end, 10 * 60000)
    sim:run_for(3000)
    sim.sched.radio:remove_rule(r1)
    sim.sched.radio:remove_rule(r2)
    local dp, sp = comps[d].pos, comps[s].pos
    local apart = math.abs(dp.x - sp.x) + math.abs(dp.z - sp.z)
    sim:expect(apart > 3, s .. " lagged at " .. lagAt .. " and its first hold notice was lost: the checks below have something to judge ("
      .. apart .. " cells from its delivery in its slot)")
    local function serverDone(j)
      for _, l in ipairs(done.lines) do if l:find("server#", 1, true) and l:find(j .. "$") then return true end end
      return false
    end
    sim:run_until(function() return serverDone(job) and atDock(comps[d].pos) and atDock(comps[s].pos) end, 2 * 3600000)
    sim:run_for(5 * 60000)
    sim:expect(#by(walked, s) >= 1, s .. " came up behind its delivery along its path (" .. tostring((by(walked, s)[1] or "it did not"):sub(-90)) .. ")")
    local lost = {}
    for _, l in ipairs(by(shut, s)) do lost[#lost + 1] = l end
    for _, l in ipairs(by(retrace, s)) do lost[#lost + 1] = l end
    sim:expect(#lost == 0, s .. " never had to find its own way home (" .. tostring((lost[1] or "none"):sub(-110)) .. ")")
    sim:expect(serverDone(job), job .. " completed")
    sim:expect(atDock(comps[d].pos) and atDock(comps[s].pos), "both are on a dock at the end")
    local last = summary.lines[#summary.lines] or ""
    sim:expect(last:find(" 0 section(s) held", 1, true) ~= nil, "the ATC holds no section at the end (" .. last:sub(-110) .. ")")
  end,
}
