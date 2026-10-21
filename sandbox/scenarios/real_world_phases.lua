-- The three-sector job on the real world copy, run until the job is complete (not a fixed six hours): used to time the job's
-- phases against the live job_0206 and the T2 run (sandbox/tools/phase_fit.py).
package.path = "sandbox/?.lua;" .. package.path
local DATA = (os.getenv("SANDBOX_DATA") or "G:/TurtleOS-Sandbox"):gsub("\\", "/")
return {
  world = DATA .. "/worlds/2026-10-18_1700/sim",
  seed = 1,
  steps = function(sim)
    sim:run_for(10 * 60000)
    sim:dispatch{ type = "ORDER_MINE", params = { x1 = 1920, z1 = -2624, x2 = 1984, z2 = -2624, minerCount = 2 } }
    local w = sim:watch_log("Job complete: job_")
    sim:run_until(function() return w.count > 0 end, 6 * 3600 * 1000)
    sim:expect(w.count > 0, "the job completed")
  end,
}
