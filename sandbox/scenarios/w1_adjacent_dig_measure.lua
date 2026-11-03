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

    local done = sim:run_until(function() return #complete.lines >= 1 end, 8 * 3600 * 1000)
    local t1 = sim.clock:now()

    local mined = 0
    for name, n in pairs(sim.sched.storage.amounts) do
      if Drops.is_ore_item(name) then mined = mined + n - (sim.initial_storage[name] or 0) end
    end

    sim.results.job_completed   = done and true or false
    sim.results.job_ms          = t1 - t0
    sim.results.job_minutes     = string.format("%.1f", (t1 - t0) / 60000)
    sim.results.ore_gained      = mined
    for k, cap in pairs(problems) do
      sim.results["problem_" .. (k:gsub("%W", "_"))] = #cap.lines
    end

    -- The job has to FINISH for the time to mean anything: a budget that ran
    -- out gives the budget back, not a duration, and two arms that both hit the
    -- ceiling would compare as equal however different they are.
    sim:expect(done,
      "the job completed inside the 8-hour budget, so its duration is a "
      .. "duration and not the budget (completed: " .. tostring(done)
      .. ", elapsed " .. sim.results.job_minutes .. " min)")

    -- And it has to have mined something, or the time is the time to do
    -- nothing. real_world_three_sectors sets its bar at 1000 blocks on this
    -- same zone; the same bar is used here so the two are comparable.
    sim:expect(mined > 1000,
      "and the miners actually worked the zone (" .. mined .. " ore blocks "
      .. "delivered) -- the figure to compare between arms, and it must come "
      .. "out the SAME on both: a faster job that mines less is not faster")
  end,
}
