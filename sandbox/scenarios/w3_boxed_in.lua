-- W3 card "A miner rebooted underground, boxed in by rock, never measures its facing and waits forever" (fix b09b972,
-- 1.9.136). An idle miner is carried into the first mining area at y=20, rock is put on all four sides of it and
-- below, its own shaft is left open above (as a miner at depth sits in the shaft it dug), and it is rebooted -- the 2026-10-08 shape: node_184 and node_182 rebooted at depth after the restart.
-- With GPS up it must dig one block out ('dug one block out to measure facing'), measure its facing ('Facing:'),
-- and get home. On b09b972~1 it logs 'Cannot detect facing -- boxed in' every 10 s and never moves.
return {
  world = "synthetic",
  seed = 1,
  miners = 1,
  steps = function(sim)
    local dug     = sim:capture_log("dug one block out to measure facing")
    local boxed   = sim:capture_log("boxed in on all four sides")
    local facing  = sim:capture_log("] Facing: ")
    local docked  = sim:capture_log("Docked at bay")
    sim:run_for(120000)
    local miner
    for _, c in ipairs(sim.sched.computers) do if c.role == "miner" then miner = c end end
    sim:expect(miner ~= nil, "found a miner")
    if not miner then return end
    local a = sim.world:meta().areas[1]
    local x, y, z = math.floor((a.x1 + a.x2) / 2), 20, math.floor((a.z1 + a.z2) / 2)
    sim:fill({ x - 1, y - 1, z - 1, x + 1, y + 1, z + 1 }, "minecraft:stone")
    for yy = y, 70 do sim:set_block(x, yy, z, nil) end                  -- its shaft, open up to the surface
    sim:teleport(miner.name, x, y, z, "north")                           -- THE TEST: rebooted in a stone box
    local f0, d0 = #facing.lines, #docked.lines
    sim:reboot(miner.name)
    local out = sim:run_until(function() return #dug.lines >= 1 end, 10 * 60000)
    sim:expect(out, "it dug one block out to measure its facing")
    sim:expect(sim:run_until(function() return #facing.lines > f0 end, 5 * 60000), "and measured its facing")
    sim:expect(sim:run_until(function() return #docked.lines > d0 end, 90 * 60000), "and got home to its dock")
    sim.results.boxed_lines = #boxed.lines
  end,
}
