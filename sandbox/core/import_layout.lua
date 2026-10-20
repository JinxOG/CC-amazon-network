-- Turns an imported world folder (see sandbox/tools/import_world.py) into what the runner needs:
-- the layout of computers, the Refined Storage contents, and the ender chest set-up.
local JSON = require("core.json")
local Blocks = require("periph.blocks")

local Import = {}

local MODEM_BLOCKS = {
  ["computercraft:wireless_modem_advanced"] = true,
  ["computercraft:wireless_modem_normal"] = true,
}

local function read(path)
  local f = io.open(path, "rb")
  if not f then return nil end
  local s = f:read("*a"); f:close(); return s
end

function Import.is_import(dir)
  local f = io.open(dir .. "/fleet.json", "rb")
  if f then f:close(); return true end
  return false
end

-- Sides of a computer at `pos` that have a wireless modem block against them.
local function modem_sides(world, pos)
  local probe = { pos = pos }
  local sides = {}
  for _, side in ipairs(Blocks.SIDES) do
    local x, y, z = Blocks.neighbour(probe, side)
    local b = x and world:get(x, y, z)
    if b and MODEM_BLOCKS[b] then sides[#sides + 1] = side end
  end
  return sides
end

-- Layout entries for Sim:add_computer / Fleet.provision.
function Import.layout(dir, world)
  local data = assert(JSON.decode(assert(read(dir .. "/fleet.json"), "no fleet.json in " .. dir)))
  local layout = {}
  for _, c in ipairs(data.fleet) do
    local spec = { id = c.id, kind = c.kind, role = c.role, installed = true, carried = c.carried, label = c.label,
      disk_from = dir .. "/disks/" .. c.id, on = c.on }
    if c.pos and not c.carried then
      spec.pos = { x = c.pos.x, y = c.pos.y, z = c.pos.z, facing = c.pos.facing }
      if c.kind == "computer" then spec.modems = modem_sides(world, spec.pos) end
    end
    if c.turtle then
      local inv = {}
      for slot, stack in pairs(c.turtle.inv or {}) do
        local s = {}
        for k, v in pairs(stack) do s[k] = v end
        inv[tonumber(slot)] = s
      end
      spec.turtle = { fuel = c.turtle.fuel, inv = inv, equipped = c.turtle.equipped or {} }
    end
    layout[#layout + 1] = spec
  end
  return layout, data.skipped
end

function Import.storage(dir)
  local text = read(dir .. "/storage.json")
  if not text then return nil end
  return JSON.decode(text)
end

-- Containers (ender chests) placed in the world, and which frequency is the fuel and ore chest.
function Import.install_chests(sim, dir)
  local meta = sim.world:meta()
  local ender = sim.sched.ender
  local f = meta.ender or {}
  if f.fuel then ender:configure(f.fuel, "endless", { item = "minecraft:coal" }) end
  if f.ore then ender:configure(f.ore, "sink", { delay_ms = ender.ore_chest_delay_ms }) end
  for _, c in ipairs(meta.containers or {}) do
    sim.world.containers[c.x .. "," .. c.y .. "," .. c.z] = ender:container(c.freq, c.block)
  end
end

return Import
