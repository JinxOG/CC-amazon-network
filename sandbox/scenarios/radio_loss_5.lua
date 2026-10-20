-- 5% of radio messages are lost for the whole job.
local job = require("scenarios._job")
return { world = "synthetic", seed = 1, miners = 2,
  steps = job.steps{ label = "both jobs complete with 5% radio loss",
    faults = function(sim) sim:radio_loss(0, 12 * 3600 * 1000, 0.05) end } }
