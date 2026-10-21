-- W3 card "Turtles say how they lost the server" (the unreachable-warning witness, 1.9.106 and later).
-- Live, every warning so far has said "radio on and loop turning -- the ACKs did not arrive", so the instrument has
-- not yet shown it can say anything else -- and 1.9.96 once said exactly that about a turtle with NO radio. Two cases
-- here, each with a known right answer:
--   A. The server goes down the moment a miner starts a loader swap. The modem is off for about a second, so by the
--      time the miner misses its acks the radio is back: right answer "radio on ... the ACKs did not arrive".
--      (This is also why the "declared comms gap" verdict never appears live: the gap is shorter than a heartbeat.)
--   B. The server is up, and the miner's modem is pulled out mid-mining for 3 minutes. Right answer: "no radio for N
--      of them -- and NO comms gap was declared". Blaming lost acks here is the 1.9.96 wrong answer.
return {
  world = "synthetic",
  seed = 1,
  miners = 1,
  steps = function(sim)
    local retrieving = sim:capture_log("phase: RETRIEVING (comms gap expected)")
    local mining     = sim:capture_log("phase: MINING")
    local warnings   = sim:capture_log("Server unreachable")
    sim:run_for(120000)
    local area = sim.world:meta().areas[1]
    sim:dispatch{ type = "ORDER_MINE", params = { x1 = area.x1, z1 = area.z1, x2 = area.x2, z2 = area.z2, minerCount = 1 } }

    local function verdicts(from, miner)
      local out = {}
      for i = from + 1, #warnings.lines do
        if warnings.lines[i]:find(miner, 1, true) then out[#out + 1] = warnings.lines[i] end
      end
      return out
    end

    -- A: server down from the start of a loader swap ----------------------------------------------------
    local hit = sim:run_until(function() return #retrieving.lines >= 2 end, 6 * 3600 * 1000)
    sim:expect(hit, "A: a miner started a loader swap")
    if not hit then return end
    local miner = retrieving.lines[2]:match("(node_%d+) phase")
    local beforeA = #warnings.lines
    sim:server_crash(sim.clock:now() - sim.t0, 3 * 60000)
    sim:run_for(10 * 60000)
    local a = verdicts(beforeA, miner)
    sim:expect(#a >= 1, "A: " .. miner .. " reported losing the server (" .. #a .. ")")
    sim:expect(#a >= 1 and a[1]:find("radio on and loop turning", 1, true) ~= nil,
      "A: the verdict is 'radio on and loop turning' -- the radio was back before the acks were missed")
    sim.results.A = a[1] and a[1]:sub(1, 260) or "none"

    -- B: modem pulled out mid-mining, server up ----------------------------------------------------------
    local m0 = #mining.lines
    local mid = sim:run_until(function() return #mining.lines > m0 end, 3 * 3600 * 1000)
    sim:expect(mid, "B: the miner is mining again")
    if not mid then return end
    sim:run_for(20000)
    local st = sim.by_name[miner].tstate
    local side
    for _, s in ipairs({ "left", "right" }) do
      if st.equipped[s] and tostring(st.equipped[s]):find("modem", 1, true) then side = s end
    end
    sim:expect(side ~= nil, "B: the miner had a modem equipped to pull")
    if not side then return end
    local modem = st.equipped[side]
    local beforeB = #warnings.lines
    sim:equip(miner, side, nil)                                -- THE TEST: no radio at all, server fine
    sim:run_for(3 * 60000)
    sim:equip(miner, side, modem)                              -- put it back so the job can finish
    sim:run_for(5 * 60000)
    local b = verdicts(beforeB, miner)
    sim:expect(#b >= 1, "B: " .. miner .. " reported losing the server (" .. #b .. ")")
    local named = false
    for _, l in ipairs(b) do if l:find("NO comms gap was declared", 1, true) then named = true end end
    local blamed = false
    for _, l in ipairs(b) do if l:find("the ACKs did not arrive", 1, true) then blamed = true end end
    sim:expect(named, "B: the verdict says there was no radio and no declared gap")
    sim:expect(not blamed, "B: it never blames lost acks while it has no radio (the 1.9.96 wrong answer)")
    sim.results.B = b[1] and b[1]:sub(1, 260) or "none"
    sim.results.miner = miner
  end,
}
