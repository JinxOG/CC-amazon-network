-- W3, 2026-11-13 (SPEC-OWNER's ruling of 2026-11-12, fix 3): T2 run shakeout-fleet-d posted 126 HOLD_TURTLE commands
-- back to back and 29 were dropped as duplicates. The bridge stamps each command with Date.now() and the server's
-- duplicate check keyed on that time and the type alone, so two DIFFERENT commands of one type queued in the same
-- millisecond shared a key. Two miners that should have been held took the two mine jobs.
--
-- Here, with no time between them (the stand-in stamps both with the same sim millisecond):
--   1. HOLD_TURTLE for two different turtles: both must be held.
--   2. The same HOLD_TURTLE twice, for a third turtle: one runs, one is dropped as the copy it is.
-- On the code before the fix the second hold of (1) is dropped.
return {
  world = "synthetic",
  seed = 1,
  miners = 1,
  steps = function(sim)
    local held = sim:capture_log("is not offered work until released")
    local dup = sim:capture_log("duplicate ignored (HOLD_TURTLE)")
    sim:run_for(180000)
    local names = {}
    for name in pairs(((sim.sched.standin.state or {}).turtles) or {}) do names[#names + 1] = name end
    table.sort(names)
    sim:expect(#names >= 3, "at least three turtles registered (" .. #names .. "): the checks below have something to judge")
    if #names < 3 then return end
    local a, b, c = names[1], names[2], names[3]

    local before = #held.lines
    sim:dispatch{ type = "HOLD_TURTLE", params = { turtleId = a, reason = "w3_dup_commands" } }
    sim:dispatch{ type = "HOLD_TURTLE", params = { turtleId = b, reason = "w3_dup_commands" } }
    sim:run_for(15000)
    local function heldOne(name)
      for i = before + 1, #held.lines do
        if held.lines[i]:find("HOLD: " .. name .. " ", 1, true) then return true end
      end
      return false
    end
    sim:expect(heldOne(a), a .. " held (the first of two holds in one millisecond)")
    sim:expect(heldOne(b), b .. " held too, not dropped as a duplicate of " .. a .. "'s")
    sim:expect(#dup.lines == 0, "no duplicate dropped in (1) (" .. #dup.lines .. ")")

    before = #held.lines
    local cmd = { type = "HOLD_TURTLE", params = { turtleId = c, reason = "w3_dup_commands twice" } }
    sim:dispatch(cmd)
    sim:dispatch(cmd)
    sim:run_for(15000)
    local n = 0
    for i = before + 1, #held.lines do if held.lines[i]:find("HOLD: " .. c .. " ", 1, true) then n = n + 1 end end
    sim:expect(n == 1, c .. " held once by the same command sent twice (" .. n .. ")")
    sim:expect(#dup.lines == 1, "and the copy dropped as a duplicate (" .. #dup.lines .. ")")
  end,
}
