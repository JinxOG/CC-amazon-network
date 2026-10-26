-- W3 card "A recall is ignored while a turtle is in sky flight" (fix f02be1e, 1.9.129; the log line, 2026-10-26).
-- The job is cancelled 20 s into the miner's outbound flight. It must turn back within 100 blocks (the recall rides the
-- radio, ~50 blocks of flight in the sim; the sector is ~230 blocks on) -- no
-- loader placed, no scanning -- and say so ("recalled in flight", now written to the server log), then dock.
-- On f02be1e~1 it flies on, places its loader and scans (the 2026-09-22 incident). On 1.9.151 it turns back but the
-- line is not in the log (the watcher could not see it).
return {
  world = "synthetic",
  seed = 1,
  miners = 1,
  steps = function(sim)
    local disp     = sim:capture_log("Dispatched job_")
    local travel   = sim:capture_log("phase: TRAVELLING")
    local placing  = sim:capture_log("phase: PLACING_LOADER")
    local scanning = sim:capture_log("phase: SCANNING")
    local recalled = sim:capture_log("recalled in flight")
    local docked   = sim:capture_log("Docked at bay")
    sim:run_for(120000)
    local area = sim.world:meta().areas[1]
    sim:dispatch{ type = "ORDER_MINE", params = { x1 = area.x1, z1 = area.z1, x2 = area.x2, z2 = area.z2, minerCount = 1 } }
    local out = sim:run_until(function() return #disp.lines >= 1 and #travel.lines >= 1 end, 20 * 60000)
    sim:expect(out, "the miner set off on its outbound flight")
    if not out then return end
    local miner = disp.lines[1]:match("%-> (node_%d+)")
    local job = disp.lines[1]:match("Dispatched (job_%d+)")
    sim:run_for(20000)                                   -- in the air, well before the sector
    local p0, s0, d0 = #placing.lines, #scanning.lines, #docked.lines
    local c = sim.by_name[miner]
    local home0 = c.home_pos
    local function away() return math.abs(c.pos.x - home0.x) + math.abs(c.pos.z - home0.z) end
    local atCancel, farthest = away(), away()
    sim:dispatch{ type = "CANCEL_JOB", params = { jobId = job } }   -- THE TEST

    local said = sim:run_until(function() return #recalled.lines >= 1 end, 3 * 60000)
    sim:expect(said, "the server logged '" .. miner .. " recalled in flight' within 3 minutes")
    -- The flight itself: before f02be1e it flew on to the sector and turned back there (nine minutes live).
    local home = sim:run_until(function()
      local a = away()
      if a > farthest then farthest = a end
      return #docked.lines > d0
    end, 60 * 60000)
    sim:expect(farthest - atCancel <= 100, string.format(
      "it turned back within 100 blocks of the recall (flew %d further; the sector was ~%d blocks on)",
      farthest - atCancel, math.abs(math.floor((sim.world:meta().areas[1].x1 + sim.world:meta().areas[1].x2) / 2) - home0.x) - atCancel))
    sim:expect(home, "the miner docked")
    sim:expect(#placing.lines == p0, "no loader was placed after the recall (" .. (#placing.lines - p0) .. ")")
    sim:expect(#scanning.lines == s0, "no scanning after the recall (" .. (#scanning.lines - s0) .. ")")
    sim.results.miner, sim.results.job = miner, job
  end,
}
