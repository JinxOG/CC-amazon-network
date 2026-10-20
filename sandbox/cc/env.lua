-- Builds the global environment of one computer: whitelisted Lua plus the CC APIs.
-- Anything the fleet calls that is not implemented raises a clear error naming it.
local Rng = require("core.rng")
local unpack = table.unpack or unpack

local CCEnv = {}

-- Global names that exist in CC but are not built yet: touching one is an error, not nil.
local KNOWN_CC_GLOBALS = {
  "term", "colors", "colours", "keys", "window", "paintutils", "vector", "rednet",
  "redstone", "rs", "multishell", "disk", "help", "pocket", "commands", "fs", "textutils",
  "shell", "settings", "http", "gps", "parallel", "peripheral", "turtle", "read", "printError",
}

function CCEnv.unimplemented(comp, api)
  return function(_, key)
    error(string.format("sandbox: %s.%s is not implemented (computer %s)", api, tostring(key), tostring(comp.id)), 2)
  end
end

-- Wrap an API table so reading a missing member raises.
function CCEnv.api(comp, name, tbl)
  return setmetatable(tbl, { __index = CCEnv.unimplemented(comp, name) })
end

-- A peripheral call that takes game time. The computer yields for a task_complete event with this
-- call's id, so every other event arriving meanwhile is discarded, as in CC. fn runs at the instant
-- the call completes, in the scheduler, so its effect on the world happens at that virtual time.
local next_task_id = 0
function CCEnv.main_thread_call(comp, duration_ms, fn)
  next_task_id = next_task_id + 1
  local id, gen = next_task_id, comp.gen
  comp.sched:at(comp:now() + duration_ms, function()
    local r = table.pack(pcall(fn))
    if comp.gen == gen then comp:queue_event({ "task_complete", id, r }) end
  end)
  while true do
    local ev = { coroutine.yield("task_complete") }
    if ev[1] == "terminate" then error("Terminated", 0) end
    if ev[2] == id then
      local r = ev[3]
      if not r[1] then error(r[2], 0) end
      return unpack(r, 2, r.n)
    end
  end
end

local function copy(t) local o = {} for k, v in pairs(t) do o[k] = v end return o end

local INSTALLERS = { "cc.os", "cc.term", "cc.fs", "cc.textutils", "cc.shell", "cc.settings", "cc.parallel", "cc.peripheral", "cc.turtle" }

function CCEnv.build(comp)
  local E = {}
  for _, name in ipairs({ "assert", "error", "getmetatable", "setmetatable", "ipairs", "pairs",
      "next", "select", "type", "tostring", "tonumber", "pcall", "xpcall", "rawequal",
      "rawget", "rawset", "rawlen", "unpack" }) do
    E[name] = _G[name]
  end
  E._VERSION = "Lua 5.1"
  E.string, E.table, E.math, E.bit32 = copy(string), copy(table), copy(math), copy(bit32)
  E.bit = E.bit32
  E._G = E
  E._ENV = E

  -- per-computer, seeded randomness (never the process-wide math.random)
  local rng = comp.sched.rng:fork(comp.name .. "#" .. comp.gen)
  E.math.random = function(m, n)
    if m == nil then return rng:next() end
    if n == nil then m, n = 1, m end
    if m > n then error("bad argument #2 to 'random' (interval is empty)", 2) end
    return rng:int(m, n)
  end
  E.math.randomseed = function(seed) rng = Rng.new(tonumber(seed) or 0) end

  -- coroutines made here count instructions toward cost
  local co = copy(coroutine)
  co.create = function(fn) return comp:new_co(fn) end
  co.wrap = function(fn)
    local c = comp:new_co(fn)
    return function(...)
      local r = { coroutine.resume(c, ...) }
      if not r[1] then error(r[2], 0) end
      return (table.unpack or unpack)(r, 2, #r)
    end
  end
  E.coroutine = co

  E.load = function(chunk, name, mode, env) return load(chunk, name, mode or "t", env or E) end
  E.loadstring = function(s, name) return load(s, name, "t", E) end

  for _, mod in ipairs(INSTALLERS) do require(mod).install(comp, E) end

  setmetatable(E, { __index = function(_, key)
    for _, g in ipairs(KNOWN_CC_GLOBALS) do
      if g == key then
        error(string.format("sandbox: %s is not implemented (computer %s)", key, tostring(comp.id)), 2)
      end
    end
    return nil
  end })
  return E
end

return CCEnv
