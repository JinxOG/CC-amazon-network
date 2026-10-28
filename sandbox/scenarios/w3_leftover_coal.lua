-- W3 card "Refuels leave turtles full of leftover coal - now returned to the chest" (fix 96add99, released in 1.9.138 (pinned ecfb1b6)).
-- A miner's tank is drained to 2,000 before it is dispatched -- less than the zone needs -- so it refuels at its dock
-- station before it sets off.
-- A refuel sucks coal into every empty working slot and burns only what the tank takes; the rest must go back to
-- the chest it came from ("Returned N leftover fuel item(s)"), leaving no loose coal outside the reserve slot 14.
-- On 96add99~1 the leftover coal stays aboard (the user's 2026-10-08 report). The simulator's fuel chest takes back
-- anything, unlike the live one, which the base keeps full; w3_leftover_coal_full covers that case.
return {
  world = "synthetic",
  seed = 1,
  miners = 1,
  steps = function(sim)
    local refuel   = sim:capture_log("Refuelling at dock station")
    local returned = sim:capture_log("leftover fuel item(s)")
    local disp     = sim:capture_log("Dispatched job_")
    local depart   = sim:capture_log("phase: DEPARTING")
    sim:run_for(120000)
    local n = 0
    for _, c in ipairs(sim.sched.computers) do         -- every miner: whichever is dispatched must refuel
      if c.role == "miner" and c.tstate then sim:set_fuel(c.name, 2000); n = n + 1 end   -- THE TEST
    end
    sim:expect(n > 0, "drained " .. n .. " miner(s) to 2,000 fuel")
    local area = sim.world:meta().areas[1]
    sim:dispatch{ type = "ORDER_MINE", params = { x1 = area.x1, z1 = area.z1, x2 = area.x2, z2 = area.z2, minerCount = 1 } }
    local went = sim:run_until(function() return #depart.lines >= 1 end, 20 * 60000)
    sim:expect(went, "the miner set off")
    if not went then return end
    local miner = sim.by_name[disp.lines[1]:match("%-> (node_%d+)")]
    -- DEPARTING is reported before the fuel check; the refuel and its log lines come after it, and turtle lines
    -- reach the log in batches. Wait until it has left the depot, then a minute more.
    local exited = sim:capture_log("Exited depot")
    sim:run_until(function() return #exited.lines >= 1 end, 15 * 60000)
    sim:run_for(60000)
    sim:expect(#refuel.lines >= 1, "it refuelled at its dock station first")
    -- Since the draw-only-what-burns fix there is normally nothing left over to return; the line is recorded, not
    -- required. What the card asks for is the check below.
    sim.results.returned_lines = #returned.lines
    local loose = {}
    for s = 1, 16 do
      local it = miner.tstate.inv[s]
      if s ~= 14 and it and tostring(it.name):find("coal", 1, true) then loose[#loose + 1] = s .. ":" .. it.count end
    end
    sim:expect(#loose == 0, "no loose coal aboard outside slot 14 as it set off (" .. table.concat(loose, " ") .. ")")
    sim.results.fuel_after = miner.tstate.fuel
  end,
}
