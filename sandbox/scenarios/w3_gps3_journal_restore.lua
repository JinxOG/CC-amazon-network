-- W3 card GPS 3, release A: the fuel journal, checked at boot against GPS and the measured facing.
-- A miner is rebooted at random points mid-job with GPS up. After each reboot it must measure its facing as before
-- ("Facing:") and its journal must agree ("Journal: agrees with GPS"). Then, in the field, it is put back in the same
-- block turned and rebooted: the check must say "JOURNAL FACING DIFFERS", the turtle must use the MEASURED facing, and
-- the job must still complete with nothing left behind.
--
-- History: the first design (4f557e7) took the facing from the journal and skipped the measurement. This scenario's
-- field put-back showed why that is unsafe: the miner turned to "face" its loader on the journal's facing, missed it,
-- left it behind, then parked at y=200 with its modem swapped out. Run --code rev:4f557e7 to see it.
-- On 1.9.151 (rev:bfc2770) there is no journal: no "Journal:" lines at all.
return {
  world = "synthetic",
  seed = 1,
  miners = 1,
  steps = function(sim)
    local done     = sim:watch_log("Job complete: job_")
    local disp     = sim:capture_log("Dispatched job_")
    local departs  = sim:capture_log("phase: DEPARTING")
    local agrees   = sim:capture_log("Journal: agrees with GPS")
    local differs  = sim:capture_log("JOURNAL FACING DIFFERS")
    local disagree = sim:capture_log("JOURNAL DISAGREES WITH GPS")
    local oneoff   = sim:capture_log("Journal: 1 block from GPS")
    local nothing  = sim:capture_log("Journal: nothing to check")
    local measured = sim:capture_log("] Facing: ")
    local failedJ  = sim:capture_log("Journal write failed")
    local leftLdr  = sim:capture_log("Loader recovery FAILED")
    sim:run_for(120000)
    local area = sim.world:meta().areas[1]
    sim:dispatch{ type = "ORDER_MINE", params = { x1 = area.x1, z1 = area.z1, x2 = area.x2, z2 = area.z2 } }
    local out = sim:run_until(function() return #disp.lines >= 1 and #departs.lines >= 1 end, 10 * 60000)
    sim:expect(out, "the job was dispatched and the miner set off")
    if not out then return end
    local miner = disp.lines[1]:match("%-> (node_%d+)")
    local c = sim.by_name[miner]

    math.randomseed(7)
    local REBOOTS, clean = 5, 0
    for i = 1, REBOOTS do
      sim:run_for(math.random(60, 360) * 1000)
      if done.count >= 1 then break end
      local a0, m0, n0 = #agrees.lines, #measured.lines, #nothing.lines
      sim:reboot(miner)
      local said = sim:run_until(function() return #agrees.lines > a0 or #nothing.lines > n0 end, 5 * 60000)
      local ok = said and #agrees.lines > a0 and #measured.lines > m0
      if ok then clean = clean + 1 end
      sim.results["reboot_" .. i] = string.format("agrees=%s measured=%d nothing=%d",
        tostring(#agrees.lines > a0), #measured.lines - m0, #nothing.lines - n0)
    end
    sim:expect(clean >= 3, string.format("reboots mid-job measured the facing and the journal agreed (%d of %d)", clean, REBOOTS))

    -- In the FIELD (inside the base, homing re-measures anyway): put back in the same block, turned.
    local home = c.home_pos
    local far = sim:run_until(function()
      return math.abs(c.pos.x - home.x) + math.abs(c.pos.z - home.z) > 150 and c.pos.y < home.y
    end, 60 * 60000)
    sim:expect(far, "the miner reached its mining area for the put-back test")
    sim:run_for(20000)
    local d0, l0 = #differs.lines, #leftLdr.lines
    local p = c.pos
    sim.results.putback_at = string.format("%d,%d,%d facing %d -> %d", p.x, p.y, p.z, p.facing, (p.facing + 1) % 4)
    sim:teleport(miner, p.x, p.y, p.z, (p.facing + 1) % 4)
    sim:reboot(miner)
    local caught = sim:run_until(function() return #differs.lines > d0 end, 5 * 60000)
    sim:expect(caught, "the put-back turned was logged: JOURNAL FACING DIFFERS")
    sim:run_for(120000)
    sim:expect(#leftLdr.lines == l0, "and the miner still found its loader (no 'Loader recovery FAILED')")

    local finished = sim:run_until(function() return done.count >= 1 end, 12 * 3600 * 1000)
    sim:expect(finished, "the job completes")
    sim:expect(#disagree.lines == 0, "no journal disagreed with GPS by more than a block (" .. #disagree.lines .. ")")
    sim:expect(#failedJ.lines == 0, "no journal write failed (" .. #failedJ.lines .. ")")
    sim.results.agrees, sim.results.differs, sim.results.one_block = #agrees.lines, #differs.lines, #oneoff.lines
    sim.results.nothing, sim.results.measured = #nothing.lines, #measured.lines
  end,
}
