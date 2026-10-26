-- Two W3 cards in one staging: a miner rebooted out in the field while every GPS host is down (6 minutes).
--   "A miner rebooted without a GPS fix flies off blind and is lost" (fix 390cb52, 1.9.132): it must not move at all
--     until GPS is back ('NOT moving until both are measured'), then measure ('Position and facing measured after') and
--     recover. On 390cb52~1 it ran boot recovery on a guessed position and flew off.
--   "A turtle stuck before its main loop was invisible" (fix bfe7e8a, 1.9.137): while it waits it reports
--     'stuck_no_fix' and the server raises NEEDS HANDS with its position, and it is never pruned. On bfe7e8a~1 nothing.
return {
  world = "synthetic",
  seed = 1,
  miners = 1,
  steps = function(sim)
    local disp     = sim:capture_log("Dispatched job_")
    local assigned = sim:capture_log("Assigned sector (")
    local notMove  = sim:capture_log("NOT moving until both are measured")
    local hands    = sim:capture_log("NEEDS HANDS")
    local measured = sim:capture_log("Position and facing measured after")
    local pruned   = sim:capture_log("Pruned stale offline turtle")
    local docked   = sim:capture_log("Docked at bay")
    sim:run_for(120000)
    local area = sim.world:meta().areas[1]
    sim:dispatch{ type = "ORDER_MINE", params = { x1 = area.x1, z1 = area.z1, x2 = area.x2, z2 = area.z2, minerCount = 1 } }
    local out = sim:run_until(function() return #disp.lines >= 1 and #assigned.lines >= 1 end, 60 * 60000)
    sim:expect(out, "the miner reached its zone")
    if not out then return end
    sim:run_for(3 * 60000)
    local name = disp.lines[1]:match("%-> (node_%d+)")
    local c = sim.by_name[name]
    local now = sim.clock:now() - sim.t0
    sim:gps_down(now, 6 * 60000)                                        -- THE TEST: no GPS for 6 minutes
    sim:run_for(2000)
    local p0 = { x = c.pos.x, y = c.pos.y, z = c.pos.z }
    local d0, h0, pr0 = #docked.lines, #hands.lines, #pruned.lines
    sim:reboot(name)                                                    -- ...and a reboot in the field
    local moved = 0
    sim:run_until(function()
      local d = math.abs(c.pos.x - p0.x) + math.abs(c.pos.y - p0.y) + math.abs(c.pos.z - p0.z)
      if d > moved then moved = d end
      return false
    end, 5 * 60000)                                                     -- the outage, minus the first seconds
    sim:expect(moved <= 1, "it did not move without GPS (moved " .. moved .. " blocks)")
    sim:expect(#notMove.lines >= 1, "it said 'NOT moving until both are measured'")
    local raised = false
    for i = h0 + 1, #hands.lines do if hands.lines[i]:find(name, 1, true) then raised = true end end
    sim:expect(raised, "the server raised NEEDS HANDS for " .. name .. " while it waited")
    local back = sim:run_until(function() return #measured.lines >= 1 end, 10 * 60000)
    sim:expect(back, "once GPS was back it measured ('Position and facing measured after')")
    local home = sim:run_until(function() return #docked.lines > d0 end, 90 * 60000)
    sim:expect(home, "and recovered home to its dock")
    local gone = false
    for i = pr0 + 1, #pruned.lines do if pruned.lines[i]:find(name, 1, true) then gone = true end end
    sim:expect(not gone, "it was never pruned as offline")
    sim.results.moved_without_gps = moved
  end,
}
