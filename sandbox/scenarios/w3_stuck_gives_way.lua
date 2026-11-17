-- W3, 2026-11-17: the card "A turtle that handed its job back on STUCK carries on with the job when it can move again"
-- (56cd393); the sim twin of sandbox/t2/scenarios/w3_stuck_gives_way.py. Sim w3_side_atc: blocked in the base, node_36
-- said STUCK and handed job_0035 back -- and went on waiting to move forward, for a job no longer its own, telling its
-- support "still coming" for 4 h. Now a turtle whose job is handed back while blocked in the base gives way.
--
-- Here: a turtle that is ON but runs nothing stands in the departure lane W1 (149,67,-2803) -- a live turtle nobody can
-- turn on or pass. One order goes out; its delivery must hand the job back, give way and go home with its support;
-- then the blocker is removed and the job, handed back, must go out again and complete.
-- CHECKS: the blocker stood in W1, on (evidence); the delivery reported STUCK and handed the job back; it gave way; it
-- and its support were home; it did not carry on with the handed-back job; with the way clear the job completed; the
-- ATC holds nothing at the end; every delivery and support ends on a dock.
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
    local stuck = sim:capture_log("handing job")
    local gave = sim:capture_log("giving way")
    local done = sim:capture_log("Job complete: job_")
    local onward = sim:capture_log("Exited depot")
    local summary = sim:capture_log("section(s) held")
    sim:storage_set("minecraft:cobblestone", 100000)
    sim:storage_set("minecraft:chest", 10000)
    sim:run_for(180000)

    -- THE FAULT: a live turtle that never moves, in the departure lane
    local blocker = sim:spawn_turtle{ id = 990, label = "blocker", pos = { x = 149, y = 67, z = -2803, facing = 3 } }
    sim:write_file(blocker.id, "startup.lua", "while true do sleep(60) end\n")
    sim:start(blocker.id)
    sim:run_for(2000)
    sim:expect(blocker.state ~= "off" and blocker.pos.x == 149, "a live blocker stood in W1 at 149,67,-2803, on ("
      .. tostring(blocker.state) .. "): the checks below have something to judge")

    sim:dispatch{ type = "ORDER_DELIVERY", params = { items = { { name = "minecraft:cobblestone", count = 33 } },
      destination = { x = 124, y = 67, z = -2824 } } }
    sim:run_until(function() return #dispatched.lines >= 1 end, 120000)
    local job, d1, s1 = (dispatched.lines[1] or ""):match("Dispatched (job_%d+) %[DELIVER%] %-> (node_%d+)%s+support job_%d+ %-> (node_%d+)")
    sim:expect(job ~= nil, "a pair was dispatched")
    if not job then return end
    local comps = {}
    for _, c in ipairs(sim.sched.computers) do comps[c.name] = c end
    local function linesBy(cap, who)
      local out = {}
      for _, l in ipairs(cap.lines) do if l:find(who .. "#", 1, true) or l:find("[" .. who .. "]", 1, true) then out[#out + 1] = l end end
      return out
    end

    sim:run_until(function() return #linesBy(stuck, d1) >= 1 end, 20 * 60000)
    sim:expect(#linesBy(stuck, d1) >= 1, d1 .. " reported STUCK and handed its job back (" .. tostring((linesBy(stuck, d1)[1] or "it never did"):sub(-110)) .. ")")
    sim:run_until(function() return #linesBy(gave, d1) >= 1 end, 5 * 60000)
    sim:expect(#linesBy(gave, d1) >= 1, d1 .. " gave way")
    sim:run_until(function() return atDock(comps[d1].pos) and atDock(comps[s1].pos) end, 10 * 60000)
    sim:expect(atDock(comps[d1].pos), d1 .. " went home")
    sim:expect(atDock(comps[s1].pos), "its support " .. s1 .. " was home too")
    local tStuck = (linesBy(stuck, d1)[1] or ""):sub(1, 24)

    sim:remove(blocker.id)                                -- the way clears
    local function serverDone()
      for _, l in ipairs(done.lines) do if l:find("server#", 1, true) and l:find(job .. "$") then return true end end
      return false
    end
    sim:run_until(serverDone, 2 * 3600000)
    sim:run_for(10 * 60000)
    -- Carrying on = leaving the depot after the STUCK, for the job it handed back: any "Exited depot" of d1 before the
    -- job was dispatched to it again (if it ever was), to the end of the run -- the way clearing is exactly when it would.
    local backToMe
    for _, l in ipairs(dispatched.lines) do
      if l:sub(1, 24) > tStuck and l:find("Dispatched " .. job .. " [DELIVER] -> " .. d1, 1, true) then backToMe = l:sub(1, 24); break end
    end
    local carried = {}
    for _, l in ipairs(linesBy(onward, d1)) do
      local t = l:sub(1, 24)
      if t > tStuck and (not backToMe or t < backToMe) then carried[#carried + 1] = l end
    end
    sim:expect(#carried == 0, d1 .. " did not carry on with the job it handed back (" .. #carried .. ": "
      .. tostring((carried[1] or "none"):sub(-90)) .. ")")
    sim:expect(serverDone(), "with the way clear, " .. job .. " went out again and completed")
    local off = {}
    for _, c in ipairs(sim.sched.computers) do
      if c.kind == "turtle" and not c.carried and (c.role == "delivery" or c.role == "support") and not atDock(c.pos) then
        off[#off + 1] = string.format("%s@%s,%s,%s", c.name, tostring(c.pos and c.pos.x), tostring(c.pos and c.pos.y), tostring(c.pos and c.pos.z))
      end
    end
    sim:expect(#off == 0, "every delivery and support turtle is on a dock at the end (" .. table.concat(off, " ") .. ")")
    local last = summary.lines[#summary.lines] or ""
    sim:expect(last:find(" 0 section(s) held", 1, true) ~= nil, "the ATC holds no section at the end (" .. last:sub(-110) .. ")")
  end,
}
