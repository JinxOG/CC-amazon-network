-- W1 card "A scan level skipped for a turtle below is still reported as a finished sector".
--
-- THE FAULT (W3, job_0058, 2026-09-16). scanSector refuses to dig a fleet
-- member standing on the scan square -- correctly: mining a miner costs the
-- computer, its files, its loader_state and its placed loader, silently. What
-- was wrong is what happened next. It handed back a bare empty list, which is
-- also exactly what a level with no ore in it hands back, so the loop counted
-- the level as scanned and the sector was reported DONE with 0 ore. The server
-- has no way to tell the two apart, so it never re-queued the sector:
-- node_138 recorded (1888,-2912) done with 0 ore while node_139 had found 81
-- ore there.
--
-- Seven separate refusals returned that same bare {} -- no scanner in slot 1,
-- the placement record not persisting, placeDown failing, the peripheral not
-- wrapping, the scan throwing, the scan returning nil, and the turtle guard.
-- Every one of them read as empty ground.
--
-- STAGING. One block on the Y=16 scan square is turned into a turtle. The dig
-- guard recognises any non-minecraft block whose name contains "turtle" as a
-- fleet member (mine_flow.isFleetTurtle), which is the real condition, and the
-- guard then refuses to clear the square. Y=16 is chosen because it is the
-- FIRST level: the miner meets the obstruction on arrival and never has to
-- descend through it, so this stages the scan-placement refusal and nothing
-- else. Blocking a deeper level would also block the descent and would be
-- testing movement instead.
--
-- WHAT IT ASSERTS, AND WHY EACH ONE IS POSITIVE. The headline is an absence --
-- the sector must NOT be reported done -- and an absence is worthless on its
-- own, because a job that never left the dock would satisfy it too. So the
-- absence is checked only alongside two positives: the miner must SAY the level
-- did not run, and the server must put the job BACK ON THE QUEUE. Every message
-- carries its evidence count.
--
-- THE RETRY IS PART OF THE FIX, NOT A WORKAROUND. A turtle on the scan square
-- is usually one crossing a shared shaft, and the sector is perfectly workable
-- ten seconds later; abandoning it immediately would turn a two-second
-- encounter into a re-dispatched job. The staged turtle here never moves, so
-- the retries are exhausted and the sector is given up -- which is the case
-- that has to work. The retry lines are asserted too, so a fix that abandons
-- the sector WITHOUT trying again does not pass.
--
-- WHY IT FAILS ON THE OLD CODE: scanSector returns {} with no reason, the loop
-- treats the level as scanned, and the sector is reported done with 0 ore. The
-- first two checks find no retry line and no "did not run" line, and the third
-- finds the sector reported done -- so all three fail, in the direction that
-- describes the bug.
return {
  world  = "synthetic",
  seed   = 1,
  miners = 2,
  steps = function(sim)
    local didnt_run = sim:capture_log("did not run")
    local retried   = sim:capture_log("retry 1 of ")
    local requeued  = sim:capture_log("back to queue")
    local done      = sim:capture_log("Sector (128,-2816) done by")
    local scanning  = sim:capture_log("128,-2816 Y=16")

    sim:run_for(120000)

    -- The sector centre, on the 32 grid and inside the first mining area
    -- (x 100..163, z -2832..-2769), so one centre in gives one sector out.
    local SX, SZ = 128, -2816
    local SQUARE = 15            -- the scanner goes one below the Y=16 level
    local TURTLE = "computercraft:turtle_advanced"

    sim:set_block(SX, SQUARE, SZ, TURTLE)
    local planted = sim.world:get(SX, SQUARE, SZ)
    sim.results.scan_square_block = tostring(planted)
    sim:expect(planted == TURTLE,
      "a fleet turtle stands on the Y=16 scan square (block is "
      .. tostring(planted) .. ") -- with nothing planted this run would prove "
      .. "nothing, because its headline check is an absence")

    sim:dispatch{ type = "ORDER_MINE",
      params = { x1 = SX, z1 = SZ, x2 = SX, z2 = SZ, minerCount = 1 } }

    -- ANCHOR. The miner reached the level this card is about. Checked first,
    -- because every assertion below is meaningless if it never got there, and
    -- "never got there" must not be allowed to read like a pass.
    local reached = sim:run_until(function() return #scanning.lines >= 1 end,
                                 6 * 3600 * 1000)
    sim.results.reached_level = #scanning.lines
    sim:expect(reached,
      "the miner reached the Y=16 scan level of this sector (lines: "
      .. #scanning.lines .. ")")

    -- POSITIVE 1: it says the level did not run. The old code said nothing at
    -- all, which is the half of this fault that made it expensive: a level that
    -- was skipped and a level that was empty printed the same thing.
    local said = sim:run_until(function() return #didnt_run.lines >= 1 end,
                               6 * 3600 * 1000)
    sim.results.level_did_not_run = table.concat(didnt_run.lines, " | ")
    sim:expect(said,
      "the miner reported that the level did not run (lines: "
      .. #didnt_run.lines .. ")")

    -- POSITIVE 2: and it tried again before giving up.
    sim.results.retry_lines = #retried.lines
    sim:expect(#retried.lines >= 1,
      "and retried the level rather than abandoning the sector on the first "
      .. "refusal (retry lines: " .. #retried.lines .. ")")

    -- POSITIVE 3: the server got the sector back. This is the accounting the
    -- card is about: a sector nobody could scan has to return to the queue.
    local back = sim:run_until(function() return #requeued.lines >= 1 end,
                               6 * 3600 * 1000)
    sim.results.requeued = table.concat(requeued.lines, " | ")
    sim:expect(back,
      "the server put the job back on the queue (lines: " .. #requeued.lines
      .. ") -- a recoverable failure is how the sector gets re-dispatched")

    -- AND THE ABSENCE, last, with both positives already in hand: the sector
    -- was never reported finished. On the old code this is the line that
    -- appeared and told the server there was nothing left to do here.
    sim.results.sector_done_lines = table.concat(done.lines, " | ")
    sim:expect(#done.lines == 0,
      "and the sector was never reported done, which is what stopped it being "
      .. "re-queued (done lines: " .. #done.lines .. " -- "
      .. (done.lines[1] or "none") .. ")")
  end,
}
