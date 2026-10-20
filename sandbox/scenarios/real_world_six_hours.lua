-- The speed benchmark on the real world copy (spec 15.1): the whole fleet as the 2026-10-18 17:00 backup had it, a
-- two-miner job on the zone the user named (x 1904..2000, z -2640..-2608), six simulated hours.
local DATA = (os.getenv("SANDBOX_DATA") or "G:/TurtleOS-Sandbox"):gsub("\\", "/")
return {
  world = DATA .. "/worlds/2026-10-18_1700/sim",
  seed = 1,
  steps = function(sim)
    sim:run_for(10 * 60000)                       -- boot, find GPS, register
    sim:dispatch{ type = "ORDER_MINE", params = { x1 = 1904, z1 = -2640, x2 = 2000, z2 = -2608, minerCount = 2 } }
    sim:run_until(6 * 3600 * 1000)
    local mined = 0
    for name, n in pairs(sim.sched.storage.amounts) do
      if name:find("ore", 1, true) then mined = mined + n - (sim.initial_storage[name] or 0) end
    end
    sim.results.ore_gained = mined
    sim:expect(mined > 1000, "the two miners brought in ore from the zone (" .. mined .. " blocks)")
  end,
}
