-- W3 card "A miner rebooted at its dock ignores the job re-sent to it and idles 8 minutes" (fix b1a96eb, 1.9.144).
-- A miner is rebooted seconds after it is dispatched, still inside the base. Before the fix the server re-sent
-- JOB_ASSIGN straight after REGISTER_ACK, while the turtle was still in base.init (filtered yields destroy it), and
-- it sat "Ready." until the idle-stuck check requeued the job 8 minutes later. Now the job goes out on its first
-- heartbeat, and the miner departs again within about a minute.
-- Fails on the code before the fix: run with --code rev:b1a96eb~1 to see it.
return {
  world = "synthetic",
  seed = 1,
  miners = 1,
  steps = function(sim)
    local done     = sim:watch_log("Job complete: job_")
    local disp     = sim:capture_log("Dispatched job_")
    local departs  = sim:capture_log("phase: DEPARTING")
    local stuck    = sim:capture_log("Idle-stuck MINE job")
    local resent   = sim:capture_log("(first heartbeat)")
    sim:run_for(120000)
    local area = sim.world:meta().areas[1]
    sim:dispatch{ type = "ORDER_MINE", params = { x1 = area.x1, z1 = area.z1, x2 = area.x2, z2 = area.z2 } }

    local out = sim:run_until(function() return #disp.lines >= 1 and #departs.lines >= 1 end, 10 * 60000)
    sim:expect(out, "the job was dispatched and the miner set off")
    if not out then return end
    local miner = disp.lines[1]:match("%-> (node_%d+)")
    sim:run_for(3000)                                   -- still in the depot lane
    local departsBefore = #departs.lines
    local t0 = sim.clock:now()
    sim:reboot(miner)                                   -- THE TEST: a reboot at the dock with a live job

    local again = sim:run_until(function() return #departs.lines > departsBefore end, 15 * 60000)
    local waited = (sim.clock:now() - t0) / 1000
    sim:expect(again, "the rebooted miner set off again on its job")
    sim:expect(again and waited < 180, string.format("it set off within 3 minutes of the reboot (%.0f s)", waited))
    sim:expect(#stuck.lines == 0, "no idle-stuck requeue was needed (" .. #stuck.lines .. ")")
    sim:expect(#resent.lines >= 1, "the server re-sent the job on its first heartbeat")
    local finished = sim:run_until(function() return done.count >= 1 end, 12 * 3600 * 1000)
    sim:expect(finished, "the job completes")
    sim.results.rebooted = miner
    sim.results.seconds_to_depart_again = waited
  end,
}
