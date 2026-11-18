-- W3, 2026-11-18 (T2 shakeout-24h-b): miner node_481 rebooted mid-job at 04:16 while the server was deaf. A turtle
-- learned its dock only from REGISTER_ACK and kept it nowhere, so it flew home not knowing where home was, logged
-- "No dock assigned, staying put" in the arrivals column at 228,200,-2782 and held ARR for 38 min (node_178 the same
-- at 839,200,-2813). Now a turtle keeps the dock it was given (dock.dat) and starts from it after a reboot.
--
-- Here: one miner; once it is digging its first mine sector it reboots, and for 10 minutes the server hears nothing
-- from it (its registration fails), as in a deaf server.
-- CHECKS: it rebooted with the server out of reach (evidence: its registration went unanswered); it knew its dock
-- from before the reboot; it never said "No dock assigned"; it did not stay where it rebooted (with its dock
-- known it re-registers once the server hears it and goes on with its job).
-- Before the fix it says "No dock assigned, staying put" and stays where it is.
local function isMine(l) return not l:find("[SURVEY]", 1, true) and not l:find("[RESCAN]", 1, true) end

return {
  world = "synthetic",
  seed = 1,
  miners = 1,
  steps = function(sim)
    local assigned = sim:capture_log("Assigned sector (")
    local surveyed = sim:capture_log("survey complete (")
    local noReply = sim:capture_log("No response from server")
    local fromDisk = sim:capture_log("Dock from before the reboot")
    local noDock = sim:capture_log("No dock assigned")
    sim:run_for(120000)
    local area = sim.world:meta().areas[1]
    sim:dispatch{ type = "ORDER_MINE", params = { x1 = area.x1, z1 = area.z1, x2 = area.x2, z2 = area.z2 } }
    local victim
    local mining = sim:run_until(function()
      if #surveyed.lines == 0 then return false end
      for _, l in ipairs(assigned.lines) do
        if isMine(l) then victim = victim or l:match("to (node_%d+)") end
      end
      return victim ~= nil
    end, 12 * 3600 * 1000)
    sim:expect(mining, "the survey finished and a miner started a mine sector")
    if not mining then return end
    sim:run_for(3 * 60000)                                         -- digging
    local comps = {}
    for _, c in ipairs(sim.sched.computers) do comps[c.name] = c end
    local m = comps[victim]
    local home = m.home_pos
    local function by(cap)
      local out = {}
      for _, l in ipairs(cap.lines) do if l:find(victim .. "#", 1, true) or l:find("[" .. victim .. "]", 1, true) then out[#out + 1] = l end end
      return out
    end
    local noReplyBefore = #by(noReply)
    local at = string.format("%d,%d,%d", m.pos.x, m.pos.y, m.pos.z)
    local rule = sim:drop_radio{ channel = 1, from = victim }      -- THE FAULT: the server hears nothing from it
    sim:reboot(victim)
    sim:run_for(10 * 60000)
    sim.sched.radio:remove_rule(rule)
    sim:run_for(60 * 60000)
    -- Its log lines go by way of the server: those from the cut-off arrive late, and boot lines can be lost, so the
    -- evidence is read at the end, and what it knew at boot from its own screen.
    local screen = sim:output(victim) or ""
    local now = string.format("%d,%d,%d", m.pos.x, m.pos.y, m.pos.z)
    sim:expect(#by(noReply) > noReplyBefore, victim .. " rebooted at " .. at .. " with the server out of reach (its registration "
      .. "went unanswered): the checks below have something to judge")
    sim:expect(screen:find("Dock from before the reboot", 1, true) ~= nil, victim .. " knew its dock from before the reboot")
    sim:expect(#by(noDock) == 0 and screen:find("No dock assigned", 1, true) == nil,
      victim .. " never said 'No dock assigned' (" .. tostring((by(noDock)[1] or "none"):sub(-80)) .. ")")
    sim:expect(now ~= at, victim .. " did not stay where it rebooted (" .. at .. " -> " .. now .. ")")
  end,
}
