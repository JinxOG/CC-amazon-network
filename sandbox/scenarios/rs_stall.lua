-- Refined Storage listItems stalls for 29 seconds, for an hour, from half an hour into the job.
local job = require("scenarios._job")
return { world = "synthetic", seed = 1, miners = 2,
  steps = job.steps{ label = "both jobs complete despite an RS stall",
    faults = function(sim) sim:rs_stall(30 * 60000, 60 * 60000, 29) end } }
