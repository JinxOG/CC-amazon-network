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
  self.name = "node_" .. tostring(opts.id)
  self.state, self.filter = "off", nil
  self.queue, self.output = {}, {}
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
  debug.sethook(co, function()
    self.cost_ms = self.cost_ms + every * TIMINGS.ns_per_instr / 1e6 * (self.cost_factor or 1)
  end, "", every)
  return co
end

function Computer:print(text)
  self.output[#self.output + 1] = { t = self:clock(), text = text }
end

function Computer:boot()
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
  self.gen = self.gen + 1
  self.state, self.co, self.filter = "off", nil, nil
  self.queue = {}
  self.sched:trace(self.name .. " shutdown")
end

function Computer:reboot()
  self:shutdown()
  self.sched:after(Computer.REBOOT_MS, function() self:boot() end)
end

-- Runs the coroutine with an event until it yields, then charges its computation cost.
function Computer:resume(ev)
  local gen = self.gen
  self.state = "running"
  local ok, res = coroutine.resume(self.co, (table.unpack or unpack)(ev))
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
  self.cost_ms = 0
  if cost > 0 then
    self.state = "busy"
    self.sched:after(cost, function()
      if self.gen ~= gen then return end
      self.state = "waiting"; self:drain()
    end)
  else
    self.state = "waiting"; self:drain()
  end
end

function Computer:drain()
  while self.state == "waiting" and #self.queue > 0 do
    local ev = table.remove(self.queue, 1)
    local name = tostring(ev[1])
    if self.filter == nil or self.filter == ev[1] or ev[1] == "terminate" then
      self.sched:trace(self.name .. " deliver " .. name)
      self:resume(ev)
    else
      self.sched:trace(self.name .. " discard " .. name)
    end
  end
end

function Computer:queue_event(ev)
  if self.state == "off" then return false end
  if #self.queue >= Computer.QUEUE_MAX then
    self.sched:trace(self.name .. " overflow " .. tostring(ev[1]))
    return false
  end
  self.queue[#self.queue + 1] = ev
  if self.state == "waiting" then self:drain() end
  return true
end

return Computer
