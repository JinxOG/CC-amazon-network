-- settings: a small in-memory store with save/load through the computer's own disk.
local CCEnv = require("cc.env")

local M = {}

function M.install(comp, E)
  local values = {}
  local S = {}
  function S.get(name, default)
    local v = values[name]
    if v == nil then return default end
    return v
  end
  function S.set(name, value) values[name] = value end
  function S.unset(name) values[name] = nil end
  function S.clear() values = {} end
  function S.getNames()
    local out = {}
    for k in pairs(values) do out[#out + 1] = k end
    table.sort(out)
    return out
  end
  function S.save(path)
    path = path or ".settings"
    return comp.disk_obj:write(path, E.textutils.serialise(values)) and true or false
  end
  function S.load(path)
    path = path or ".settings"
    local data = comp.disk_obj:read(path)
    if not data then return false end
    local t = E.textutils.unserialise(data)
    if type(t) ~= "table" then return false end
    for k, v in pairs(t) do values[k] = v end
    return true
  end
  E.settings = CCEnv.api(comp, "settings", S)
end

return M
