-- W1 card "Miners report ore they are not allowed to dig, and re-mine it forever".
--
-- The geo scanner sees further than the miner may go: radius 16 from the
-- deepest scan level (Y=-52) reaches Y=-68, while the bedrock safety floor is
-- MIN_ORE_Y = -58. Only that level crosses it; 16, 0 and -32 cannot.
--
-- Ore below the floor used to be counted as FOUND and sent to the server in
-- SECTOR_DONE.foundOres, and only then silently dropped at mining time. The
-- server's rescan verdict is driven straight off that field
-- (central_server.lua: hasOre = next(p.foundOres) ~= nil), so it read "ore
-- remains", re-queued the sector, the miner dropped the same ore again and
-- reported 0 mined -- a loop that ended only at "re-mine exhausted". W6
-- measured 12 wasted sectors and ~35 miner-minutes on node_139 alone
-- (2026-09-10); on 2026-09-11 jobs 0043/0044 found 454 ores across 20 types and
-- mined 0 of every one.
--
-- STAGING. A grid of ore is planted at Y=-60 across the first mining area --
-- below the floor, inside the deepest level's view. Nothing natural is touched:
-- only plain stone is replaced, and the planting is counted so a run that
-- planted nothing cannot pass.
--
-- WHAT IT ASSERTS, AND WHY NOT JUST "NO ore remains". An absence is not
-- evidence on its own: a run where no rescan happened at all would show zero
-- "ore remains" lines and look identical to a fix. So the gate is positive on
-- both sides -- the miner must SAY it dropped below-floor ore, and the server
-- must deliver a "clean" rescan verdict. The absence of "ore remains" is
-- checked beside those, never instead of them.
--
-- WHY IT FAILS ON THE OLD CODE: pre-fix there is no below-floor line at all, so
-- the first check fails; and the planted ore reaches foundOres, so the rescan
-- says "ore remains" and the last check fails too.
return {
  world  = "synthetic",
  seed   = 1,
  miners = 2,
  steps = function(sim)
    local dropped  = sim:capture_log("dig floor at scan level")
    local clean    = sim:capture_log("— clean [")
    local remains  = sim:capture_log("— ore remains [")
    local exhaust  = sim:capture_log("re-mine exhausted")
    local done     = sim:watch_log("Job complete: job_")

    sim:run_for(120000)

    -- Plant below-floor ore on a 16-block grid, at Y=-60 (synthetic terrain is
    -- stone from -63 up, bedrock at -64).
    local area    = sim.world:meta().areas[1]
    local planted = 0
    for x = area.x1 + 8, area.x2 - 8, 16 do
      for z = area.z1 + 8, area.z2 - 8, 16 do
        if sim.world:get(x, -60, z) == "minecraft:stone" then
          sim:set_block(x, -60, z, "minecraft:diamond_ore")
          planted = planted + 1
        end
      end
    end
    sim.results.planted_below_floor = planted
    sim:expect(planted >= 8,
      "planted below-floor ore for the deepest scan level to see (planted "
      .. planted .. ") -- with none planted this run would prove nothing")

    sim:dispatch{ type = "ORDER_MINE",
      params = { x1 = area.x1, z1 = area.z1, x2 = area.x2, z2 = area.z2 } }

    -- POSITIVE 1: the miner says it dropped below-floor ore. Absent before the
    -- fix, because the old code dropped it without a word.
    local said = sim:run_until(function() return #dropped.lines >= 1 end,
                               12 * 3600 * 1000)
    sim.results.below_floor_lines = table.concat(dropped.lines, " | ")
    sim:expect(said,
      "the miner reported dropping ore below the dig floor (lines: "
      .. #dropped.lines .. ")")

    local finished = sim:run_until(function() return done.count >= 2 end,
                                   12 * 3600 * 1000)
    sim.results.job_completed = finished
    sim:expect(finished, "both mining jobs completed within 12 simulated hours")

    -- POSITIVE 2: the server reached a verdict, and it was "clean". This is what
    -- actually stops the loop: the rescan's verdict is read straight off
    -- foundOres, so excluding unreachable ore there is the whole fix.
    sim.results.rescan_clean   = #clean.lines
    sim.results.rescan_remains = #remains.lines
    sim:expect(#clean.lines >= 1,
      "the server returned a 'clean' rescan verdict (clean: " .. #clean.lines
      .. ") -- zero means no rescan happened and the next check proves nothing")

    sim:expect(#remains.lines == 0,
      "and never 'ore remains' for ore nobody may dig (remains: "
      .. #remains.lines .. ") -- only evidence beside the clean verdict above")

    sim:expect(#exhaust.lines == 0,
      "and no zone ran out of re-mine attempts (exhausted: " .. #exhaust.lines .. ")")
  end,
}
