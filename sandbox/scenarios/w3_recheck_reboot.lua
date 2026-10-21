-- W3 card "A requeued zone forgets its re-mine list and closes with ore left" (fix 6aee2ae, 1.9.144).
-- A miner is rebooted the moment its zone starts the rescan pass: it reports "recovering", its job is requeued,
-- and the zone must keep its rescan list (and the dead holder's sector) for whoever takes the job next, instead
-- of being rebuilt from the store as "0/N sectors remaining" and closed with the rescan never done.
-- Fails on the code before the fix: run with --code rev:6aee2ae~1 to see it.
return {
  world = "synthetic",
  seed = 1,
  miners = 2,
  steps = function(sim)
    local done      = sim:watch_log("Job complete: job_")
    local started   = sim:capture_log("starting rescan of")
    local holders   = sim:capture_log("[RESCAN] to node_")
    local kept      = sim:capture_log("keeps its rescan zone")
    local rescans   = sim:capture_log("Rescan (")
    local zeroLeft  = sim:capture_log(": 0/")          -- "Mine zone job_X: 0/N sectors remaining" = rebuilt empty
    sim:run_for(120000)                                 -- boot, find GPS, register
    local area = sim.world:meta().areas[1]
    sim:dispatch{ type = "ORDER_MINE", params = { x1 = area.x1, z1 = area.z1, x2 = area.x2, z2 = area.z2 } }

    local reached = sim:run_until(function() return started.count >= 1 and #holders.lines >= 1 end, 12 * 3600 * 1000)
    sim:expect(reached, "the zone reached its rescan pass")
    if not reached then return end
    local total = tonumber(started.lines[1]:match("starting rescan of (%d+)")) or 0
    local holder = holders.lines[1]:match("%[RESCAN%] to (node_%d+)")
    sim:run_for(5000)                                   -- the order is out; the miner is on its way to the sector
    local zerosBefore = #zeroLeft.lines
    sim:reboot(holder)                                  -- THE TEST: a field reboot during the rescan pass

    local finished = sim:run_until(function() return done.count >= 2 end, 12 * 3600 * 1000)
    sim:expect(finished, "both jobs complete after a reboot during the rescan pass")
    sim:expect(kept.count >= 1, "the requeued job kept its rescan zone ('keeps its rescan zone' logged)")
    sim:expect(#zeroLeft.lines == zerosBefore,
      "no job was rebuilt as '0/N sectors remaining' after the reboot (" .. (#zeroLeft.lines - zerosBefore) .. " were)")
    local seen = {}
    for _, line in ipairs(rescans.lines) do
      local s = line:match("Rescan %((%-?%d+,%-?%d+)%)")
      if s then seen[s] = true end
    end
    local n = 0
    for _ in pairs(seen) do n = n + 1 end
    sim:expect(total > 0 and n >= total,
      "every sector of the rescan pass was rescanned: " .. n .. " of " .. total)
    sim.results.rebooted = holder
    sim.results.rescan_total = total
    sim.results.rescanned_distinct = n
  end,
}
