-- W3, 2026-11-24 (T2 shakeout-payload-e, pin d57e43e): node_221 reached its destination 160,67,-2752, in chunk
-- 10,-172, while its support node_234 held 21 blocks back in chunk z -174 ("Delivery ascending"). The support is the
-- pair's chunk loader and at Advanced Peripherals' default chunkyTurtleRadius = 0 it loads only its own chunk, so
-- the delivery stopped dead out there. The invariant (Head Engineer ruling, 2026-11-24): a delivery never steps into
-- a chunk unless its support is in the chunk it is leaving, and never sends ASCENDING until its support is in its chunk.
--
-- Here: one pair out to 196,67,-2761, several chunk borders from the dispatch exit; from the moment the support starts
-- following, every POSITION_UPDATE to it is dropped -- the worst follow lag there is: it hears nothing of its
-- delivery's steps. The rule is lifted once the delivery is back underground after delivering.
-- CHECKS: the drops happened (evidence); on the way out, while both travel underground, the delivery is never more than one chunk
-- from its support, and never in a chunk its support has not reached the edge of -- measured every scheduler step;
-- the support is in its delivery's chunk, or right behind it, when told to hold for the ascent; the order completed; both end
-- on a dock.
-- Before the gate: the support stands at the dispatch exit and its delivery travels on alone.
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

local function chunk(p) return math.floor(p.x / 16), math.floor(p.z / 16) end

return {
  world = "synthetic",
  seed = 1,
  miners = 1,
  atc = true,
  preset_docks = true,
  steps = function(sim)
    local dispatched = sim:capture_log("Dispatched job_")
    local following = sim:capture_log("1 block behind")
    local hold = sim:capture_log("Delivery ascending")
    local done = sim:capture_log("Job complete: job_")
    sim:storage_set("minecraft:cobblestone", 100000)
    sim:storage_set("minecraft:chest", 10000)
    sim:run_for(180000)
    sim:dispatch{ type = "ORDER_DELIVERY", params = { items = { { name = "minecraft:cobblestone", count = 33 } },
      destination = { x = 196, y = 67, z = -2761 } } }
    sim:run_until(function() return #dispatched.lines >= 1 end, 120000)
    local job, d, s = (dispatched.lines[1] or ""):match("Dispatched (job_%d+) %[DELIVER%] %-> (node_%d+)%s+support job_%d+ %-> (node_%d+)")
    sim:expect(job ~= nil, "a pair was dispatched")
    if not job then return end
    local comps = {}
    for _, c in ipairs(sim.sched.computers) do comps[c.name] = c end
    -- THE FAULT: from the support's first follow, none of its delivery's steps reach it.
    local rule
    sim:watch(function() return #following.lines >= 1 end, function(x)
      rule = x:drop_radio{ type = "POSITION_UPDATE", to = s }
    end)
    -- THE MEASUREMENT: every scheduler step while both travel underground.
    local worst, samples, crossedAhead, atAscent = 0, 0, 0, nil
    local lastD
    sim:watch(function()
      local dp, sp = comps[d].pos, comps[s].pos
      if rule and #hold.lines == 0 and dp and sp and dp.y == 60 and sp.y == 60 then   -- the way out, to the ascent
        local dx, dz = chunk(dp)
        local sx, sz = chunk(sp)
        local dist = math.max(math.abs(dx - sx), math.abs(dz - sz))
        samples = samples + 1
        if dist > worst then worst = dist end
        if lastD and (lastD[1] ~= dx or lastD[2] ~= dz) and (sx ~= lastD[1] or sz ~= lastD[2]) then
          crossedAhead = crossedAhead + 1
        end
        lastD = { dx, dz }
      end
      if not atAscent and #hold.lines >= 1 and dp and sp then
        local dx, dz = chunk(dp)
        local sx, sz = chunk(sp)
        local behind = math.abs(dp.x - sp.x) + math.abs(dp.y - sp.y) + math.abs(dp.z - sp.z) == 1
        atAscent = { same = (dx == sx and dz == sz) or behind,
                     text = string.format("delivery chunk %d,%d, support chunk %d,%d", dx, dz, sx, sz) }
      end
      return false     -- never fires: it only measures
    end, function() end)
    local function serverDone()
      for _, l in ipairs(done.lines) do if l:find("server#", 1, true) and l:find(job .. "$") then return true end end
      return false
    end
    sim:run_until(function() return #hold.lines >= 1 end, 60 * 60000)
    -- lifted once the delivery has delivered and is back down: the way home is the existing follow
    sim:run_until(function() local p = comps[d].pos; return p and p.y == 60 end, 30 * 60000)
    if rule then sim.sched.radio:remove_rule(rule) end
    sim:run_until(function() return atDock(comps[d].pos) and atDock(comps[s].pos) end, 2 * 3600000)
    sim:run_for(5 * 60000)
    sim:expect(rule ~= nil, s .. "'s POSITION_UPDATEs were dropped from its first follow (evidence)")
    sim:expect(samples > 100, "the pair was measured travelling underground (" .. samples .. " samples)")
    sim:expect(worst <= 1, "the delivery was never more than one chunk from its support (worst " .. worst .. ")")
    sim:expect(crossedAhead == 0, "it never stepped into a new chunk with its support outside the one it left (" .. crossedAhead .. " times)")
    sim:expect(atAscent ~= nil and atAscent.same, "its support was in its chunk, or right behind it, when told to hold for the ascent ("
      .. tostring(atAscent and atAscent.text or "never told") .. ")")
    sim:expect(serverDone(), "the order completed (" .. job .. ")")
    sim:expect(atDock(comps[d].pos) and atDock(comps[s].pos), "both end on a dock")
  end,
}
