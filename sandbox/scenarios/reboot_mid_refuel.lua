-- A miner starts short of fuel, so it refuels from its fuel ender chest early on; it is rebooted in the
-- middle of that refuel.
local job = require("scenarios._job")
local Synth = require("world.synth")
return { world = "synthetic", seed = 1, miners = 2,
  layout = function(waypoints)
    local layout = Synth.layout(waypoints, { miners = 2 })
    for _, spec in ipairs(layout) do
      if spec.role == "miner" then spec.turtle.fuel = 3500 end
    end
    return layout
  end,
  steps = job.steps{ label = "both jobs complete despite a reboot during a refuel",
    faults = function(sim) sim:turtle_reboot(0, "node_11", { at_action = "refuel" }) end } }
