-- Timing probe for the capacity study: 150 turtles (118 miners and their loaders, 16 delivery, 16 support), idle
-- for 30 simulated minutes. Records how fast the simulator runs at this size, and the server's files.
return {
  world = "synthetic",
  seed = 1,
  -- per-bay docks (shakeout, 2026-11-10): worker/support bay 1 hold 16 delivery / 16 support, the other eight
  -- bays 128 miners, so the 150 are 118 miners (each with its loader), 16 delivery and 16 support. per_bay lays
  -- the same out on code from before per-bay types.
  miners = 118,
  workers = 150,
  per_bay = true,
  steps = function(sim)
    local t0 = os.clock()
    sim:run_for(30 * 60000)
    local server
    for _, c in ipairs(sim.sched.computers) do if c.role == "server" then server = c end end
    sim.results.cpu_seconds = os.clock() - t0
    local n = 0
    for _, c in ipairs(sim.sched.computers) do if c.kind == "turtle" and c.state ~= "off" then n = n + 1 end end
    sim.results.turtles_on = n
    sim.results.free = server.disk_obj:free_space()
    sim:expect(n >= 140, "about 150 turtles running (" .. n .. ")")
  end,
}
