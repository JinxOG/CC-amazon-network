-- W3 card "Mid-sector ore progress ..." -- the second fault found with it (2026-09-30: after the requeue the zone read
-- 1,384 ore found where it read 21,250 before).
-- A job mines until a sector with ore has finished; then it is cancelled and the same ground is ordered again. The new job's
-- zone is built from the store. At its first scan report its mined ore must still include the first sector's, and
-- when it finishes the store must not hold less than before.
-- On the code before the fix the totals are recomputed from the new job's scans alone at its first report, and the
-- next finished sector writes that smaller figure over the store.
local function zoneMined(sim, key)
  local zones = sim.sched.standin.state.mineZones
  local z = type(zones) == "table" and zones[key]
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
    local disp  = sim:capture_log("Dispatched job_")
    local done  = sim:capture_log("done by")
    local scans = sim:capture_log("scan by")
    sim:run_for(120000)
    local area = sim.world:meta().areas[1]
    local order = { x1 = area.x1, z1 = area.z1, x2 = area.x1 + 32, z2 = area.z1, minerCount = 1 }
    sim:dispatch{ type = "ORDER_MINE", params = order }
    sim:run_until(function() return #disp.lines >= 1 end, 10 * 60000)
    local job1 = disp.lines[1] and disp.lines[1]:match("Dispatched (job_%d+)")
    sim:expect(job1 ~= nil, "the first job was dispatched")
    if not job1 then return end
    -- A sector that finishes after the zone has mined ore (the first ones mined can be empty).
    sim:expect(sim:run_until(function() return (zoneMined(sim, job1) or 0) >= 100 end, 6 * 3600000),
      "the zone mined at least 100 ore")
    local d1 = #done.lines
    local mineDone = function()
      for i = d1 + 1, #done.lines do
        local l = done.lines[i]
        if l:find("Sector (", 1, true) and l:find(job1, 1, true) then return true end
      end
      return false
    end
    sim:expect(sim:run_until(mineDone, 6 * 3600000), "and then a sector was finished")
    sim:run_for(10000)
    local before = zoneMined(sim, job1) or 0
    sim:expect(before > 0, "it mined ore (" .. before .. ")")
    sim:dispatch{ type = "CANCEL_JOB", params = { jobId = job1 } }
    sim:run_for(20 * 60000)                                  -- the miner goes home
    local d0, s0 = #disp.lines, #scans.lines
    sim:dispatch{ type = "ORDER_MINE", params = order }      -- THE TEST: the same ground again
    sim:run_until(function() return #disp.lines > d0 end, 30 * 60000)
    local job2 = disp.lines[d0 + 1] and disp.lines[d0 + 1]:match("Dispatched (job_%d+)")
    sim:expect(job2 ~= nil, "the second job was dispatched")
    if not job2 then return end
    local scanned = sim:run_until(function()
      for i = s0 + 1, #scans.lines do if scans.lines[i]:find(job2, 1, true) then return true end end
      return false
    end, 3 * 3600000)
    sim:expect(scanned, "the second job reported a scan")
    sim:run_for(5000)
    local after = zoneMined(sim, job2)
    sim.results.mined_before, sim.results.mined_after = before, after
    sim:expect(after ~= nil and after >= before,
      "after the new job's first scan the zone's mined ore (" .. tostring(after) .. ") still includes the "
      .. before .. " mined before")
  end,
}
