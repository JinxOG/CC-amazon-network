-- A small deterministic world to build and test the simulator on, before the real world copy is read.
--   terrain: bedrock at y=-64, stone to y=60, dirt 61-62, grass at 63 (so a turtle stands at y=64)
--   base:    48x48 around (0,64,0), always loaded; the dock and the depot sit inside it
--   areas:   three 64x64 mining areas east of the base with ore veins
--   gps:     four hosts high above the base. Not all at one height: four coplanar hosts leave a mirror
--            solution that a fifth cannot break.
local World = require("world.world")
local Rng = require("core.rng")

local Synth = {}

local ORES = {
  { name = "minecraft:coal_ore", veins = 30 },
  { name = "minecraft:iron_ore", veins = 30 },
  { name = "create:zinc_ore", veins = 16 },
  { name = "minecraft:diamond_ore", veins = 8 },
}

local STEPS = { { 1, 0, 0 }, { -1, 0, 0 }, { 0, 1, 0 }, { 0, -1, 0 }, { 0, 0, 1 }, { 0, 0, -1 } }

function Synth.generate(seed)
  local rng = Rng.new(seed or 1)
  local meta = {
    terrain = { bottom = -64, stone_top = 60, soil_top = 63 },
    base_loaded = { { -24, -24, 23, 23 } },
    dock = { x = 0, y = 64, z = 0 },
    depot = { x = 8, y = 64, z = 0 },
    spawn = { x = 0, y = 64, z = 0 },
    areas = {},
    gps_hosts = { { 24, 255, 24 }, { -24, 255, 24 }, { 24, 255, -24 }, { -24, 250, -24 } },
    synthetic_seed = seed or 1,
  }
  local world = World.new_empty(meta)

  for i = 1, 3 do
    local x1 = 80 * i
    local area = { name = "Z" .. i, x1 = x1, x2 = x1 + 63, z1 = -32, z2 = 31, ymin = -50, ymax = 50 }
    meta.areas[i] = area
    local r = rng:fork("area" .. i)
    for _, ore in ipairs(ORES) do
      for _ = 1, ore.veins do
        local x = r:int(area.x1, area.x2)
        local y = r:int(area.ymin, area.ymax)
        local z = r:int(area.z1, area.z2)
        for _ = 1, r:int(5, 10) do
          if x >= area.x1 and x <= area.x2 and z >= area.z1 and z <= area.z2 and y >= area.ymin and y <= area.ymax
              and world:get(x, y, z) == "minecraft:stone" then
            world:set(x, y, z, ore.name)
          end
          local s = STEPS[r:int(1, #STEPS)]
          x, y, z = x + s[1], y + s[2], z + s[3]
        end
      end
    end
  end
  return world
end

return Synth
