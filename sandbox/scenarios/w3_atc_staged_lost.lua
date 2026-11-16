-- W3, 2026-11-16: T2 shakeout-side-d (pin 99a7f03) froze every departure. A radio loss lost node_216's SUPPORT_STAGED
-- (it was sent once). Its delivery node_208 kept waiting at the dispatch hole; node_216 stepped on into the hole cell
-- where node_208 still stood, and inside the base a blocked move waits for ever: it never heard its delivery stand it
-- down. At 600 s node_208 gave up and turned for home -- through node_216. Each blocked the other's only way out, both
-- in ERROR, and the ATC held the dispatch corner for them: no departure was let in again.
--
-- Here: one delivery. Every SUPPORT_STAGED its support sends is dropped from the moment it is dispatched until 15 s
-- after it has staged (the radio loss); then a second delivery is ordered.
-- CHECKS: the support staged and its SUPPORT_STAGED was dropped (evidence); the pair went down together all the same;
-- nobody reported STUCK; both deliveries completed; at the end every turtle is on a dock and nobody holds the
-- dispatch hole. On 99a7f03 the pair jam at the hole and the second delivery is never let out.
--
-- W3_LONG=1: the loss outlasts the delivery's 600 s wait -- SUPPORT_STAGED and its PARTNER_LEFT both dropped for
-- 15 minutes after staging. The pair cannot go together: the delivery gives up, the support must not stand in its
-- way home for good. Same checks, except that the first try goes back and is delivered on a later one.
local LONG = os.getenv("W3_LONG") ~= nil
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
    local staged = sim:capture_log("Staged behind hole")
    local together = sim:capture_log("Support staged")
    local stuck = sim:capture_log("STUCK ")
    local neverStaged = sim:capture_log("never staged in")
    local neverWent = sim:capture_log("still in the hole cell after")
    local done = sim:capture_log("Job complete: job_")
    local summary = sim:capture_log("section(s) held")
    sim:storage_set("minecraft:cobblestone", 100000)
    sim:storage_set("minecraft:chest", 10000)
    sim:run_for(180000)
    sim:dispatch{ type = "ORDER_DELIVERY", params = { items = { { name = "minecraft:cobblestone", count = 33 } },
      destination = { x = 124, y = 67, z = -2824 } } }
    sim:run_until(function() return #dispatched.lines >= 1 end, 120000)
    local djob, dname, sname = (dispatched.lines[1] or ""):match("Dispatched (job_%d+) %[DELIVER%] %-> (node_%d+)%s+support job_%d+ %-> (node_%d+)")
    sim:expect(dname ~= nil, "a delivery and its support were dispatched")
    if not dname then return end
    local function by(lines, who)
      local out = {}
      for _, l in ipairs(lines) do if l:find("[" .. who .. "]", 1, true) or l:find(who .. "#", 1, true) then out[#out + 1] = l end end
      return out
    end
    -- THE FAULT: its SUPPORT_STAGED is lost until 15 s after it staged.
    local now = sim.clock:now()
    local rule = sim.sched.radio:add_rule{ drop_rate = 1, type = "SUPPORT_STAGED", from = sname, from_ms = now, until_ms = now + 3600000 }
    local st = sim:run_until(function() return #by(staged.lines, sname) >= 1 end, 20 * 60000)
    local rule2
    if LONG then
      local t = sim.clock:now()
      rule2 = sim.sched.radio:add_rule{ drop_rate = 1, type = "PARTNER_LEFT", from = dname, from_ms = t, until_ms = t + 3600000 }
      sim:run_for(15 * 60000)
    else
      sim:run_for(15000)
    end
    if type(rule) == "number" then sim.sched.radio:remove_rule(rule) end
    if type(rule2) == "number" then sim.sched.radio:remove_rule(rule2) end
    sim:expect(st, sname .. " staged behind the hole and its SUPPORT_STAGED was dropped: the checks below have something to judge")

    local function serverDone(j)
      for _, l in ipairs(done.lines) do if l:find("server#", 1, true) and l:find(j .. "$") then return true end end
      return false
    end
    sim:run_until(function() return serverDone(djob) end, 3600000)
    sim:dispatch{ type = "ORDER_DELIVERY", params = { items = { { name = "minecraft:cobblestone", count = 33 } },
      destination = { x = 130, y = 67, z = -2824 } } }
    -- The new order's job: the first DELIVER dispatched that is not the first job (sent again in W3_LONG).
    local function second()
      for _, l in ipairs(dispatched.lines) do
        local j = l:match("Dispatched (job_%d+) %[DELIVER%]")
        if j and j ~= djob then return j end
      end
    end
    sim:run_until(function() return second() ~= nil end, 20 * 60000)
    local djob2 = second()
    sim:run_until(function() return djob2 and serverDone(djob2) end, 3600000)
    sim:run_for(15 * 60000)

    if not LONG then
      sim:expect(#by(together.lines, dname) >= 1, dname .. " and " .. sname .. " went down together all the same ('Support staged')")
      sim:expect(#stuck.lines == 0, "nobody reported STUCK (" .. tostring((stuck.lines[1] or "none"):sub(1, 150)) .. ")")
    else
      sim:expect(#by(neverStaged.lines, dname) >= 1, dname .. " gave up waiting at the hole ('never staged'): the long loss really outlasted its wait")
      sim:expect(#by(neverWent.lines, sname) >= 1, sname .. " gave up waiting for the hole cell to clear and went home ("
        .. tostring((by(neverWent.lines, sname)[1] or "nothing"):sub(1, 140)) .. ")")
    end
    sim:expect(serverDone(djob), "the first delivery completed (" .. djob .. ")")
    sim:expect(djob2 ~= nil and serverDone(djob2), "a delivery ordered after it was let out and completed (" .. tostring(djob2) .. ")")
    local off = {}
    for _, c in ipairs(sim.sched.computers) do
      if c.kind == "turtle" and not c.carried and (c.role == "delivery" or c.role == "support") and not atDock(c.pos) then
        off[#off + 1] = string.format("%s@%s,%s,%s", c.name, tostring(c.pos and c.pos.x), tostring(c.pos and c.pos.y), tostring(c.pos and c.pos.z))
      end
    end
    sim:expect(#off == 0, "every delivery and support turtle is on a dock at the end (" .. table.concat(off, " ") .. ")")
    local last = summary.lines[#summary.lines] or ""
    sim:expect(not last:find("DH=", 1, true), "nobody holds the dispatch hole at the end (" .. last:sub(-110) .. ")")
  end,
}
