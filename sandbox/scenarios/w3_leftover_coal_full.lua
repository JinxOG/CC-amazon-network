-- W3 card "Refuels leave turtles full of leftover coal" -- the live fault behind it, 2026-10-27.
-- The return of leftover coal (96add99) never once worked live: 325 refuels since 1.9.138 and no "Returned" line,
-- and on the test server a miner came away from a FORCE_REFUEL with 265 coal aboard. The coal chests are kept topped
-- up by the base, so they are full again before the turtle can hand anything back. The simulator's fuel chest is an
-- endless source that swallows anything put back, which is why w3_leftover_coal passed here and failed there.
-- This scenario makes every coal chest the miner can reach kept-full: it never runs out and accepts nothing.
-- An idle miner's tank is set to 70,000 (room for 375 coal), FORCE_REFUEL is sent, and afterwards it must be full
-- with no loose coal outside the reserve slot 14.
-- Fails on 7a78325 (takes 64 into every free slot and cannot give the rest back); passes on the fix (takes only
-- what the tank burns).
local COAL = "minecraft:coal"

local function kept_full(c)
  c.put  = function() return 0 end
  c.take = function(_, n, name)
    if name ~= nil and name ~= COAL then return nil end
    return { name = COAL, count = math.min(n, 64) }
  end
end

return {
  world = "synthetic",
  seed = 1,
  miners = 1,
  steps = function(sim)
    local force = sim:capture_log("FORCE_REFUEL received")
    local done  = sim:capture_log("Refuelled +")
    sim:run_for(120000)
    -- THE TEST: the fuel frequency, and any chest already in the world that gives coal, kept full
    local fuel = sim.sched.ender:inventory("fuel")
    kept_full(fuel)
    local n = 0
    for _, ct in pairs(sim.world.containers) do
      local probe = ct.take and ct.inventory and ct.inventory.list and ct.inventory:list() or {}
      for _, st in pairs(probe) do
        if st.name == COAL then kept_full(ct); n = n + 1; break end
      end
    end
    sim.results.kept_full_chests = n
    local miner
    for _, c in ipairs(sim.sched.computers) do
      if c.role == "miner" and c.tstate then miner = c; break end
    end
    sim:expect(miner ~= nil, "a miner")
    if not miner then return end
    sim:set_fuel(miner.name, 70000)
    sim:run_for(15000)
    sim:dispatch{ type = "FORCE_REFUEL", params = { turtleId = miner.name } }
    local got = sim:run_until(function() return #force.lines >= 1 end, 120000)
    sim:expect(got, miner.name .. " received FORCE_REFUEL")
    sim:run_until(function() return #done.lines >= 1 end, 120000)
    sim:run_for(30000)
    sim:expect(miner.tstate.fuel >= 99920, "the tank is full (" .. tostring(miner.tstate.fuel) .. ")")
    local loose = {}
    for s = 1, 16 do
      local it = miner.tstate.inv[s]
      if s ~= 14 and it and tostring(it.name):find("coal", 1, true) then loose[#loose + 1] = s .. ":" .. it.count end
    end
    sim:expect(#loose == 0, "no loose coal aboard outside slot 14 (" .. table.concat(loose, " ") .. ")")
    sim.results.fuel_after = miner.tstate.fuel
  end,
}
