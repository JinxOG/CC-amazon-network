-- peripheral: lookups over the hardware attached to this computer (Computer:attach) and the peripheral
-- blocks standing next to it (periph/blocks.lua).
local CCEnv = require("cc.env")
local Blocks = require("periph.blocks")
require("periph.geo_scanner")
require("periph.rs_bridge")
require("periph.kv_storage")

local M = {}

function M.install(comp, E)
  local P = {}
  local names_of = setmetatable({}, { __mode = "k" }) -- wrapped table -> its name

  function P.getNames() return Blocks.names(comp) end
  function P.isPresent(name) return Blocks.lookup(comp, name) ~= nil end

  function P.getType(p)
    if type(p) == "table" then p = names_of[p] end
    local d = Blocks.lookup(comp, p)
    return d and d.type or nil
  end

  function P.getMethods(name)
    local d = Blocks.lookup(comp, name)
    if not d then return nil end
    local out = {}
    for m in pairs(d.methods) do out[#out + 1] = m end
    table.sort(out)
    return out
  end

  function P.getName(wrapped) return names_of[wrapped] end

  function P.call(name, method, ...)
    local d = Blocks.lookup(comp, name)
    if not d then error("No peripheral attached", 2) end
    local fn = d.methods[method]
    if not fn then error("No such method " .. tostring(method), 2) end
    return fn(...)
  end

  function P.wrap(name)
    local d = Blocks.lookup(comp, name)
    if not d then return nil end
    -- Like CC's own wrappers, every method looks the peripheral up by NAME at call time: while nothing is attached under
    -- that name (a turtle's modem unequipped for a loader swap) the call raises "No such method <m>", and it works again when
    -- something is attached there again. The text is what real CC:Tweaked gave the fleet in a T2 run at 1x
    -- ("/protocol.lua:486: No such method transmit", 5 times in a three-sector job, run cmp-1x).
    local w = {}
    for m in pairs(d.methods) do
      w[m] = function(...)
        local cur = Blocks.lookup(comp, name)
        if not cur then error("No such method " .. tostring(m), 2) end
        local fn = cur.methods[m]
        if not fn then error("No such method " .. tostring(m), 2) end
        return fn(...)
      end
    end
    names_of[w] = name
    return w
  end

  -- find(type [, filter]) returns every matching peripheral, wrapped.
  function P.find(type_, filter)
    local out = {}
    for _, name in ipairs(Blocks.names(comp)) do
      local d = Blocks.lookup(comp, name)
      if d and d.type == type_ then
        local w = P.wrap(name)
        if not filter or filter(name, w) then out[#out + 1] = w end
      end
    end
    return (table.unpack or unpack)(out)
  end

  E.peripheral = CCEnv.api(comp, "peripheral", P)
end

return M
