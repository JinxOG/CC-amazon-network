-- W3 card "A job handed on after a reboot re-surveys its zone and restarts the half-mined sector" (job_0210,
-- 2026-10-22). Proof 1 of the spec owner's three: a solo miner rebooted in its first mine pass, nothing done yet.
-- The zone must not be surveyed again; job time and ore are reported to compare with today's rebuild.
-- Fails on 1.9.151 (rev:bfc2770): the zone is surveyed twice.
local p = require("scenarios._w3_mine_pass")
return { world = "synthetic", seed = 1, miners = 1, steps = p.steps("reboot") }
