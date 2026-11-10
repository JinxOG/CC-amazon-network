-- W1 card "After a restart, turtles resume the job where they stand instead of
-- flying home" -- THE OTHER HALF. The card asks for both:
--
--   "A miner restarted with one forced condition (full inventory, no GPS,
--    recalled job) goes home and logs that reason."
--
-- and lists as a FAILED IF: "a recalled job is resumed". So this is the arm
-- that proves the fix knows when NOT to resume, and says which reason. Without
-- it, "it resumed" is the only behaviour ever tested, and a decision that
-- always says yes would pass the happy-path scenario perfectly.
--
-- THE FORCED CONDITION IS A RECALL, chosen over the other two because it is the
-- one the card calls a FAILED IF rather than merely a reason, and because it is
-- the only one of the three a scenario can stage honestly: RECALL_ALL is a real
-- dispatch the fleet already understands (w3_recall_all_final uses it), where
-- "no GPS" would be waited out rather than refused -- base.waitForPositionFix
-- blocks until a fix arrives -- and a full inventory would be topped back up by
-- the miner's own banking before the decision ever read it. Those two are
-- covered as pure cases in mine_flow's unit tests, where they can be stated
-- without a world arguing about them.
--
-- THE ORDER MATTERS. The recall is sent while the miner is DOWN, so it is
-- waiting for it when it boots -- which is exactly the live case: the daily
-- restart and an operator's recall can land in either order, and a turtle that
-- resumed a cancelled job would fly out to a sector no server is expecting.
--
-- WHAT IT ASSERTS: it goes home, it says the reason was the recall, and it does
-- NOT report resuming. All three, because "did not resume" on its own would
-- also be satisfied by a miner that simply crashed.
local function node(sim, role)
  for _, c in ipairs(sim.sched.computers) do if c.role == role then return c end end
end

return {
  world  = "synthetic",
  seed   = 1,
  miners = 1,
  steps = function(sim)
    local disp     = sim:capture_log("Dispatched job_")
    local mining   = sim:capture_log("phase: MINING")
    local resumed  = sim:capture_log("resuming sector (")
    local wentHome = sim:capture_log("going home: ")
    local docked   = sim:capture_log("phase: DOCKED")
    local registered = sim:capture_log("Registered successfully.")

    sim:run_for(120000)
    local miner = node(sim, "miner")
    sim:expect(miner ~= nil, "found a miner")
    if not miner then return end

    local area = sim.world:meta().areas[1]
    sim:dispatch{ type = "ORDER_MINE",
      params = { x1 = area.x1, z1 = area.z1, x2 = area.x1, z2 = area.z1, minerCount = 1 } }
    sim:run_until(function() return #disp.lines >= 1 end, 10 * 60000)
    sim:expect(#disp.lines >= 1, "the job was dispatched")
    if #disp.lines < 1 then return end

    local atWork = sim:run_until(function() return #mining.lines >= 1 end, 4 * 3600000)
    sim:expect(atWork, "the miner reached the MINING phase before the restart")
    if not atWork then return end
    sim:run_for(60000)

    local d0, gen0 = #docked.lines, miner.gen
    local reg0 = #registered.lines
    sim:world_restart(sim.clock:now() - sim.t0 + 1000)

    -- AFTER IT RE-REGISTERS, NOT THE INSTANT IT REBOOTS.
    --
    -- The first run of this scenario sent the recall as soon as the computer
    -- came up and the server threw it away: "sendTo: unknown turtle 'node_11'
    -- -- dropping RECALL", three seconds before it registered. Nothing was
    -- wrong with the fleet; the scenario had staged a message to a turtle the
    -- server had no route to. (Worth knowing in its own right: a recall sent
    -- in that window is lost, which could matter in a boot rush. Not this
    -- card.)
    --
    -- Waiting for registration still stages what the card asks for -- the
    -- recall arrives while the turtle is in boot recovery, long before it could
    -- resume anything, so it has still "landed while it was down" as far as the
    -- job is concerned.
    sim:run_until(function() return #registered.lines > reg0 end, 10 * 60000)
    sim:expect(#registered.lines > reg0, "the miner re-registered after the restart")
    sim:dispatch{ type = "RECALL_ALL", params = { reason = "w1_resume_refused_recall" } }

    -- POSITIVE 1: it said why, and the why was the recall.
    local said = sim:run_until(function() return #wentHome.lines >= 1 end, 20 * 60000)
    sim.results.went_home = table.concat(wentHome.lines, " | ")
    sim:expect(said, "the miner reported going home and named a reason ("
      .. #wentHome.lines .. " lines)")
    -- EITHER OF TWO REASONS IS CORRECT HERE, and which one it is depends on
    -- something the turtle cannot control: whether it was listening when the
    -- recall went out. Boot recovery swaps the modem out for the chunk loader,
    -- so a miner retrieving its loader is deaf -- this run produced
    -- "no_job_came_back", because from the turtle's side that is exactly what
    -- happened: the job it was waiting for was cancelled and never re-sent.
    -- "job_recalled" is the reason when it did hear the broadcast.
    --
    -- Both end in the same correct action and both satisfy the card's FAILED IF
    -- ("a recalled job is resumed"), so both are accepted -- but a THIRD reason,
    -- or no reason at all, still fails. Pinning it to one string would be
    -- pinning the test to the radio timing rather than to the behaviour.
    local named = 0
    for _, l in ipairs(wentHome.lines) do
      if l:find("job_recalled", 1, true) or l:find("no_job_came_back", 1, true) then
        named = named + 1
      end
    end
    sim.results.named_reason = named
    sim:expect(named >= 1,
      "and the reason was the recall or the job never coming back (" .. named
      .. " of " .. #wentHome.lines .. ": " .. sim.results.went_home .. ")")

    -- POSITIVE 2: it actually went home, rather than merely saying so.
    local home = sim:run_until(function() return #docked.lines > d0 end, 30 * 60000)
    sim.results.docked_after = #docked.lines - d0
    sim:expect(home, "and it docked (" .. (#docked.lines - d0) .. " DOCKED lines)")

    -- AND IT NEVER CLAIMED TO RESUME. Checked last, with the positives in hand.
    sim.results.resume_lines = #resumed.lines
    sim:expect(#resumed.lines == 0,
      "and it never reported resuming a recalled job (" .. #resumed.lines
      .. ") -- the card's own FAILED IF")
  end,
}
