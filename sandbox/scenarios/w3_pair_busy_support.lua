-- W3, 2026-11-17 (T2 shakeout-side-e jam 1, pin 9c81a76): node_218, a support out on the returns side, said its job
-- was over and was paired with a new delivery 23 ms later, 200 blocks from its dock. It refused ("busy"); its half was
-- requeued alone, nothing ever paired it again, and the delivery went to the dispatch hole and held it 600 s waiting for
-- a support that did not exist -- 3 departures, 3 returns and 7 supports queued behind it.
-- Design: docs/superpowers/specs/2026-11-17-delivery-pair-and-hole-design.md, rule R1 (a pair only from two docked
-- turtles; both accept before either moves; a refusal cancels both and re-pairs).
--
-- Here: one pair goes out; while it is out its job is cancelled, so both come home; the moment the cancel is given a
-- second order is placed, with every other support held, so the only support the server could offer is the one still
-- on its way home.
-- CHECKS: the second order came while its only support was still out (evidence: recalled mid-follow); no support refused a job it was offered; no delivery waited at the hole for a support that never staged;
-- the second order was delivered; every delivery and support is on a dock at the end; the ATC holds nothing.
-- On 9c81a76 the support is offered the job on its way home, refuses it, and the delivery waits 600 s at the hole.
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
    local rejected = sim:capture_log("rejected by")
    local neverStaged = sim:capture_log("never staged in")
    local done = sim:capture_log("Job complete: job_")
    local summary = sim:capture_log("section(s) held")
    local follow = sim:capture_log("Following node_")
    local docked = sim:capture_log("Docked at bay")
    local departing = sim:capture_log("Departing via dispatch lane")
    local recalledOut = sim:capture_log("Recalled mid-follow")
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
    -- Every other support is held: the second order can only be offered s1.
    local held = {}
    for _, c in ipairs(sim.sched.computers) do
      if c.kind == "turtle" and c.role == "support" and c.name ~= s1 then
        sim:dispatch{ type = "HOLD_TURTLE", params = { turtleId = c.name, reason = "w3_pair_busy_support" } }
        held[#held + 1] = c.name
      end
    end
    -- Out in the world, following its delivery.
    sim:run_until(function()
      for _, l in ipairs(follow.lines) do if l:find(s1 .. "#", 1, true) then return true end end
      return false
    end, 20 * 60000)
    sim:run_for(30000)
    sim:dispatch{ type = "CANCEL_JOB", params = { jobId = job1 } }
    local away = {}
    -- THE FAULT: a second order at once, while s1 is still out.
    sim:dispatch{ type = "ORDER_DELIVERY", params = { items = { { name = "minecraft:cobblestone", count = 33 } },
      destination = { x = 130, y = 67, z = -2824 } } }
    local function second()
      for i = 2, #dispatched.lines do
        local j, d, s = dispatched.lines[i]:match("Dispatched (job_%d+) %[DELIVER%] %-> (node_%d+)%s+support job_%d+ %-> (node_%d+)")
        if j and j ~= job1 then return j, d, s, i end
      end
    end
    -- Where s1 stood each time a second-order dispatch named it.
    local seen = 0
    local function noteAway()
      for i = seen + 1, #dispatched.lines do
        local j, _, s = dispatched.lines[i]:match("Dispatched (job_%d+) %[DELIVER%] %-> node_%d+%s+support job_%d+ %-> (node_%d+)")
        if j and j ~= job1 and s == s1 and not atDock(comps[s1].pos) then
          local p = comps[s1].pos
          away[#away + 1] = string.format("%s at %s,%s,%s", j, tostring(p.x), tostring(p.y), tostring(p.z))
        end
      end
      seen = #dispatched.lines
    end
    local function serverDone(j)
      for _, l in ipairs(done.lines) do if l:find("server#", 1, true) and l:find(j .. "$") then return true end end
      return false
    end
    sim:run_until(function() noteAway(); local j = second(); return j ~= nil and serverDone(j) end, 2 * 3600000)
    for _, n in ipairs(held) do sim:dispatch{ type = "RELEASE_TURTLE", params = { turtleId = n } } end
    sim:run_for(15 * 60000)
    noteAway()
    -- From the logs as well (the polls above see the support only between steps): a support that docks AFTER it was
    -- paired was not on its dock when it was paired. Its first "Docked" after the dispatch line, before any staging.
    for i = 2, #dispatched.lines do
      local l = dispatched.lines[i]
      local j, s = l:match("Dispatched (job_%d+) %[DELIVER%] %-> node_%d+%s+support job_%d+ %-> (node_%d+)")
      if j and j ~= job1 then
        local t = l:sub(1, 23)
        -- ...docking before it next departs (a "Docked" after its new job's trip is that trip's).
        local dockAt, departAt
        for _, dl in ipairs(docked.lines) do
          if dl:find(s .. "#", 1, true) and dl:sub(1, 23) > t and (not dockAt or dl:sub(1, 23) < dockAt) then dockAt = dl:sub(1, 23) end
        end
        for _, dl in ipairs(departing.lines) do
          if dl:find(s .. "#", 1, true) and dl:sub(1, 23) > t and (not departAt or dl:sub(1, 23) < departAt) then departAt = dl:sub(1, 23) end
        end
        if dockAt and (not departAt or dockAt < departAt) then
          away[#away + 1] = string.format("%s: %s docked at %s, after it was paired at %s", j, s, dockAt:sub(12, 19), t:sub(12, 19))
        end
      end
    end

    local refusals = {}
    for _, l in ipairs(rejected.lines) do if l:find("busy", 1, true) then refusals[#refusals + 1] = l:match("Job .*$") or l end end
    local out = nil
    for _, l in ipairs(recalledOut.lines) do if l:find(s1 .. "#", 1, true) then out = l end end
    sim:expect(out ~= nil, string.format("the second order came while its only support %s was still out, following "
      .. "(recalled mid-follow): the checks below have something to judge (%s)", s1, tostring(out and out:sub(1, 60))))
    sim:expect(#away == 0, "no turtle was offered a job away from its dock (" .. table.concat(away, "; ") .. ")")
    sim:expect(#refusals == 0, "no support refused a job it was offered (" .. tostring(refusals[1]) .. ")")
    sim:expect(#neverStaged.lines == 0, "no delivery waited at the hole for a support that never staged ("
      .. tostring((neverStaged.lines[1] or "none"):sub(1, 140)) .. ")")
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
