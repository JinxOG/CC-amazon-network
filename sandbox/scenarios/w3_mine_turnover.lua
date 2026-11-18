-- W3, 2026-11-18 (SPEC-OWNER: "one MINE a minute still means 128 miners take about 2 h to all leave after a start or a
-- world restart"; the user noticed slow miner turnover). Measures how fast miners leave the base, and what it costs the
-- base, with the dispatch stagger as it is set (CFG.DISPATCH_STAGGER / CFG.MINE_STAGGER).
--
-- Here: the 150-turtle base (118 miners, 16 delivery, 16 support) under its ATC. 30 zones of two miners each (60 MINE
-- jobs) are ordered at once, with a delivery every 5 minutes; then an hour.
-- MEASURES (NOTE lines, for comparing two staggers): MINE jobs dispatched in the first 10, 30 and 60 minutes, and the
-- minute the 60th went; deliveries dispatched and completed; the worst ATC wait to be let in; STUCK reports; LOOP
-- STALLs. CHECKS: the base did not jam (no ATC wait over 900 s, nobody STUCK).
return {
  world = "synthetic",
  seed = 1,
  miners = 118,
  workers = 150,
  per_bay = true,
  atc = true,
  preset_docks = true,
  steps = function(sim)
    local dispatched = sim:capture_log("Dispatched job_")
    local done = sim:capture_log("Job complete: job_")
    local waits = sim:capture_log("Still waiting")
    local stuck = sim:capture_log("STUCK ")
    local stalls = sim:capture_log("LOOP STALL")
    sim:storage_set("minecraft:cobblestone", 10000000)
    sim:storage_set("minecraft:chest", 100000)
    sim:run_for(5 * 60000)
    local area = sim.world:meta().areas[1]
    for n = 0, 29 do
      local x = area.x1 + 64 * 3 * (n % 10)
      local z = area.z1 + 64 * 3 * math.floor(n / 10)
      sim:dispatch{ type = "ORDER_MINE", params = { x1 = x, z1 = z, x2 = x + 64, z2 = z, minerCount = 2 } }
      sim:run_for(2)
    end
    local t0 = sim.clock:now()
    local DESTS = { { x = 118, z = -2830 }, { x = 124, z = -2830 }, { x = 196, z = -2761 }, { x = 130, z = -2830 } }
    local mineAt, delN = {}, 0
    for minute = 1, 60 do
      if minute % 5 == 1 then
        local d = DESTS[(delN % #DESTS) + 1]
        delN = delN + 1
        sim:dispatch{ type = "ORDER_DELIVERY", params = { items = { { name = "minecraft:cobblestone", count = 33 } },
          destination = { x = d.x, y = 67, z = d.z } } }
      end
      sim:run_for(60000)
      local n = 0
      for _, l in ipairs(dispatched.lines) do if l:find("[MINE]", 1, true) then n = n + 1 end end
      mineAt[minute] = n
    end
    local sixtiethMin
    for m = 1, 60 do if not sixtiethMin and mineAt[m] >= 60 then sixtiethMin = m end end
    local delD, delC = 0, 0
    local delJobs = {}
    for _, l in ipairs(dispatched.lines) do
      local j = l:match("Dispatched (job_%d+) %[DELIVER%]")
      if j then delD = delD + 1; delJobs[j] = true end
    end
    for _, l in ipairs(done.lines) do
      local j = l:match("server#.*Job complete: (job_%d+)")
      if j and delJobs[j] then delC = delC + 1 end
    end
    local worst = 0
    for _, l in ipairs(waits.lines) do
      local s = tonumber(l:match("Still waiting (%d+)s")) or 0
      if l:find("ATC:", 1, true) and s > worst then worst = s end
    end
    local stuckN = 0
    for _, l in ipairs(stuck.lines) do if not l:find("Moving again", 1, true) then stuckN = stuckN + 1 end end
    sim:expect(true, string.format("NOTE MINE dispatched: %d in 10 min, %d in 30, %d in 60; the 60th at minute %s", mineAt[10],
      mineAt[30], mineAt[60], tostring(sixtiethMin or "-")))
    sim:expect(true, string.format("NOTE DELIVER: %d ordered, %d dispatched, %d completed; worst ATC wait %d s; LOOP STALLs %d",
      delN, delD, delC, worst, #stalls.lines))
    sim:expect(worst <= 900, "the base did not jam: no ATC wait over 900 s (worst " .. worst .. " s)")
    sim:expect(stuckN == 0, "nobody reported STUCK (" .. stuckN .. ")")
    sim:expect(sim.clock:now() - t0 >= 3600000, "an hour ran")
  end,
}
