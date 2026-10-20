-- A two-miner job on the synthetic world, with the real fleet files.
return {
  world = "synthetic",
  seed = 1,
  miners = 2,
  steps = function(sim)
    local done = sim:watch_log("Job complete: job_")
    sim:run_for(120000)                     -- let the fleet boot, find the server and register
    local area = sim.world:meta().areas[1]
    sim:dispatch{ type = "ORDER_MINE", params = { x1 = area.x1, z1 = area.z1, x2 = area.x2, z2 = area.z2 } }
    local finished = sim:run_until(function() return done.count >= 2 end, 8 * 3600 * 1000)
    sim:expect(finished, "both mining jobs complete within 8 simulated hours")
  end,
}
