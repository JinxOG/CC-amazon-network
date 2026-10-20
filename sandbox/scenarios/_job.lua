-- Shared by the named scenarios: boot the fleet, order a two-miner job on the first mining area, and wait for it.
local M = {}

-- opts.faults(sim): called once the job is ordered, to schedule faults (times count from the scenario's start)
-- opts.label: what the check is called in the report
function M.steps(opts)
  return function(sim)
    local done = sim:watch_log("Job complete: job_")
    sim:run_for(120000)
    if opts.faults then opts.faults(sim) end
    local area = sim.world:meta().areas[1]
    sim:dispatch{ type = "ORDER_MINE", params = { x1 = area.x1, z1 = area.z1, x2 = area.x2, z2 = area.z2 } }
    local finished = sim:run_until(function() return done.count >= 2 end, (opts.hours or 10) * 3600 * 1000)
    sim:expect(finished, (opts.label or "both mining jobs complete") .. " within " .. (opts.hours or 10) .. " simulated hours")
  end
end

return M
