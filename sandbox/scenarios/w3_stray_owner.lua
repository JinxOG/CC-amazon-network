-- W3 card "The server hands out sectors to a turtle that does not own the job" (fix 9353f36, 1.9.145).
-- The live case (2026-10-15, two computers both labelled node_177): a miner still working a job the server had
-- already given to someone else. Staged here the realistic way: one miner's radio is cut both ways long enough
-- for the server to declare it absent and hand its job to the second miner; then the radio comes back, and the
-- first miner re-registers with its job still running in its own head.
-- Current code: its sector requests (and any completion/failure) for that job are refused, and it is recalled.
-- Fails on the code before the fix: run with --code rev:9353f36~1.
return {
  world = "synthetic",
  seed = 1,
  miners = 2,
  steps = function(sim)
    local done      = sim:watch_log("Job complete: job_")
    local disp      = sim:capture_log("Dispatched job_")
    local assigned  = sim:capture_log("Assigned sector (")
    local refused   = sim:capture_log("refused: the job is")
    local requeued  = sim:capture_log("back to queue")
    sim:run_for(120000)
    local area = sim.world:meta().areas[1]
    sim:dispatch{ type = "ORDER_MINE", params = { x1 = area.x1, z1 = area.z1, x2 = area.x2, z2 = area.z2, minerCount = 1 } }

    -- Wait until the first miner is mining (a non-survey sector assigned), with its modem on.
    local mining = sim:run_until(function()
      for _, l in ipairs(assigned.lines) do if not l:find("SURVEY", 1, true) then return true end end
      return false
    end, 6 * 3600 * 1000)
    sim:expect(mining, "the first miner reached its mine phase")
    if not mining then return end
    local stray = disp.lines[1]:match("%-> (node_%d+)")
    local job = disp.lines[1]:match("Dispatched (job_%d+)")

    -- THE TEST: cut the stray's radio, both ways, for 15 minutes.
    local now = sim.clock:now()
    sim.sched.radio:add_rule{ drop_rate = 1, from = stray, from_ms = now, until_ms = now + 15 * 60000 }
    sim.sched.radio:add_rule{ drop_rate = 1, to = stray, from_ms = now, until_ms = now + 15 * 60000 }
    sim.results.intervention = "radio of " .. stray .. " cut both ways for 15 min (the test)"

    local handed = sim:run_until(function()
      for i = 2, #disp.lines do
        if disp.lines[i]:find(job, 1, true) and not disp.lines[i]:find(stray, 1, true) then return true end
      end
      return false
    end, 14 * 60000)
    sim:expect(handed, "the server gave " .. job .. " to another miner while " .. stray .. " was silent")
    if not handed then return end
    local owner
    for i = 2, #disp.lines do
      if disp.lines[i]:find(job, 1, true) then owner = disp.lines[i]:match("%-> (node_%d+)") end
    end
    local assignedBefore = #assigned.lines

    sim:run_until(function() return sim.clock:now() >= now + 15 * 60000 end, 16 * 60000)  -- radio back
    -- To the end of the job, not a fixed while: the first version stopped 20 minutes after the radio came back,
    -- and the stray's SECTOR_DONE -- the door the 1.9.145 fix missed -- arrived 30 minutes after.
    local finished = sim:run_until(function() return done.count >= 1 end, 12 * 3600 * 1000)

    local strayServed = 0
    for i = assignedBefore + 1, #assigned.lines do
      local l = assigned.lines[i]
      if l:find("to " .. stray, 1, true) and l:find(job, 1, true) then strayServed = strayServed + 1 end
    end
    sim:expect(strayServed == 0, "the stray was given no sector of " .. job .. " after the hand-over (" .. strayServed .. ")")
    sim:expect(#refused.lines >= 1, "the server refused the stray's report for " .. owner .. "'s job (" .. #refused.lines .. " refusals)")
    sim:expect(finished, "the job completes under its new owner")
    sim.results.stray, sim.results.owner, sim.results.job = stray, owner, job
    sim.results.refusals = #refused.lines
    sim.results.stray_sectors_after_handover = strayServed
  end,
}
