-- The Refined Storage network's contents: item name -> amount. One per run, seeded by the scenario or by
-- the importer's storage.json. Faults act on it: stall_ms makes listItems slow, offline makes it fail.
local Storage = {}
Storage.__index = Storage

local function pretty(name)
  local path = name:match(":(.+)$") or name
  return (path:gsub("_", " "):gsub("(%a)([%w]*)", function(a, b) return a:upper() .. b end))
end

-- items: list of {name=, amount=, displayName=, craftable=}
function Storage.new(items)
  local self = setmetatable({ amounts = {}, display = {}, craftable = {}, stall_ms = 0, offline = false, crafted = {} }, Storage)
  for _, it in ipairs(items or {}) do
    self.amounts[it.name] = (self.amounts[it.name] or 0) + (it.amount or it.count or 0)
    self.display[it.name] = it.displayName
    if it.craftable then self.craftable[it.name] = true end
  end
  return self
end

function Storage:amount(name) return self.amounts[name] or 0 end

function Storage:add(name, n)
  if n <= 0 then return 0 end
  self.amounts[name] = (self.amounts[name] or 0) + n
  return n
end

function Storage:remove(name, n)
  local have = self.amounts[name] or 0
  local removed = math.min(have, n)
  if removed <= 0 then return 0 end
  if have - removed == 0 then self.amounts[name] = nil else self.amounts[name] = have - removed end
  return removed
end

function Storage:set(name, n)
  if n <= 0 then self.amounts[name] = nil else self.amounts[name] = n end
end

function Storage:entry(name)
  local n = self.amounts[name] or 0
  local d = self.display[name] or pretty(name)
  return { name = name, amount = n, count = n, displayName = d, isCraftable = self.craftable[name] == true }
end

-- Sorted by name so every run lists in the same order.
function Storage:list()
  local names = {}
  for name in pairs(self.amounts) do names[#names + 1] = name end
  table.sort(names)
  local out = {}
  for i, name in ipairs(names) do out[i] = self:entry(name) end
  return out
end

function Storage:list_craftable()
  local names = {}
  for name in pairs(self.craftable) do names[#names + 1] = name end
  table.sort(names)
  local out = {}
  for i, name in ipairs(names) do out[i] = self:entry(name) end
  return out
end

-- For snapshots.
function Storage:state()
  return { amounts = self.amounts, display = self.display, craftable = self.craftable }
end

function Storage:load_state(s)
  self.amounts, self.display, self.craftable = s.amounts or {}, s.display or {}, s.craftable or {}
end

return Storage
