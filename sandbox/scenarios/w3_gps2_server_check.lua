-- W3 card "GPS 2 - Central server checks GPS itself and alerts the dashboard".
-- Every GPS host goes silent for 5 minutes while a mining job is waiting to go out. The server, which never moves,
-- locates itself once a minute: it must raise the alert, send nothing out on a GPS it cannot trust, stay able to
-- hear the fleet while it checks (no turtle may lose the server because of the check), and clear the alert and
-- dispatch the job once GPS is back.
-- On the code before GPS 2 there is no check: the job goes out into the outage.
return {
  world = "synthetic",
  seed = 1,
  miners = 2,
  steps = function(sim)
    local failed     = sim:capture_log("GPS CHECK FAILED")
    local held       = sim:capture_log("Dispatch hold: GPS check failing")
    local back       = sim:capture_log("GPS check: back after")
    local dispatched = sim:capture_log("Dispatched job_")
    local lost       = sim:capture_log("Server unreachable")
    sim:run_for(180000)                               -- boot; the server's first check learns where it stands
    local t0 = sim.clock:now() - sim.t0
    sim:gps_down(t0, 5 * 60000)                        -- every host silent for 5 minutes
    sim:run_for(30000)
    local lostBefore = #lost.lines
    local area = sim.world:meta().areas[1]
    sim:dispatch{ type = "ORDER_MINE", params = { x1 = area.x1, z1 = area.z1, x2 = area.x2, z2 = area.z2, minerCount = 1 } }
    local beforeBack = sim:run_until(function() return sim.clock:now() - sim.t0 >= t0 + 5 * 60000 end, 6 * 60000)
    local sentDuringOutage = #dispatched.lines
    local lostDuringOutage = #lost.lines - lostBefore
    sim:run_for(4 * 60000)                             -- GPS back; the next check clears it

    sim:expect(#failed.lines >= 1, "the server raised the GPS alert (" .. #failed.lines .. ")")
    sim:expect(#held.lines >= 1, "it held dispatch while GPS was failing (" .. #held.lines .. " hold lines)")
    sim:expect(sentDuringOutage == 0, "no job went out during the outage (" .. sentDuringOutage .. ")")
    sim:expect(lostDuringOutage == 0, "no turtle lost the server because of the check (" .. lostDuringOutage .. " warnings)")
    sim:expect(#back.lines >= 1, "the alert cleared when GPS came back")
    sim:expect(#dispatched.lines >= 1, "the waiting job went out once GPS was back")
    sim.results.alerts, sim.results.holds = #failed.lines, #held.lines
    sim.results.back = back.lines[1] or "none"
    sim.results.first_dispatch = dispatched.lines[1] or "none"
  end,
}
