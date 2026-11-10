-- W1, resume-after-restart at FLEET SCALE. Written before SHAKEOUT 5 depends on
-- it, because 1.9.161 is new behaviour that 160 turtles will exercise for 24
-- hours and I had only ever tested it with one miner.
--
-- THE RISK I INTRODUCED. A miner that reboots mid-job now HOLDS POSITION and
-- waits for the server to re-send its job. If that job never comes,
-- base.setIdleAction brings it home after three idle minutes. With one miner
-- that is obviously fine. With a fleet, two things could go wrong and neither
-- would have shown up in the single-miner runs:
--
--   1. A THUNDERING HERD. Every miner reboots at the same instant in a world
--      restart, so every three-minute timer expires at the same instant too. If
--      the jobs do not come back, they all fly home together and converge on
--      the single-block arrivals hole -- which is the chokepoint the ATC cards
--      exist for, and the thing that stranded the LAST miner home in earlier
--      incidents. The old behaviour staggered itself naturally, because each
--      miner's flight home started when its own loader retrieval finished.
--   2. CROSSED ORDERS. Several miners resume from their own persisted orders
--      while the server is independently re-sending jobs and re-issuing
--      sectors. If any two end up on the same sector, or a miner resumes a
--      sector the server has given to someone else, that is the "mined twice"
--      the parent card calls a FAILED IF -- and with one miner it is
--      unobservable by construction.
--
-- WHAT IT ASSERTS. Every miner that was working must be mining again, none may
-- dock in between, and no sector may be reported done twice across the whole
-- fleet. The last one is the point: it is the check that only exists at scale.
--
-- WHY FOUR MINERS AND NOT 160. This is the cheap sentinel, not the shakeout.
-- Four is enough for two miners to collide on one sector and for the herd to be
-- visible as a count, and it runs in a minute rather than a day. If it fails,
-- SHAKEOUT 5 would have found the same thing after 24 hours of someone's time.
local function miners(sim)
  local out = {}
  for _, c in ipairs(sim.sched.computers) do
    if c.role == "miner" then out[#out + 1] = c end
  end
  return out
end

return {
  world  = "synthetic",
  seed   = 1,
  miners = 4,
  steps = function(sim)
    local disp     = sim:capture_log("Dispatched job_")
    local mining   = sim:capture_log("phase: MINING")
    local resumed  = sim:capture_log("resuming sector (")
    local wentHome = sim:capture_log("going home: ")
    local docked   = sim:capture_log("phase: DOCKED")
    local done     = sim:capture_log("done by")

    sim:run_for(120000)
    local ms = miners(sim)
    sim:expect(#ms >= 2, "at least two miners, or the collision checks below "
      .. "cannot fail by construction (" .. #ms .. ")")
    if #ms < 2 then return end

    -- A zone wide enough that the server cuts it into several sectors and hands
    -- one to each miner: that is what makes two of them able to collide.
    local area = sim.world:meta().areas[1]
    sim:dispatch{ type = "ORDER_MINE",
      params = { x1 = area.x1, z1 = area.z1, x2 = area.x1 + 32, z2 = area.z1,
                 minerCount = #ms } }
    sim:run_until(function() return #disp.lines >= 1 end, 10 * 60000)
    sim:expect(#disp.lines >= 1, "a job was dispatched")
    if #disp.lines < 1 then return end

    -- Wait for MORE THAN ONE miner to be mining, so the restart catches several
    -- of them mid-sector rather than one.
    local function nodesMining()
      local seen = {}
      for _, l in ipairs(mining.lines) do
        local n = l:match("(node_%d+) phase: MINING")
        if n then seen[n] = true end
      end
      local k = 0
      for _ in pairs(seen) do k = k + 1 end
      return k
    end
    local several = sim:run_until(function() return nodesMining() >= 2 end, 4 * 3600000)
    sim.results.mining_before_restart = nodesMining()
    sim:expect(several, "at least two miners were mid-sector when the world "
      .. "restarted (" .. sim.results.mining_before_restart .. ")")
    if not several then return end
    sim:run_for(60000)

    local d0, m0 = #docked.lines, #mining.lines
    local gens = {}
    for _, c in ipairs(ms) do gens[c.name] = c.gen end

    sim:world_restart(sim.clock:now() - sim.t0 + 1000)   -- THE TEST

    local allBack = sim:run_until(function()
      for _, c in ipairs(ms) do if c.gen == gens[c.name] then return false end end
      return true
    end, 15 * 60000)
    sim:expect(allBack, "every miner rebooted")

    -- They must resume, and the count matters: one resuming while three fly
    -- home would pass a "did anyone resume" check and still be the herd.
    sim:run_until(function() return #mining.lines > m0 end, 15 * 60000)
    sim:run_for(300000)
    sim.results.resume_lines = #resumed.lines
    sim.results.went_home_lines = #wentHome.lines
    sim.results.docked_after_restart = #docked.lines - d0

    sim:expect(sim.results.resume_lines >= 2,
      "at least two miners resumed where they stood (" .. sim.results.resume_lines
      .. " resume lines, " .. sim.results.went_home_lines .. " went home)")

    -- THE HERD. Nobody should dock; if they do, it must not be all of them at
    -- once, which is the arrivals-hole pile-up.
    sim:expect(sim.results.docked_after_restart == 0,
      "no miner docked after the restart (" .. sim.results.docked_after_restart
      .. ") -- several at once is the arrivals-hole chokepoint the ATC cards are about")

    -- CROSSED ORDERS: the check that only exists at scale.
    local seen, dupes = {}, {}
    for _, l in ipairs(done.lines) do
      local sx, sz = l:match("Sector %((-?%d+),(-?%d+)%) done by")
      if sx then
        local k = sx .. "," .. sz
        if seen[k] then dupes[#dupes + 1] = k end
        seen[k] = true
      end
    end
    sim.results.sector_done_lines = #done.lines
    sim.results.sectors_done_twice = table.concat(dupes, " ")
    sim:expect(#dupes == 0,
      "no sector was reported done twice across the fleet (" .. #dupes .. " of "
      .. #done.lines .. ": " .. sim.results.sectors_done_twice
      .. ") -- two miners resuming onto one sector is the parent card's FAILED IF")
  end,
}
