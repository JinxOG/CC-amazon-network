-- W1 card "Miners lose GPS and freeze on one stretch of the flight lane
-- (x ~1300-1550, y 200, z -2813)" -- THE MECHANISM EXPERIMENT.
--
-- This decides nothing about the live lane. It answers the one question the
-- card cannot answer from its own evidence, in a world where I can dispatch
-- jobs: CAN a miner in flight be frozen by its chunk unloading at all?
--
-- WHY THE QUESTION MATTERS MORE THAN THE CARD'S OWN THEORY. The card is framed
-- as a GPS coverage gap over one stretch of sky and proposes either a relay
-- part-way along or a different route. W3's update of 2026-10-20 points
-- somewhere else entirely: TWO frozen miners were woken by a passing turtle
-- (node_177 on 10-15, node_178 on 10-20), and node_183 crossed the whole lane
-- both ways that day with zero GPS failures. "Woken by a passer" is what chunk
-- loading looks like, not what a radio dead spot looks like. If the mechanism
-- is chunk unloading then a GPS relay fixes nothing, and the card's proposed
-- fix is aimed at the wrong thing.
--
-- AND THERE IS A REASON TO DOUBT IT TOO, which is why this is an experiment and
-- not a demonstration. A miner in travel mode carries its own chunk loader and
-- logs "self-loading restored" -- if that ticket holds in flight, its chunk
-- CANNOT unload under it and chunk unloading is excluded as the mechanism,
-- leaving the GPS theory standing. Either outcome is worth having. The checks
-- below therefore assert only that the experiment was validly staged; WHAT
-- HAPPENED is recorded in sim.results for a human to read, because a test that
-- asserts the answer it hopes for is not an experiment.
--
-- HOW IT IS STAGED. A mining job sends a miner out; once it is at travel
-- altitude and moving, the chunk it is standing in is force-unloaded for two
-- minutes, then allowed back. The question is whether its own log goes silent
-- across that window and resumes afterwards.
--
-- WHAT A READER SHOULD DO WITH IT. If lines_during_unload is 0 and lines_after
-- is not, chunk unloading freezes a miner in flight and the card should be
-- re-aimed at chunk loading on the lane -- which also makes sense of the live
-- symptom nobody could explain, since a lane crosses chunks nobody else keeps
-- loaded. If the miner keeps logging throughout, its own ticket holds and the
-- card's GPS framing survives.
local function node(sim, role)
  for _, c in ipairs(sim.sched.computers) do if c.role == role then return c end end
end

