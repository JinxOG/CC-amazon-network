-- The Advanced Peripherals RS bridge. Contents come from the run's Storage. listItems yields for rs_list_ms
-- plus whatever stall the rs_stall fault adds; with the network offline every call raises.
local CCEnv = require("cc.env")
local TIMINGS = require("timings")
local Blocks = require("periph.blocks")

local M = {}

local function find_inventory(comp, name)
  local d = Blocks.lookup(comp, name)
  return d and d.inventory
end

-- Builds the bridge's methods as seen by `comp`.
function M.methods(comp)
  local m = {}
  local function storage()
    local s = comp.sched.storage
    if not s then error("sandbox: no storage in this run (computer " .. comp.id .. ")", 3) end
    if s.offline then error("RS network is not connected", 3) end
    return s
  end
  local function timed(ms, fn)
    local s = comp.sched.storage
    local extra = s and s.stall_ms or 0
    return CCEnv.main_thread_call(comp, (ms + extra) * (comp.sched.action_scale or 1), fn)
  end
  local function filter_name(f)
    if type(f) ~= "table" or type(f.name) ~= "string" then error("Item filter needs a name", 3) end
    return f.name
  end

  function m.listItems()
    storage()
    return timed(TIMINGS.rs_list_ms, function() return storage():list() end)
  end
  function m.listCraftableItems()
    storage()
    return timed(TIMINGS.rs_list_ms * 4, function() return storage():list_craftable() end) -- the slow one; unverified
  end
  function m.getItem(f)
    storage()
    local name = filter_name(f)
    return timed(TIMINGS.turtle_cmd_ms, function() return storage():entry(name) end)
  end
  function m.craftItem(f)
    storage()
    local name = filter_name(f)
    return timed(TIMINGS.turtle_cmd_ms, function()
      local s = storage()
      s.crafted[#s.crafted + 1] = { name = name, count = f.count or 1 } -- recorded; crafting itself is not modelled
      return true
    end)
  end
  function m.importItem(f, dir)
    storage()
    local name = filter_name(f)
    local inv = find_inventory(comp, dir)
    if not inv then error("No inventory on side " .. tostring(dir), 2) end
    return timed(TIMINGS.turtle_cmd_ms, function()
      local s, moved, want = storage(), 0, f.count or math.huge
      while moved < want do
        local stack = inv:take(math.min(64, want - moved), name)
        if not stack then break end
        s:add(stack.name, stack.count); moved = moved + stack.count
      end
      return moved
    end)
  end
  function m.exportItem(f, dir)
    storage()
    local name = filter_name(f)
    local inv = find_inventory(comp, dir)
    if not inv then error("No inventory on side " .. tostring(dir), 2) end
    return timed(TIMINGS.turtle_cmd_ms, function()
      local s, moved, want = storage(), 0, f.count or 64
      while moved < want and s:amount(name) > 0 do
        local n = math.min(64, want - moved, s:amount(name))
        local put = inv:put({ name = name, count = n })
        if put <= 0 then break end
        s:remove(name, put); moved = moved + put
      end
      return moved
    end)
  end
  return m
end

Blocks.register("advancedperipherals:rs_bridge", function(comp)
  return { type = "rsBridge", methods = M.methods(comp) }
end)

return M
