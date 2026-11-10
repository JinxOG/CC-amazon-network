-- W1, 1.9.167: a RESUMED sector's survey must describe the Y it actually
-- covered, not the whole column.
--
-- THE FAULT. The ore index publishes a per-sector census with a `band` saying
-- which Y the counts describe. That band was built from SCAN_LEVELS and
-- SCAN_RADIUS -- the nominal column, -68..32 -- every single time. But a miner
-- that reboots mid-sector resumes AT THE LEVEL IT REACHED and never re-scans
-- the levels it already finished (which is right: that ground has been dug, and
-- redoing it was most of what a resume used to cost). So a sector resumed at
-- level 3 censuses two levels out of four, covering roughly -68..-17, and
-- published those counts against -68..32.
--
-- Every count was therefore SHORT, by however much ore sat in the levels it
-- skipped, and nothing in the payload said so. That is worse than a missing
-- field: a consumer reading "4 iron in Y -68..32" cannot tell it from a sector
-- genuinely holding 4 iron, so the index does not look incomplete, it looks
-- wrong -- and a planner sourcing a build from it would under-order from a
-- sector that was actually rich. The design document's own rule is that an
-- absent field means "this survey did not say" and never zero; this was the
-- same error with a number in place of the absence.
--
-- WHY IT NEEDS ITS OWN SCENARIO. w1_resume_after_restart restarts the world the
-- moment the miner reaches the MINING phase, which is during its FIRST scan
-- level -- so it resumes at level 1, re-scans everything, and its survey is
-- legitimately complete. That run reports 12 surveys and 0 partial: the
-- scenario is right for its own card and simply never reaches this state. The
-- consistency checks it carries would have passed on the old code too.
--
-- HOW THIS ONE REACHES IT. It waits for the miner to have finished scanning its
-- THIRD level before restarting the world, so the resume must skip levels 1 and
-- 2.
--
-- The anchor is the miner's own per-level census line, "Census: N blocks in Y
-- -48..-17". My first attempt waited for its progress line "depth 3/4" and
-- failed with 0 lines: sendProgress goes to the SERVER, not through print, so it
-- never reaches a log the simulator can read. The census line does, and it is a
-- better anchor anyway -- -48..-17 is the band censusBand gives level 3 of this
-- geometry, so the wait names the level by the very arithmetic under test rather
-- than by a counter kept somewhere else. The run log of the failed attempt
-- confirms the four levels tile the column exactly once: 0..32, -16..-1,
-- -48..-17, -68..-49.
--
-- WHY IT FAILS ON THE OLD CODE: the band was the nominal column whatever
-- happened, so no survey line could ever report fewer levels than the total,
-- and the partial check below finds nothing. On 1.9.167 the resumed sector
-- reports 2 (or 3) of 4 and names the narrower band.
local function node(sim, role)
  for _, c in ipairs(sim.sched.computers) do if c.role == role then return c end end
end

