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
-- WHY THE SYNTHETIC WORLD AND NOT THE ZONE THE CARD NAMES. The first attempt
-- used real_world_three_sectors.lua's zone on the imported 2026-10-18 world,
-- and it measured nothing at all: both arms came back byte-identical, 6645 ore
-- blocks and 231.5 minutes, twice. The cause is established, in the code and in
-- the artefact. import_layout.lua marks every computer of an imported world
-- `installed = true`, and fleet.lua writes the repository's files only when
-- `not spec.installed` -- its own comment says so: "entries with
-- installed = true already have their disk (an imported world)". So a scenario
-- on an imported world runs the fleet code FROZEN IN THAT SNAPSHOT, and the
-- working tree is never installed. Checked on the run itself: the miner's
-- startup.lua (ore_turtle is installed under that name) contained no
-- adjacentDir, no digAdjacentOre and none of the instrumentation. Both arms ran
-- the same old code, so of course they matched -- and `--code rev:...` is
-- equally powerless there, which means the "before" arm was not what it was
-- labelled either.
--
-- On the synthetic world the fleet code IS installed from the tree, which is
-- why the other W1 scenarios could fail on the old code and pass on the new.
-- The zone is therefore four sectors in the first synthetic mining area
-- (x 100..163, z -2832..-2769): centres 128 and 160 on x, -2816 and -2784 on z,
-- all on the 32 grid. Four rather than the card's three, because only two
-- centres fit along each axis of that area; said plainly rather than quietly
-- substituted. Two miners, as real_world_three_sectors uses. Synthetic ore
-- grows in veins of 5-10 contiguous blocks, which is the geometry this card
-- turns on.
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
  world  = "synthetic",
  seed   = 1,
  miners = 2,
  steps = function(sim)
    local complete = sim:capture_log("Job complete: ")
    local problems = {}
    for _, k in ipairs({ "Skipped ", "ore below the Y=", "did not run", "re-mine exhausted",
                         "back to queue", "retry 1/", "permanently failed", "NEEDS HANDS" }) do
      problems[k] = sim:capture_log(k)
    end

    sim:run_for(10 * 60000)                      -- boot, find GPS, register

    -- PLANT THE ORE, because this world has none. Measured on the first
    -- synthetic attempt: 44 scans of these four sectors, every one "Found 0 ore
    -- blocks", and the job finished in 28.7 minutes having delivered nothing.
    -- There was no throughput to compare and no vein for the shortcut to apply
    -- to.
    --
    -- Planting is the better experiment anyway. What this card turns on is vein
    -- GEOMETRY -- whether standing one cell further out costs back the move it
    -- saved -- so setting that deliberately beats hoping a world supplies it.
    -- Twenty 2x2x2 clusters: eight contiguous blocks each, so every block in a
    -- cluster is adjacent to another, which is the shape real ore grows in
    -- (veins of 5-10) and the shape the shortcut is meant to exploit. If the
    -- adjacent dig cannot pay here it cannot pay anywhere, which makes a null
    -- result meaningful rather than merely absent.
    --
    -- Fixed coordinates, not a random scatter: both arms must plant the SAME
    -- ore or the comparison is between two different worlds. All of it sits at
    -- y 0..1, inside the Y=0 scan level's reach and far above the -58 dig
    -- floor, so the below-floor split cannot touch it.
    local planted = 0
    for gx = 0, 4 do
      for gz = 0, 3 do
        local ox, oz = 118 + gx * 5, -2826 + gz * 5
        for dx = 0, 1 do
          for dy = 0, 1 do
            for dz = 0, 1 do
              local x, y, z = ox + dx, dy, oz + dz
              if sim.world:get(x, y, z) == "minecraft:stone" then
                sim:set_block(x, y, z, "minecraft:iron_ore")
                planted = planted + 1
              end
            end
          end
        end
      end
    end
    sim.results.planted_ore = planted
    sim:expect(planted >= 150,
      "planted a vein field for the miners to work (" .. planted .. " of 160 "
      .. "blocks in 20 clusters of 8) -- with nothing planted this world is "
      .. "bare and neither arm measures anything")

    local t0 = sim.clock:now()
    sim:dispatch{ type = "ORDER_MINE",
      params = { x1 = 128, z1 = -2816, x2 = 160, z2 = -2784, minerCount = 2 } }

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
    -- The bar is 150 against 160 planted, not real_world_three_sectors' 1000: that
    -- on the imported world's zone and means nothing here. 200 blocks over four
    -- synthetic sectors is low enough not to fail a working run and high enough
    -- that a run which mined almost nothing cannot pass.
    sim:expect(sim.results.ore_at_6h > 150,
      "the miners worked the zone within the 6-hour checkpoint ("
      .. sim.results.ore_at_6h .. " ore blocks delivered; "
      .. (done and ("job completed in " .. sim.results.job_minutes .. " min")
              or "job did not complete within 24 h")
      .. ") -- below this bar there is nothing to compare")
  end,
}
