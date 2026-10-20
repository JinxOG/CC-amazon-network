-- The CloudSolutions kv_storage peripheral: one key space for the whole player, shared by every computer.
-- A working local store (spec section 6): survives reboots and server crashes within a run, can be saved
-- and reloaded between runs, starts empty. Limits are the ones measured in the world (cloudstore.lua).
local CCEnv = require("cc.env")
local TIMINGS = require("timings")
local luaser = require("core.luaser")

local KV = {}
KV.__index = KV

KV.VALUE_LIMIT = 500000
KV.KEY_LIMIT = 10240

-- path: where flush() writes (nil keeps it in memory only). Loads the file if it exists.
function KV.new(path)
  local self = setmetatable({ path = path, data = {}, count = 0, dirty = false }, KV)
  if path then
    local f = io.open(path, "rb")
    if f then
      local t = luaser.parse(f:read("*a")); f:close()
      if type(t) == "table" then self.data = t end
      for _ in pairs(self.data) do self.count = self.count + 1 end
    end
  end
  return self
end

function KV:get(key) return self.data[key] end

function KV:put(key, value)
  if type(key) ~= "string" then error("key must be a string", 0) end
  if type(value) ~= "string" then error("value must be a string", 0) end
  if #value > KV.VALUE_LIMIT then error("value exceeds limit of " .. KV.VALUE_LIMIT .. " bytes", 0) end
  if self.data[key] == nil then
    if self.count >= KV.KEY_LIMIT then error("key limit of " .. KV.KEY_LIMIT .. " reached", 0) end
    self.count = self.count + 1
  end
  self.data[key] = value
  self.dirty = true
end

function KV:delete(key)
  if self.data[key] ~= nil then self.data[key] = nil; self.count = self.count - 1; self.dirty = true end
end

function KV:keys()
  local out = {}
  for k in pairs(self.data) do out[#out + 1] = k end
  table.sort(out)
  return out
end

function KV:clear() self.data, self.count, self.dirty = {}, 0, true end

function KV:flush()
  if not self.path or not self.dirty then return end
  local f = assert(io.open(self.path, "wb")); f:write(luaser.dump(self.data)); f:close()
  self.dirty = false
end

-- The peripheral as a computer sees it. `comp.sched.kv` is the run's store.
function KV.methods(comp)
  local m = {}
  local function kv()
    local k = comp.sched.kv
    if not k then error("sandbox: no cloud store in this run (computer " .. comp.id .. ")", 3) end
    if k.offline then error("kv_storage is not reachable", 3) end
    return k
  end
  local function timed(fn) return CCEnv.main_thread_call(comp, TIMINGS.kv_call_ms * (comp.sched.action_scale or 1), fn) end
  function m.get(key) kv(); return timed(function() return kv():get(key) end) end
  function m.put(key, value) kv(); return timed(function() return kv():put(key, value) end) end
  function m.delete(key) kv(); return timed(function() return kv():delete(key) end) end
  function m.list() kv(); return timed(function() return kv():keys() end) end
  return m
end

-- Wire a kv_storage peripheral straight onto a computer (the block name is not needed for this).
function KV.attach(comp, side) comp:attach(side or "back", "kv_storage", KV.methods(comp)) end

return KV
