-- Proof 2: two miners share one zone (minerCount 2). One is rebooted in the first mine pass. The other's lease is
-- never released, the rebooted one's sector goes back to pending exactly once, no sector is mined twice.
local p = require("scenarios._w3_mine_pass")
return { world = "synthetic", seed = 1, miners = 2, steps = p.steps("shared") }
