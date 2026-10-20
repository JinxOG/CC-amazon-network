-- peripheral: lookups over the hardware attached to this computer (Computer:attach).
local CCEnv = require("cc.env")

local M = {}

function M.install(comp, E)
  local P = {}
  local names_of = setmetatable({}, { __mode = "k" }) -- wrapped table -> its name

  local function sorted_names()
    local out = {}
    for name in pairs(comp.peripherals) do out[#out + 1] = name end
    table.sort(out)
    return out
  end

  function P.getNames() return sorted_names() end
  function P.isPresent(name) return comp.peripherals[name] ~= nil end

  function P.getType(p)
    if type(p) == "table" then p = names_of[p] end
    local d = comp.peripherals[p]
    return d and d.type or nil
  end

  function P.getMethods(name)
    local d = comp.peripherals[name]
    if not d then return nil end
    local out = {}
    for m in pairs(d.methods) do out[#out + 1] = m end
    table.sort(out)
    return out
  end

  function P.getName(wrapped) return names_of[wrapped] end

  function P.call(name, method, ...)
    local d = comp.peripherals[name]
    if not d then error("No peripheral attached", 2) end
    local fn = d.methods[method]
    if not fn then error("No such method " .. tostring(method), 2) end
    return fn(...)
  end

  function P.wrap(name)
    local d = comp.peripherals[name]
    if not d then return nil end
    local w = {}
    for m, fn in pairs(d.methods) do w[m] = fn end
    names_of[w] = name
    return w
  end

  -- find(type [, filter]) returns every matching peripheral, wrapped.
  function P.find(type_, filter)
    local out = {}
    for _, name in ipairs(sorted_names()) do
      local d = comp.peripherals[name]
      if d.type == type_ then
        local w = P.wrap(name)
        if not filter or filter(name, w) then out[#out + 1] = w end
      end
    end
    return (table.unpack or unpack)(out)
  end

  E.peripheral = CCEnv.api(comp, "peripheral", P)
end

return M
