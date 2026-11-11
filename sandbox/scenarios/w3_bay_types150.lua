-- W3, shakeout Task 2 (2026-11-10): PER-BAY DOCK TYPES on the 150-turtle base under the ATC. Layer 1 of the card
-- "the server picks docks by type, and moves misplaced live miners once".
--   W3_BT_HOURS     = simulated hours of traffic before the drain (default 4)
--   W3_BT_DRAIN_MIN = the most the drain may take (default 90)
-- The layout agreed with the user (spec 2026-11-09-shakeout-stress-test-design.md section 4.1): worker bay 1 holds
-- delivery turtles only, support bay 1 support turtles only, the other eight bays (worker 2-5, support 2-5) miners.
-- The fleet: 150 turtles -- 120 miners (each with its loader), 14 delivery, 16 support -- standing where the server's
-- dock_assignments.dat says they are, as a real base does. TWO OF THE MINERS (node_11, node_12) stand on DELIVERY
-- docks in worker bay 1, as the live base's miners do today; the server must move each to a MINER dock exactly once.
-- The other 118 are spread over the miner bays, worker side first, so 54 of them live NORTH of the taxiway, where
-- only support turtles ever docked before, and the two moved miners land there too (the free MINER docks are the
-- last ones of support bay 5).
-- Mining is held to eight miners -- the two moved, four from the north side, two from the south -- by operator
-- holds on the rest, so north-side miners are certain to fly (the dispatcher picks by fuel, and every miner is full).
-- CHECKS (each must be able to fail; on today's master all of 1, 2 and 4 do -- master sends every miner to a
-- DELIVERY dock, so the 54 north-side miners find none free and stay dockless, and nothing is ever moved):
--   1. every turtle ends on a dock cell OF ITS OWN TYPE, and the server's record of its dock is that cell
--   2. each of the two misplaced miners logged 'Dock moved: ... (DELIVERY) to ... (MINER) -- per-bay types' exactly
--      once, and ends on the MINER dock it was moved to
--   3. deliveries, their support jobs and mining all completed (with counts as evidence)
--   4. at least one MINE job was completed by a miner docked north of the taxiway, and one by a moved miner
--   5. no turtle waited more than 30 s at a section edge for an answered ATC request (the ATC bound,
--      docs/superpowers/specs/2026-11-03-base-atc-design.md), and nobody reported STUCK
-- Not run yet (2026-11-10): the machine's memory was in use. Run with SANDBOX_NO_TRACE=1.
local Synth = require("world.synth")

local HOUR = 3600000
local HOURS = tonumber(os.getenv("W3_BT_HOURS") or "4")
local DRAIN_MIN = tonumber(os.getenv("W3_BT_DRAIN_MIN") or "90")
local WHITE_Z, RED_Z = -2803, -2801
local MOVED = { "node_11", "node_12" }

-- The agreed type of the dock cell at p, or nil when p is not a dock cell. By position, not from the code's
-- waypoints.lua, so the check means the same thing on code from before per-bay types.
local function cellType(p)
  if not p or p.y ~= 67 then return nil end
  local south = (p.z == -2806 or p.z == -2810)
  local north = (p.z == -2797 or p.z == -2793)
  if not (south or north) then return nil end
  for b = 0, 4 do
    local dx = p.x - (157 + 14 * b)
    if dx ~= 0 and dx >= -4 and dx <= 4 then
      if b > 0 then return "MINER" end
      return south and "DELIVERY" or "SUPPORT"
    end
  end
  return nil
end
local ROLE_TYPE = { miner = "MINER", delivery = "DELIVERY", support = "SUPPORT" }

