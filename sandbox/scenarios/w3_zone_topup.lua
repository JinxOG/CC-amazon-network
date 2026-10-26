-- W3 card "A zone left short of miners tops itself back up" (fix 4c27f64, 1.9.121). Two miners share one zone. Once both
-- are at work, one of them reports its job complete with sectors still left -- the outcome seen on 2026-09-29 (job_0095
-- reported complete 4 minutes into a four-sector zone; the trigger was never established, so it is staged here as a
-- JOB_COMPLETE sent as that miner, a serialised string on channel 1, the way a turtle sends it). The zone, now short of
-- miners, must queue a replacement ('... K of M miner(s) on it', 'Auto-respawn'). On 4c27f64~1 nothing is queued and
-- the zone carries on half-crewed.
return {
  world = "synthetic",
  seed = 1,
  miners = 2,
  steps = function(sim)
    local disp    = sim:capture_log("Dispatched job_")
    local mining  = sim:capture_log("Assigned sector (")
    local short   = sim:capture_log("miner(s) on it")
    local respawn = sim:capture_log("Auto-respawn")
    sim:run_for(120000)
    local area = sim.world:meta().areas[1]
    sim:dispatch{ type = "ORDER_MINE", params = { x1 = area.x1, z1 = area.z1, x2 = area.x2, z2 = area.z2, minerCount = 2 } }
    local both = sim:run_until(function()
      local seen = {}
      local n = 0
      for _, l in ipairs(mining.lines) do
        local m = l:match("to (node_%d+)")
        if m and not seen[m] then seen[m] = true; n = n + 1 end
      end
      return #disp.lines >= 2 and n >= 2
    end, 60 * 60000)
    sim:expect(both, "both miners are at work on the zone")
    if not both then return end
    local leaver = disp.lines[2]:match("%-> (node_%d+)")
    local job = disp.lines[2]:match("Dispatched (job_%d+)")
    sim:run_for(60000)
    local s0, r0 = #short.lines, #respawn.lines
    sim:send_radio(1, 1, string.format('{type="JOB_COMPLETE",from="%s",to="server",seq=990002,ts=0,payload={jobId="%s",result={}}}',
      leaver, job), { from = leaver })                                  -- THE TEST: one miner leaves early
    local topped = sim:run_until(function() return #respawn.lines > r0 end, 5 * 60000)
    sim:expect(#short.lines > s0, "the server saw the zone left short ('K of M miner(s) on it')")
    sim:expect(topped, "and queued a replacement ('Auto-respawn')")
    sim.results.leaver, sim.results.job = leaver, job
  end,
}
