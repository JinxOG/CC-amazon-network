-- A miner is rebooted in the middle of a dump, with its ore ender chest placed in the world.
--
-- node_181, 2026-10-08: DUMPING at 22:48:33, the reboot at 22:52 left the chest standing near
-- 2048,16,-3392. Slot 16 was empty at boot, so the pre-departure preflight refused every job with
-- slot_16_must_hold_the_ore_ender_chest, and the miner stayed benched until the user handed it a
-- new chest. Nothing on disk said a chest was out there, so nothing could go back for it.
--
-- The ore chest is now a base.ledger kind, recorded before the place and recovered at boot.
--
-- WHAT THIS ASSERTS, AND WHY NOT "THE JOBS COMPLETE". With two miners the other one finishes both
-- jobs while the crippled one sits benched, so a completion check passes on broken code -- it did,
-- on master, before this was rewritten. The symptom itself is the refusal, so that is what is
-- counted: on old code the rebooted miner refuses for a missing chest, and on fixed code it
-- recovers the chest and never refuses.
local job = require("scenarios._job")
return { world = "synthetic", seed = 1, miners = 2,
  steps = function(sim)
    local done    = sim:watch_log("Job complete: job_")
    local refused = sim:watch_log("must_hold_the_ore_ender_chest")
    local ledger  = sim:watch_log("Ledger: recovered the ore_chest")

    sim:run_for(120000)
    sim:turtle_reboot(0, "node_11", { at_action = "drop" })
    local area = sim.world:meta().areas[1]
    sim:dispatch{ type = "ORDER_MINE", params = { x1 = area.x1, z1 = area.z1, x2 = area.x2, z2 = area.z2 } }

    local finished = sim:run_until(function() return done.count >= 2 end, 10 * 3600 * 1000)
    sim:expect(finished, "both jobs complete despite a reboot during a dump within 10 simulated hours")
    sim:expect(refused.count == 0,
      "no miner is benched for a missing ore chest after a reboot mid-dump (refusals: "
      .. tostring(refused.count) .. ")")
    sim:expect(ledger.count >= 1,
      "the ledger recovered a placed ore chest at boot (recovery lines: "
      .. tostring(ledger.count) .. ") -- zero means the reboot never caught a placed chest, so "
      .. "this scenario proved nothing")
  end }
