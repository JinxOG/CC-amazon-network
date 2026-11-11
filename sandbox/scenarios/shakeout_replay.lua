-- Shakeout replay (plan Task 5; spec section 5, "what replayed means"): runs a T2 shakeout's schedule.json in the simulator,
-- which is deterministic, so a finding can be tried again exactly. The schedule is written by sandbox/t2/shakeout/schedule.py
-- (make_schedule / one_of_each) under the simulator's fault names; this file calls ONLY simulator verbs (the Sim methods of
-- faults/faults.lua and control/control.lua) and refuses a schedule naming a fault it has no verb for, by name, before
-- anything runs.
--
--   SHAKEOUT_SCHEDULE   path of the schedule.json (required)
--   SHAKEOUT_MINERS / SHAKEOUT_DELIVERY / SHAKEOUT_SUPPORT   the fleet (default 128 / 16 / 16: the shakeout's 160, per-bay docks,
--                       standing where dock_assignments.dat says, with the ATC). A small fleet replays the same schedule: each
--                       selector is taken modulo the turtles of its role, so it names the same dock's turtle where there is one
--   SHAKEOUT_TAIL_MIN   simulated minutes run after the last fault (default 60)
-- Run with SANDBOX_NO_TRACE=1 (the G: drive is nearly full).
--
-- Times: the schedule's t_ms and durations are REAL ms on T2 and are replayed here as simulated ms from the scenario's start.
-- Selectors ({role, index, prefer}) pick a turtle by its home dock (x, then z), as the T2 runner does by its dock cell;
-- prefer = "working" takes one away from its dock when there is one. A role this fleet does not have falls back to every
-- fleet turtle.
--
-- How each fault is replayed (simulator verb, at the entry's t_ms; "at the end" = at t_ms + its window):
--   server_crash sim:server_crash(t, down_ms)          atc_crash    sim:atc_crash(t, down_ms)
--   world_restart sim:world_restart(t, {gps_delay})    restart_burst5  sim:world_restart x count, each just after the last boot
--   warehouse_crash sim:shutdown(warehouse), sim:start(warehouse) at the end
--   radio_loss / radio_latency / rs_stall / rs_offline / tps_drop / bridge_down / bridge_slow: the verb of that name
--   gps_down     sim:gps_down(t, dur, {hosts}) (the hosts chosen as on T2: by id, `count` of them from `pick`)
--   chunk_unload sim:chunk_unload(t, area round the turtle); at the end the loading model's own undo, loading:clear_forced()
--                (the simulator's chunk_unload has no duration; w1_lane_freeze_mechanism.lua undoes it the same way)
--   disk_full    sim:disk_full(t, server, leave_bytes); at the end sim:disk_full again with the room it had before
--   turtle_reboot sim:turtle_reboot(t, node, {at_action})    remove_item  sim:remove_item(t, node, Lua slot)
--   put_back_turned sim:teleport(node, where it stands, facing + turn)
--   low_fuel     sim:set_fuel(node, fuel)              full_inventory  sim:set_slot(node, every empty slot, item, 64)
local JSON = require("core.json")
local Synth = require("world.synth")
local Computer = require("core.computer")

local R = {}

local function die(msg) error("shakeout_replay: " .. msg, 0) end

local ROLE = { MINER = "miner", DELIVERY = "delivery", SUPPORT = "support" }

local function fleet_turtles(sim, role)
  local out = {}
  for _, c in ipairs(sim.sched.computers) do
    if c.kind == "turtle" and not c.carried and (role and c.role == role or (not role and (c.role == "miner" or c.role == "delivery" or c.role == "support"))) then
      out[#out + 1] = c
    end
  end
  table.sort(out, function(a, b)
    local ha, hb = a.home_pos or a.pos or {}, b.home_pos or b.pos or {}
    if (ha.x or 0) ~= (hb.x or 0) then return (ha.x or 0) < (hb.x or 0) end
    if (ha.z or 0) ~= (hb.z or 0) then return (ha.z or 0) < (hb.z or 0) end
    return a.id < b.id
  end)
  return out
end

local function off_dock(c)
  local h, p = c.home_pos, c.pos
  return h and p and (h.x ~= p.x or h.y ~= p.y or h.z ~= p.z)
end

local function pick(sim, sel)
  local pool = fleet_turtles(sim, ROLE[sel.role])
  if #pool == 0 then pool = fleet_turtles(sim, nil) end
  if #pool == 0 then die("no fleet turtle to aim a fault at") end
  if sel.prefer == "working" then
    local working = {}
    for _, c in ipairs(pool) do if off_dock(c) then working[#working + 1] = c end end
    if #working > 0 then pool = working end
  end
  return pool[((sel.index or 0) % #pool) + 1]
end

local function by_role(sim, role)
  for _, c in ipairs(sim.sched.computers) do if c.role == role then return c end end
  die("this run has no " .. role .. " computer")
end

local function gps_hosts(sim, count, start)
  local hosts = {}
  for _, c in ipairs(sim.sched.computers) do if c.kind == "gps_host" then hosts[#hosts + 1] = c.id end end
  table.sort(hosts)
  if count == "all" or #hosts == 0 then return nil end
  local n = math.min(#hosts, tonumber(count) or 1)
  local out = {}
  for j = 0, n - 1 do out[#out + 1] = hosts[((start or 0) + j) % #hosts + 1] end
  table.sort(out)
  return out
end

-- handler(sim, entry, t, at_end): calls the simulator verbs; at_end(t_end, fn) runs fn once the replay reaches t_end.
R.HANDLERS = {
  server_crash = function(sim, e, t) sim:server_crash(t, e.args.down_ms) end,
  atc_crash = function(sim, e, t) sim:atc_crash(t, e.args.down_ms) end,
  warehouse_crash = function(sim, e, t, at_end)
    local w = by_role(sim, "warehouse")
    sim:shutdown(w.name)
    at_end(t + e.args.down_ms, function() sim:start(w.name) end)
  end,
  world_restart = function(sim, e, t) sim:world_restart(t, { gps_delay = e.args.gps_delay_ms or 0 }) end,
  restart_burst5 = function(sim, e, t)
    local gap = Computer.REBOOT_MS + 2000          -- each restart comes just after the computers are back from the last
    for i = 0, (e.args.count or 5) - 1 do sim:world_restart(t + i * gap, {}) end
  end,
  radio_loss = function(sim, e, t) sim:radio_loss(t, e.args.dur_ms, e.args.rate) end,
  radio_latency = function(sim, e, t) sim:radio_latency(t, e.args.dur_ms, e.args.ms) end,
  gps_down = function(sim, e, t) sim:gps_down(t, e.args.dur_ms, { hosts = gps_hosts(sim, e.args.count, e.args.pick) }) end,
  chunk_unload = function(sim, e, t, at_end)
    local c = pick(sim, e.args.target)
    local r = e.args.radius_chunks or 1
    local cx, cz = math.floor((c.pos.x or 0) / 16), math.floor((c.pos.z or 0) / 16)
    sim:chunk_unload(t, { (cx - r) * 16, (cz - r) * 16, (cx + r + 1) * 16 - 1, (cz + r + 1) * 16 - 1 })
    at_end(t + e.args.dur_ms, function() sim.sched.loading:clear_forced() end)
  end,
  rs_stall = function(sim, e, t) sim:rs_stall(t, e.args.dur_ms, e.args.seconds) end,
  rs_offline = function(sim, e, t) sim:rs_offline(t, e.args.dur_ms) end,
  tps_drop = function(sim, e, t) sim:tps_drop(t, e.args.dur_ms, e.args.tps) end,
  bridge_down = function(sim, e, t) sim:bridge_down(t, e.args.dur_ms) end,
  bridge_slow = function(sim, e, t) sim:bridge_slow(t, e.args.dur_ms, e.args.ms) end,
  disk_full = function(sim, e, t, at_end)
    local s = by_role(sim, "server")
    local quota = (s.disk_obj and s.disk_obj.quota) or 1000000
    sim:disk_full(t, s.name, e.args.leave_bytes or 0)
    at_end(t + e.args.dur_ms, function()
      local used = s.disk_obj and s.disk_obj:used() or 0
      sim:disk_full(t + e.args.dur_ms, s.name, math.max(0, quota - used))     -- quota = used + this = what it was
    end)
  end,
  turtle_reboot = function(sim, e, t)
    sim:turtle_reboot(t, pick(sim, e.args.target).name, { at_action = e.args.at_action })
  end,
  remove_item = function(sim, e, t) sim:remove_item(t, pick(sim, e.args.target).name, e.args.slot) end,
  put_back_turned = function(sim, e)
    local c = pick(sim, e.args.target)
    local p = c.pos
    sim:teleport(c.name, p.x, p.y, p.z, ((p.facing or 0) + (e.args.turn or 1)) % 4)
  end,
  low_fuel = function(sim, e) sim:set_fuel(pick(sim, e.args.target).name, e.args.fuel) end,
  full_inventory = function(sim, e)
    local c = pick(sim, e.args.target)
    for slot = 1, 16 do
      if not (c.tstate and c.tstate.inv[slot]) then sim:set_slot(c.name, slot, e.args.item or "minecraft:cobblestone", 64) end
    end
  end,
}

-- The schedule's entries, sorted by t_ms; refuses (by name) any fault without a handler, before anything is replayed.
function R.load(path)
  local f = io.open(path or "", "rb")
  if not f then die("cannot open the schedule " .. tostring(path) .. " (set SHAKEOUT_SCHEDULE)") end
  local text = f:read("*a")
  f:close()
  local ok, doc = pcall(JSON.decode, text)
  if not ok or type(doc) ~= "table" then die("the schedule " .. path .. " is not JSON") end
  local entries = doc.entries or doc
  for i, e in ipairs(entries) do
    if type(e) ~= "table" or not R.HANDLERS[e.fault] then
      die(string.format("unknown fault %q (entry %s): the simulator has no verb for it", tostring(type(e) == "table" and e.fault or e),
        tostring(type(e) == "table" and e.id or i)))
    end
    e._order = i
  end
  table.sort(entries, function(a, b) if a.t_ms ~= b.t_ms then return a.t_ms < b.t_ms end return a._order < b._order end)
  return entries
end

-- Replays the entries; returns the fault names handled, in order. opts.tail_ms: how long to run after the last one.
function R.run(sim, entries, opts)
  opts = opts or {}
  local ends, handled, last = {}, {}, 0
  local function flush(upto)
    table.sort(ends, function(a, b) return a.t < b.t end)
    while ends[1] and ends[1].t <= upto do
      local x = table.remove(ends, 1)
      sim:run_until_time(x.t)
      x.fn()
    end
  end
  for _, e in ipairs(entries) do
    flush(e.t_ms)
    sim:run_until_time(e.t_ms)
    R.HANDLERS[e.fault](sim, e, e.t_ms, function(t, fn) ends[#ends + 1] = { t = t, fn = fn } end)
    handled[#handled + 1] = e.fault
    last = math.max(last, e.t_ms + (e.args.dur_ms or e.args.down_ms or 0))
  end
  flush(math.huge)
  sim:run_until_time(last + (opts.tail_ms or 0))
  return handled
end

return {
  world = "synthetic",
  seed = 1,
  atc = true,
  layout = function(waypoints)
    local m = tonumber(os.getenv("SHAKEOUT_MINERS") or "128")
    local d = tonumber(os.getenv("SHAKEOUT_DELIVERY") or "16")
    local s = tonumber(os.getenv("SHAKEOUT_SUPPORT") or "16")
    return Synth.layout(waypoints, { miners = m, workers = m + d + s, delivery = d, support = s, atc = true,
      preset_docks = true, per_bay = true })
  end,
  steps = function(sim)
    local entries = R.load(os.getenv("SHAKEOUT_SCHEDULE"))
    local stuck = sim:capture_log("STUCK ")
    local needs = sim:capture_log("NEEDS HANDS")
    local handled = R.run(sim, entries, { tail_ms = tonumber(os.getenv("SHAKEOUT_TAIL_MIN") or "60") * 60000 })
    sim.results.replayed = #handled
    sim.results.stuck_lines = #stuck.lines
    sim.results.needs_hands_lines = #needs.lines
    sim:expect(#handled == #entries, string.format("every schedule entry was replayed (%d of %d)", #handled, #entries))
  end,
  replay = R,
}
