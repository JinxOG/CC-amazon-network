-- MEASUREMENT for the W1 card "Mining - dig ore from the adjacent block instead
-- of stepping into it (measure first)". This file decides nothing on its own:
-- it is the same job, run twice, once on each code revision, so the two can be
-- compared. The card's instruction is explicit -- only ship the change if the
-- measurement shows a real gain -- so the comparison is written BEFORE the
-- change, and deliberately not tuned to it.
--
-- WHAT THE CHANGE WOULD BE. navToOre moves the turtle INTO each ore's cell;
-- base.move.to digs whatever is in the way, so arriving is what mines the ore.
-- GeoMiner instead stops in the free space beside the ore and digs sideways.
--
-- THE ARITHMETIC THAT MAKES IT LOOK LIKE A WIN. With sandbox/timings.lua as
-- fitted on T2 at 1x, move_ms = 400 and dig_ms = 200. Stepping into a solid
-- cell costs a dig AND a move: 600 ms. Digging it from beside costs 200 ms. So
-- the headline saving is one move -- 400 ms and 1 fuel -- per ore.
--
-- AND THE REASON IT MIGHT NOT BE. After stepping in, the miner is STANDING in
-- the cell it just emptied, which in a vein is usually adjacent to the next ore.
-- After digging from beside, it is one cell further away from wherever the vein
-- continues, and mine_flow.takeNearest will then send it a step it did not have
-- to make before. Ore grows in veins of 5-10 contiguous blocks, so most picks
-- are vein-internal and this is the common case, not the corner case. The sign
-- of the result is genuinely unknown, which is the whole reason the card says
-- measure first, and why this file must not be written as if the answer were
-- already known.
--
-- WHAT IS MEASURED, AND THE ONE THING THAT IS NOT.
--   * simulated time from the order to "Job complete" -- the primary figure.
--     With a fixed cost per move and per dig, time IS the move count in the
--     unit that matters, and it also catches any extra travel the change
--     causes rather than only the saving it was aimed at.
--   * ore delivered to storage -- the SAFETY check, not a benefit. It must come
--     out the same on both arms. A faster job that mines less ore is not a
--     faster job.
--   * problem lines, counted by kind. A change to the mining loop that trades
--     time for refusals, aborts or re-mines has not saved anything.
--   * FUEL IS NOT MEASURED HERE, and that is a limitation rather than an
--     oversight. The simulator records no move counter and no cumulative burn,
--     and the miners refuel from an endless ender chest, so the fuel LEVEL at
--     the end says nothing about what was spent. Simulated time is the proxy,
--     and it is a good one only because every move costs the same fixed 400 ms.
--     Counting moves properly needs a counter in sandbox/cc/turtle.lua, which
--     belongs to the sandbox owner; if the time difference comes out small
--     enough to argue about, that counter is what settles it.
--
-- WHY THIS ZONE. The same three sectors as real_world_three_sectors.lua, on the
-- imported 2026-10-18 world: ordered as sector CENTRES (1920..1984, z -2624),
-- because the server pads an order by the scan radius and snaps it to the 32
-- step -- handing it the footprint turns 3 sectors into 15, twelve of them
-- outside the imported world. Two miners, as that scenario uses, and the zone
-- the card names.
--
-- HOW TO RUN THE PAIR. Same seed, same world, nothing else on the machine:
--     sandbox/sim run sandbox/scenarios/w1_adjacent_dig_measure.lua --code rev:<before>
--     sandbox/sim run sandbox/scenarios/w1_adjacent_dig_measure.lua --code rev:<after>
-- A contended run is not a measurement -- one arm of this card's earlier
-- attempt was taken while a 1x test-server run was live and had to be thrown
-- away. The run report records a host snapshot at start and end, so check it.
-- These two arms run DIFFERENT code, so their traces diverge legitimately and
-- byte-identical determinism does not apply between them; it still applies
-- within an arm, so either can be repeated to check its own stability.
package.path = "sandbox/?.lua;" .. package.path
local Drops = require("world.drops")
local DATA = (os.getenv("SANDBOX_DATA") or "G:/TurtleOS-Sandbox"):gsub("\\", "/")
return {
  world = DATA .. "/worlds/2026-10-18_1700/sim",
  seed  = 1,
  steps = function(sim)
    local complete = sim:capture_log("Job complete: ")
    local problems = {}
    for _, k in ipairs({ "Skipped ", "ore below the Y=", "did not run", "re-mine exhausted",
                         "back to queue", "retry 1/", "permanently failed", "NEEDS HANDS" }) do
      problems[k] = sim:capture_log(k)
    end

    sim:run_for(10 * 60000)                      -- boot, find GPS, register

    local t0 = sim.clock:now()
    sim:dispatch{ type = "ORDER_MINE",
      params = { x1 = 1920, z1 = -2624, x2 = 1984, z2 = -2624, minerCount = 2 } }

    local function oreDelivered()
      local n = 0
      for name, amount in pairs(sim.sched.storage.amounts) do
        if Drops.is_ore_item(name) then n = n + amount - (sim.initial_storage[name] or 0) end
      end
      return n
    end

    -- TWO FIGURES, BECAUSE ONE OF THEM MIGHT NOT EXIST.
    --
    -- The clean comparison is fixed WORK: run the job to completion on both
    -- arms and compare how long it took, with the ore delivered coming out the
    -- same as the check that nothing was traded away. That needs the job to
    -- finish, and real_world_three_sectors -- the same zone, the same two
    -- miners -- does NOT assert that it finishes: it runs six hours and checks
    -- the ore. Nobody has established that this zone completes inside any
    -- particular budget, and the first sector alone held 2013 ores at one
    -- level on the test server.
    --
    -- So the fixed-TIME figure is taken first and always: ore delivered at a
    -- six-hour checkpoint, which is a throughput and exists whatever happens.
    -- Then the run continues to a generous ceiling in case the job does
    -- complete, which gives the fixed-work figure as well. Neither is asserted
    -- as a pass or fail -- this file measures, it does not judge -- but a run
    -- that produced no ore at all has measured nothing, and that IS asserted.
    local CHECKPOINT = 6 * 3600 * 1000
    local CEILING    = 24 * 3600 * 1000

    local doneEarly = sim:run_until(function() return #complete.lines >= 1 end, CHECKPOINT)
    sim.results.ore_at_6h = oreDelivered()

    local done = doneEarly
    if not done then
      done = sim:run_until(function() return #complete.lines >= 1 end, CEILING - CHECKPOINT)
    end
    local t1 = sim.clock:now()

    sim.results.job_completed = done and true or false
    sim.results.ore_total     = oreDelivered()
    if done then
      sim.results.job_ms      = t1 - t0
      sim.results.job_minutes = string.format("%.1f", (t1 - t0) / 60000)
    else
      sim.results.job_ms      = "not completed within 24 h"
      sim.results.job_minutes = "n/a"
    end
    for k, cap in pairs(problems) do
      sim.results["problem_" .. (k:gsub("%W", "_"))] = #cap.lines
    end

    -- HOW TO READ THE PAIR.
    --   both arms completed  -> compare job_minutes; ore_total must match, or
    --                           the faster arm bought its speed with lost ore.
    --   neither completed    -> compare ore_at_6h; more ore in the same time is
    --                           the same claim in the other direction.
    --   one completed        -> compare ore_at_6h only. A completion time
    --                           against a timeout is not a comparison.
    -- And in every case check the problem_ counts: a mining change that trades
    -- time for refusals, aborts or re-mines has not saved anything.

    -- The only thing asserted. real_world_three_sectors sets its bar at 1000
    -- blocks on this same zone, so the same bar is used and the two stay
    -- comparable. Below it, the miners did not work the zone and neither figure
    -- above means anything.
    sim:expect(sim.results.ore_at_6h > 1000,
      "the miners worked the zone within the 6-hour checkpoint ("
      .. sim.results.ore_at_6h .. " ore blocks delivered; "
      .. (done and ("job completed in " .. sim.results.job_minutes .. " min")
              or "job did not complete within 24 h")
      .. ") -- below this bar there is nothing to compare")
  end,
}
