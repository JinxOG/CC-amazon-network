-- The speed benchmark: the whole fleet, one two-miner job, six simulated hours (spec section 9: at most 72 s of wall time).
return {
  world = "synthetic",
  seed = 1,
  miners = 2,
  steps = function(sim)
    local done = sim:watch_log("Job complete: job_")
    sim:run_for(120000)
    local area = sim.world:meta().areas[1]
    sim:dispatch{ type = "ORDER_MINE", params = { x1 = area.x1, z1 = area.z1, x2 = area.x2, z2 = area.z2 } }
    sim:run_until(6 * 3600 * 1000)           -- to six hours after the scenario started
    sim:expect(done.count >= 2, "both jobs complete inside the six hours")
  end,
}
