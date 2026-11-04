-- W3, the ATC card (2026-11-03): the 150-turtle base under the air-traffic control computer, with one fault.
--   W3_ATC_FAULT = none | atc | server | world | stuck   (default none)
--   W3_ATC_HOURS = simulated hours of traffic before the drain (default 6)
--   W3_ATC_DRAIN_MIN = the most the drain may take (default 90)
--   W3_NO_ATC=1  no ATC computer: the same traffic on code without one (today's master) -- every check must be
--                able to fail, and this is where they do
-- The fleet: 8 miners (each with its loader), 71 delivery, 71 support. At the start a BURST of 20 deliveries at
-- once (card addition C); then two zones mining at a time and a delivery every 10 minutes to four destinations
-- inside the loaded area. After the traffic, no new orders and a drain of up to 90 minutes.
-- CHECKS (bounds stated here, and in docs/superpowers/specs/2026-11-03-base-atc-design.md):
--   * every turtle ends on a dock cell (zero gridlock), and none is ERROR/STUCK unless the fault made it so
--   * no turtle logged a wait of more than 30 s at a section edge ('Still waiting Ns -- ATC: waiting to enter')
--   * nobody waited to enter the dispatch corner (the dispatch hole never holds a queue)
--   * inside the base, nobody was blocked by a turtle for more than 30 s
--   * per fault: atc -- while it is down no turtle enters a new section, and all resume after; server -- turtles
--     on their way home while it is down reach their docks before it returns; world -- the ATC rebuilds from
--     reports and the base clears; stuck -- the stuck turtle's job is back in the queue within 4 minutes
local HOUR = 3600000
local FAULT = os.getenv("W3_ATC_FAULT") or "none"
local HOURS = tonumber(os.getenv("W3_ATC_HOURS") or "6")
local NO_ATC = os.getenv("W3_NO_ATC") ~= nil
local DRAIN_MIN = tonumber(os.getenv("W3_ATC_DRAIN_MIN") or "90")   -- today's code jams, its log floods, and the
                                                                     -- sim runs out of memory near sim hour 1.9

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

-- Inside the building's traffic area (the floor of the base, off the docks): a rough box, for sampling.
local function inBase(p)
  return p and p.y == 67 and p.x >= 143 and p.x <= 228 and p.z >= -2813 and p.z <= -2782 and not atDock(p)
end

local function workers(sim)
  local out = {}
  for _, c in ipairs(sim.sched.computers) do
    if c.kind == "turtle" and not c.carried and (c.role == "delivery" or c.role == "support" or c.role == "miner") then
      out[#out + 1] = c
    end
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
  miners = 8,
  workers = 150,
  atc = not NO_ATC,
  preset_docks = os.getenv("W3_ATC_BOOT_RUSH") == nil,   -- the server knows the docks, as a real base does
  steps = function(sim)
    local edgeWaits = sim:capture_log("ATC: waiting to enter")
    local blocked = sim:capture_log("a turtle is blocking")
    local stuck = sim:capture_log("STUCK ")
    local docked = sim:capture_log("Docked at bay")
    local done = sim:capture_log("Job complete: job_")
    local deliveries = sim:capture_log("[DELIVER] -> node_")
    local settled = sim:capture_log("settled: rebuilt")
    -- The holding line must lie in the loaded base, or turtles sent to its far slots freeze there (23 did, at a
    -- 40-slot line reaching x 308 past the loaded edge at 260, 2026-11-03).
    if not NO_ATC then
      local Wl = assert(loadfile(sim.sched.code_dir .. "/waypoints.lua", "t",
        setmetatable({ fs = { exists = function() return false end } }, { __index = _G })))()
      local far = Wl.holdingSlot(Wl.ATC.HOLD_SLOTS)
      local box = (sim.world:meta().base_loaded or {})[1]
      sim:expect(box and far.x >= box[1] and far.x <= box[3] and far.z >= box[2] and far.z <= box[4],
        string.format("the holding line lies in the loaded base (last slot x %d; loaded x %s..%s)", far.x,
          tostring(box and box[1]), tostring(box and box[3])))
    end
    sim:storage_set("minecraft:cobblestone", 10000000)
    sim:storage_set("minecraft:chest", 100000)
    sim:run_for(5 * 60000)

    local area = sim.world:meta().areas[1]
    local nextZone, nextDest = 0, 0
    local function orderZone()
      local x = area.x1 + 64 * 3 * (nextZone % 40)
      local z = area.z1 + 64 * 3 * math.floor(nextZone / 40)
      nextZone = nextZone + 1
      sim:dispatch{ type = "ORDER_MINE", params = { x1 = x, z1 = z, x2 = x + 64, z2 = z, minerCount = 2 } }
    end
    -- Each order a little different: the server drops a bridge command identical to one it just took, so twenty
    -- identical orders were ONE job (2026-11-03).
    local ordered = 0
    local function orderDelivery()
      nextDest = nextDest % 4 + 1
      ordered = ordered + 1
      sim:dispatch{ type = "ORDER_DELIVERY", params = { items = { { name = "minecraft:cobblestone", count = 32 + ordered } },
        destination = { x = 112 + 6 * nextDest, y = 67, z = -2830 } } }
    end
    local function activeMines()
      local n = 0
      for _, j in pairs(sim.sched.standin.state.jobs or {}) do
        if type(j) == "table" and j.type == "MINE" and (j.status == "PENDING" or j.status == "ASSIGNED" or j.status == "IN_PROGRESS") then n = n + 1 end
      end
      return n
    end

    -- THE BURST (addition C): twenty deliveries at once
    for _ = 1, 20 do orderDelivery() end
    orderZone(); orderZone()

    local faultAt = math.floor(HOURS / 2 * 60) * 60000      -- halfway
    local faultDone, faultInfo = false, {}
    local minute = 0
    local function stepMinute()
      sim:run_for(60000)
      minute = minute + 1
      if minute % 10 == 0 then orderDelivery() end
      -- at most two orders a minute: a loop "until two are active" never ended once the synthetic world ran out of
      -- fresh ground (~1.45 h): the sim clock stopped and the orders filled memory (11.7 GB, 2026-11-03)
      for _ = 1, 2 do if activeMines() < 2 then orderZone() end end
    end

    while minute * 60000 < HOURS * HOUR do
      if not faultDone and minute * 60000 >= faultAt then
        faultDone = true
        if FAULT == "atc" and not NO_ATC then
          -- THE CHECK MUST BE ABLE TO FAIL: crash the ATC while a turtle is moving through the base, and require
          -- that evidence. (The first version crashed it at a quiet moment: nobody wanted in, 0 entries proved
          -- nothing.) Then, every 2 s for the 5 minutes it is down, no turtle may step into a different section.
          local Wp = assert(loadfile(sim.sched.code_dir .. "/waypoints.lua", "t",
            setmetatable({ fs = { exists = function() return false end } }, { __index = _G })))()
          local function sec(p) return p and Wp.atcSection(p.x, p.y, p.z) or nil end
          local moving
          for _ = 1, 900 do                                    -- up to 30 min, every 2 s
            local seen = {}
            for _, c in ipairs(workers(sim)) do seen[c.name] = { x = c.pos.x, y = c.pos.y, z = c.pos.z } end
            sim:run_for(2000)
            for _, c in ipairs(workers(sim)) do
              local b = seen[c.name]
              if sec(c.pos) and b and (b.x ~= c.pos.x or b.y ~= c.pos.y or b.z ~= c.pos.z) then moving = c; break end
            end
            if moving then break end
          end
          sim:expect(moving ~= nil, "a turtle was moving through the base when the ATC went down (evidence: "
            .. tostring(moving and moving.name) .. ")")
          sim:atc_crash(sim.clock:now() - sim.t0, 5 * 60000)
          sim:run_for(3000)            -- a step granted just before the crash may still finish: that one is allowed
          local inside0 = {}
          for _, c in ipairs(workers(sim)) do if sec(c.pos) then inside0[#inside0 + 1] = c.name end end
          faultInfo.in_base_at_atc_crash = #inside0
          local last, entered, whoEntered = {}, 0, {}
          for _, c in ipairs(workers(sim)) do last[c.name] = sec(c.pos) or "" end
          for _ = 1, 143 do                                    -- 4 min 46 s of the 5 min down
            sim:run_for(2000)
            for _, c in ipairs(workers(sim)) do
              local now = sec(c.pos) or ""
              if now ~= "" and now ~= last[c.name] then entered = entered + 1; whoEntered[#whoEntered + 1] = c.name .. "->" .. now end
              last[c.name] = now
            end
          end
          faultInfo.entered_while_down = entered
          sim:expect(entered == 0, string.format("with the ATC down, no turtle stepped into a new section (%d; %d were in the base when it went down)",
            entered, #inside0) .. (entered > 0 and (": " .. table.concat(whoEntered, " ")) or ""))
          minute = minute + 35
        elseif FAULT == "server" then
          -- MEASURED FROM WHERE THE TURTLES ARE, not from their 'Docked' lines: those travel through the server, so
          -- while it is down they wait in the turtles' outboxes (the first version counted 0 for that reason).
          -- Crash it while turtles are coming home -- in the arrivals section or the holding line -- and require it.
          local Wp = assert(loadfile(sim.sched.code_dir .. "/waypoints.lua", "t",
            setmetatable({ fs = { exists = function() return false end } }, { __index = _G })))()
          local function homeward(p)
            if not p then return false end
            local sec = Wp.atcSection(p.x, p.y, p.z)
            if sec == "ARR" or (sec and sec:match("^R%d")) then return true end
            return p.y == 60 and p.x > 228 and p.x <= 228 + 2 * Wp.ATC.HOLD_SLOTS and p.z >= -2783 and p.z <= -2778
          end
          local coming = {}
          for _ = 1, 900 do                                    -- up to 30 min, every 2 s
            for _, c in ipairs(workers(sim)) do if homeward(c.pos) then coming[#coming + 1] = c end end
            if #coming > 0 then break end
            sim:run_for(2000)
          end
          local names = {}
          for _, c in ipairs(coming) do names[#names + 1] = c.name end
          sim:expect(#coming > 0, "turtles were coming home when the server went down (evidence: " .. table.concat(names, " ") .. ")")
          sim:server_crash(sim.clock:now() - sim.t0, 20 * 60000)
          sim:run_for(20 * 60000 - 30000)
          local parked, left = 0, {}
          for _, c in ipairs(coming) do if atDock(c.pos) then parked = parked + 1 else left[#left + 1] = c.name end end
          faultInfo.coming_home_at_server_crash = #coming
          faultInfo.parked_while_server_down = parked
          sim:expect(#coming > 0 and parked == #coming, string.format(
            "with the server down, every one of them parked (%d of %d)%s", parked, #coming,
            #left > 0 and (": not " .. table.concat(left, " ")) or ""))
          local inside = 0
          for _, c in ipairs(workers(sim)) do if inBase(c.pos) then inside = inside + 1 end end
          faultInfo.in_base_at_end_of_outage = inside
          sim:expect(inside == 0, "and none was left on the base floor off a dock when it came back (" .. inside .. ")")
          minute = minute + 50
        elseif FAULT == "world" then
          -- Restart the world while turtles stand in the base, so the rebuild has something to rebuild (the first
          -- version restarted it at a quiet moment: "rebuilt 0 turtle(s)", and passed proving nothing).
          local Wp = assert(loadfile(sim.sched.code_dir .. "/waypoints.lua", "t",
            setmetatable({ fs = { exists = function() return false end } }, { __index = _G })))()
          local inside, insideC = {}, {}
          for _ = 1, 900 do                                    -- up to 30 min, every 2 s
            for _, c in ipairs(workers(sim)) do
              if c.pos and Wp.atcSection(c.pos.x, c.pos.y, c.pos.z) then inside[#inside + 1] = c.name; insideC[#insideC + 1] = c end
            end
            if #inside > 0 then break end
            sim:run_for(2000)
          end
          faultInfo.in_base_at_world_restart = #inside
          sim:expect(#inside > 0, "turtles stood in the base when the world restarted (evidence: " .. table.concat(inside, " ") .. ")")
          local s0 = #settled.lines
          sim:world_restart(sim.clock:now() - sim.t0, { gps_delay = 30000 })
          sim:run_for(10 * 60000)
          if not NO_ATC then
            -- Turtles that come up after the 15 s settle (GPS back 30 s late) are taken in on first contact, where
            -- they stand: the settle count is information, the base clearing is the check.
            local line = settled.lines[#settled.lines] or ""
            faultInfo.rebuilt_at_settle = tonumber(line:match("rebuilt (%d+) turtle")) or -1
            sim:expect(#settled.lines > s0, "the ATC came back and rebuilt (" .. (line ~= "" and line or "no line") .. ")")
          end
          faultInfo.world_restart_inside = insideC
          minute = minute + 40
        elseif FAULT == "stuck" then
          -- The first turtle with a job seen in a taxiway lane is BOXED IN by turtle-shaped blocks on every free side,
          -- for good -- a physical blockade, as a jam of turtles is. (The first version overrode turtle.inspect with
          -- sim:eval, but turtle_base keeps its inspect functions from load time: the victim never saw a turtle, and
          -- the "job back in 8 s" was another job, looked up by a list index that had moved.)
          local victim, jobKey
          for _ = 1, 120 do
            for _, c in ipairs(workers(sim)) do
              local p = c.pos
              if p and p.y == 67 and p.z >= -2803 and p.z <= -2801 and p.x > 143 and p.x < 228 then
                for _, j in pairs(sim.sched.standin.state.jobs or {}) do
                  if type(j) == "table" and j.assignedTo == c.name and j.status == "IN_PROGRESS" then victim, jobKey = c, j.id end
                end
              end
              if victim then break end
            end
            if victim then break end
            sim:run_for(5000)
          end
          sim:expect(victim ~= nil and jobKey ~= nil, "found a turtle with a job in a taxiway lane to make stuck ("
            .. tostring(victim and victim.name) .. ", " .. tostring(jobKey) .. ")")
          if victim and jobKey then
            local p, placed = victim.pos, 0
            local occupied = {}
            for _, c in ipairs(sim.sched.computers) do if c.pos then occupied[c.pos.x .. "," .. c.pos.y .. "," .. c.pos.z] = true end end
            for _, d in ipairs({ { 1, 0, 0 }, { -1, 0, 0 }, { 0, 0, 1 }, { 0, 0, -1 }, { 0, 1, 0 }, { 0, -1, 0 } }) do
              local x, y, z = p.x + d[1], p.y + d[2], p.z + d[3]
              if sim.world:get(x, y, z) == nil and not occupied[x .. "," .. y .. "," .. z] then
                sim.world:set(x, y, z, "computercraft:turtle_advanced"); placed = placed + 1
              end
            end
            faultInfo.stuck_victim, faultInfo.stuck_job, faultInfo.stuck_blocks = victim.name, tostring(jobKey), placed
            local t0 = sim.clock:now()
            local function job()
              for _, j in pairs(sim.sched.standin.state.jobs or {}) do if type(j) == "table" and j.id == jobKey then return j end end
            end
            local back = sim:run_until(function()
              local j = job()
              return j == nil or j.assignedTo ~= victim.name
            end, 10 * 60000)
            faultInfo.stuck_job_back_after_s = back and math.floor((sim.clock:now() - t0) / 1000) or -1
            -- it must have taken the stuck rule's time, not happened for some other reason at once
            sim:expect(back and sim.clock:now() - t0 <= 4 * 60000 and sim.clock:now() - t0 >= 150000,
              string.format("the boxed-in turtle's job %s went back to the queue in 2.5..4 minutes (%s s)", tostring(jobKey),
                tostring(faultInfo.stuck_job_back_after_s)))
            local said = false
            for _, l in ipairs(stuck.lines) do if l:find(victim.name, 1, true) then said = true end end
            sim:expect(said, victim.name .. " reported STUCK")
            local reg = ((sim.sched.standin.state or {}).turtles or {})[victim.name]
            faultInfo.stuck_status_at_server = reg and tostring(reg.status) or "?"
            sim:expect(reg ~= nil and reg.status ~= "IDLE", "and the server no longer counts it IDLE (" .. faultInfo.stuck_status_at_server .. ")")
            faultInfo.victim = victim
          end
        end
      else
        stepMinute()
      end
    end

    -- the drain: no new orders; everybody home
    -- With a turtle boxed in for good in a lane, the turtles whose way home crosses that lane cannot get there
    -- until somebody removes it. Waiting in the holding line (or a dock) is the design's safe place; anywhere
    -- else is not.
    local function inHoldingLine(p)
      return p and p.x > 228 and p.x <= 256 and p.z >= -2781 and p.z <= -2779 and (p.y == 60 or p.y >= 100)
    end
    local heldBack = {}
    local function offDock()
      local off = {}
      heldBack = {}
      for _, c in ipairs(workers(sim)) do
        if not atDock(c.pos) and c ~= faultInfo.victim then
          if FAULT == "stuck" and inHoldingLine(c.pos) then heldBack[#heldBack + 1] = c.name else off[#off + 1] = c end
        end
      end
      return off
    end
    sim:run_until(function() return #offDock() == 0 and activeMines() == 0 end, DRAIN_MIN * 60000)
    local off = offDock()
    local where = {}
    for i = 1, math.min(#off, 12) do
      local p = off[i].pos
      where[#where + 1] = string.format("%s@%s,%s,%s", off[i].name, tostring(p and p.x), tostring(p and p.y), tostring(p and p.z))
    end
    sim.results.fault = FAULT
    sim.results.atc = not NO_ATC
    sim.results.jobs_completed = #done.lines
    sim.results.off_dock = #off
    sim.results.waiting_in_holding_line_behind_stuck = #heldBack
    sim.results.off_dock_where = table.concat(where, " ")
    for k, v in pairs(faultInfo) do if type(v) ~= "table" then sim.results[k] = v end end
    sim:expect(#off == 0, "every turtle ended on a dock cell (" .. #off .. " not: " .. table.concat(where, " ") .. ")")
    if faultInfo.world_restart_inside then
      local home = 0
      for _, c in ipairs(faultInfo.world_restart_inside) do if atDock(c.pos) then home = home + 1 end end
      sim:expect(home == #faultInfo.world_restart_inside, string.format(
        "every turtle standing in the base at the world restart got home (%d of %d)", home, #faultInfo.world_restart_inside))
    end
    -- A wait the ATC did not answer is the base pausing while it is down -- the point of "safe when down" -- not a
    -- wait at an edge it refused; the 30 s bound is for the second kind.
    local answered = {}
    for _, l in ipairs(edgeWaits.lines) do if not l:find("no answer from the ATC", 1, true) then answered[#answered + 1] = l end end
    local edge = maxSeconds(answered, "waiting to enter")
    sim.results.max_wait_unanswered_s = maxSeconds(edgeWaits.lines, "no answer from the ATC")
    sim.results.max_edge_wait_s = edge
    sim:expect(edge <= 30, "no turtle waited more than 30 s at a section edge (worst " .. edge .. " s)")
    local dh = 0
    for _, l in ipairs(edgeWaits.lines) do if l:find("waiting to enter DH", 1, true) then dh = dh + 1 end end
    sim:expect(dh == 0, "nobody queued to enter the dispatch corner (" .. dh .. ")")
    -- The same two questions asked of the turtles themselves, so they can fail on code with no ATC (whose own wait
    -- lines a no-ATC run never prints): blocked by a turtle for over 30 s in the base, and at the dispatch hole.
    local inBaseBlocked, dhBlocked = 0, 0
    for _, l in ipairs(blocked.lines) do
      local x, y, z = l:match("blocking %a+ at (%-?%d+),(%-?%d+),(%-?%d+)")
      local s = tonumber(l:match("Still waiting (%d+)s"))
      x, y, z = tonumber(x), tonumber(y), tonumber(z)
      if x and s and s > 30 then
        if inBase({ x = x, y = y, z = z }) then inBaseBlocked = inBaseBlocked + 1 end
        if (x == 143 and z <= -2803 and z >= -2813 and y >= 60 and y <= 67) or (y == 67 and z == -2803 and x >= 144 and x <= 156) then
          dhBlocked = dhBlocked + 1
        end
      end
    end
    sim.results.dispatch_hole_blocked_over_30s = dhBlocked
    sim:expect(dhBlocked == 0, "nobody stood blocked over 30 s at the dispatch hole or in its lane (" .. dhBlocked .. " lines)")
    sim.results.in_base_blocked_over_30s = inBaseBlocked
    sim:expect(inBaseBlocked == 0, "inside the base nobody was blocked by a turtle for more than 30 s (" .. inBaseBlocked .. " lines)")
    if FAULT ~= "stuck" then
      sim:expect(#stuck.lines == 0, "nobody reported STUCK (" .. #stuck.lines .. ")")
    end
    sim.results.edge_wait_lines = #edgeWaits.lines
    -- THE RUN MUST HAVE DONE WORK. 144 of 150 turtles once sat held by the server for the whole run, and every
    -- check above passed because nothing moved (2026-11-03).
    sim.results.deliveries_dispatched = #deliveries.lines
    sim:expect(#deliveries.lines >= 10, "deliveries actually went out (" .. #deliveries.lines .. " dispatched)")
  end,
}
