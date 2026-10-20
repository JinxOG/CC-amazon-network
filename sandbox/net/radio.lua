-- The radio network: every on computer with a modem that has the channel open hears a transmission,
-- unless a rule drops it. Messages are deep-copied, as CC copies them between computers.
local TIMINGS = require("timings")

local Radio = {}
Radio.__index = Radio

-- CC refuses functions in messages and cannot send cycles.
local function deep_copy(v, seen, depth)
  local t = type(v)
  if t == "nil" or t == "boolean" or t == "number" or t == "string" then return v end
  if t ~= "table" then error("Unable to serialize " .. t .. " in a modem message", 0) end
  depth = depth or 0
  seen = seen or {}
  if seen[v] then error("Message contains a table that refers to itself", 0) end
  if depth > 50 then error("Message is nested too deeply", 0) end
  seen[v] = true
  local o = {}
  for k, x in pairs(v) do
    local kt = type(k)
    if kt ~= "string" and kt ~= "number" and kt ~= "boolean" then error("Unable to serialize a " .. kt .. " table key", 0) end
    o[k] = deep_copy(x, seen, depth + 1)
  end
  seen[v] = nil
  return o
end
Radio.deep_copy = deep_copy

function Radio.new(opts)
  local self = setmetatable({}, Radio)
  self.sched = opts.sched
  self.rng = opts.rng:fork("radio")
  self.rules, self.next_rule = {}, 0
  self.listeners = {}   -- trace_radio taps: function(record)
  return self
end

function Radio:add_rule(r)
  self.next_rule = self.next_rule + 1
  r.id = self.next_rule
  self.rules[#self.rules + 1] = r
  return r.id
end

function Radio:remove_rule(id)
  for i, r in ipairs(self.rules) do
    if r.id == id then table.remove(self.rules, i); return true end
  end
  return false
end

local function matches(rule, now, channel, from, to, mtype)
  if rule.from_ms and now < rule.from_ms then return false end
  if rule.until_ms and now >= rule.until_ms then return false end
  if rule.channel and rule.channel ~= channel then return false end
  if rule.type and rule.type ~= mtype then return false end
  if rule.from and rule.from ~= from.id and rule.from ~= from.name then return false end
  if rule.to and rule.to ~= to.id and rule.to ~= to.name then return false end
  return true
end

local function distance(a, b)
  local p, q = a.pos or {}, b.pos or {}
  local dx, dy, dz = (p.x or 0) - (q.x or 0), (p.y or 0) - (q.y or 0), (p.z or 0) - (q.z or 0)
  return math.sqrt(dx * dx + dy * dy + dz * dz)
end

-- `side` is the name of the sending modem on from_comp (so it does not hear itself).
function Radio:transmit(from_comp, side, channel, reply, msg)
  local sched = self.sched
  local now = from_comp.sched.clock:now()
  local copy = deep_copy(msg)
  local mtype = type(copy) == "table" and copy.type or nil
  local heard = false
  for _, comp in ipairs(sched.computers) do
    for mname, p in pairs(comp.peripherals) do
      if p.type == "modem" and p.is_open and p.is_open(channel) and not (comp == from_comp and mname == side) then
        heard = true
        local drop, latency = false, TIMINGS.radio_latency_ms
        for _, rule in ipairs(self.rules) do
          if matches(rule, now, channel, from_comp, comp, mtype) then
            if rule.drop_rate and rule.drop_rate > 0 and self.rng:next() < rule.drop_rate then drop = true end
            if rule.latency_ms then latency = latency + rule.latency_ms end
          end
        end
        local label = string.format("%s -> %s ch=%d type=%s", from_comp.name, comp.name, channel, tostring(mtype or "?"))
        sched:trace("radio " .. label .. (drop and " dropped" or " delivered"))
        for _, fn in ipairs(self.listeners) do
          fn{ t = now, arrive_ms = (not drop) and (now + latency) or nil, from = from_comp.name, to = comp.name, channel = channel, type = mtype, dropped = drop }
        end
        if not drop then
          local ev = { "modem_message", mname, channel, reply, deep_copy(copy), distance(from_comp, comp) }
          sched:at(now + latency, function() comp:queue_event(ev) end)
        end
      end
    end
  end
  if not heard then
    sched:trace(string.format("radio %s -> - ch=%d type=%s unheard", from_comp.name, channel, tostring(mtype or "?")))
  end
end

return Radio
