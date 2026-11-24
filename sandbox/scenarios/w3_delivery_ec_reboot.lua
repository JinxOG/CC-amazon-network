-- W3, 2026-11-18 (T2 shakeout-24h-b, pin 7af241ff): after the world restarts, node_210, node_214 and node_217 raised
-- "NEEDS HANDS: delivery_ec ... unknown_kind" and left their own delivery ender chests in the world. base.init's boot
-- recovery (base.homeAfterBoot) is the one that runs while the chest is still beside the turtle, and the delivery
-- registered the chest's kind on the line after base.init: unknown to the ledger, it was left for hands.
--
-- Here: one pair; the moment its delivery has put its ender chest down at the destination (it dumps its road debris
-- into it), the delivery reboots.
-- CHECKS: the delivery rebooted with its chest down (evidence); the ledger recovered the chest, not "unknown_kind";
-- its ender chest is back aboard (slot 16) at the end; the order completed; both turtles end on a dock.
-- Before the fix: "Ledger: needs_hands: delivery_ec ... unknown_kind" and the chest stays in the world.
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
    local dumping = sim:capture_log("Dumping road debris into ender chest")
    local recovered = sim:capture_log("Ledger: recovered the delivery_ec")
    local unknown = sim:capture_log("unknown_kind")
    local done = sim:capture_log("Job complete: job_")
    sim:storage_set("minecraft:cobblestone", 100000)
    sim:storage_set("minecraft:chest", 10000)
    sim:run_for(180000)
    sim:dispatch{ type = "ORDER_DELIVERY", params = { items = { { name = "minecraft:cobblestone", count = 33 } },
      destination = { x = 124, y = 67, z = -2824 } } }
    sim:run_until(function() return #dispatched.lines >= 1 end, 120000)
    local job, d, s = (dispatched.lines[1] or ""):match("Dispatched (job_%d+) %[DELIVER%] %-> (node_%d+)%s+support job_%d+ %-> (node_%d+)")
    sim:expect(job ~= nil, "a pair was dispatched")
    if not job then return end
    local comps = {}
    for _, c in ipairs(sim.sched.computers) do comps[c.name] = c end
    local function mine(cap, who)
      for _, l in ipairs(cap.lines) do if l:find(who .. "#", 1, true) or l:find("[" .. who .. "]", 1, true) then return l end end
      return nil
    end
    -- THE FAULT: a reboot with its chest in the world -- at the very step it says it is dumping into it (a watch
    -- fires on the scheduler step; polling from here landed seconds late, after the chest was back aboard)
    -- W3_AFTER_CHEST=1 (Head Engineer, 2026-11-24: "a reboot landing just after 'Placed chest 1' is a real moment"):
    -- the reboot comes the moment its regular chest is in the world below 124,67,-2823 -- the delivery has stepped
    -- off its ender chest (below 124,67,-2824) to put it there. By the world's own state: log lines reach the
    -- scenario in batches, and a trigger on one landed after the chest was back aboard.
    local AFTER_CHEST = os.getenv("W3_AFTER_CHEST") ~= nil
    local function blockName(x, y, z)
      local b = sim:get_block(x, y, z)
      return type(b) == "table" and b.name or b
    end
    local rebootedAt
    if AFTER_CHEST then
      sim:watch(function() return blockName(124, 66, -2823) == "minecraft:chest" end,
        function(x) rebootedAt = x.clock:now(); x:reboot(d) end)
    else
      -- the moment its ender chest is down below the destination (the dump), by the world's state too
      sim:watch(function() local b = blockName(124, 66, -2824); return b ~= nil and tostring(b):find("ender_chest", 1, true) ~= nil end,
        function(x) rebootedAt = x.clock:now(); x:reboot(d) end)
    end
    local down = sim:run_until(function() return rebootedAt ~= nil end, 30 * 60000)
    sim:expect(down, d .. " put its ender chest down at the destination")
    if not down then return end
    sim:expect(true, d .. " rebooted with its delivery chest down: the checks below have something to judge")
    local function serverDone()
      for _, l in ipairs(done.lines) do if l:find("server#", 1, true) and l:find(job .. "$") then return true end end
      return false
    end
    sim:run_until(function() return atDock(comps[d].pos) and atDock(comps[s].pos) end, 2 * 3600000)
    sim:run_for(10 * 60000)
    sim:expect(mine(unknown, d) == nil, "the ledger knew the chest's kind (" .. tostring((mine(unknown, d) or "no unknown_kind"):sub(-90)) .. ")")
    sim:expect(mine(recovered, d) ~= nil, d .. " recovered its delivery chest (" .. tostring((mine(recovered, d) or "it did not"):sub(-90)) .. ")")
    local inv = comps[d].tstate and comps[d].tstate.inv or {}
    local s16 = inv[16]
    sim:expect(s16 ~= nil and tostring(s16.name):find("ender_chest", 1, true) ~= nil,
      "its ender chest is back in slot 16 (" .. tostring(s16 and s16.name) .. ")")
    sim:expect(atDock(comps[d].pos) and atDock(comps[s].pos), "both turtles end on a dock")
    sim:expect(serverDone() or #dispatched.lines >= 2, "the order completed, or was handed back to go out again (" .. job .. ")")
  end,
}
