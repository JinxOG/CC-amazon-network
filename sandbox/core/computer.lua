-- One in-game computer: its own environment, disk, event queue and coroutine.
-- Delivery follows CC: the head of the queue goes to a waiting computer only if its
-- filter matches (or the event is "terminate"); otherwise the event is discarded.
local Computer = {}
Computer.__index = Computer

Computer.QUEUE_MAX = 256
local TIMINGS = require("timings")
Computer.REBOOT_MS = TIMINGS.reboot_ms

-- Tests may pass their own env_builder.
Computer.default_env_builder = function(comp) return require("cc.env").build(comp) end

function Computer.new(opts)
  local self = setmetatable({}, Computer)
  self.id, self.label, self.kind = opts.id, opts.label, opts.kind or "computer"
  self.disk, self.sched, self.pos = opts.disk, opts.sched, opts.pos
  self.env_builder = opts.env_builder
  self.native = opts.native -- {on_boot=fn(comp), on_event=fn(comp, ev)} for computers that run no Lua program
  self.name = "node_" .. tostring(opts.id)
  self.state, self.filter = "off", nil
  self.queue, self.output = {}, {}
  self.peripherals = {}  -- hardware: survives reboots
  self.cost_ms = 0
  self.gen = 0       -- bumped on every boot and shutdown; stale callbacks check it
  self.booted_ms = 0
  return self
end

function Computer:clock() return self.sched.clock:now() end

-- This computer's own "now": scheduler time plus computation it has run but not yet been charged for.
function Computer:now() return self.sched.clock:now() + math.floor(self.cost_ms) end

-- A coroutine inside this computer; every one counts instructions toward cost_ms.
function Computer:new_co(fn)
  local co = coroutine.create(fn)
  local every = TIMINGS.instr_hook_every
  local profile = Computer.profile
  debug.sethook(co, function()
    self.cost_ms = self.cost_ms + every * TIMINGS.ns_per_instr / 1e6 * (self.cost_factor or 1)
    if profile then profile(self) end
  end, "", every)
  return co
end

