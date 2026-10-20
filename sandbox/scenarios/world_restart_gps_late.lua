-- The whole world restarts 45 minutes in, and the GPS hosts come back ten minutes late (the 10-05 incident).
local job = require("scenarios._job")
return { world = "synthetic", seed = 1, miners = 2,
  steps = job.steps{ label = "both jobs complete despite a world restart with late GPS",
    faults = function(sim) sim:world_restart(45 * 60000, { gps_delay = 10 * 60000 }) end } }
