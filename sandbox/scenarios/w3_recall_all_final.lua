-- W3 card "Recall-all is undone by a job retry: a recalled miner docks and is sent straight back out" (fix 3227577,
-- 1.9.135). A recall-all is sent while a miner is on its way out. Every unfinished job must be cancelled for good:
-- the miner docks and is NOT sent out again (no retry, no re-dispatch) for the next 25 minutes.
-- The live race is staged exactly: straight after the recall-all, the miner's own JOB_FAILED arrives for the same job
-- with a recoverable reason ("placement_blocked", as node_184's did on 2026-10-08 08:39). On 3227577~1 the recall left
-- the job open, so that failure was retried and the miner sent straight back out (retry 1/3, re-dispatched in the same
-- second). With the fix the recall-all has already cancelled it, and a cancel is final.
return {
  world = "synthetic",
  seed = 1,
  miners = 1,
  steps = function(sim)
    local disp      = sim:capture_log("Dispatched job_")
    local working   = sim:capture_log("Assigned sector (")
    local cancelled = sim:capture_log("Recall-all cancelled")
    local retry     = sim:capture_log(" retry ")
    local docked    = sim:capture_log("Docked at bay")
    sim:run_for(120000)
    local area = sim.world:meta().areas[1]
    sim:dispatch{ type = "ORDER_MINE", params = { x1 = area.x1, z1 = area.z1, x2 = area.x2, z2 = area.z2, minerCount = 1 } }
    -- At work in the zone (its first sector handed out), not merely flying: the live 2026-10-08 case was a miner
    -- whose job failed as the recall landed, and the old server retried it.
    local out = sim:run_until(function() return #disp.lines >= 1 and #working.lines >= 1 end, 60 * 60000)
    sim:expect(out, "the miner reached its zone and took a sector")
    if not out then return end
    local job = disp.lines[1]:match("Dispatched (job_%d+)")
    sim:run_for(60000)
    local disp0, retry0, dock0 = #disp.lines, #retry.lines, #docked.lines
    sim:dispatch{ type = "RECALL_ALL", params = { reason = "w3_recall_all_final" } }   -- THE TEST
    sim:run_for(3000)
    local miner = disp.lines[1]:match("%-> (node_%d+)")
    -- The miner's failure report, as a real turtle sends it (a serialised string on channel 1).
    sim:send_radio(1, 1, string.format('{type="JOB_FAILED",from="%s",to="server",seq=990001,ts=0,'
      .. 'payload={jobId="%s",reason="placement_blocked",recoverable=true}}', miner, job), { from = miner })

    local said = sim:run_until(function() return #cancelled.lines >= 1 end, 60000)
    sim:expect(said, "the server cancelled the unfinished job ('Recall-all cancelled')")
    local home = sim:run_until(function() return #docked.lines > dock0 end, 60 * 60000)
    sim:expect(home, "the recalled miner docked")
    sim:run_for(25 * 60000)                               -- long enough for any idle-stuck requeue or retry
    local again = 0
    for i = disp0 + 1, #disp.lines do if disp.lines[i]:find(job, 1, true) then again = again + 1 end end
    local retried = 0
    for i = retry0 + 1, #retry.lines do if retry.lines[i]:find(job, 1, true) then retried = retried + 1 end end
    sim:expect(again == 0, job .. " was not dispatched again after the recall-all (" .. again .. ")")
    sim:expect(retried == 0, job .. " was not retried after the recall-all (" .. retried .. ")")
    sim.results.job = job
  end,
}
