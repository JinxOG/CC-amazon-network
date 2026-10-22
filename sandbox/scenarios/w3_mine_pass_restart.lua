-- Proof 3: the whole world restarts (dispatch server included, as the live 12:03 daily restart) while the miner is
-- in its first mine pass. The kept zone must come back through active_zones.dat and be reused, not resurveyed.
local p = require("scenarios._w3_mine_pass")
return { world = "synthetic", seed = 1, miners = 1, steps = p.steps("restart") }
