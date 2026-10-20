-- "Pull a string": every fault of spec section 7 is one call on the sim. Times are milliseconds after the
-- start of the scenario's steps (Sim.t0). Each call records itself for the report.
local Sim = require("core.sim")
local GpsHost = require("periph.gps_host")
local Computer = require("core.computer")

local Faults = {}

local function describe(...)
  local out = {}
  for i = 1, select("#", ...) do
    local v = select(i, ...)
    if type(v) == "table" then
      local parts = {}
      for k, x in pairs(v) do parts[#parts + 1] = tostring(k) .. "=" .. tostring(x) end
      table.sort(parts)
      out[#out + 1] = "{" .. table.concat(parts, ",") .. "}"
    else out[#out + 1] = tostring(v) end
  end
  return table.concat(out, " ")
end

local function record(sim, t, name, ...)
  sim.faults[#sim.faults + 1] = { t_ms = t, name = name, args = describe(...) }
end

local function at(sim, t, fn) sim.sched:at(sim.t0 + t, fn) end

local function find(sim, node)
  if type(node) == "table" then return node end
  local c = sim.by_name[node] or sim.by_id[tonumber(node)] or sim.by_id[tonumber(tostring(node):gsub("^node_", ""))]
  if not c then error("fault: no such computer " .. tostring(node), 3) end
  return c
end

local function server(sim)
  for _, c in ipairs(sim.sched.computers) do if c.role == "server" then return c end end
  error("fault: this run has no dispatch server", 3)
end

-- The dispatch computer stops, then reboots from its disk.
function Sim:server_crash(t, down_for)
  record(self, t, "server_crash", "down_for=" .. down_for)
  at(self, t, function()
    local s = server(self)
    s:shutdown()
    local gen = s.gen
    self.sched:after(down_for, function() if s.gen == gen then s:boot() end end)
  end)
end

-- Every computer reboots; GPS hosts may come back late.
function Sim:world_restart(t, opts)
  opts = opts or {}
  local gps_delay = opts.gps_delay or 0
  record(self, t, "world_restart", opts)
  at(self, t, function()
    local sched = self.sched
    for _, c in ipairs(sched.computers) do
      if c.state ~= "off" then
        c:shutdown()
        local gen = c.gen
        local delay = (c.kind == "gps_host") and gps_delay or Computer.REBOOT_MS
        sched:after(delay, function() if c.gen == gen then c:boot() end end)
      end
    end
  end)
end

-- The server's computation costs `factor` times more virtual time.
function Sim:server_lag(t, dur, factor)
  record(self, t, "server_lag", "dur=" .. dur, "factor=" .. factor)
  at(self, t, function() server(self).cost_factor = factor end)
  at(self, t + dur, function() server(self).cost_factor = 1 end)
end

-- Every turtle action takes 20/tps times as long.
function Sim:tps_drop(t, dur, tps)
  record(self, t, "tps_drop", "dur=" .. dur, "tps=" .. tps)
  at(self, t, function() self.sched.action_scale = 20 / tps end)
  at(self, t + dur, function() self.sched.action_scale = 1 end)
end

function Sim:radio_loss(t, dur, rate, opts)
  opts = opts or {}
  record(self, t, "radio_loss", "dur=" .. dur, "rate=" .. rate, opts)
  self.sched.radio:add_rule{ drop_rate = rate, channel = opts.channel, from_ms = self.t0 + t, until_ms = self.t0 + t + dur }
end

function Sim:radio_latency(t, dur, ms)
  record(self, t, "radio_latency", "dur=" .. dur, "ms=" .. ms)
  self.sched.radio:add_rule{ latency_ms = ms, from_ms = self.t0 + t, until_ms = self.t0 + t + dur }
end

-- opts.hosts: ids of the hosts to silence (default: all of them).
function Sim:gps_down(t, dur, opts)
  opts = opts or {}
  record(self, t, "gps_down", "dur=" .. dur, opts)
  local function hosts()
    local out = {}
    for _, c in ipairs(self.sched.computers) do
      if c.kind == "gps_host" then
        local wanted = not opts.hosts
        for _, id in ipairs(opts.hosts or {}) do if id == c.id then wanted = true end end
        if wanted then out[#out + 1] = c end
      end
    end
    return out
  end
  at(self, t, function() for _, h in ipairs(hosts()) do GpsHost.set_on(h, false) end end)
  at(self, t + dur, function() for _, h in ipairs(hosts()) do GpsHost.set_on(h, true) end end)
end

-- listItems takes `seconds` longer.
function Sim:rs_stall(t, dur, seconds)
  record(self, t, "rs_stall", "dur=" .. dur, "seconds=" .. seconds)
  at(self, t, function() self.sched.storage.stall_ms = seconds * 1000 end)
  at(self, t + dur, function() self.sched.storage.stall_ms = 0 end)
end

function Sim:rs_offline(t, dur)
  record(self, t, "rs_offline", "dur=" .. dur)
  at(self, t, function() self.sched.storage.offline = true end)
  at(self, t + dur, function() self.sched.storage.offline = false end)
end

-- Reboot a turtle in the middle of an action: opts.at_action = "refuel", "drop", "place", "dig" ... (the first
-- action whose name starts with that). Without it, reboot at t.
function Sim:turtle_reboot(t, node, opts)
  opts = opts or {}
  record(self, t, "turtle_reboot", tostring(node), opts)
  at(self, t, function()
    local c = find(self, node)
    if opts.at_action then c.reboot_on_action = opts.at_action
    else c:reboot() end
  end)
end

-- The area (x1, z1, x2, z2 in blocks) stops being loaded: computers in it freeze.
function Sim:chunk_unload(t, area)
  record(self, t, "chunk_unload", table.concat(area, ","))
  at(self, t, function() self.sched.loading:force_unload(area) end)
end

-- The computer's disk has only `bytes_free` left.
function Sim:disk_full(t, node, bytes_free)
  record(self, t, "disk_full", tostring(node), "bytes_free=" .. bytes_free)
  at(self, t, function()
    local c = find(self, node)
    local D = c.disk_obj
    if not D then error("fault: " .. c.name .. " has no disk yet", 0) end
    D.quota = D:used() + bytes_free
  end)
end

function Sim:bridge_down(t, dur)
  record(self, t, "bridge_down", "dur=" .. dur)
  at(self, t, function() self.sched.standin.down = true end)
  at(self, t + dur, function() self.sched.standin.down = false end)
end

function Sim:bridge_slow(t, dur, ms)
  record(self, t, "bridge_slow", "dur=" .. dur, "ms=" .. ms)
  at(self, t, function() self.sched.standin.extra_latency_ms = ms end)
  at(self, t + dur, function() self.sched.standin.extra_latency_ms = 0 end)
end

function Sim:remove_item(t, node, slot)
  record(self, t, "remove_item", tostring(node), "slot=" .. slot)
  at(self, t, function() find(self, node).tstate.inv[slot] = nil end)
end

function Sim:event_queue_flood(t, node, n)
  record(self, t, "event_queue_flood", tostring(node), "n=" .. n)
  at(self, t, function()
    local c = find(self, node)
    for i = 1, n do c:queue_event({ "sandbox_flood", i }) end
  end)
end

Faults.NAMES = { "server_crash", "world_restart", "server_lag", "tps_drop", "radio_loss", "radio_latency", "gps_down",
  "rs_stall", "rs_offline", "turtle_reboot", "chunk_unload", "disk_full", "bridge_down", "bridge_slow", "remove_item",
  "event_queue_flood" }

return Faults