local function workers(sim)
  local out = {}
  for _, c in ipairs(sim.sched.computers) do
    if c.kind == "turtle" and not c.carried and ROLE_TYPE[c.role] then out[#out + 1] = c end
  end
  return out
end

local function maxSeconds(lines, pattern)
  local m = 0
  for _, l in ipairs(lines) do
    local s = tonumber(l:match("Still waiting (%d+)s"))
    if s and l:find(pattern, 1, true) and s > m then m = s end
  end
  return m
end

return {
  world = "synthetic",
  seed = 1,
  atc = true,
  layout = function(waypoints)
    return Synth.layout(waypoints, { miners = 120, workers = 150, delivery = 14, support = 16, atc = true,
      preset_docks = true, per_bay = true, miners_on_delivery = #MOVED })
  end,
  steps = function(sim)
    local edgeWaits = sim:capture_log("ATC: waiting to enter")
    local stuck = sim:capture_log("STUCK ")
    local moved = sim:capture_log("Dock moved: ")
    local deliveries = sim:capture_log("[DELIVER] -> node_")
    -- COMPLETIONS FROM THE SERVER'S OWN LINES (final review, 2026-11-11): /state lists only active jobs, so the old sweep of
    -- its COMPLETE jobs counted 0 of the 64 the log shows done (run 20261111-045214). "Dispatched job_N [TYPE] -> node_X
    -- support job_M -> node_Y" names each job's type and turtle; "INFO Job complete: job_N" (the server's, not the
    -- warehouse's "[WH] Job complete") says it is done.
    local dispatched = sim:capture_log("Dispatched job_")
    local doneLines = sim:capture_log("Job complete: job_")
    -- ONE COMMAND PER SIMULATED MILLISECOND: the server drops a bridge command whose "ts:type" it has seen, so 112 holds
    -- posted in one millisecond were ONE hold (111 "duplicate ignored" in the same run) and 14 miners flew, not 8.
    local function post(cmd) sim:dispatch(cmd); sim:run_for(2) end
    local function reg(name) return (((sim.sched.standin.state or {}).turtles) or {})[name] end
    sim:storage_set("minecraft:cobblestone", 10000000)
    sim:storage_set("minecraft:chest", 100000)
    sim:run_for(10 * 60000)          -- boot, register, the two moves, and the moved miners driving to their new docks

    -- Hold every miner but eight: the two moved, four docked north of the taxiway, two south.
    local free, north, south = {}, 0, 0
    for _, n in ipairs(MOVED) do free[n] = true end
    for _, c in ipairs(workers(sim)) do
      if c.role == "miner" and not free[c.name] and c.pos then
        if c.pos.z > RED_Z and north < 4 then free[c.name] = true; north = north + 1
        elseif c.pos.z < WHITE_Z and south < 2 then free[c.name] = true; south = south + 1 end
      end
    end
    sim:expect(north == 4 and south == 2, string.format("found the free miners (%d north, %d south)", north, south))
    for _, c in ipairs(workers(sim)) do
      if c.role == "miner" and not free[c.name] then
        post{ type = "HOLD_TURTLE", params = { turtleId = c.name, reason = "w3_bay_types150: not one of the eight" } }
      end
    end
    sim:run_for(60000)

    local area = sim.world:meta().areas[1]
    local nextZone, nextDest, ordered = 0, 0, 0
    local function orderZone()
      local x = area.x1 + 64 * 3 * (nextZone % 40)
      local z = area.z1 + 64 * 3 * math.floor(nextZone / 40)
      nextZone = nextZone + 1
      post{ type = "ORDER_MINE", params = { x1 = x, z1 = z, x2 = x + 64, z2 = z, minerCount = 2 } }
    end
    -- each order a little different: the server drops a bridge command identical to one it just took
    local function orderDelivery()
      nextDest = nextDest % 4 + 1
      ordered = ordered + 1
      post{ type = "ORDER_DELIVERY", params = { items = { { name = "minecraft:cobblestone", count = 32 + ordered } },
        destination = { x = 112 + 12 * nextDest, y = 67, z = -2820 - 4 * nextDest } } }
    end
    -- completed jobs, by id, as the server's /state shows them (a finished job may later be pruned from it)
    local completed = {}
    local function sweepJobs()
      for _, j in pairs(sim.sched.standin.state.jobs or {}) do
        if type(j) == "table" and j.status == "COMPLETE" and j.id and not completed[j.id] then
          local t = j.assignedTo and reg(j.assignedTo)
          completed[j.id] = { type = j.type, by = j.assignedTo, dockZ = t and t.dockZ }
        end
      end
    end
    local function activeMines()
      local n = 0
      for _, j in pairs(sim.sched.standin.state.jobs or {}) do
        if type(j) == "table" and j.type == "MINE" and (j.status == "PENDING" or j.status == "ASSIGNED" or j.status == "IN_PROGRESS") then n = n + 1 end
      end
      return n
    end

    for _ = 1, 10 do orderDelivery() end
    orderZone(); orderZone()
    local minute = 0
    while minute * 60000 < HOURS * HOUR do
      sim:run_for(60000)
      minute = minute + 1
      sweepJobs()
      if minute % 10 == 0 then orderDelivery() end
      -- at most two orders a minute, up to four zones at once (eight miners, two each)
      for _ = 1, 2 do if activeMines() < 4 then orderZone() end end
    end

    -- the drain: no new orders; everybody home
    local function wrong()
      local out = {}
      for _, c in ipairs(workers(sim)) do
        local t = reg(c.name)
        local cell = cellType(c.pos)
        local ok = cell == ROLE_TYPE[c.role] and t ~= nil and t.dockX == c.pos.x and t.dockZ == c.pos.z
        if not ok then out[#out + 1] = c end
      end
      return out
    end
    sim:run_until(function() return #wrong() == 0 and activeMines() == 0 end, DRAIN_MIN * 60000)
    sweepJobs()

    -- 1. every turtle on a dock of its own type, and the server agrees which
    local bad, where = wrong(), {}
    for i = 1, math.min(#bad, 12) do
      local c, t = bad[i], reg(bad[i].name)
      where[#where + 1] = string.format("%s(%s)@%s,%s,%s cell=%s serverDock=%s,%s", c.name, c.role,
        tostring(c.pos and c.pos.x), tostring(c.pos and c.pos.y), tostring(c.pos and c.pos.z), tostring(cellType(c.pos)),
        tostring(t and t.dockX), tostring(t and t.dockZ))
    end
    sim.results.wrong_dock = #bad
    sim.results.wrong_dock_where = table.concat(where, " ")
    sim:expect(#bad == 0, string.format("every one of %d turtles ended on a dock of its own type, the one the server "
      .. "has for it (%d not: %s)", #workers(sim), #bad, table.concat(where, " ")))

    -- 2. the two misplaced miners: moved exactly once each, and standing on the dock they were moved to
    for _, name in ipairs(MOVED) do
      local n, line = 0, nil
      for _, l in ipairs(moved.lines) do
        if l:find("Dock moved: " .. name .. " ", 1, true) then n = n + 1; line = l end
      end
      sim:expect(n == 1 and line:find("(DELIVERY) to bay", 1, true) ~= nil and line:find("(MINER) -- per-bay types", 1, true) ~= nil,
        string.format("%s was moved from its DELIVERY dock to a MINER dock exactly once (%d lines%s)", name, n,
          line and (": " .. line) or ""))
      local c
      for _, w in ipairs(workers(sim)) do if w.name == name then c = w end end
      sim:expect(c ~= nil and cellType(c.pos) == "MINER", string.format("%s stands on a MINER dock (%s)", name,
        c and c.pos and (c.pos.x .. "," .. c.pos.y .. "," .. c.pos.z) or "?"))
    end
    sim.results.dock_moved_lines = #moved.lines
    sim:expect(#moved.lines == #MOVED, "no other turtle was moved (" .. #moved.lines .. " 'Dock moved' lines)")

    -- 3. the work was done
    local byType, northMine, movedMine = {}, 0, 0
    local isMoved = {}
    for _, n in ipairs(MOVED) do isMoved[n] = true end
    local jobOf = {}
    for _, l in ipairs(dispatched.lines) do
      local id, ty, by = l:match("Dispatched (job_%d+) %[(%u[%u_]*)%] %-> (node_%d+)")
      if id then jobOf[id] = { type = ty, by = by } end
      local sid, sby = l:match("support (job_%d+) %-> (node_%d+)")
      if sid then jobOf[sid] = { type = "SUPPORT_FOLLOW", by = sby } end
    end
    for _, l in ipairs(doneLines.lines) do
      local id = l:match("INFO%s+Job complete: (job_%d+)")
      if id and jobOf[id] and not completed[id] then
        local t = reg(jobOf[id].by)
        completed[id] = { type = jobOf[id].type, by = jobOf[id].by, dockZ = t and t.dockZ }
      end
    end
    sim.results.done_lines = #doneLines.lines
    for _, j in pairs(completed) do
      byType[j.type or "?"] = (byType[j.type or "?"] or 0) + 1
      if j.type == "MINE" then
        if j.dockZ and j.dockZ > RED_Z then northMine = northMine + 1 end
        if isMoved[j.by] then movedMine = movedMine + 1 end
      end
    end
    sim.results.completed_deliver = byType.DELIVER or 0
    sim.results.completed_support = byType.SUPPORT_FOLLOW or 0
    sim.results.completed_mine = byType.MINE or 0
    sim.results.deliveries_dispatched = #deliveries.lines
    sim:expect((byType.DELIVER or 0) >= 10, "deliveries completed (" .. (byType.DELIVER or 0) .. ", "
      .. #deliveries.lines .. " dispatched)")
    sim:expect((byType.SUPPORT_FOLLOW or 0) >= 10, "their support jobs completed (" .. (byType.SUPPORT_FOLLOW or 0) .. ")")
    sim:expect((byType.MINE or 0) >= 4, "mine jobs completed (" .. (byType.MINE or 0) .. ")")
    -- 4. north-side and moved miners really flew
    sim.results.mine_by_north_miner = northMine
    sim.results.mine_by_moved_miner = movedMine
    sim:expect(northMine >= 1, "a miner docked north of the taxiway completed a mine job (" .. northMine .. ")")
    sim:expect(movedMine >= 1, "a moved miner completed a mine job from its new dock (" .. movedMine .. ")")

    -- 5. the ATC bound, and nobody stuck
    local answered = {}
    for _, l in ipairs(edgeWaits.lines) do if not l:find("no answer from the ATC", 1, true) then answered[#answered + 1] = l end end
    local edge = maxSeconds(answered, "waiting to enter")
    sim.results.max_edge_wait_s = edge
    sim.results.edge_wait_lines = #edgeWaits.lines
    sim:expect(edge <= 30, "no turtle waited more than 30 s at a section edge (worst " .. edge .. " s)")
    sim:expect(#stuck.lines == 0, "nobody reported STUCK (" .. #stuck.lines .. ")")
  end,
}
