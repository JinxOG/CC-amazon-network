-- A small deterministic world to build and test the simulator on, before the real world copy is read.
-- It is built around the real depot coordinates in waypoints.lua, because fleet files are never edited:
--   terrain: bedrock at y=-64, stone to y=65, grass at y=66 (so a turtle stands at y=67, the depot floor)
--   depot:   the dispatch and arrivals holes are shafts from the floor down to y=60 (waypoints.lua)
--   base:    always loaded, covers the depot and the server rooms
--   areas:   three 64x64 mining areas east of the depot with ore veins between y = -58 and 32 (the miner scans at 16, 0, -32 and -52, radius 16)
--   gps:     four hosts high above the depot. Not all at one height: four coplanar hosts leave a mirror
--            solution that a fifth cannot break.
local World = require("world.world")
local Rng = require("core.rng")

local Synth = {}

local ORES = {
  { name = "minecraft:coal_ore", veins = 80 },
  { name = "minecraft:iron_ore", veins = 80 },
  { name = "create:zinc_ore", veins = 40 },
  { name = "minecraft:diamond_ore", veins = 20 },
}

local STEPS = { { 1, 0, 0 }, { -1, 0, 0 }, { 0, 1, 0 }, { 0, -1, 0 }, { 0, 0, 1 }, { 0, 0, -1 } }

Synth.FLOOR_Y = 67

function Synth.generate(seed)
  local rng = Rng.new(seed or 1)
  local meta = {
    terrain = { bottom = -64, stone_top = 65, soil_top = 66 },
    base_loaded = { { 110, -2840, 260, -2760 } },
    dock = { x = 157, y = 67, z = -2806 },
    spawn = { x = 157, y = 67, z = -2806 },
    areas = {},
    gps_hosts = { { 150, 120, -2800 }, { 235, 120, -2800 }, { 150, 120, -2780 }, { 235, 110, -2820 } },
    synthetic_seed = seed or 1,
  }
  local world = World.new_empty(meta)

  -- the two shafts of the depot: air from the grass down to the underground travel level
  for _, hole in ipairs({ { 143, -2813 }, { 228, -2782 } }) do
    for y = 60, 66 do world:set(hole[1], y, hole[2], nil) end
  end

  for i = 1, 3 do
    local x1 = 300 * i + 100
    local area = { name = "Z" .. i, x1 = x1, x2 = x1 + 63, z1 = -2832, z2 = -2769, ymin = -58, ymax = 32 }
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

-- The computers of the synthetic fleet. `opts.miners` workers (each carrying a loader) and the shared
-- infrastructure. waypoints supplies the dock positions, so the fleet starts where the depot expects it.
function Synth.layout(waypoints, opts)
  opts = opts or {}
  local n_miners = opts.miners or 2
  local L = {}
  local function add(spec) L[#L + 1] = spec; return spec end

  -- GPS hosts
  local hosts = { { 150, 120, -2800 }, { 235, 120, -2800 }, { 150, 120, -2780 }, { 235, 110, -2820 } }
  for i, h in ipairs(hosts) do add{ id = 100 + i, kind = "gps_host", pos = { x = h[1], y = h[2], z = h[3] } } end

  -- dispatch server: wireless modem, an RS bridge on its right, the cloud store behind it
  add{ id = 1, kind = "computer", role = "server", label = "dispatch", pos = { x = 170, y = 67, z = -2820, facing = 0 },
    modems = { "left" }, kv = { "back" },
    blocks = { { side = "right", block = "advancedperipherals:rs_bridge" } } }

  -- warehouse: modem, RS bridge, and the delivery ender chest on top ("top" is what warehouse.lua expects)
  add{ id = 2, kind = "computer", role = "warehouse", label = "warehouse", pos = { x = 176, y = 67, z = -2820, facing = 0 },
    modems = { "left" },
    blocks = { { side = "right", block = "advancedperipherals:rs_bridge" },
               { side = "top", block = "enderstorage:ender_chest", freq = "delivery" } } }

  -- miners and the loaders they carry
  local docks = waypoints.docks.DELIVERY
  for i = 1, n_miners do
    local d = docks[i]
    local miner_id, loader_id = 10 + i, 20 + i
    local loader_label = "loader_" .. i
    add{ id = loader_id, kind = "turtle", role = "loader", label = loader_label, carried = true,
      turtle = { equipped = { left = "computercraft:wireless_modem_advanced", right = "advancedperipherals:chunk_controller" } } }
    add{ id = miner_id, kind = "turtle", role = "miner", pos = { x = d.x, y = d.y, z = d.z, facing = 0 },
      turtle = {
        equipped = { left = "computercraft:wireless_modem_advanced", right = "advancedperipherals:chunk_controller" },
        inv = {
          [1] = { name = "advancedperipherals:geo_scanner", count = 1 },
          [2] = { name = "computercraft:turtle_advanced", count = 1, displayName = loader_label, computer_id = loader_id },
          [3] = { name = "minecraft:diamond_pickaxe", count = 1 }, -- the stowed tool; chunky is equipped while flying
          [15] = { name = "enderstorage:ender_chest", count = 1, frequency = "fuel" },
          [16] = { name = "enderstorage:ender_chest", count = 1, frequency = "ore" },
        } } }
  end
  return L
end

return Synth
