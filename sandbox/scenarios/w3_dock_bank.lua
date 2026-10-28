-- W1 card "Docked miners never bank travel debris - the dock guard cancels the whole bank, not just the dig"
-- (fix 0dc2575, branch w1-dock-bank; layer 1 written by W3 with the baton, 2026-10-28).
-- A miner docks carrying debris in its mining slots, with its station chest below it -- as every bay has. It must bank
-- the debris through a face that is already free ("Dock tidy: banking travel debris"), end with its mining slots
-- 5-13 empty, leave the station chest below where it is, and drop nothing on the floor.
-- On the code before the fix the block below makes it refuse: "no free space below for the ore chest - travel debris
-- kept aboard" (the 2026-10-08 measurement: twelve of those and no banking line across miners 177-183).
-- The tidy runs when a miner comes home (not on a plain reboot at the dock), so a one-sector job is sent and the
-- debris is given as the miner turns for home.
return {
  world = "synthetic",
  seed = 1,
  miners = 1,
  steps = function(sim)
    local banked = sim:capture_log("banking travel debris")
    local kept   = sim:capture_log("travel debris kept aboard")
    local docked = sim:capture_log("phase: DOCKED")
    sim:run_for(120000)
    local miner
    for _, c in ipairs(sim.sched.computers) do
      if c.role == "miner" and c.tstate then miner = c; break end
    end
    sim:expect(miner ~= nil, "a miner")
    if not miner then return end
    local p = miner.pos
    local below = sim:get_block(p.x, p.y - 1, p.z)
    if not below then                                      -- every real bay has its station chest below
      sim:set_block(p.x, p.y - 1, p.z, "minecraft:chest")
      below = "minecraft:chest"
    end
    sim.results.below = below
    local returning = sim:capture_log("phase: RETURNING")
    local b0, k0 = #banked.lines, #kept.lines
    local area = sim.world:meta().areas[1]
    sim:dispatch{ type = "ORDER_MINE", params = { x1 = area.x1, z1 = area.z1, x2 = area.x1, z2 = area.z1, minerCount = 1 } }
    local home = sim:run_until(function()
      for _, l in ipairs(returning.lines) do if l:find(miner.name, 1, true) then return true end end
      return false
    end, 6 * 3600000)
    sim:expect(home, "the miner turned for home")
    if not home then return end
    sim:set_slot(miner.name, 6, "minecraft:cobblestone", 40)   -- THE TEST: travel debris aboard on the way home
    sim:set_slot(miner.name, 7, "minecraft:dirt", 20)
    local d0 = #docked.lines
    sim:run_until(function() return #banked.lines > b0 or #kept.lines > k0 end, 60 * 60000)
    sim:run_for(30000)
    sim.results.docked_lines = #docked.lines - d0
    sim:expect(#banked.lines > b0, "it banked the debris ('Dock tidy: banking travel debris')")
    sim:expect(#kept.lines == k0, "it did not refuse ('travel debris kept aboard': " .. (#kept.lines - k0) .. ")")
    local left = {}
    for s = 5, 13 do
      local it = miner.tstate.inv[s]
      if it then left[#left + 1] = s .. ":" .. tostring(it.name) .. "x" .. it.count end
    end
    sim:expect(#left == 0, "mining slots 5-13 are empty (" .. table.concat(left, " ") .. ")")
    sim:expect(sim:get_block(p.x, p.y - 1, p.z) == below, "the station chest below is still there ("
      .. tostring(sim:get_block(p.x, p.y - 1, p.z)) .. ")")
    local floor = 0
    for _, d in ipairs(miner.tstate.dropped or {}) do floor = floor + (d.count or 0) end
    sim:expect(floor == 0, "nothing was dropped on the floor (" .. floor .. ")")
  end,
}
