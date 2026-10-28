-- W3 card "A miner that reconnects after its last sector goes home without closing the job" (job_0052 2026-09-15,
-- job_0061 2026-09-17), layer 1 as ruled 2026-10-26: drop exactly this miner's JOB_COMPLETE; the idle-stuck watchdog
-- must close the job within 15 minutes, and the turtle's 'JOB_COMPLETE sent for job_X' line says which side lost it.
-- Needs the radio's type rule to match the serialised strings the fleet sends (sandbox/net/radio.lua, 2026-10-28).
-- The drop covers only the first JOB_COMPLETE: the watchdog's re-dispatch ends with a second one, which must arrive.
return {
  world = "synthetic",
  seed = 1,
  miners = 1,
  steps = function(sim)
    local disp     = sim:capture_log("Dispatched job_")
    local sent     = sim:capture_log("JOB_COMPLETE sent for")
    local stuck    = sim:capture_log("Idle-stuck MINE job")
    local complete = sim:capture_log("Job complete: job_")
    local docked   = sim:capture_log("phase: DOCKED")
    sim:run_for(120000)
    local miner
    for _, c in ipairs(sim.sched.computers) do if c.role == "miner" then miner = c end end
    local rule = { drop_rate = 1, type = "JOB_COMPLETE", from = miner.name }   -- THE TEST
    sim.sched.radio:add_rule(rule)
    local area = sim.world:meta().areas[1]
    sim:dispatch{ type = "ORDER_MINE", params = { x1 = area.x1, z1 = area.z1, x2 = area.x1, z2 = area.z1, minerCount = 1 } }
    sim:run_until(function() return #disp.lines >= 1 end, 10 * 60000)
    local job = disp.lines[1] and disp.lines[1]:match("Dispatched (job_%d+)")
    sim:expect(job ~= nil, "the job was dispatched")
    if not job then return end
    local first = sim:run_until(function() return #sent.lines >= 1 end, 8 * 3600000)
    sim:expect(first, "the miner sent its JOB_COMPLETE ('JOB_COMPLETE sent for " .. job .. "')")
    if not first then return end
    rule.until_ms = sim.clock:now() + 5000                 -- only that one is lost
    local t_sent = sim.clock:now()
    sim:run_for(30000)
    sim:expect(#complete.lines == 0, "the server did not hear it (no 'Job complete' yet)")
    local closed = sim:run_until(function()
      for _, l in ipairs(complete.lines) do if l:find(job, 1, true) then return true end end
      return false
    end, 30 * 60000)
    local mins = (sim.clock:now() - t_sent) / 60000
    sim.results.minutes_to_close = mins
    sim:expect(#stuck.lines >= 1, "the idle-stuck watchdog caught it (" .. tostring(stuck.lines[1]) .. ")")
    sim:expect(closed and mins <= 15, string.format("%s was closed within 15 minutes (%.1f min)", job, mins))
  end,
}
