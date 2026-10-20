-- Peripherals that are blocks next to a computer: the geo scanner a miner places under itself, the RS
-- bridge beside the warehouse, an ender chest on top of it. A computer sees them on its six sides.
-- Static attachments (comp:attach) win over blocks, so a scenario can always wire a peripheral directly.
local Ender = require("periph.ender")

local Blocks = {}

-- block name -> function(comp, x, y, z) returning a descriptor {type=, methods=, inventory=}
Blocks.factories = {}

function Blocks.register(block_name, factory) Blocks.factories[block_name] = factory end

local SIDES = { "back", "bottom", "front", "left", "right", "top" }
Blocks.SIDES = SIDES

local DX = { [0] = 0, 1, 0, -1 }
local DZ = { [0] = -1, 0, 1, 0 }

local function neighbour(comp, side)
  local p = comp.pos
  if not p or not p.x then return nil end
  local f = p.facing or 0
  if side == "top" then return p.x, p.y + 1, p.z end
  if side == "bottom" then return p.x, p.y - 1, p.z end
  local d
  if side == "front" then d = f
  elseif side == "back" then d = (f + 2) % 4
  elseif side == "right" then d = (f + 1) % 4
  elseif side == "left" then d = (f + 3) % 4
  else return nil end
  return p.x + DX[d], p.y, p.z + DZ[d]
end

Blocks.neighbour = neighbour

local function block_descriptor(comp, side)
  local world = comp.sched.world
  if not world then return nil end
  local x, y, z = neighbour(comp, side)
  if not x then return nil end
  local key = x .. "," .. y .. "," .. z
  local occupant = world.occupants and world.occupants[key]
  if occupant and occupant ~= comp and Blocks.occupant_descriptor then
    return Blocks.occupant_descriptor(comp, occupant)
  end
  local name = world:get(x, y, z)
  if not name then return nil end

  local cache = world.block_periph
  if not cache then cache = {}; world.block_periph = cache end
  local ckey = comp.id .. "@" .. key
  local hit = cache[ckey]
  if hit and hit.block == name then return hit.desc end

  local desc
  local container = world.containers and world.containers[key]
  if container and container.inventory then
    desc = { type = name, methods = Ender.peripheral_methods(container.inventory), inventory = container.inventory }
  elseif Blocks.factories[name] then
    desc = Blocks.factories[name](comp, x, y, z)
  end
  if desc then cache[ckey] = { block = name, desc = desc } end
  return desc
end

-- The descriptor of the peripheral called `name` as seen by `comp`, or nil.
function Blocks.lookup(comp, name)
  local static = comp.peripherals[name]
  if static then return static end
  for _, s in ipairs(SIDES) do
    if s == name then return block_descriptor(comp, name) end
  end
  return nil
end

-- Every peripheral name `comp` can currently see, sorted.
function Blocks.names(comp)
  local seen, out = {}, {}
  for name in pairs(comp.peripherals) do seen[name] = true; out[#out + 1] = name end
  for _, s in ipairs(SIDES) do
    if not seen[s] and block_descriptor(comp, s) then out[#out + 1] = s end
  end
  table.sort(out)
  return out
end

return Blocks
