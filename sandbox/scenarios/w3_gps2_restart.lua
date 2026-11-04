-- W3 card "GPS 2", the watcher's FAILED verdict (2026-11-03): a ~91 h live outage was logged as SEVEN outages,
-- because each server restart forgot GPS was down ('GPS CHECK FAILED' again ~10 s after every boot), and its one
-- 'GPS check: back after 15515s' counted from the last restart instead of the outage's start.
-- Every GPS host goes silent for 5 minutes, and the server restarts 2 minutes in, with a job waiting.
--   * exactly ONE 'GPS CHECK FAILED' (the restart is not a new outage), and one 'still down after a server restart'
--   * dispatch still held after the restart: no job out until GPS is back
--   * the one 'back after Ns' counts from the outage's real start: about 300 s, not about 180 s
-- On the code before the fix: two 'GPS CHECK FAILED' and 'back after' about 180 s.
return {
  world = "synthetic",
  seed = 1,
  miners = 2,
  steps = function(sim)
    local failed     = sim:capture_log("GPS CHECK FAILED")
    local carried    = sim:capture_log("still down after a server restart")
    local back       = sim:capture_log("GPS check: back after")
    local dispatched = sim:capture_log("Dispatched job_")
    local online     = sim:capture_log("Central server online")
    local server
    for _, c in ipairs(sim.sched.computers) do if c.role == "server" then server = c end end
    sim:run_for(180000)                               -- boot; the server's first check learns where it stands
    local t0 = sim.clock:now() - sim.t0
    sim:gps_down(t0, 5 * 60000)
    sim:run_for(30000)
    local area = sim.world:meta().areas[1]
    sim:dispatch{ type = "ORDER_MINE", params = { x1 = area.x1, z1 = area.z1, x2 = area.x2, z2 = area.z2, minerCount = 1 } }
    sim:run_for(90000)                                -- 2 minutes into the outage
    local onlineBefore = #online.lines
    sim:reboot(server.name)
    sim:run_until(function() return sim.clock:now() - sim.t0 >= t0 + 5 * 60000 end, 4 * 60000)
    local sentDuringOutage = #dispatched.lines
    sim:run_for(4 * 60000)                            -- GPS back; the next check clears it

    local secs = tonumber((back.lines[1] or ""):match("back after (%d+)s"))
    sim:expect(#online.lines > onlineBefore, "the server restarted during the outage (evidence: "
      .. (#online.lines - onlineBefore) .. " 'Central server online' after the restart)")
    sim:expect(#failed.lines == 1, "one outage, one 'GPS CHECK FAILED' (" .. #failed.lines .. ")")
    sim:expect(#carried.lines >= 1, "the restarted server said the outage was still on ("
      .. tostring(carried.lines[1]) .. ")")
    sim:expect(sentDuringOutage == 0, "no job went out during the outage, restart included (" .. sentDuringOutage .. ")")
    sim:expect(#back.lines == 1, "one 'back' line (" .. #back.lines .. ")")
    sim:expect(secs and secs >= 270 and secs <= 330, "'back after' counts from the outage's start, about 300 s ("
      .. tostring(back.lines[1]) .. ")")
    sim:expect(#dispatched.lines >= 1, "the waiting job went out once GPS was back")
    sim.results.failed, sim.results.carried = #failed.lines, carried.lines[1] or "none"
    sim.results.back = back.lines[1] or "none"
  end,
}
