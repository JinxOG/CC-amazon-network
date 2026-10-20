-- Inventories: chests and ender chests.
-- Ender chests are shared by frequency. Each frequency is configured as one of
--   chest  (default)  a 27-slot inventory every holder of the frequency shares
--   endless           a source of one item that never runs out (the fuel chest: coal)
--   sink              items put in arrive in Refined Storage after a delay (the ore chest)
local Ender = {}
Ender.__index = Ender

local SLOTS = 27
local STACK = 64

-- Inventory ---------------------------------------------------------------------------------

local Inventory = {}
Inventory.__index = Inventory

local function copy_stack(s, count)
  local o = {}
  for k, v in pairs(s) do o[k] = v end
  o.count = count or s.count
  o.frequency = nil -- a stack inside a chest is not an ender chest's own frequency
  return o
end

function Inventory.new(slots)
  return setmetatable({ n = slots or SLOTS, slots = {} }, Inventory)
end

-- Adds the stack; returns how many went in.
function Inventory:put(stack)
  local left = stack.count
  for s = 1, self.n do
    local i = self.slots[s]
    if left > 0 and i and i.name == stack.name and i.frequency == stack.frequency and i.count < STACK then
      local m = math.min(left, STACK - i.count); i.count = i.count + m; left = left - m
    end
  end
  for s = 1, self.n do
    if left > 0 and not self.slots[s] then
      local m = math.min(left, STACK); self.slots[s] = copy_stack(stack, m); left = left - m
    end
  end
  return stack.count - left
end

-- Takes up to n of `name` (or of the first stack when name is nil).
function Inventory:take(n, name)
  for s = 1, self.n do
    local i = self.slots[s]
    if i and (name == nil or i.name == name) then
      local m = math.min(n, i.count)
      local out = copy_stack(i, m)
      i.count = i.count - m
      if i.count <= 0 then self.slots[s] = nil end
      return out
    end
  end
  return nil
end

function Inventory:list()
  local out = {}
  for s = 1, self.n do local i = self.slots[s]; if i then out[s] = { name = i.name, count = i.count } end end
  return out
end

function Inventory:size() return self.n end

function Inventory:count(name)
  local c = 0
  for s = 1, self.n do local i = self.slots[s]; if i and (not name or i.name == name) then c = c + i.count end end
  return c
end

-- Endless source / sink -----------------------------------------------------------------------

local Endless = setmetatable({}, { __index = Inventory })
Endless.__index = Endless

function Endless.new(item) return setmetatable({ n = 1, slots = {}, item = item }, Endless) end
function Endless:put(stack) return stack.count end                   -- leftovers go back in and vanish
function Endless:take(n, name)
  if name ~= nil and name ~= self.item then return nil end
  return { name = self.item, count = math.min(n, STACK) }
end
function Endless:list() return { [1] = { name = self.item, count = STACK } } end

local Sink = setmetatable({}, { __index = Inventory })
Sink.__index = Sink

function Sink.new(sched, storage, delay_ms)
  return setmetatable({ n = 1, slots = {}, sched = sched, storage = storage, delay_ms = delay_ms }, Sink)
end
function Sink:put(stack)
  local name, count = stack.name, stack.count
  self.sched:after(self.delay_ms, function() self.storage:add(name, count) end)
  return count
end
function Sink:take() return nil end
function Sink:list() return {} end

-- Registry ----------------------------------------------------------------------------------

function Ender.new(sched, storage)
  return setmetatable({ sched = sched, storage = storage, config = {}, inventories = {},
    ore_chest_delay_ms = 5000 }, Ender)
end

-- kind: "chest" | "endless" | "sink"; opts: {item=} for endless, {delay_ms=} for sink.
function Ender:configure(freq, kind, opts)
  opts = opts or {}
  self.config[freq] = { kind = kind, opts = opts }
  self.inventories[freq] = nil
end

function Ender:inventory(freq)
  freq = freq or "default"
  local inv = self.inventories[freq]
  if inv then return inv end
  local cfg = self.config[freq] or { kind = "chest", opts = {} }
  if cfg.kind == "endless" then inv = Endless.new(cfg.opts.item or "minecraft:coal")
  elseif cfg.kind == "sink" then inv = Sink.new(self.sched, self.storage, cfg.opts.delay_ms or self.ore_chest_delay_ms)
  else inv = Inventory.new(SLOTS) end
  self.inventories[freq] = inv
  return inv
end

-- The thing a turtle talks to when an ender chest sits in the world: put/take on the shared inventory,
-- and as_item() so digging it up gives the chest back with its frequency.
function Ender:container(freq, block_name)
  local inv = self:inventory(freq)
  return {
    freq = freq, inventory = inv, block_name = block_name or "enderstorage:ender_chest",
    put = function(_, stack) return inv:put(stack) end,
    take = function(_, n, name) return inv:take(n, name) end,
    as_item = function() return { name = block_name or "enderstorage:ender_chest", count = 1, frequency = freq } end,
  }
end

-- A plain chest placed in the world: its own inventory, which is lost when it is dug up.
function Ender.plain_chest(block_name)
  local inv = Inventory.new(SLOTS)
  return {
    inventory = inv, block_name = block_name, plain = true,
    put = function(_, stack) return inv:put(stack) end,
    take = function(_, n, name) return inv:take(n, name) end,
    as_item = function() return { name = block_name, count = 1 } end,
  }
end

-- Methods of the chest as seen by a computer (the warehouse's "top" peripheral).
function Ender.peripheral_methods(inv)
  local m = {}
  function m.list() return inv:list() end
  function m.size() return inv:size() end
  function m.getItemDetail(slot)
    local i = inv.slots[slot]
    if not i then return nil end
    return { name = i.name, count = i.count }
  end
  return m
end

-- Hook for turtle.place: ender chests and ordinary chests become containers in the world.
local CHESTS = { ["minecraft:chest"] = true, ["minecraft:barrel"] = true, ["minecraft:trapped_chest"] = true }

function Ender:install_hook(sched)
  sched.hooks = sched.hooks or {}
  local previous = sched.hooks.place
  sched.hooks.place = function(comp, stack, x, y, z, dir)
    if stack.name == "enderstorage:ender_chest" then
      comp.sched.world.containers[x .. "," .. y .. "," .. z] = self:container(stack.frequency or "default", stack.name)
      return true, stack.name
    elseif CHESTS[stack.name] then
      comp.sched.world.containers[x .. "," .. y .. "," .. z] = Ender.plain_chest(stack.name)
      return true, stack.name
    end
    if previous then return previous(comp, stack, x, y, z, dir) end
    return false
  end
end

Ender.Inventory = Inventory
return Ender
