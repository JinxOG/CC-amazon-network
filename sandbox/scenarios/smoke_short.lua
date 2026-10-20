-- Half an hour of mining on the synthetic world: short enough for tests that compare whole runs.
return {
  world = "synthetic",
  seed = 1,
  miners = 2,
  workers = 6,
  steps = function(sim)
    sim:run_for(120000)
    local area = sim.world:meta().areas[1]
    sim:dispatch{ type = "ORDER_MINE", params = { x1 = area.x1, z1 = area.z1, x2 = area.x2, z2 = area.z2 } }
    sim:run_for(1800000)
  end,
}
