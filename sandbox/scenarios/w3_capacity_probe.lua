-- Timing probe for the capacity study: 150 turtles (8 miners and their loaders, the rest delivery and support), idle
-- for 30 simulated minutes. Records how fast the simulator runs at this size, and the server's files.
return {
  world = "synthetic",
  seed = 1,
  miners = 8,
  workers = 150,
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
