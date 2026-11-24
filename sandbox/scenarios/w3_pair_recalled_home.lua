-- W3, 2026-11-17 (sim w3_side_atc on 7294978): the warehouse recalled a delivery already on its way home (a
-- CHESTS_PLACED timeout); its job went back, the server recalled its support as "stale", and the support -- out in the
-- world, unable to dig -- went home alone and stayed in the tunnel. R4: the pair keeps together; a delivery recalled out
-- in the world brings its support home, and the server does not pull a following support away from it.
--
-- Here: one pair; the moment the delivery heads for its holding slot on the way home, it is recalled.
-- CHECKS: the delivery was recalled on its way home (evidence); its support never took it for gone, never found its own
-- way home; both on a dock at the end; the ATC holds nothing.
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
    local follow = sim:capture_log("Following node_")
    local holding = sim:capture_log("holding position")
    local offline = sim:capture_log("-- taken for gone. Returning to dock")
    local retrace = sim:capture_log("retracing the")
    local shut = sim:capture_log("way home is shut")
    local done = sim:capture_log("Job complete: job_")
    local summary = sim:capture_log("section(s) held")
    sim:storage_set("minecraft:cobblestone", 100000)
    sim:storage_set("minecraft:chest", 10000)
    sim:run_for(180000)
    sim:dispatch{ type = "ORDER_DELIVERY", params = { items = { { name = "minecraft:cobblestone", count = 33 } },
      destination = { x = 196, y = 67, z = -2761 } } }
    sim:run_until(function() return #dispatched.lines >= 1 end, 120000)
    local job, d, s = (dispatched.lines[1] or ""):match("Dispatched (job_%d+) %[DELIVER%] %-> (node_%d+)%s+support job_%d+ %-> (node_%d+)")
    sim:expect(job ~= nil, "a pair was dispatched")
    if not job then return end
    local function by(lines, who)
      local out = {}
      for _, l in ipairs(lines) do if l:find("[" .. who .. "]", 1, true) or l:find(who .. "#", 1, true) then out[#out + 1] = l end end
      return out
    end
    local toSlot = sim:capture_log("Navigating underground to holding slot")
    local recalledLog = sim:capture_log("RECALL")
    local following = sim:run_until(function() return #by(follow.lines, s) >= 1 end, 20 * 60000)
    sim:run_until(function() return #by(toSlot.lines, d) >= 1 end, 40 * 60000)
    -- THE FAULT: recalled on its way home, as the warehouse's timeout did.
    sim:dispatch{ type = "RECALL_TURTLE", params = { turtleId = d, reason = "w3_pair_recalled_home" } }
    local function serverDone(j)
      for _, l in ipairs(done.lines) do if l:find("server#", 1, true) and l:find(j .. "$") then return true end end
      return false
    end
    sim:run_until(function()
      local n = 0
      for _, c in ipairs(sim.sched.computers) do if (c.name == d or c.name == s) and atDock(c.pos) then n = n + 1 end end
      return n == 2
    end, 2 * 3600000)
    sim:run_for(15 * 60000)

    sim:expect(following and #by(recalledLog.lines, d) >= 1, d .. " was recalled on its way home: the checks below have something to judge")
    local off = by(offline.lines, s)
    sim:expect(#off == 0, s .. " never took its delivery for gone (" .. tostring((off[1] or "none"):sub(1, 120)) .. ")")
    local alone = by(retrace.lines, s)
    for _, l in ipairs(by(shut.lines, s)) do alone[#alone + 1] = l end
    sim:expect(#alone == 0, s .. " never had to find its own way home (" .. tostring((alone[1] or "none"):sub(1, 140)) .. ")")
    local offDock = {}
    for _, c in ipairs(sim.sched.computers) do
      if (c.name == d or c.name == s) and not atDock(c.pos) then
        offDock[#offDock + 1] = string.format("%s@%s,%s,%s", c.name, tostring(c.pos and c.pos.x), tostring(c.pos and c.pos.y), tostring(c.pos and c.pos.z))
      end
    end
    sim:expect(#offDock == 0, "both are on a dock at the end (" .. table.concat(offDock, " ") .. ")")
    local last = summary.lines[#summary.lines] or ""
    sim:expect(last:find(" 0 section(s) held", 1, true) ~= nil, "the ATC holds nothing at the end (" .. last:sub(-110) .. ")")
  end,
}
