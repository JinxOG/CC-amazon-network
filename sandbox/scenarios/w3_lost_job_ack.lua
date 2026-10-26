-- W3 card "A lost JOB_ACK costs the whole job, and it is recorded as complete" (fix 606de4a, 1.9.103).
-- Everything the miner sends the server is dropped from just before the dispatch until 6 s after it, so its JOB_ACK
-- never arrives (the server allows 10 s). The radio drops by message type only for table payloads, and the fleet sends
-- serialised strings, so the whole uplink is cut for those few seconds. Its next heartbeat names the job: the server must accept the job on that evidence ("accepted on that
-- evidence"), never time it out, and the miner must carry on to its first sector with the job still open.
-- On 606de4a~1 the server timed the ack out, recalled the miner and recorded the job as complete.
return {
  world = "synthetic",
  seed = 1,
  miners = 1,
  steps = function(sim)
    local disp     = sim:capture_log("Dispatched job_")
    local accepted = sim:capture_log("accepted on that evidence")
    local timeout  = sim:capture_log("ACK timeout")
    local done     = sim:capture_log("Job complete: job_")
    local sector   = sim:capture_log("Assigned sector (")
    sim:run_for(120000)
    local miner
    for _, c in ipairs(sim.sched.computers) do if c.role == "miner" then miner = c end end
    local rule = { drop_rate = 1, channel = 1, from = miner.name }      -- THE TEST: the miner's uplink, cut
    sim.sched.radio:add_rule(rule)
    local area = sim.world:meta().areas[1]
    sim:dispatch{ type = "ORDER_MINE", params = { x1 = area.x1, z1 = area.z1, x2 = area.x2, z2 = area.z2, minerCount = 1 } }
    sim:run_until(function() return #disp.lines >= 1 end, 5 * 60000)
    rule.until_ms = sim.clock:now() + 6000                              -- back 6 s after the assignment
    sim:run_for(60000)
    sim.sched.radio:remove_rule(rule.id)
    local job = disp.lines[1] and disp.lines[1]:match("Dispatched (job_%d+)")
    sim:expect(job ~= nil, "the job was dispatched")
    if not job then return end
    local onEvidence = sim:run_until(function()
      for _, l in ipairs(accepted.lines) do if l:find(job, 1, true) then return true end end
      return false
    end, 5 * 60000)
    sim:expect(onEvidence, "the server accepted " .. job .. " on the miner's own reports ('accepted on that evidence')")
    local working = sim:run_until(function() return #sector.lines >= 1 end, 30 * 60000)
    sim:expect(working, "the miner carried on to its first sector")
    sim:expect(#timeout.lines == 0, "no ACK timeout (" .. #timeout.lines .. ")")
    sim:expect(#done.lines == 0, "the job was NOT recorded complete (" .. #done.lines .. ")")
    sim.results.job = job
  end,
}
