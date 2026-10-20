-- Full control of the sandbox (spec section 7.1): reach into the world, any computer's disk, memory and event
-- queue, and the clock. None of this exists outside the sandbox.
-- Everything that changes the world or a computer is recorded as an INTERVENTION in the run's report;
-- reads, pause, step, snapshot, watch and status are not.
local Sim = require("core.sim")
local Turtle = require("cc.turtle")
local GpsHost = require("periph.gps_host")
local Modem = require("periph.modem")
local luaser = require("core.luaser")
local Storage = require("periph.storage")

local Control = {}

local FACING = { north = 0, east = 1, south = 2, west = 3 }
local function facing_of(f)
  if f == nil then return nil end
  if type(f) == "number" then return f % 4 end
  local n = FACING[tostring(f):lower()]
  if n == nil then error("facing must be 0-3 or north/east/south/west, got " .. tostring(f), 3) end
  return n
end

local function find(sim, node, level)
  if type(node) == "table" then return node end
  local c = sim.by_name[node] or sim.by_id[tonumber(node)]
  if not c and type(node) == "string" then c = sim.by_id[tonumber((node:gsub("^node_", "")))] end
  if not c and type(node) == "string" then
    for _, x in ipairs(sim.sched.computers) do if x.label == node then c = x end end
  end
  if not c then error("no such computer: " .. tostring(node), (level or 2) + 1) end
  return c
end

local function disk_of(c)
  if not c.disk_obj then c.disk_obj = require("core.disk").new(c.disk, c.quota) end
  return c.disk_obj
end

