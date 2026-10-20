-- Incident 2026-10-05: the world restarted before the GPS hosts were up. The miners mid-job rebooted with
-- "No GPS fix. Tracking from (0,0,0)" and then ran boot recovery on a wrong picture of where they were and
-- which way they faced, flying off toward their loaders thousands of blocks away in the wrong direction. All four
-- were lost. 1.9.132 (390cb52) added waitForPositionFix; this scenario asks whether a miner still gets lost.
--
-- The world restarts 45 minutes into a two-miner job and the GPS hosts come back `gps_delay` later (default 60 s,
-- inside the miners' two-minute boot wait). It hands its verdict to the test in sim.results:
--   lost_miners          miners that end up neither at the depot nor anywhere near the mining area
--   miner_positions      where each miner ended up
--   not_moving_logged    some turtle logged "NOT moving"        (the wait-for-a-fix messages)
--   can_go_ahead_logged  some turtle logged "can go ahead"     (it got its fix and carried on)
return {
  world = "synthetic",
  seed = 1,
  miners = 2,
  workers = 6,
  gps_delay = 60000,
  steps = function(sim)
    local waiting = sim:capture_log("NOT moving")
    local resumed = sim:capture_log("can go ahead")
    sim:run_for(120000)
    local area = sim.world:meta().areas[1]
    sim:dispatch{ type = "ORDER_MINE", params = { x1 = area.x1, z1 = area.z1, x2 = area.x2, z2 = area.z2 } }
    local restart_at = 45 * 60000
    local delay = sim.scenario.gps_delay
    sim:world_restart(restart_at, { gps_delay = delay })
    sim:run_until_time(restart_at + delay + 15 * 60000)  -- the GPS is back; give them time to recover or get lost

    local function near(x, z, box) return x >= box[1] and x <= box[3] and z >= box[2] and z <= box[4] end
    local depot = { 100, -2850, 260, -2750 }
    local zone = { area.x1 - 150, area.z1 - 150, area.x2 + 150, area.z2 + 150 }
    local lost, where = 0, {}
    for _, id in ipairs({ 11, 12 }) do
      local c = sim.by_id[id]
      local x, y, z = c.pos.x or 0, c.pos.y or 0, c.pos.z or 0
      where[#where + 1] = string.format("node_%d at %d,%d,%d", id, x, y, z)
      if not near(x, z, depot) and not near(x, z, zone) then lost = lost + 1 end
    end
    sim.results.lost_miners = lost
    sim.results.miner_positions = where
    sim.results.not_moving_logged = waiting.count > 0
    sim.results.can_go_ahead_logged = resumed.count > 0
  end,
}
