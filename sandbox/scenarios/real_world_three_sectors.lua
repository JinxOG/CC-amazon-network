-- The same zone as real_world_six_hours, ordered the way that makes the server cut it into 3 sectors: the order is
-- the sector CENTRES (1920..1984, z -2624); the footprint 1904..2000 x -2640..-2608 is what the dashboard draws around
-- them. real_world_six_hours passes the footprint corners as the order, which the server pads to 5 x 3 = 15 sectors,
-- twelve of them outside the imported world.
local DATA = (os.getenv("SANDBOX_DATA") or "G:/TurtleOS-Sandbox"):gsub("\\", "/")
return {
  world = DATA .. "/worlds/2026-10-18_1700/sim",
  seed = 1,
  steps = function(sim)
    sim:run_for(10 * 60000)                       -- boot, find GPS, register
    sim:dispatch{ type = "ORDER_MINE", params = { x1 = 1920, z1 = -2624, x2 = 1984, z2 = -2624, minerCount = 2 } }
    sim:run_until(6 * 3600 * 1000)
    local mined = 0
    for name, n in pairs(sim.sched.storage.amounts) do
      if name:find("ore", 1, true) then mined = mined + n - (sim.initial_storage[name] or 0) end
    end
    sim.results.ore_gained = mined
    sim:expect(mined > 1000, "the two miners brought in ore from the zone (" .. mined .. " blocks)")
  end,
}
