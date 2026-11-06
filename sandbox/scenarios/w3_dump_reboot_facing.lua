-- W3, the card "Miners rebooted during DUMPING journal the wrong facing (3 of 5 at the 11-03 restart, no hand moves)".
-- The question: what does the dump step do to the facing, and does the journal record it? Answer: the dump makes no
-- turn at all; the journal was right. Underground the block ahead of a dumping miner is rock, so at boot
-- detectFacing turns right until a step is free -- and the boot check compared the journal's facing from BEFORE those
-- turns with the facing measured AFTER them (fixed: the measuring turns are counted).
--
-- Here: two miners mine; every time one reports DUMPING it is rebooted on the spot. Its true facing is read from the
-- world just before. Each reboot's boot check line is then read. A reboot only proves anything if the miner had to
-- TURN to measure (its facing after the boot differs from before): that is the evidence count.
-- CHECKS: at least 2 reboots mid-DUMPING needed a measuring turn; none of them logged JOURNAL FACING DIFFERS; every
-- one logged "Journal: agrees". On the code before the fix every turned reboot logs JOURNAL FACING DIFFERS.
-- Evidence is the boot's own "Facing:" line against the facing the world had just before the reboot.
return {
  world = "synthetic",
  seed = 1,
  miners = 2,
  steps = function(sim)
    local dumping = sim:capture_log("phase: DUMPING")
    local agrees = sim:capture_log("Journal: agrees")
    local differs = sim:capture_log("JOURNAL FACING DIFFERS")
    local facings = sim:capture_log("] Facing: ")
    local NAMES = { north = 0, east = 1, south = 2, west = 3 }
    sim:run_for(180000)
    local area = sim.world:meta().areas[1]
    sim:dispatch{ type = "ORDER_MINE", params = { x1 = area.x1, z1 = area.z1, x2 = area.x2, z2 = area.z2, minerCount = 2 } }
    local byName = {}
    for _, c in ipairs(sim.sched.computers) do byName[c.name] = c end

    local seen, trials, turned = 0, {}, 0
    local deadline = 6 * 3600000
    local t0 = sim.clock:now()
    while turned < 3 and #trials < 30 and sim.clock:now() - t0 < deadline do
      local ok = sim:run_until(function() return #dumping.lines > seen end, deadline)
      if not ok then break end
      seen = #dumping.lines
      local name = dumping.lines[seen]:match("(node_%d+) phase: DUMPING")
      local c = name and byName[name]
      if c and c.pos and c.pos.x then
        local before = { x = c.pos.x, y = c.pos.y, z = c.pos.z, facing = c.pos.facing }
        local a0, d0, f0 = #agrees.lines, #differs.lines, #facings.lines
        sim:turtle_reboot(sim.clock:now() - sim.t0, name)
        local booted = sim:run_until(function()
          for i = a0 + 1, #agrees.lines do if agrees.lines[i]:find(name, 1, true) then return true end end
          for i = d0 + 1, #differs.lines do if differs.lines[i]:find(name, 1, true) then return true end end
          return false
        end, 10 * 60000)
        -- What the boot measured: its own "Facing:" line (after any measuring turns).
        local after
        for i = f0 + 1, #facings.lines do
          if facings.lines[i]:find("[" .. name .. "]", 1, true) then
            after = NAMES[facings.lines[i]:match("Facing: (%a+)")]
            break
          end
        end
        local said = "none"
        for i = d0 + 1, #differs.lines do if differs.lines[i]:find(name, 1, true) then said = "DIFFERS" end end
        if said == "none" then
          for i = a0 + 1, #agrees.lines do if agrees.lines[i]:find(name, 1, true) then said = "agrees" end end
        end
        local t = { name = name, at = string.format("%d,%d,%d", before.x, before.y, before.z), before = before.facing,
          after = after, turnedToMeasure = booted and after ~= before.facing, said = said }
        trials[#trials + 1] = t
        if t.turnedToMeasure then turned = turned + 1 end
        sim:run_for(60000)
      end
    end

    local bad, unanswered, lines = 0, 0, {}
    for _, t in ipairs(trials) do
      if t.said == "DIFFERS" then bad = bad + 1 end
      if t.said == "none" then unanswered = unanswered + 1 end
      lines[#lines + 1] = string.format("%s@%s facing %s->%s %s", t.name, t.at, tostring(t.before), tostring(t.after), t.said)
    end
    sim.results.trials = table.concat(lines, "; ")
    sim:expect(turned >= 2, string.format("%d reboot(s) mid-DUMPING needed a measuring turn (of %d): the check below has "
      .. "something to judge", turned, #trials))
    sim:expect(bad == 0, string.format("no reboot logged JOURNAL FACING DIFFERS (%d did): %s", bad, table.concat(lines, "; ")))
    sim:expect(unanswered == 0, string.format("every reboot's boot check said agrees (%d said nothing)", unanswered))
  end,
}
