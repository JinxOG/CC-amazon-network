-- Incident 2026-10-05: the world restarted before the GPS hosts were up. Every turtle booted with "No GPS fix",
-- and the miners mid-job ran boot recovery from that guess, flying off toward loaders 1,700-2,800 blocks away
-- (fixed in 1.9.132, 390cb52: a miner never flies on a guessed position). The scenario restarts the world 45
-- minutes into a two-miner job with the GPS hosts ten minutes late, and records into sim.results:
--   moved_during_outage   how far (blocks) the farthest miner travelled while the GPS was still down
--   not_moving_logged     whether any turtle logged "NOT moving until one arrives"
--   fix_logged            whether any turtle later logged "can go ahead" (it recovered once the fix came back)
return {
  world = "synthetic",
  seed = 1,
  miners = 2,
  workers = 6,
  steps = function(sim)
    local waiting = sim:capture_log("NOT moving")
    local resumed = sim:capture_log("can go ahead")
    sim:run_for(120000)
    local area = sim.world:meta().areas[1]
    sim:dispatch{ type = "ORDER_MINE", params = { x1 = area.x1, z1 = area.z1, x2 = area.x2, z2 = area.z2 } }
    local restart_at = 45 * 60000
    local outage = 60000
    sim:world_restart(restart_at, { gps_delay = outage })

    local function miners_at()
      local out = {}
      for _, id in ipairs({ 11, 12 }) do
        local c = sim.by_id[id]
        out[id] = { x = c.pos.x or 0, y = c.pos.y or 0, z = c.pos.z or 0 }
      end
      return out
    end
    -- let the restart happen and the miners come back up, then watch them while the GPS is still down
    sim:run_until_time(restart_at + 90000)
    local before = miners_at()
    sim:run_until_time(restart_at + outage - 30000)
    local after = miners_at()
    local far = 0
    for id, b in pairs(before) do
      local a = after[id]
      local d = math.abs(a.x - b.x) + math.abs(a.y - b.y) + math.abs(a.z - b.z)
      if d > far then far = d end
    end
    sim.results.moved_during_outage = far
    sim:run_until_time(restart_at + outage + 15 * 60000)   -- the GPS is back; give them time to recover
    sim.results.not_moving_logged = waiting.count > 0
    sim.results.fix_logged = resumed.count > 0
    sim.results.not_moving_lines = waiting.lines
  end,
}
