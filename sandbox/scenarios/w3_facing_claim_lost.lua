-- W3, 2026-11-23 (T2 shakeout-payload-c): node_453, docked in bay 4, claimed the sections beside its dock to measure
-- its facing (claimAround: one-off claims, not a booking); its one ATC_LEAVE for N4 was lost, and N4 stood claimed for
-- good -- no report healed a one-off claim, and its messages kept it alive. The 8 miners docked beside it could never
-- claim N4 to measure their own facing ("the ATC has not granted the sections around it") and were decommissioned.
-- Now a report drops every reservation of the turtle it no longer stands in, and a turtle that let go of what it
-- claimed says it is out a while, as after stepping out of the base.
--
-- Here: miners docked under the ATC. A is rebooted with every ATC_LEAVE it sends lost; once it has measured, every
-- other miner whose dock shares a section with A's is rebooted, and a mine order for every miner is placed.
-- CHECKS: A measured its facing with its ATC_LEAVEs lost (evidence: after it measured, the ATC held a section for A, or let one go on A's own report);
-- with work ordered for every miner, every neighbour measured its facing; the ATC let A's
-- claim go on A's own report.
-- Before the fix the neighbours never measure.
return {
  world = "synthetic",
  seed = 1,
  miners = 8,
  per_bay = true,
  atc = true,
  preset_docks = true,
  steps = function(sim)
    local measured = sim:capture_log("] Facing: ")
    local refused = sim:capture_log("has not granted the sections around it")
    local summary = sim:capture_log("section(s) held")
    local healed = sim:capture_log("reports from outside the base")
    sim:run_for(5 * 60000)
    local Wl = assert(loadfile(sim.sched.code_dir .. "/waypoints.lua", "t",
      setmetatable({ fs = { exists = function() return false end } }, { __index = _G })))()
    local function around(p)
      local s, cur = {}, Wl.atcSection(p.x, p.y, p.z)
      for _, d in ipairs({ { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } }) do
        local x = Wl.atcSection(p.x + d[1], p.y, p.z + d[2])
        if x and x ~= cur then s[x] = true end
      end
      return s
    end
    local miners = {}
    for _, c in ipairs(sim.sched.computers) do
      if c.kind == "turtle" and c.role == "miner" and c.pos and c.pos.x then miners[#miners + 1] = c end
    end
    -- A: the miner with the most docked neighbours sharing a section with it
    local best, bestN
    for _, a in ipairs(miners) do
      local sa, n = around(a.pos), {}
      for _, b in ipairs(miners) do
        if b ~= a then
          for s in pairs(around(b.pos)) do if sa[s] then n[#n + 1] = b; break end end
        end
      end
      if not best or #n > #bestN then best, bestN = a, n end
    end
    sim:expect(best ~= nil and #bestN >= 1, string.format("a docked miner shares a section with %d other(s)", bestN and #bestN or 0))
    if not best or #bestN == 0 then return end
    local A = best.name
    local function by(cap, who, from)
      local out = {}
      for i = from or 1, #cap.lines do local l = cap.lines[i]; if l:find("[" .. who .. "]", 1, true) or l:find(who .. "#", 1, true) then out[#out + 1] = l end end
      return out
    end
    local m0 = #measured.lines
    sim:drop_radio{ type = "ATC_LEAVE", from = A }                     -- THE FAULT: every ATC_LEAVE it sends is lost
    sim:reboot(A)
    local okA = sim:run_until(function() return #by(measured, A, m0 + 1) >= 1 end, 10 * 60000)
    local s0 = #summary.lines
    local m1, r1 = #measured.lines, #refused.lines
    for _, b in ipairs(bestN) do sim:reboot(b.name) end
    -- A docked miner refused at boot measures again when it has to move: when it is given work (payload-c's 8 were
    -- given jobs and stood "stuck_no_fix: facing unknown"). Work for every miner.
    sim:run_for(60000)
    local area = sim.world:meta().areas[1]
    sim:dispatch{ type = "ORDER_MINE", params = { x1 = area.x1, z1 = area.z1, x2 = area.x2, z2 = area.z2, minerCount = #miners } }
    sim:run_until(function()
      for _, b in ipairs(bestN) do if #by(measured, b.name, m1 + 1) == 0 then return false end end
      return true
    end, 90 * 60000)
    local missing = {}
    for _, b in ipairs(bestN) do if #by(measured, b.name, m1 + 1) == 0 then missing[#missing + 1] = b.name end end
    sim:expect(#missing == 0, string.format("all %d neighbours measured their facing once given work, within 90 min (not: %s; "
      .. "%d refusals)", #bestN, table.concat(missing, " "), #refused.lines - r1))
    -- Evidence, read at the end (the ATC's summary is not printed often): after A measured, the ATC held a section for it.
    local heldForA
    for i = s0 + 1, #summary.lines do
      local l = summary.lines[i]
      if l:find("=" .. A, 1, true) then heldForA = l; break end
    end
    for _, l in ipairs(healed.lines) do if not heldForA and l:find(A .. " reports", 1, true) then heldForA = l end end
    sim:expect(okA and heldForA ~= nil, A .. " measured with its ATC_LEAVEs lost and the ATC still held a section for it after (or let it go on its "
      .. "own report): the "
      .. "checks have something to judge (" .. tostring((heldForA or "never held"):sub(-110)) .. ")")
    local own
    for _, l in ipairs(healed.lines) do if not own and l:find(A .. " reports", 1, true) then own = l end end
    sim:expect(own ~= nil, "the ATC let " .. A .. "'s claim go on its own report (" .. tostring((own or "it did not"):sub(-90)) .. ")")
  end,
}