return {
  world  = "synthetic",
  seed   = 1,
  miners = 1,
  steps = function(sim)
    local disp   = sim:capture_log("Dispatched job_")
    local travel = sim:capture_log("phase: TRAVELLING")
    local phases   = sim:capture_log("node_11 phase:")

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

    -- IN FLIGHT, AT ALTITUDE. Not at the dock and not at the sector: the card is
    -- about the lane, and a turtle on the ground has neighbours keeping its
    -- chunks loaded.
    local flying = sim:run_until(function()
      local p = miner.pos
      return #travel.lines >= 1 and p and p.y and p.y >= 100
    end, 20 * 60000)
    local p = miner.pos
    sim.results.unload_at = p and string.format("%d,%d,%d", p.x, p.y, p.z) or "unknown"
    sim:expect(flying and p ~= nil,
      "the miner was in flight at altitude when the chunk was pulled (at "
      .. sim.results.unload_at .. ") -- on the ground or at its dock this would "
      .. "be testing something else entirely")
    if not (flying and p) then return end

    -- THE EXPERIMENT. Pull the chunk it is standing in, and watch whether it
    -- keeps MOVING.
    --
    -- Movement, not logging. The first attempt used its log lines and failed
    -- with "0 lines" -- a miner in flight prints almost nothing, which is the
    -- very thing this card documents: node_118's log had a 15-minute hole
    -- across a flight home, and that silence is exactly why a frozen miner and
    -- a flying one were indistinguishable live. Position is the signal the live
    -- symptom was actually read from ("appeared frozen at their loader
    -- coordinates"), so it is the signal used here.
    local function at()
      local q = miner.pos
      return q and string.format("%d,%d,%d", q.x or 0, q.y or 0, q.z or 0) or "?"
    end
    local function movedOver(ms)
      local a = at(); sim:run_for(ms); return at() ~= a, a, at()
    end

    local movedBefore, b1, b2 = movedOver(20000)
    sim.results.before_unload = b1 .. " -> " .. b2
    sim:expect(movedBefore,
      "the miner was moving before the chunk was pulled (" .. sim.results.before_unload
      .. ") -- without that, stillness afterwards proves nothing")

    local cx, cz = math.floor((miner.pos.x or 0) / 16) * 16, math.floor((miner.pos.z or 0) / 16) * 16
    sim.results.chunk_pulled = string.format("%d,%d..%d,%d", cx, cz, cx + 15, cz + 15)
    sim:chunk_unload(sim.clock:now() - sim.t0 + 1000, { cx, cz, cx + 15, cz + 15 })
    sim:run_for(5000)

    -- PHASE LINES TELL "FROZEN" FROM "ARRIVED", which movement alone cannot: a
    -- miner that reached its sector also stops moving along the lane, and the
    -- first run of this read exactly that as an inconclusive stop. A turtle
    -- that arrived reports a new phase (PLACING_LOADER, SCANNING); a frozen one
    -- reports nothing at all, because it is not being ticked.
    local ph0 = #phases.lines
    local movedDuring, d1, d2 = movedOver(120000)
    sim.results.during_unload = d1 .. " -> " .. d2
    sim.results.phases_during_unload = #phases.lines - ph0
    -- AND GIVE THE CHUNK BACK, which is the half that decides what the fix has
    -- to be. If a frozen miner wakes up and carries on, keeping the lane loaded
    -- is enough. If it does not, the lane needs loading AND something to
    -- recover the turtles already stranded on it -- which the 24-hour shakeout
    -- would otherwise discover the hard way, with 160 turtles.
    --
    -- clear_forced is the loading model's own undo. Called directly rather than
    -- through a fault, because the fault list has no "load" verb: chunk_unload
    -- takes no duration in the simulator (the test server's does).
    local ph1 = #phases.lines
    sim.sched.loading:clear_forced()
    local movedAfter, a1, a2 = movedOver(300000)
    sim.results.after_unload = a1 .. " -> " .. a2
    sim.results.phases_after_unload = #phases.lines - ph1

    local silentDuring = (not movedDuring) and sim.results.phases_during_unload == 0
    local aliveAfter = movedAfter or sim.results.phases_after_unload > 0

    sim.results.verdict =
      (silentDuring and aliveAfter)
        and "FROZEN BY THE UNLOAD AND RECOVERED -- chunk loading freezes a miner in flight, so it IS a live mechanism for the lane card and a GPS relay would not fix it"
      or (silentDuring and "FROZEN AND STILL FROZEN at the end of the run -- the unload stopped it; whether it recovers needs a longer window")
      or ((not movedDuring) and "STOPPED BUT STILL REPORTING -- it arrived rather than froze; the unload did not catch it in flight")
      or "KEPT MOVING THROUGH THE UNLOAD -- its own chunk ticket held, so chunk unloading is NOT the mechanism and the card's GPS framing survives"
    sim.results.moved = string.format("moved before=%s during=%s after=%s; phase lines during=%d after=%d",
      tostring(movedBefore), tostring(movedDuring), tostring(movedAfter),
      sim.results.phases_during_unload, sim.results.phases_after_unload)

    -- The only assertion: the experiment ran and produced a reading. What the
    -- reading SAYS is deliberately not asserted -- see the header.
    sim:expect(sim.results.verdict ~= nil,
      "the experiment produced a reading: " .. tostring(sim.results.verdict))
  end,
}
