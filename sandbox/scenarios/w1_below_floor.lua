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
-- STAGING: ONE SECTOR, NOT A WHOLE AREA. Ore is planted at Y=-60 inside the
-- single sector this orders -- below the floor, inside the deepest level's
-- view. The order names one sector CENTRE, because the server pads an order by
-- the scan radius and snaps it to the 32 step: handing it an area's footprint
-- turns 3 sectors into 15. Two reasons the sector is kept to one. A zone of 16
-- sectors is a long run for a question this small; and "ore remains" is a claim
-- about a whole sector, so any NATURAL unreachable ore anywhere in a big zone
-- would trip the last check for a reason this card is not about (that is the
-- skip-reason card). Nothing natural is overwritten: only plain stone is
-- replaced, and the planting is counted, so a run that planted nothing fails
-- instead of passing quietly.
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
    local dropped  = sim:capture_log("ore below the Y=")
    local verdict  = sim:capture_log("Rescan (128,-2816) done by")
    local exhaust  = sim:capture_log("re-mine exhausted")

    sim:run_for(120000)

    -- One sector centre, on the 32 grid and inside the first mining area
    -- (x 100..163, z -2832..-2769): floor and ceil of 128/32 and -2816/32 both
    -- land on themselves, so the server builds exactly one sector from it.
    local SX, SZ = 128, -2816
    local spots  = { {133, -2811}, {123, -2822}, {138, -2806}, {120, -2808} }
    local planted = 0
    for _, s in ipairs(spots) do
      if sim.world:get(s[1], -60, s[2]) == "minecraft:stone" then
        sim:set_block(s[1], -60, s[2], "minecraft:diamond_ore")
        planted = planted + 1
      end
    end
    sim.results.planted_below_floor = planted
    sim:expect(planted >= 3,
      "planted below-floor ore for the deepest scan level to see (planted "
      .. planted .. " of " .. #spots .. ") -- with none planted this run would "
      .. "prove nothing")

    sim:dispatch{ type = "ORDER_MINE",
      params = { x1 = SX, z1 = SZ, x2 = SX, z2 = SZ, minerCount = 1 } }

    -- POSITIVE 1: the miner says it dropped below-floor ore. Absent before the
    -- fix, because the old code dropped it without a word -- and that silence
    -- is half of what made this expensive to find, since "found nothing" and
    -- "found ore I may not touch" read identically in the log.
    local said = sim:run_until(function() return #dropped.lines >= 1 end,
                               6 * 3600 * 1000)
    sim.results.below_floor_lines = table.concat(dropped.lines, " | ")
    sim:expect(said,
      "the miner reported dropping ore below the dig floor (lines: "
      .. #dropped.lines .. ")")

    -- POSITIVE 2: the server reached a verdict at all. Checked before its
    -- content, because with no rescan the next check reads an empty list and
    -- would pass on no data.
    local judged = sim:run_until(function() return #verdict.lines >= 1 end,
                                 6 * 3600 * 1000)
    sim.results.rescan_verdicts = table.concat(verdict.lines, " | ")
    sim:expect(judged,
      "the server logged a rescan verdict for this sector (verdicts: "
      .. #verdict.lines .. ") -- zero means the job never reached the rescan "
      .. "phase, which is inconclusive rather than a pass")

    -- POSITIVE 3: and it was "clean". This is what actually stops the loop: the
    -- verdict is read straight off foundOres, so excluding ore nobody may dig
    -- from that field is the whole of the fix.
    local clean, remains = 0, 0
    for _, l in ipairs(verdict.lines) do
      if l:find("clean", 1, true)       then clean   = clean   + 1 end
      if l:find("ore remains", 1, true) then remains = remains + 1 end
    end
    sim.results.rescan_clean   = clean
    sim.results.rescan_remains = remains
    sim:expect(clean >= 1 and remains == 0,
      "and the verdict was 'clean', never 'ore remains' for ore nobody may dig "
      .. "(clean " .. clean .. ", remains " .. remains .. ")")

    sim:expect(#exhaust.lines == 0,
      "and the zone never ran out of re-mine attempts (exhausted: "
      .. #exhaust.lines .. ")")
  end,
}