function Computer:print(text)
  self.output[#self.output + 1] = { t = self:clock(), text = text }
end

-- Attach hardware by side or network name. `methods` is a table of functions.
-- `on_shutdown` (optional) runs when the computer goes down, e.g. a modem closing its channels.
function Computer:attach(name, type_, methods, on_shutdown)
  self.peripherals[name] = { type = type_, methods = methods, on_shutdown = on_shutdown }
end

function Computer:detach(name) self.peripherals[name] = nil end

function Computer:boot()
  if self.native then
    self.gen = self.gen + 1
    self.queue, self.filter, self.cost_ms = {}, nil, 0
    self.booted_ms = self:clock()
    self.state = "waiting"
    self.sched:trace(self.name .. " boot")
    if self.native.on_boot then self.native.on_boot(self) end
    return
  end
  self.gen = self.gen + 1
  self.queue, self.filter, self.cost_ms = {}, nil, 0
  self.booted_ms = self:clock()
  local build = self.env_builder or Computer.default_env_builder
  self.env = build(self)
  local path = self.disk .. "/startup.lua"
  local fn, err = loadfile(path, "t", self.env)
  if not fn then
    self.state = "off"; self:print("startup.lua: " .. tostring(err)); return
  end
  self.co = self:new_co(fn)
  self.state = "waiting"
  self.sched:trace(self.name .. " boot")
  self:resume({})
end

function Computer:shutdown()
  for _, p in pairs(self.peripherals) do if p.on_shutdown then p.on_shutdown() end end
  self.gen = self.gen + 1
  self.state, self.co, self.filter = "off", nil, nil
  self.queue = {}
  self.sched:trace(self.name .. " shutdown")
end

function Computer:reboot()
  self:shutdown()
  local gen = self.gen
  -- a shutdown in the meantime (the chunk unloaded, a player switched it off) cancels the reboot
  self.sched:after(Computer.REBOOT_MS, function() if self.gen == gen then self:boot() end end)
end

-- Runs the coroutine with an event until it yields, then charges its computation cost.
function Computer:resume(ev)
  local gen = self.gen
  self.state = "running"
  local t0 = os.clock()
  local ok, res = coroutine.resume(self.co, (table.unpack or unpack)(ev))
  local spent = os.clock() - t0
  self.wall_s = (self.wall_s or 0) + spent       -- real time spent running this computer, for the speed report
  if spent > (self.max_resume_s or 0) then self.max_resume_s = spent; self.max_resume_at = self.sched.clock:now() end
  if self.gen ~= gen then return end -- shut down or rebooted from inside
  if not ok then
    self:print(tostring(res)); self.state = "off"; self.co = nil
    self.sched:trace(self.name .. " crash " .. tostring(res))
    return
  end
  if coroutine.status(self.co) == "dead" then
    self.state = "off"; self.co = nil; self.sched:trace(self.name .. " exit"); return
  end
  self.filter = res
  local cost = math.ceil(self.cost_ms)
  self.cost_total_ms = (self.cost_total_ms or 0) + cost
  self.cost_ms = 0
  if cost > 0 then
    -- Busy for `cost` ms of virtual time. No wake-up event is scheduled unless something is waiting for it: an
    -- event that arrives meanwhile asks for one (see queue_event). Most busy periods pass with nobody calling.
    self.state = "busy"
    self.busy_until = self.sched.clock:now() + cost
    if #self.queue > 0 then self:schedule_wake() end
  else
    self.state = "waiting"; self:drain()
  end
end

-- At busy_until, if still the same boot and still busy, go back to listening and take what queued up.
function Computer:schedule_wake()
  if self.wake_pending then return end
  self.wake_pending = true
  local gen = self.gen
  self.sched:at(self.busy_until, function()
    self.wake_pending = false
    if self.gen ~= gen or self.state ~= "busy" then return end
    self.state = "waiting"; self:drain()
  end)
end

-- "busy" is only a claim until the clock passes busy_until; this is what the computer is really doing now.
function Computer:effective_state()
  if self.state == "busy" and self.sched.clock:now() >= self.busy_until then return "waiting" end
  return self.state
end

-- Events lost on the way to a program, by cause ("discarded": a filtered yield was waiting for something else;
-- "overflowed": the 256-event queue was full) and by event name. Read by scenarios that measure message loss.
function Computer:count(kind, name)
  local st = self.stats
  if not st then st = { discarded = {}, overflowed = {}, delivered = {}, acks = {} }; self.stats = st end
  st[kind][name] = (st[kind][name] or 0) + 1
end

-- Heartbeat acknowledgements addressed to this computer, counted at each stage on the way to the program, so a
-- scenario can say where acks are lost: "arrived" (the queue was asked to take it), "overflowed", "queued", "discarded"
-- (dropped by a filtered yield) and "delivered" (handed to the program). Only the stage counts; nothing changes.
function Computer:ack_stage(ev, stage)
  local m = ev[5]
  -- on the air a message is serialised text: {   type = "HEARTBEAT_ACK",   to = "node_32", ...
  if ev[1] == "modem_message" and type(m) == "string" and m:find('type = "HEARTBEAT_ACK"', 1, true)
     and m:find('to = "' .. self.name .. '"', 1, true) then
    self:count("acks", stage)
  end
end

function Computer:drain()
  while self.state == "waiting" and #self.queue > 0 do
    local ev = table.remove(self.queue, 1)
    local name = tostring(ev[1])
    if self.filter == nil or self.filter == ev[1] or ev[1] == "terminate" then
      self.sched:trace(self.name .. " deliver " .. name)
      if name == "modem_message" then self:count("delivered", name) end
      self:ack_stage(ev, "delivered")
      self:resume(ev)
    else
      self.sched:trace(self.name .. " discard " .. name)
      self:count("discarded", name)
      self:ack_stage(ev, "discarded")
    end
  end
end

function Computer:queue_event(ev)
  if self.state == "off" then return false end
  if self.native then
    if self.native.on_event then self.native.on_event(self, ev) end
    return true
  end
  if #self.queue >= Computer.QUEUE_MAX then
    self.sched:trace(self.name .. " overflow " .. tostring(ev[1]))
    self:count("overflowed", tostring(ev[1]))
    self:ack_stage(ev, "overflowed")
    return false
  end
  self.queue[#self.queue + 1] = ev
  self:ack_stage(ev, "queued")
  local st = self.state
  if st == "waiting" then
    self:drain()
  elseif st == "busy" then
    if self.sched.clock:now() >= self.busy_until then
      self.state = "waiting"; self:drain()
    else
      self:schedule_wake()
    end
  end
  return true
end

return Computer
