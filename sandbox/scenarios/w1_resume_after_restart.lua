-- W1 card "After a restart, turtles resume the job where they stand instead of
-- flying home (36 min lost per miner today)". Asked for by the user 2026-11-03:
-- "turtles can recover when a server reboots without going back to base. They
-- should be able to recover and just continue the job from where they are at.
-- Returning back to base wastes a lot of time."
--
-- WHAT IT COST, MEASURED LIVE on the 13:02 UTC daily restart, all five miners
-- mid-job about 2,000 blocks out: boot recovery at 13:02:56-13:03:00, docked
-- 13:20:42-13:22:07, departing again 13:21:45-13:26:53, and node_178 did not
-- mine until 13:39:36. About 36 minutes each, nearly all of it a round trip to
-- collect a job the server re-sends on registration anyway. Every single day.
--
-- WHAT THE FIX IS. Three pieces, and the middle one is the reason this card was
-- not simply "skip the flight":
--   1. The sector order goes on disk beside the loader record (loader_state),
--      because a reboot loses it with the job coroutine and NOTHING else has
--      it: the server withholds the sector on re-registration whenever the
--      turtle is not awaiting one ("mid-sector, it already has its order" --
--      true after a RE_REGISTER, false after a reboot), and SECTOR_REQUEST
--      cannot recover it either, because the held sector left the zone's list
--      when it was assigned. Asking would start a DIFFERENT sector and abandon
--      this one, which is the "sector skipped" this card calls a FAILED IF.
--   2. Boot recovery retrieves the loader as before but then holds position
--      instead of flying home. The loader is in the pack, not abandoned, which
--      is what makes it safe: the worst case if no job ever arrives is a turtle
--      idling in the field rather than at its dock.
--   3. The job runner decides, through mine_flow.resumeDecision -- pure and
--      unit-tested over nine ways home -- and on a resume skips base.depart and
--      the climb to the sky lane, then starts the sector from its own recorded
--      order rather than asking for one.
--
-- WHAT THIS SCENARIO ASSERTS, and why each one is here:
--   * the miner SAYS it resumed, naming the sector. A positive: the absence of
--     a dock line could just as easily mean the job died.
--   * no DOCKED line between the restart and mining again. The card's own
--     wording, and the whole point.
--   * it is mining again within five minutes of its boot line.
--   * the job still finishes, and no sector is reported done twice. Resuming
--     the wrong sector would show up here and nowhere else.
--
-- SECTOR GRANULARITY, SAID PLAINLY. The resume restarts the sector at its first
-- scan level, not at the exact ore. Nothing is mined twice -- what was taken is
-- no longer there to find -- and nothing is skipped, but the scans done before
-- the reboot are redone. Per-ore resume needs the server's per-sector progress
-- and is a separate card. This scenario therefore does not assert that no ore
-- is re-scanned, because it is.
--
-- WHY IT FAILS ON THE OLD CODE: the old path always flew home, so the resume
-- line never appears, a DOCKED line does, and the gap from boot to mining again
-- is the round trip rather than five minutes.
local function node(sim, role)
  for _, c in ipairs(sim.sched.computers) do if c.role == role then return c end end
end

