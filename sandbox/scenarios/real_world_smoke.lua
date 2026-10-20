-- The fleet exactly as the world copy of 2026-10-18 17:00 had it: every computer boots from its real disk, on the
-- real depot, with the real storage contents. This version only boots it and lets it settle (no job); the job
-- scenario takes the mining zone the user names.
local DATA = (os.getenv("SANDBOX_DATA") or "G:/TurtleOS-Sandbox"):gsub("\\", "/")
return {
  world = DATA .. "/worlds/2026-10-18_1700/sim",
  seed = 1,
  steps = function(sim)
    local registered = sim:watch_log("Registered successfully")
    sim:run_for(30 * 60000)
    sim:expect(registered.count >= 10, "at least ten turtles registered with the server (" .. registered.count .. ")")
  end,
}
