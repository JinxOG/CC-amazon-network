-- W3, 2026-11-17 (T2 shakeout-side-e jam 2, pin 9c81a76): a server crash at 02:13 split node_218 from its delivery.
-- A following support that hears nothing for 15 s asks the server whether its delivery is online; the server, back
-- from its crash, had not heard the delivery again yet and said "offline" -- "Partner offline. Returning to dock." --
-- and the support, which cannot dig, went home alone, was given no holding slot of its own, retraced 198 steps and
-- ended stacked under another support in one column: each held what the other needed.
-- Design: docs/superpowers/specs/2026-11-17-delivery-pair-and-hole-design.md, rule R4 (a support leaves its delivery
-- only on the delivery's own word, never on the server's online flag).
--
-- Here: one pair; once the support is following its delivery out in the world, the server crashes for 90 s.
-- CHECKS: the server went down while the support was following (evidence); the support never left its delivery on
-- the server's word ("Partner offline"); it never had to find its own way home (no retrace, no "way home is shut");
-- the delivery completed; both are on a dock at the end; the ATC holds nothing.
-- On 9c81a76 the support says "Partner offline" and goes home alone.
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
    local offline = sim:capture_log("Partner offline")
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
    local following = sim:run_until(function() return #by(follow.lines, s) >= 1 end, 20 * 60000)
    sim:run_for(5000)
    -- THE FAULT: the server is down 90 s while the pair is out.
    sim:server_crash(sim.clock:now() - sim.t0, 90000)
    local function serverDone(j)
      for _, l in ipairs(done.lines) do if l:find("server#", 1, true) and l:find(j .. "$") then return true end end
      return false
    end
    sim:run_until(function() return serverDone(job) end, 2 * 3600000)
    sim:run_for(15 * 60000)

    sim:expect(following, s .. " was following " .. d .. " out in the world when the server went down: the checks below have something to judge")
    local off = by(offline.lines, s)
    sim:expect(#off == 0, s .. " never left its delivery on the server's word (" .. tostring((off[1] or "none"):sub(1, 120)) .. ")")
    local alone = by(retrace.lines, s)
    for _, l in ipairs(by(shut.lines, s)) do alone[#alone + 1] = l end
    sim:expect(#alone == 0, s .. " never had to find its own way home (" .. tostring((alone[1] or "none"):sub(1, 140)) .. ")")
    sim:expect(serverDone(job), "the delivery completed (" .. job .. ")")
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
