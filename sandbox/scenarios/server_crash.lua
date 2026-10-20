-- The dispatch computer crashes 40 minutes into the job and is down for 10 minutes.
local job = require("scenarios._job")
return { world = "synthetic", seed = 1, miners = 2,
  steps = job.steps{ label = "both jobs complete despite a server crash",
    faults = function(sim) sim:server_crash(40 * 60000, 10 * 60000) end } }
