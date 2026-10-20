-- Discrete-event scheduler: pops the earliest item, moves the virtual clock there, runs it.
local Heap = require("core.heap")

local Scheduler = {}
Scheduler.__index = Scheduler

function Scheduler.new(opts)
  local self = setmetatable({}, Scheduler)
  self.clock, self.rng = opts.clock, opts.rng
  self.heap = Heap.new()
  self.computers = {}
  self.trace_path = opts.trace
  self.trace_buf, self.trace_lines = {}, 0
  if opts.trace then self.trace_file = assert(io.open(opts.trace, "wb")) end
  return self
end

-- Slows the run so simulated time advances at most `speed` times faster than the wall clock.
function Scheduler:set_pace(speed)
  self.pace = speed and { speed = speed, wall0 = os.clock(), sim0 = self.clock:now() } or nil
end

function Scheduler:add(comp) self.computers[#self.computers + 1] = comp; comp.sched = self end

function Scheduler:at(t_ms, fn)
  local now = self.clock:now()
  if t_ms < now then t_ms = now end
  self.heap:push(t_ms, fn)
end

function Scheduler:after(delay_ms, fn) self:at(self.clock:now() + delay_ms, fn) end

function Scheduler:post(t_ms, comp, ev)
  self:at(t_ms, function() comp:queue_event(ev) end)
end

function Scheduler:trace(line)
  self.trace_lines = self.trace_lines + 1
  if not self.trace_file then return end
  local buf = self.trace_buf
  buf[#buf + 1] = self.clock:now() .. " " .. line .. "\n"
  if #buf >= 1000 then self:flush() end
end

function Scheduler:flush()
  if self.trace_file and #self.trace_buf > 0 then
    self.trace_file:write(table.concat(self.trace_buf)); self.trace_buf = {}
  end
end

function Scheduler:close()
  self:flush()
  if self.trace_file then self.trace_file:close(); self.trace_file = nil end
end

-- Runs until nothing is left ("idle"), the time limit ("until"), the event limit
-- ("max_events") or stop() returns true ("stopped").
function Scheduler:run(opts)
  opts = opts or {}
  local n = 0
  while true do
    if opts.stop and opts.stop() then return "stopped" end
    local nxt = self.heap:peek_time()
    if nxt == nil then
      if opts.until_ms and opts.until_ms > self.clock:now() then self.clock:set(opts.until_ms) end
      return "idle"
    end
    if opts.until_ms and nxt > opts.until_ms then
      self.clock:set(opts.until_ms); return "until"
    end
    if opts.max_events and n >= opts.max_events then return "max_events" end
    local t, fn = self.heap:pop()
    self.clock:set(t)
    fn()
    n = n + 1
    if self.on_step and (t - (self.last_step or 0) >= 100 or n % 64 == 0) then
      self.last_step = t
      self.on_step()
    end
    if self.pace and n % 64 == 0 then
      local target = (t - self.pace.sim0) / 1000 / self.pace.speed
      while os.clock() - self.pace.wall0 < target do end
    end
  end
end

return Scheduler
