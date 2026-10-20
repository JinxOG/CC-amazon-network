-- A two-miner job on an unmined zone the user named (x 1904..2000, z -2640..-2608), on the world copy of
-- 2026-10-18 17:00 with the fleet booted from its real disks.
local DATA = (os.getenv("SANDBOX_DATA") or "G:/TurtleOS-Sandbox"):gsub("\\", "/")
return {
  world = DATA .. "/worlds/2026-10-18_1700/sim",
  seed = 1,
  steps = function(sim)
    local done = sim:watch_log("Job complete: job_")
    sim:run_for(10 * 60000)                       -- let the fleet boot, find GPS and register
    sim:dispatch{ type = "ORDER_MINE", params = { x1 = 1904, z1 = -2640, x2 = 2000, z2 = -2608, minerCount = 2 } }
    local finished = sim:run_until(function() return done.count >= 2 end, 16 * 3600 * 1000)
    sim:expect(finished, "the mining job on the user's zone (both jobs) complete within 16 simulated hours (" .. done.count .. " done)")
  end,
}
