-- W3, 2026-11-24 (T2 shakeout-payload-g on 8ce3b2f): the ATC admitted pair node_225 + node_221 at 02:53:05; the
-- server then dropped out, and node_221, still on its dock -- in no section -- paused ("Server unreachable --
-- pausing"), holding DH J1 N1 W1 and every departure behind it, until its support's 180 s HOLE_READY wait ran out at
-- 03:02:51 (a timer-cleared wait). A turtle holding an admitted booking does not pause for the server: inside the
-- base the ATC is the authority (ATC card, requirement 7), as it already is for a turtle standing in a section.
--
-- Here: DH is held by a stand-in booking (a radio request from "node_fake"), so the pair waits in line; the moment
-- both halves have accepted, the server goes down for 5 minutes; a minute later the stand-in gives DH back, and the
-- pair is let in with the server still down -- as node_221 was, knowing the server unreachable.
-- CHECKS: the server was down while the delivery stood on its dock (evidence); the delivery left the dispatch hole
-- while the server was still down; its support never gave up on HOLE_READY; the order completed; both end on a dock;
-- the ATC holds nothing at the end.
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
    local go = sim:capture_log("both halves accepted -- go")
    local exited = sim:capture_log("Exited depot at")
    local holeTimeout = sim:capture_log("No HOLE_READY signal after")
    local done = sim:capture_log("Job complete: job_")
    local summary = sim:capture_log("section(s) held")
    sim:storage_set("minecraft:cobblestone", 100000)
    sim:storage_set("minecraft:chest", 10000)
    sim:run_for(180000)
    local function fake(t, payload)
      sim:send_radio(7, 1, string.format('{type="%s",from="node_fake",to="atc",seq=%d,ts=0,payload=%s}', t, 990100 + math.random(1, 9999), payload),
        { from = "node_11" })
    end
    fake("ATC_REQUEST", '{route={"DH"},ch=1}')
    sim:dispatch{ type = "ORDER_DELIVERY", params = { items = { { name = "minecraft:cobblestone", count = 33 } },
      destination = { x = 124, y = 67, z = -2824 } } }
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
    -- THE FAULT: the server goes down as the pair goes.
    local downAt, onDock
    sim:watch(function() return #go.lines >= 1 end, function(x)
      downAt = x.clock:now()
      onDock = atDock(comps[d].pos)
      x:server_crash(x.clock:now() - x.t0, 300000)
    end)
    sim:run_until(function() return downAt ~= nil end, 10 * 60000)
    sim:run_for(60000)
    local releasedAt, dockedAtRelease = sim.clock:now(), atDock(comps[d].pos)
    fake("ATC_CANCEL", '{ch=1}')
    sim:expect(downAt ~= nil and onDock and dockedAtRelease,
      "the server went down with " .. d .. " on its dock, waiting in line, and DH came free with it still there (evidence)")
    if not downAt then return end
    -- by the lines' own times: log lines reach the scenario in batches, seconds to minutes late
    local function secsOf(l)
      if not l then return nil end
      local h, m, sec = l:match("T(%d+):(%d+):([%d.]+)")
      return h and ((tonumber(h) * 60 + tonumber(m)) * 60 + tonumber(sec)) or nil
    end
    local function serverDone()
      for _, l in ipairs(done.lines) do if l:find("server#", 1, true) and l:find(job .. "$") then return true end end
      return false
    end
    sim:run_until(function() return serverDone() and atDock(comps[d].pos) and atDock(comps[s].pos) end, 2 * 3600000)
    sim:run_for(3 * 60000)
    local t0, t1 = secsOf(go.lines[1]), secsOf(mine(exited, d))
    local after = (t0 and t1) and (t1 - t0) or nil
    sim:expect(after ~= nil and after > 60 and after < 300,
      d .. " left the dispatch hole while the server was still down, after DH came free (" .. tostring(after and math.floor(after)) .. " s after it went down)")
    sim:expect(mine(holeTimeout, s) == nil, s .. " never gave up waiting for HOLE_READY (" .. tostring((mine(holeTimeout, s) or "none"):sub(-80)) .. ")")
    sim:expect(serverDone(), "the order completed (" .. job .. ")")
    sim:expect(atDock(comps[d].pos) and atDock(comps[s].pos), "both end on a dock")
    local last = summary.lines[#summary.lines] or ""
    sim:expect(last:find("0 section%(s%) held") ~= nil, "the ATC holds nothing at the end (" .. last:sub(-80) .. ")")
  end,
}