return {
  world  = "synthetic",
  seed   = 1,
  miners = 1,
  steps = function(sim)
    local disp    = sim:capture_log("Dispatched job_")
    -- The miner's own PRINT, not its progress message. sendProgress needs a
    -- working modem and during loader recovery the miner's is detached -- the
    -- first run of this scenario reported 0 resume lines while the resume had
    -- plainly happened, because "Send failed (modem detached or missing?)" ate
    -- the radio copy. The local log is kept and shipped later, so it is the
    -- record that always exists.
    local resumed = sim:capture_log("resuming sector (")
    local wentHome = sim:capture_log("going home: ")
    local docked  = sim:capture_log("phase: DOCKED")
    local mining  = sim:capture_log("phase: MINING")
    local booted  = sim:capture_log("[MINER] v")
    local done    = sim:capture_log("done by")
    local complete = sim:capture_log("Job complete: ")

    sim:run_for(120000)
    local miner = node(sim, "miner")
    sim:expect(miner ~= nil, "found a miner")
    if not miner then return end

    -- The same zone w3_sector_progress_restart uses, which is established to
    -- hold minable ore: the first area's CORNER, which the server pads by the
    -- scan radius and snaps to the 32 step. Picking sector centres by hand is
    -- how I landed on bare ground once already.
    local area = sim.world:meta().areas[1]
    sim:dispatch{ type = "ORDER_MINE",
      params = { x1 = area.x1, z1 = area.z1, x2 = area.x1, z2 = area.z1, minerCount = 1 } }
    sim:run_until(function() return #disp.lines >= 1 end, 10 * 60000)
    local job = disp.lines[1] and disp.lines[1]:match("Dispatched (job_%d+)")
    sim:expect(job ~= nil, "the job was dispatched")
    if not job then return end

    -- MID-SECTOR, not between sectors. The loader has to be standing and the
    -- order recorded, or this tests the easy case: a turtle between sectors has
    -- nothing to resume and going home was never wrong for it.
    local atWork = sim:run_until(function() return #mining.lines >= 1 end, 4 * 3600000)
    sim:expect(atWork, "the miner reached the MINING phase before the restart ("
      .. #mining.lines .. " lines)")
    if not atWork then return end
    sim:run_for(60000)   -- let it get properly into the sector

    local d0, m0 = #docked.lines, #mining.lines
    local gen0 = miner.gen

    -- Fault times are milliseconds after the START of steps (sim.t0), not from
    -- now, so a bare 0 here would schedule the restart hours in the past.
    sim:world_restart(sim.clock:now() - sim.t0 + 1000)   -- THE TEST: all reboot, miner mid-sector

    -- CAME BACK, judged on the simulator's own view of the computer rather than
    -- on a shipped log line. The boot line is printed with the modem off during
    -- recovery and reaches the server only on a later flush, so waiting for it
    -- measures log shipping, not rebooting -- the first run of this scenario
    -- failed here with 0 boot lines while the restart had plainly happened.
    -- c.gen is what faults.lua itself uses to tell one boot from the next.
    local cameBack = sim:run_until(function() return miner.gen ~= gen0 end, 10 * 60000)
    sim:expect(cameBack, "the miner rebooted after the world restart (gen "
      .. tostring(gen0) .. " -> " .. tostring(miner.gen) .. ")")
    if not cameBack then return end
    local bootAt = sim.clock:now()

    -- POSITIVE: it said it was resuming, and which sector.
    local saidResume = sim:run_until(function() return #resumed.lines >= 1 end, 10 * 60000)
    sim.results.resume_lines = table.concat(resumed.lines, " | ")
    sim.results.went_home_lines = table.concat(wentHome.lines, " | ")
    sim:expect(saidResume,
      "the miner reported resuming its sector where it stands (resume lines: "
      .. #resumed.lines .. ", went-home lines: " .. #wentHome.lines
      .. (wentHome.lines[1] and (" -- " .. wentHome.lines[1]) or "") .. ")")

    -- AND IT IS MINING AGAIN, within the card's five minutes of the boot line.
    -- run_until evaluates the condition once more when its budget runs out, so
    -- it can return true AFTER the deadline -- the first run of this scenario
    -- "passed" at 10.0 minutes against a 5-minute budget. The claim is a
    -- duration, so the duration is what is asserted.
    local backAtWork = sim:run_until(function() return #mining.lines > m0 end, 30 * 60000)
    local mins = (sim.clock:now() - bootAt) / 60000
    sim.results.minutes_to_mining = string.format("%.1f", mins)
    sim:expect(backAtWork and mins <= 5,
      "it was mining again within 5 minutes of booting (took "
      .. sim.results.minutes_to_mining .. " min; mining again: "
      .. tostring(backAtWork) .. ")")

    -- AND IT NEVER WENT HOME. Checked after the positives, so an absence cannot
    -- pass on a job that simply died.
    sim.results.docked_after_restart = #docked.lines - d0
    sim:expect(#docked.lines == d0,
      "no DOCKED line between the restart and mining again ("
      .. (#docked.lines - d0) .. ") -- the 36 minutes this card is about")

    -- AND THE JOB STILL FINISHES, with no sector done twice. Resuming the wrong
    -- sector shows up here and nowhere else.
    local finished = sim:run_until(function() return #complete.lines >= 1 end, 6 * 3600000)
    sim:expect(finished, "the job completed after the restart")

    local seen, dupes = {}, 0
    for _, l in ipairs(done.lines) do
      local sx, sz = l:match("Sector %((-?%d+),(-?%d+)%) done by")
      if sx then
        local k = sx .. "," .. sz
        if seen[k] then dupes = dupes + 1 end
        seen[k] = true
      end
    end
    sim.results.sector_done_lines = #done.lines
    sim.results.sectors_done_twice = dupes
    sim:expect(dupes == 0,
      "no sector was reported done twice (" .. dupes .. " of " .. #done.lines
      .. " done lines) -- a resume onto the wrong sector would double one up")
  end,
}
