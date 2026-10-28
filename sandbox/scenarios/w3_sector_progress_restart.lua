-- W3 card "Mid-sector ore progress is only saved when a sector finishes; an outage loses it" (found 2026-09-30:
-- 3,575 of the zone's mined ore did not survive the whole-host outage).
-- A one-sector job; once the miner has mined at least 100 ore in its sector, that figure is taken from /state, a
-- minute and a bit is allowed to pass (the sectors in flight are written at most once a minute), and the dispatch
-- computer is restarted mid-sector. The zone's mined ore in the first /state after the restart must not be less than
-- the figure taken before it.
-- On the code before the fix the working copy is written only at sector boundaries, so the first /state after the
-- restart reads what was mined at the sector's assignment: about nothing.
local function node(sim, role)
  for _, c in ipairs(sim.sched.computers) do if c.role == role then return c end end
end

local function mined(sim, jobId)
  local zones = sim.sched.standin.state.mineZones
  local z = type(zones) == "table" and zones[jobId]
  if type(z) ~= "table" or type(z.oreMined) ~= "table" then return nil end
  local n = 0
  for _, v in pairs(z.oreMined) do if type(v) == "number" then n = n + v end end
  return n
end

return {
  world = "synthetic",
  seed = 1,
  miners = 1,
  steps = function(sim)
    local disp   = sim:capture_log("Dispatched job_")
    local online = sim:capture_log("Central server online")
    sim:run_for(120000)
    local server = node(sim, "server")
    local area = sim.world:meta().areas[1]
    sim:dispatch{ type = "ORDER_MINE", params = { x1 = area.x1, z1 = area.z1, x2 = area.x1, z2 = area.z1, minerCount = 1 } }
    sim:run_until(function() return #disp.lines >= 1 end, 10 * 60000)
    local job = disp.lines[1] and disp.lines[1]:match("Dispatched (job_%d+)")
    sim:expect(job ~= nil, "the job was dispatched")
    if not job then return end
    local got = sim:run_until(function() return (mined(sim, job) or 0) >= 100 end, 4 * 3600000)
    sim:expect(got, "the miner mined at least 100 ore in its sector (" .. tostring(mined(sim, job)) .. ")")
    if not got then return end
    local before = mined(sim, job)
    sim:run_for(70000)                                       -- a progress write falls in this minute
    local o0 = #online.lines
    sim.sched.standin.state.mineZones = nil                  -- so the next figure read is the restarted server's
    sim:reboot(server.name)                                  -- THE TEST: a restart in the middle of the sector
    sim:run_until(function() return #online.lines > o0 end, 5 * 60000)
    sim:run_until(function() return mined(sim, job) ~= nil end, 60000)
    local after = mined(sim, job)
    sim.results.mined_before, sim.results.mined_after = before, after
    sim:expect(after ~= nil and after >= before,
      "the zone's mined ore after the restart (" .. tostring(after) .. ") is not less than before it (" .. before .. ")")
  end,
}
