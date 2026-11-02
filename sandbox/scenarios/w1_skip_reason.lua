-- W1 card "A sector that refuses every ore reports the same as an empty one".
--
-- W3 measured node_183/job_0167 on 1.9.135: two re-mine trips scanned 134 and
-- 100 ores at Y=-52 and mined 0, with no abort line. The log could not say
-- which, because mineOreList printed a bare count --
-- "Skipped N unreachable ores (bedrock/fenced/blocked)" -- so "134 refused" and
-- "nothing was there" rendered identically. That parenthesis also overclaimed:
-- nothing in the move layer can tell bedrock from any other unbreakable block.
--
-- 1.9.154 buckets the reason move.to already returned and navToOre discarded:
--   [MINER] Skipped 4 of 137 attempted (scan 140, 3 below Y=-58): blocked 4
--
-- HOW THE REFUSAL IS MADE REAL. A normal run refuses almost nothing -- ore
-- outside the lease is already dropped by filterToLease before mineOreList sees
-- it -- so this seals a few ore blocks inside a shell of BEDROCK, which the
-- simulator refuses to dig exactly as CC does (sandbox/cc/turtle.lua: "Cannot
-- break block"). The ore still scans, so it still enters the list; it simply
-- cannot be entered from any of its six faces, which is the real shape of the
-- fault -- an ore reported as found and then not mined.
--
-- THE SKIP COUNT IS MUCH LARGER THAN THE NUMBER PLANTED, and that is expected
-- rather than a flattering accident. Measured on 2026-11-02: 4 planted ores,
-- and the miner reported
--   Skipped 2 of 150 attempted (scan 150, 0 below Y=-58): blocked 2
--   Skipped 74 of 150 attempted (scan 150, 0 below Y=-58): blocked 74
--   Skipped 11 of 72 attempted (scan 72, 0 below Y=-58): blocked 11
-- because a 3x3x3 of bedrock does not only wall in its own ore -- it also
-- blocks the paths to natural ore behind it. Every one of those is still a
-- genuine unbreakable-block refusal, so the bucket is right; the count simply
-- is not "the ores I planted". These checks therefore assert the LINE and the
-- BUCKET, never a particular number. The 74-of-150 line is also the closest
-- thing to W3's original 134-of-134 report that can be staged on purpose.
--
-- WHY IT FAILS ON THE OLD CODE: pre-1.9.154 prints the bare-count line, so the
-- new-format watcher stays at zero and the first assertion fails. The old
-- string is asserted absent as well, so a half-applied change cannot pass.
return {
  world = "synthetic",
  seed  = 1,
  miners = 1,
  steps = function(sim)
    -- Plain-substring watchers (watch_log is not a Lua pattern).
    -- " attempted (scan " appears only in the 1.9.154 line.
    local newFmt = sim:capture_log(" attempted (scan ")
    local oldFmt = sim:capture_log("unreachable ores")
    local done   = sim:watch_log("Job complete: job_")

    sim:run_for(120000)

    local area = sim.world:meta().areas[1]
    local cx   = math.floor((area.x1 + area.x2) / 2)
    local cz   = math.floor((area.z1 + area.z2) / 2)

    -- PLANT the ore rather than seal existing ore, and plant it the same way
    -- the test-server scenario does, so both layers stage one fault.
    --
    -- Sealing natural ore was the first attempt and it sealed NOTHING: the
    -- synthetic world grows ore in veins of 5-10 contiguous blocks (synth.lua),
    -- so almost every ore block has an ore neighbour, and a shell would have
    -- overwritten ore -- destroying the very counts this scenario reads. Only
    -- an isolated block was eligible and there are effectively none.
    --
    -- So: find a pocket of plain stone, fill it with bedrock, and put one ore
    -- block in the middle. Nothing natural is touched, the ore still scans, and
    -- it cannot be entered from any of its six faces.
    local sealed, sealedAt = 0, {}
    local y = 0                            -- a scan level: 16, 0, -32, -52
    for dx = -12, 12, 6 do
      for dz = -12, 12, 6 do
        if sealed >= 4 then break end
        local x, z = cx + dx, cz + dz
        -- Every block of the 3x3x3 must be plain stone, or planting would
        -- overwrite something that was already there.
        local clear = true
        for ax = x - 1, x + 1 do
          for ay = y - 1, y + 1 do
            for az = z - 1, z + 1 do
              if sim.world:get(ax, ay, az) ~= "minecraft:stone" then clear = false end
            end
          end
        end
        if clear then
          sim:fill({ x - 1, y - 1, z - 1, x + 1, y + 1, z + 1 }, "minecraft:bedrock")
          sim:set_block(x, y, z, "minecraft:iron_ore")
          sealed = sealed + 1
          sealedAt[sealed] = string.format("%d,%d,%d", x, y, z)
        end
      end
    end
    sim.results.planted_ores = sealed
    sim.results.planted_at   = table.concat(sealedAt, " ")
    -- Without this the whole run could pass having refused nothing at all.
    sim:expect(sealed >= 4,
      "planted 4 ore blocks inside bedrock to force a real refusal (planted "
      .. sealed .. ")")

    sim:dispatch{ type = "ORDER_MINE",
      params = { x1 = area.x1, z1 = area.z1, x2 = area.x2, z2 = area.z2 } }

    local said = sim:run_until(function() return #newFmt.lines >= 1 end,
                               6 * 3600 * 1000)
    sim.results.skip_lines = table.concat(newFmt.lines, " | ")
    sim:expect(said,
      "the miner reported a skip in the 1.9.154 format, with its denominators "
      .. "(lines: " .. #newFmt.lines .. ")")

    -- A reason, and specifically the right one: these ores are walled in, so the
    -- bucket must be "blocked". If it came out "unknown" the classifier stopped
    -- recognising a string move.to really returns, which is the failure the
    -- unknown bucket exists to make visible rather than hide.
    local gotBlocked = false
    for _, l in ipairs(newFmt.lines) do
      if l:find("blocked", 1, true) then gotBlocked = true break end
    end
    sim:expect(gotBlocked,
      "and named the reason as 'blocked' -- walled-in ore is exactly that; "
      .. "'unknown' here would mean the classifier lost a reason string")

    -- Only meaningful BESIDE the positive check above: with no skip at all this
    -- passes on absence alone, which is how a check quietly stops being one.
    -- The gate is the pair.
    sim:expect(#oldFmt.lines == 0,
      "and the bare-count line is gone (old-format lines: " .. #oldFmt.lines
      .. ") -- only evidence alongside the positive check, never on its own")

    -- Sealing must not strand the miner: a refusal is a skip, not an abort.
    local finished = sim:run_until(function() return done.count >= 1 end,
                                   6 * 3600 * 1000)
    sim.results.job_completed = finished
    sim:expect(finished,
      "and the job still completed despite the unreachable ore -- a refused "
      .. "ore must cost one skip, not the sector")
  end,
}