return {
  world  = "synthetic",
  seed   = 1,
  -- ONE MINER, for the reason w1_scan_level_blocked carries: two of them
  -- contend for the base aisle and can burn a job's retries on each other
  -- before either gets deep, and this scenario needs its miner to reach level
  -- 3 of a sector. The fault is single-turtle behaviour.
  miners = 1,
  steps = function(sim)
    local disp    = sim:capture_log("Dispatched job_")
    -- Level 3's owned band, which is level 3's census and no other's.
    local deep    = sim:capture_log("blocks in Y -48..-17")
    local survey  = sim:capture_log(" survey: Y ")
    local resumed = sim:capture_log("resuming sector (")
    local complete = sim:capture_log("Job complete: ")

    sim:run_for(120000)
    local miner = node(sim, "miner")
    sim:expect(miner ~= nil, "found a miner")
    if not miner then return end

    local area = sim.world:meta().areas[1]
    sim:dispatch{ type = "ORDER_MINE",
      params = { x1 = area.x1, z1 = area.z1, x2 = area.x1, z2 = area.z1,
                 minerCount = 1 } }
    sim:run_until(function() return #disp.lines >= 1 end, 10 * 60000)
    sim:expect(#disp.lines >= 1, "the job was dispatched")
    if #disp.lines < 1 then return end

    -- ANCHOR: deep in a sector, not at its first level. Checked and returned on,
    -- because every assertion below is about what a resume SKIPS -- a run that
    -- restarted at level 1 would report a complete survey and look like a pass.
    local atDepth = sim:run_until(function() return #deep.lines >= 1 end,
                                  6 * 3600000)
    sim.results.reached_level_3 = #deep.lines
    sim:expect(atDepth,
      "the miner censused the THIRD scan level of a sector before the restart ("
      .. #deep.lines .. " lines in Y -48..-17) -- restarting at level 1 "
      .. "re-scans everything and cannot produce a partial survey at all")
    if not atDepth then return end

    local gen = miner.gen
    sim:world_restart(sim.clock:now() - sim.t0 + 1000)      -- THE TEST

    sim:run_until(function() return miner.gen ~= gen end, 15 * 60000)
    sim:expect(miner.gen ~= gen,
      "the miner rebooted (gen " .. gen .. " -> " .. miner.gen .. ")")

    -- It must actually resume rather than fly home: a miner that went home and
    -- took a fresh sector would survey all four levels of it and the partial
    -- check below would find nothing, for a reason that is not this fault.
    local back = sim:run_until(function() return #resumed.lines >= 1 end,
                               15 * 60000)
    sim.results.resume_lines = #resumed.lines
    sim:expect(back, "and resumed its sector where it stood (" .. #resumed.lines
      .. " resume lines) -- without a resume there is nothing partial to report")
    if not back then return end

    sim:run_until(function() return #complete.lines >= 1 end, 6 * 3600000)
    sim:run_for(60000)

    -- THE POINT: a survey that covered part of the column says so, in both of
    -- the ways a consumer might read it -- the level count AND the band itself.
    local partial, badBand = 0, {}
    for _, l in ipairs(survey.lines) do
      local lo, hi, n, of = l:match("Y (-?%d+)%.%.(-?%d+) from (%d+) of (%d+) levels")
      if lo then
        lo, hi, n, of = tonumber(lo), tonumber(hi), tonumber(n), tonumber(of)
        if n < of then
          partial = partial + 1
          -- A SHORT COUNT MUST COME WITH A SHORT BAND. Reporting 2 of 4 levels
          -- and still claiming -68..32 would be the original fault wearing a
          -- label: the number a planner reads is the band, not the level count.
          if lo <= -68 and hi >= 32 then badBand[#badBand + 1] = l end
        end
      end
    end
    sim.results.survey_lines = #survey.lines
    sim.results.survey_partial_lines = partial
    sim.results.partial_with_full_band = table.concat(badBand, " | ")

    sim:expect(#survey.lines >= 1,
      "the miner published sector surveys (" .. #survey.lines
      .. ") -- with none the checks below cannot fail")
    sim:expect(partial >= 1,
      "the resumed sector reported covering FEWER levels than the sector has ("
      .. partial .. " partial of " .. #survey.lines .. " surveys) -- this is "
      .. "the line the old code could never print")
    -- partial >= 1 IS PART OF THIS CHECK, not just of the one above it. With no
    -- partial survey to examine, "none of them claimed the full column" is
    -- vacuously true -- a pass state identical to the no-data state, which on
    -- the old code is exactly what it was: 0 inconsistent of 0. A verdict that
    -- cannot fail for want of evidence must report that as a failure.
    sim:expect(partial >= 1 and #badBand == 0,
      "and the band each partial survey named was narrower than the full column "
      .. "(" .. #badBand .. " of " .. partial .. " partial surveys examined "
      .. "still claiming -68..32: " .. (badBand[1] or "none") .. ")")
  end,
}
