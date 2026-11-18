-- W3, 2026-11-17 (sim w3_side_atc on w3-leave-wip): in the outage the server timed out node_32 -- alive, its goods
-- delivered, in the holding line -- and sent job_0036 out again: it was delivered TWICE, its support node_51 was
-- RECALLed out in the tunnel ("partner_timed_out") and went home alone into the next pair, and the next order to that
-- destination waited behind "already has an active delivery". Once a delivery has collected (ITEM_COLLECTED: the goods
-- are at the destination), a timeout is a turtle late home: the job is complete and its support is left with it.
--
-- Here: one pair; the moment the warehouse has the delivery's ITEM_COLLECTED, everything the delivery sends the server
-- is lost for 600 s (the server's timeout is 240 s, counted from the last word heard and checked only every 240 s, so up to 480 s can pass; the miner and the others are heard, so the server is not deaf).
-- CHECKS: the server timed the delivery out after it had delivered (evidence); the job was not sent out again; its
-- support was not recalled; both came home; a second order to the same destination went out (nothing left "active");
-- the ATC holds nothing at the end. Before the fix the job is dispatched a second time.
local function atDock(p)
  if not p or p.y ~= 67 then return false end
  for _, row in ipairs({ -2806, -2810, -2797, -2793 }) do
    if p.z == row then
      for b = 0, 4 do
        local dx = p.x - (157 + 14 * b)
        if dx ~= 0 and dx >= -4 and dx <= 4 then return true end
      end
    end
  end
  return false
end

return {
  world = "synthetic",
  seed = 1,
  miners = 1,
  atc = true,
  preset_docks = true,
  steps = function(sim)
    local dispatched = sim:capture_log("Dispatched job_")
    local whDone = sim:capture_log("[WH] Job complete: job_")
    local timedOut = sim:capture_log("late home")
    local offline = sim:capture_log("turtle_timeout")
    local recalled = sim:capture_log("RECALL")
    local done = sim:capture_log("Job complete: job_")
    local summary = sim:capture_log("section(s) held")
    sim:storage_set("minecraft:cobblestone", 100000)
    sim:storage_set("minecraft:chest", 10000)
    sim:run_for(180000)
    local DEST = { x = 124, y = 67, z = -2824 }
    sim:dispatch{ type = "ORDER_DELIVERY", params = { items = { { name = "minecraft:cobblestone", count = 33 } }, destination = DEST } }
    sim:run_until(function() return #dispatched.lines >= 1 end, 120000)
    local job, d, s = (dispatched.lines[1] or ""):match("Dispatched (job_%d+) %[DELIVER%] %-> (node_%d+)%s+support job_%d+ %-> (node_%d+)")
    sim:expect(job ~= nil, "a pair was dispatched")
    if not job then return end
    local comps = {}
    for _, c in ipairs(sim.sched.computers) do comps[c.name] = c end
    local function has(cap, a, b)
      for _, l in ipairs(cap.lines) do if l:find(a, 1, true) and (not b or l:find(b, 1, true)) then return l end end
      return nil
    end
    sim:run_until(function() return has(whDone, job) ~= nil end, 30 * 60000)
    sim:expect(has(whDone, job) ~= nil, d .. " delivered (the warehouse has its ITEM_COLLECTED)")
    local rule = sim:drop_radio{ channel = 1, from = d }                 -- THE FAULT: the server hears nothing from it
    local tLoss = sim.clock:now()
    sim:run_until(function() return sim.clock:now() - tLoss >= 600000 end, 700000)
    sim.sched.radio:remove_rule(rule)
    local timeoutLine
    for _, l in ipairs(timedOut.lines) do if l:find(d, 1, true) and l:find("server#", 1, true) then timeoutLine = l end end
    for _, l in ipairs(offline.lines) do if not timeoutLine and l:find(d, 1, true) and l:find("server#", 1, true) then timeoutLine = l end end
    -- the code before logs "back to queue (from node_X: turtle_timeout)"; the fix logs "... it is late home"
    sim:expect(timeoutLine ~= nil, "the server timed " .. d .. " out after it had delivered: the checks below have something to judge ("
      .. tostring((timeoutLine or "it never did"):sub(-100)) .. ")")
    sim:run_until(function() return atDock(comps[d].pos) and atDock(comps[s].pos) end, 30 * 60000)
    local again = 0
    for _, l in ipairs(dispatched.lines) do if l:find("Dispatched " .. job .. " [DELIVER]", 1, true) then again = again + 1 end end
    sim:expect(again == 1, job .. " was not sent out again (" .. again .. " dispatch lines)")
    local rec = has(recalled, s)
    sim:expect(rec == nil, s .. " was not recalled (" .. tostring((rec or "none"):sub(-90)) .. ")")
    sim:expect(atDock(comps[d].pos) and atDock(comps[s].pos), "both came home")
    local before = #dispatched.lines
    sim:dispatch{ type = "ORDER_DELIVERY", params = { items = { { name = "minecraft:cobblestone", count = 33 } }, destination = DEST } }
    local went = sim:run_until(function() return #dispatched.lines > before end, 5 * 60000)
    sim:expect(went, "a second order to the same destination went out (nothing left active there)")
    sim:run_for(30 * 60000)
    local last = summary.lines[#summary.lines] or ""
    sim:expect(last:find(" 0 section(s) held", 1, true) ~= nil, "the ATC holds no section at the end (" .. last:sub(-110) .. ")")
  end,
}
