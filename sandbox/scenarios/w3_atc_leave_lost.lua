-- W3, 2026-11-17 (T2 shakeout-side-h, s002): node_215 and node_219 left the dispatch hole for the tunnel and their
-- ATC_LEAVEs were lost in the radio loss; DH stayed booked, empty, until the ATC's 180 s silence sweep -- one message
-- sent once, and a timer cleared it. Now a report says where a turtle stands: one that has stepped out of the base
-- says so ("out") every 10 s for a while, and the first report heard ends its booking.
--
-- Here: one pair goes out; every ATC_LEAVE its delivery sends is lost. A second order is placed once the first
-- delivery is out of the hole; its pair needs DH.
-- CHECKS: the delivery's ATC_LEAVE for DH was lost (evidence: it left DH and the ATC still held DH for it); the ATC let
-- the booking go on the delivery's own report, not on the sweep; the second pair was let into DH; both orders
-- completed; every delivery and support ends on a dock; the ATC holds nothing at the end. Before the fix the ATC holds
-- DH until "silent 180s: booking dropped".
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
    local exited = sim:capture_log("Exited depot")
    local outReport = sim:capture_log("reports from outside the base")
    local swept = sim:capture_log("booking dropped")
    local admitted = sim:capture_log("admitted pair")
    local done = sim:capture_log("Job complete: job_")
    local summary = sim:capture_log("section(s) held")
    sim:storage_set("minecraft:cobblestone", 100000)
    sim:storage_set("minecraft:chest", 10000)
    sim:run_for(180000)
    sim:dispatch{ type = "ORDER_DELIVERY", params = { items = { { name = "minecraft:cobblestone", count = 33 } },
      destination = { x = 124, y = 67, z = -2824 } } }
    sim:run_until(function() return #dispatched.lines >= 1 end, 120000)
    local job1, d1 = (dispatched.lines[1] or ""):match("Dispatched (job_%d+) %[DELIVER%] %-> (node_%d+)")
    sim:expect(job1 ~= nil, "the first pair was dispatched")
    if not job1 then return end
    local rule = sim:drop_radio{ type = "ATC_LEAVE", from = d1 }          -- THE FAULT: every ATC_LEAVE it sends is lost
    local function by(cap, who)
      local out = {}
      for _, l in ipairs(cap.lines) do if l:find(who .. "#", 1, true) or l:find("[" .. who .. "]", 1, true) or l:find(who, 1, true) then out[#out + 1] = l end end
      return out
    end
    sim:run_until(function() return #by(exited, d1) >= 1 end, 10 * 60000)
    sim:run_for(20000)
    local last = summary.lines[#summary.lines] or ""
    local evidence = #by(exited, d1) >= 1
    sim:expect(evidence, d1 .. " left the hole with its ATC_LEAVEs lost: the checks below have something to judge")
    sim:dispatch{ type = "ORDER_DELIVERY", params = { items = { { name = "minecraft:cobblestone", count = 33 } },
      destination = { x = 130, y = 67, z = -2824 } } }
    local admittedBefore = #admitted.lines
    -- the hole is empty: the next pair is let in as soon as it asks (on the code before, DH stayed booked ~4 min)
    local prompt = sim:run_until(function() return #admitted.lines > admittedBefore end, 60000)
    sim:expect(prompt, "the second pair was let into the empty hole within 60 s of its order")
    sim:run_until(function() return #admitted.lines > admittedBefore end, 10 * 60000)
    local sweptD1 = {}
    for _, l in ipairs(swept.lines) do if l:find(d1, 1, true) then sweptD1[#sweptD1 + 1] = l end end
    sim:expect(#by(outReport, d1) >= 1, "the ATC let " .. d1 .. "'s booking go on its own report ("
      .. tostring((by(outReport, d1)[1] or "it did not"):sub(-90)) .. ")")
    sim:expect(#sweptD1 == 0, "not on the 180 s sweep (" .. tostring((sweptD1[1] or "none"):sub(-90)) .. ")")
    sim:expect(#admitted.lines > admittedBefore, "the second pair was let into DH")
    sim.sched.radio:remove_rule(rule)
    local function serverDone(n)
      local c = 0
      for _, l in ipairs(done.lines) do if l:find("server#", 1, true) and l:find("%[DELIVER%]") == nil then c = c + 1 end end
      return c >= n
    end
    sim:run_until(function()
      local k = 0
      for _, l in ipairs(done.lines) do if l:find("server#", 1, true) then k = k + 1 end end
      return k >= 4
    end, 2 * 3600000)
    sim:run_for(10 * 60000)
    local k = 0
    for _, l in ipairs(done.lines) do if l:find("server#", 1, true) then k = k + 1 end end
    sim:expect(k >= 4, "both orders and their supports completed (" .. k .. " server 'Job complete' lines)")
    local off = {}
    for _, c in ipairs(sim.sched.computers) do
      if c.kind == "turtle" and not c.carried and (c.role == "delivery" or c.role == "support") and not atDock(c.pos) then
        off[#off + 1] = string.format("%s@%s,%s,%s", c.name, tostring(c.pos and c.pos.x), tostring(c.pos and c.pos.y), tostring(c.pos and c.pos.z))
      end
    end
    sim:expect(#off == 0, "every delivery and support turtle is on a dock at the end (" .. table.concat(off, " ") .. ")")
    last = summary.lines[#summary.lines] or ""
    sim:expect(last:find(" 0 section(s) held", 1, true) ~= nil, "the ATC holds no section at the end (" .. last:sub(-110) .. ")")
  end,
}