local function intervene(sim, what)
  sim.interventions[#sim.interventions + 1] = { t_ms = sim.clock:now() - sim.t0, what = what }
end

local function pos_string(...)
  local out = {}
  for i = 1, select("#", ...) do out[i] = tostring((select(i, ...))) end
  return table.concat(out, ",")
end

-- Time and runs ------------------------------------------------------------------------------------

-- pause() makes every run call return at once (and a running one stop at its next step) until resume().
function Sim:pause() self.paused = true end
function Sim:resume() self.paused = false end

function Sim:step(n)
  if self.paused then return "paused" end
  return self.sched:run{ max_events = n or 1, stop = function() return self.paused end }
end

-- t: milliseconds after the scenario's start, or a function that becomes true. Returns whether it was reached.
function Sim:run_until_time(t_ms)
  if self.paused then return false end
  local target = self.t0 + t_ms
  if target <= self.clock:now() then return true end
  self.sched:run{ until_ms = target, stop = function() return self.paused end }
  return self.clock:now() >= target
end

function Sim:set_speed(x)
  if x == "max" or x == nil then self.sched:set_pace(nil) else self.sched:set_pace(tonumber(x)) end
end

-- Turtles and computers ------------------------------------------------------------------------------

function Sim:teleport(node, x, y, z, facing)
  local c = find(self, node)
  intervene(self, string.format("teleport %s to %s facing %s", c.name, pos_string(x, y, z), tostring(facing)))
  c.carried = nil
  Turtle.set_pos(c, x, y, z, facing_of(facing))
  self.sched.loading:update_pos(c)
end

-- Put a stranded turtle back in its dock, as a player would: carried back to where it started, and rebooted.
function Sim:recover(node)
  local c = find(self, node)
  local h = c.home_pos
  if not h then error("recover: " .. c.name .. " has no home position", 2) end
  intervene(self, "recover " .. c.name .. " to " .. pos_string(h.x, h.y, h.z))
  c.carried = nil
  Turtle.set_pos(c, h.x, h.y, h.z, h.facing or 0)
  if c.state ~= "off" then c:shutdown() end
  self.sched.loading:update_pos(c)
  if c.state == "off" and not c.frozen then c:boot() end
end

local function tstate(c)
  if not c.tstate then error(c.name .. " is not a turtle", 3) end
  return c.tstate
end

function Sim:set_slot(node, slot, item, count)
  local c = find(self, node)
  intervene(self, string.format("set_slot %s slot %d = %s x%d", c.name, slot, tostring(item), count or 1))
  local stack = type(item) == "table" and item or { name = item, count = count or 1 }
  stack.count = stack.count or count or 1
  tstate(c).inv[slot] = stack
end

function Sim:clear_slot(node, slot)
  local c = find(self, node)
  intervene(self, string.format("clear_slot %s slot %d", c.name, slot))
  tstate(c).inv[slot] = nil
end

function Sim:give(node, item, count)
  local c = find(self, node)
  intervene(self, string.format("give %s %s x%d", c.name, tostring(item), count or 1))
  local st = tstate(c)
  local left = count or 1
  for s = 1, 16 do
    local i = st.inv[s]
    if left > 0 and i and i.name == item and i.count < 64 then
      local n = math.min(left, 64 - i.count); i.count = i.count + n; left = left - n
    end
  end
  for s = 1, 16 do
    if left > 0 and not st.inv[s] then
      local n = math.min(left, 64); st.inv[s] = { name = item, count = n }; left = left - n
    end
  end
  if left > 0 then error("give: " .. c.name .. " has no room for " .. left .. " more", 2) end
end

function Sim:set_fuel(node, n)
  local c = find(self, node)
  intervene(self, string.format("set_fuel %s = %d", c.name, n))
  tstate(c).fuel = n
end

function Sim:equip(node, side, upgrade)
  local c = find(self, node)
  intervene(self, string.format("equip %s %s = %s", c.name, side, tostring(upgrade)))
  tstate(c).equipped[side] = upgrade
  if c.on_equipment_changed then c.on_equipment_changed(c) end
end

-- spec: as Sim:add_computer, plus copy_of = <node> to copy that computer's disk and chunk-loading identity
-- (a copy keeps the original's identity, as in the real game), plus install = true to run the real installer.
function Sim:spawn_turtle(spec)
  spec.kind = "turtle"
  return self:spawn_computer(spec)
end

function Sim:spawn_computer(spec)
  spec.kind = spec.kind or "computer"
  spec.id = spec.id or (1000 + #self.sched.computers)
  intervene(self, string.format("spawn %s %d (%s)", spec.kind, spec.id, tostring(spec.role or spec.copy_of or "bare")))
  local original = spec.copy_of and find(self, spec.copy_of)
  if original then
    spec.role = spec.role or original.role
    spec.modems = spec.modems or (original.spec and original.spec.modems)
    spec.turtle = spec.turtle or (original.spec and original.spec.turtle)
    local c = self:add_computer(spec)
    disk_of(original):copy_all_to(disk_of(c))
    -- a copy keeps the original's chunk-loading identity, as in the real game (the copied-loader incident)
    c.chunk_identity = original.chunk_identity or ("computer:" .. original.id)
    if c.pos and c.pos.x then self.sched.loading:update_pos(c) end
    if c.state == "off" and not c.frozen and c.pos and c.pos.x then c:boot() end
    return c
  end
  if spec.role then
    require("core.fleet").provision(self, { spec })
    return self.by_id[spec.id]
  end
  local c = self:add_computer(spec)
  return c
end

function Sim:remove(node)
  local c = find(self, node)
  intervene(self, "remove " .. c.name)
  if c.state ~= "off" then c:shutdown() end
  local p = c.pos
  if p and p.x then self.world.occupants[p.x .. "," .. p.y .. "," .. p.z] = nil end
  self.sched.loading:release(c)
  for i, x in ipairs(self.sched.computers) do if x == c then table.remove(self.sched.computers, i); break end end
  self.by_id[c.id], self.by_name[c.name] = nil, nil
end

function Sim:reboot(node)
  local c = find(self, node)
  intervene(self, "reboot " .. c.name)
  if c.state == "off" then c:boot() else c:reboot() end
end

function Sim:shutdown(node)
  local c = find(self, node)
  intervene(self, "shutdown " .. c.name)
  c.frozen = nil
  if c.state ~= "off" then c:shutdown() end
end

function Sim:start(node)
  local c = find(self, node)
  intervene(self, "start " .. c.name)
  if c.state == "off" then c.frozen = nil; c:boot() end
end

function Sim:read_file(node, path) return disk_of(find(self, node)):read(path) end

function Sim:write_file(node, path, text)
  local c = find(self, node)
  intervene(self, string.format("write_file %s %s (%d bytes)", c.name, path, #text))
  local ok, err = disk_of(c):write(path, text)
  if not ok then error("write_file: " .. tostring(err), 2) end
end

function Sim:delete_file(node, path)
  local c = find(self, node)
  intervene(self, string.format("delete_file %s %s", c.name, path))
  disk_of(c):delete(path)
end

-- Runs Lua inside the computer's own environment (its globals, its os, its fs) and returns the results.
-- Code that assigns counts as an intervention.
function Sim:eval(node, code)
  local c = find(self, node)
  if not c.env then error(c.name .. " has never booted, so it has no environment", 2) end
  if code:find("[^=~<>]=[^=]") then intervene(self, string.format("eval %s: %s", c.name, code:sub(1, 120))) end
  local fn, err = load("return " .. code, "eval", "t", c.env)
  if not fn then fn, err = load(code, "eval", "t", c.env) end
  if not fn then error("eval: " .. tostring(err), 2) end
  local r = table.pack(pcall(fn))
  if not r[1] then error("eval: " .. tostring(r[2]), 2) end
  return (table.unpack or unpack)(r, 2, r.n)
end

function Sim:output(node)
  local c = find(self, node)
  local out = {}
  for i, l in ipairs(c.output) do out[i] = l.text end
  return table.concat(out, "\n")
end

-- Its event queue right now: length, the events, pending timers, open channels.
function Sim:queue(node)
  local c = find(self, node)
  local events = {}
  for i, ev in ipairs(c.queue) do events[i] = tostring(ev[1]) end
  local timers = {}
  for id in pairs(c.timers or {}) do timers[#timers + 1] = id end
  table.sort(timers)
  local channels = {}
  for _, p in pairs(c.peripherals) do
    if p.channels then for _, ch in ipairs(p.channels()) do channels[#channels + 1] = ch end end
  end
  table.sort(channels)
  return { state = c:effective_state(), length = #c.queue, events = events, timers = timers, channels = channels, filter = c.filter }
end

-- The world ------------------------------------------------------------------------------------------

function Sim:get_block(x, y, z) return self.world:get(x, y, z) end

function Sim:set_block(x, y, z, name)
  intervene(self, string.format("set_block %s = %s", pos_string(x, y, z), tostring(name)))
  self.world:set(x, y, z, name)
end

-- area: {x1, y1, z1, x2, y2, z2}
function Sim:fill(area, name)
  intervene(self, string.format("fill %s = %s", pos_string(table.unpack(area)), tostring(name)))
  local x1, x2 = math.min(area[1], area[4]), math.max(area[1], area[4])
  local y1, y2 = math.min(area[2], area[5]), math.max(area[2], area[5])
  local z1, z2 = math.min(area[3], area[6]), math.max(area[3], area[6])
  for x = x1, x2 do for y = y1, y2 do for z = z1, z2 do self.world:set(x, y, z, name) end end end
end

function Sim:load_chunks(area)
  intervene(self, "load_chunks " .. pos_string(table.unpack(area)))
  self.sched.loading:force_load(area)
end

function Sim:unload_chunks(area)
  intervene(self, "unload_chunks " .. pos_string(table.unpack(area)))
  self.sched.loading:force_unload(area)
end

-- Injects a radio message as any sender (opts.from = a computer; default an invisible one).
function Sim:send_radio(channel, reply, message, opts)
  opts = opts or {}
  intervene(self, string.format("send_radio ch=%d type=%s", channel, tostring(type(message) == "table" and message.type or "?")))
  local from = opts.from and find(self, opts.from)
  if not from then
    from = self.phantom
    if not from then
      from = { id = 0, name = "sandbox", sched = self.sched, pos = { x = 0, y = 64, z = 0 }, peripherals = {} }
      self.phantom = from
    end
  end
  self.sched.radio:transmit(from, "sandbox", channel, reply, message)
end

-- Drops matching messages from now on. filter: {channel=, type=, from=, to=}. Returns a rule id for radio:remove_rule.
function Sim:drop_radio(filter)
  intervene(self, "drop_radio " .. pos_string(filter.channel, filter.type, filter.from, filter.to))
  return self.sched.radio:add_rule{ drop_rate = 1, channel = filter.channel, type = filter.type, from = filter.from, to = filter.to }
end

function Sim:storage_set(item, count)
  intervene(self, string.format("storage_set %s = %d", item, count))
  self.sched.storage:set(item, count)
end
function Sim:storage_add(item, count)
  intervene(self, string.format("storage_add %s +%d", item, count))
  self.sched.storage:add(item, count)
end
function Sim:storage_remove(item, count)
  intervene(self, string.format("storage_remove %s -%d", item, count))
  return self.sched.storage:remove(item, count)
end

function Sim:kv_get(key) return self.sched.kv:get(key) end
function Sim:kv_set(key, value)
  intervene(self, "kv_set " .. key)
  self.sched.kv:put(key, value)
end
function Sim:kv_clear()
  intervene(self, "kv_clear")
  self.sched.kv:clear()
end

-- contents: list of {name=, count=} stacks for the ender chest of that frequency.
function Sim:ender_set(frequency, contents)
  intervene(self, string.format("ender_set %s (%d stacks)", frequency, #contents))
  local cfg = self.sched.ender.config[frequency]
  if cfg and cfg.kind ~= "chest" then error("ender_set: frequency " .. frequency .. " is an endless or sink chest", 2) end
  local inv = self.sched.ender:inventory(frequency)
  inv.slots = {}
  for _, stack in ipairs(contents) do inv:put(stack) end
end

function Sim:gps_host(id, on)
  local h = find(self, id)
  intervene(self, string.format("gps_host %s %s", h.name, on and "on" or "off"))
  GpsHost.set_on(h, on and true or false)
end

function Sim:place_gps_host(x, y, z)
  local id = 200
  while self.by_id[id] do id = id + 1 end
  intervene(self, "place_gps_host " .. pos_string(x, y, z))
  local h = GpsHost.place(self.sched, id, x, y, z)
  self.by_id[id], self.by_name[h.name] = h, h
  return h
end

-- Watching --------------------------------------------------------------------------------------------

-- When condition(sim) becomes true: action = "pause", "snapshot" (named after the time), "log" or a function.
-- Checked at least every 100 simulated ms (and every 64 events), so it fires just after the moment, not on the exact event.
function Sim:watch(condition, action)
  self.watches = self.watches or {}
  local w = { condition = condition, action = action, fired = false }
  self.watches[#self.watches + 1] = w
  if not self.sched.on_step then
    self.sched.on_step = function()
      for _, x in ipairs(self.watches) do
        if not x.fired and x.condition(self) then
          x.fired = true
          local a = x.action
          if a == "pause" then self:pause()
          elseif a == "snapshot" then self:snapshot("watch-" .. (self.clock:now() - self.t0))
          elseif a == "log" then self.sched:trace("watch fired")
          elseif type(a) == "function" then a(self) end
        end
      end
    end
  end
  return w
end

-- Records every radio message matching filter ({channel=, type=, from=, to=}) with send and arrival times.
function Sim:trace_radio(filter)
  filter = filter or {}
  local record = {}
  table.insert(self.sched.radio.listeners, function(e)
    if (not filter.channel or filter.channel == e.channel) and (not filter.type or filter.type == e.type)
        and (not filter.from or filter.from == e.from) and (not filter.to or filter.to == e.to) then
      record[#record + 1] = e
    end
  end)
  return record
end

-- One table of the whole fleet.
function Sim:status()
  local rows = {}
  local st = self.sched.standin.state
  for _, c in ipairs(self.sched.computers) do
    local row = { name = c.name, role = c.role, kind = c.kind, state = c:effective_state(), queue = #c.queue,
      pos = c.pos and c.pos.x and { x = c.pos.x, y = c.pos.y, z = c.pos.z, facing = c.pos.facing } or nil }
    if c.tstate then
      row.fuel = c.tstate.fuel
      local inv = {}
      for s = 1, 16 do local i = c.tstate.inv[s]; if i then inv[#inv + 1] = s .. ":" .. i.name .. "x" .. i.count end end
      row.inventory = inv
    end
    local reported = st and st.turtles and st.turtles[c.name]
    if reported then row.status, row.job = reported.status, reported.jobId end
    rows[#rows + 1] = row
  end
  return rows
end

Control.FACING = FACING
return Control
