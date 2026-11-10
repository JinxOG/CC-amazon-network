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

-- The computers of the synthetic fleet: GPS hosts, the dispatch server, the warehouse, and `workers` worker
-- turtles in all (opts.workers, default 15; opts.miners of them mine, each carrying a loader). The others are
-- delivery and support turtles, which sit idle at their docks unless the scenario gives them work. Docks come
-- from waypoints.lua, in the order the server hands them out (registration order), so the fleet starts
-- where the depot expects it.
-- PER-BAY DOCK TYPES (shakeout Task 2, 2026-11-10). Code with a waypoints.docks.MINER list puts each kind on its
-- own type's docks: delivery in DELIVERY (worker bay 1), support in SUPPORT (support bay 1), miners in MINER (the
-- other eight bays, worker side first). Code from before that has no MINER list and keeps the old placement --
-- miners first on the worker docks, then delivery -- so every existing run of older code is unchanged, unless
-- opts.per_bay asks for the per-bay layout there too: then the turtles stand where they would on new code (bay 1
-- delivery / support, miners in bays 2-5 of both sides), so a check on per-bay docks can fail on old code.
-- A kind with more turtles than its docks is an error here, not a turtle placed on nothing.
-- opts.miners_on_delivery = n: the first n miners stand on DELIVERY docks (worker bay 1), as the live base's miners
-- did before per-bay types; the server should move each to a MINER dock once.
function Synth.layout(waypoints, opts)
  opts = opts or {}
  local n_miners = opts.miners or 2
  local workers = opts.workers or 15
  local L = {}
  local function add(spec) L[#L + 1] = spec; return spec end

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

  -- the base air-traffic control computer (atc.lua, 2026-11-03), when the scenario asks for one: a modem and
  -- nothing else. Off by default, so every existing run and every run of older code is unchanged.
  if opts.atc then
    add{ id = 3, kind = "computer", role = "atc", label = "atc", pos = { x = 182, y = 67, z = -2820, facing = 0 },
      modems = { "left" } }
  end

  local MODEM, PICK = "computercraft:wireless_modem_advanced", "minecraft:diamond_pickaxe"
  local docks = waypoints.docks
  local lists, next_of = {}, {}
  if docks.MINER then
    lists = { delivery = docks.DELIVERY, support = docks.SUPPORT, miner = docks.MINER }
  elseif opts.per_bay then
    local function pick(list, want)
      local out = {}
      for _, d in ipairs(list) do if want(d.bay) then out[#out + 1] = d end end
      return out
    end
    local bay1 = function(b) return b == 1 end
    local other = function(b) return b ~= 1 end
    lists = { delivery = pick(docks.DELIVERY, bay1), support = pick(docks.SUPPORT, bay1),
              miner = pick(docks.DELIVERY, other) }
    for _, d in ipairs(pick(docks.SUPPORT, other)) do lists.miner[#lists.miner + 1] = d end
  else
    -- as always: miners and delivery share the worker docks, in that order
    lists = { delivery = docks.DELIVERY, support = docks.SUPPORT, miner = docks.DELIVERY }
    next_of[docks.DELIVERY] = 1
  end
  local function take(kind)
    local list = lists[kind]
    local n = next_of[list] or 1
    next_of[list] = n + 1
    return assert(list[n], string.format("synth: no %s dock left for %s turtle %d (%d docks of that type)",
      kind, kind, n, #list))
  end

  -- miners and the loaders they carry
  for i = 1, n_miners do
    local d = take((i <= (opts.miners_on_delivery or 0)) and "delivery" or "miner")
    -- IDs as they always were for a small fleet (so every existing run is unchanged); a big fleet (the capacity
    -- study's 150) gets its own ranges, or miner, loader, delivery and support IDs collide with each other and the GPS hosts.
    local loader_id, loader_label = (i <= 9) and (20 + i) or (2000 + i), "loader_" .. i
    add{ id = loader_id, kind = "turtle", role = "loader", label = loader_label, carried = true,
      turtle = { equipped = { left = MODEM, right = "advancedperipherals:chunk_controller" } } }
    add{ id = (i <= 9) and (10 + i) or (1000 + i), kind = "turtle", role = "miner", pos = { x = d.x, y = d.y, z = d.z, facing = 0 },
      turtle = {
        equipped = { left = MODEM, right = "advancedperipherals:chunk_controller" },
        inv = {
          [1] = { name = "advancedperipherals:geo_scanner", count = 1 },
          [2] = { name = "computercraft:turtle_advanced", count = 1, displayName = loader_label, computer_id = loader_id },
          [3] = { name = PICK, count = 1 }, -- the stowed tool; chunky is equipped while flying
          [15] = { name = "enderstorage:ender_chest", count = 1, frequency = "fuel" },
          [16] = { name = "enderstorage:ender_chest", count = 1, frequency = "ore" },
        } } }
  end

  -- the rest of the fleet: delivery turtles take worker docks, support turtles take support docks
  local remaining = workers - n_miners
  local n_delivery = opts.delivery or math.ceil(remaining / 2)
  local n_support = opts.support or (remaining - n_delivery)
  for i = 1, n_delivery do
    local d = take("delivery")
    add{ id = (i <= 19) and (30 + i) or (3000 + i), kind = "turtle", role = "delivery", pos = { x = d.x, y = d.y, z = d.z, facing = 0 },
      turtle = { equipped = { left = MODEM, right = PICK }, inv = {
        [15] = { name = "enderstorage:ender_chest", count = 1, frequency = "fuel" },
        [16] = { name = "enderstorage:ender_chest", count = 1, frequency = "delivery" } } } }
  end
  for i = 1, n_support do
    local d = take("support")
    add{ id = (i <= 49) and (50 + i) or (4000 + i), kind = "turtle", role = "support", pos = { x = d.x, y = d.y, z = d.z, facing = 0 },
      turtle = { equipped = { left = MODEM, right = PICK }, inv = {
        [16] = { name = "enderstorage:ender_chest", count = 1, frequency = "fuel" } } } }
  end
  -- opts.preset_docks: the server starts knowing who sits in which dock, as a real base does (its
  -- dock_assignments.dat survives restarts). Without it the server hands docks out in registration order, which is
  -- not the layout's order, and at boot nearly every turtle drives to a new dock at once -- a rush the live fleet
  -- never sees (W3, the ATC card, 2026-11-03).
  -- The file names each dock twice: by its place in the code's own typed lists ([type][index], all that code
  -- from before per-bay types reads) and by position (byPos "x,z", what code since reads). Each turtle is written
  -- under the list that holds the cell it stands on, whatever its kind: on old code a miner standing in a support
  -- bay is in its SUPPORT list, exactly as a live file would say.
  if opts.preset_docks then
    local byRole, byPos = { DELIVERY = {}, SUPPORT = {}, MINER = docks.MINER and {} or nil }, {}
    for _, spec in ipairs(L) do
      if spec.kind == "turtle" and spec.pos and not spec.carried then
        for key, list in pairs(docks) do
          for i, d in ipairs(list) do
            if d.x == spec.pos.x and d.z == spec.pos.z then
              byRole[key] = byRole[key] or {}
              byRole[key][i] = "node_" .. spec.id
              byPos[#byPos + 1] = string.format("[%q] = %q", d.x .. "," .. d.z, "node_" .. spec.id)
            end
          end
        end
      end
    end
    local parts = {}
    for role, slots in pairs(byRole) do
      local s = {}
      for i, name in pairs(slots) do s[#s + 1] = string.format("[%d] = %q", i, name) end
      parts[#parts + 1] = role .. " = { " .. table.concat(s, ", ") .. " }"
    end
    -- only code with per-bay types gets byPos: older code would read it as a dock type named "byPos" (harmless,
    -- but its runs are then not byte-identical to before)
    if docks.MINER then parts[#parts + 1] = "byPos = { " .. table.concat(byPos, ", ") .. " }" end
    for _, spec in ipairs(L) do
      if spec.role == "server" then spec.files = { ["dock_assignments.dat"] = "{ " .. table.concat(parts, ", ") .. " }" } end
    end
  end
  return L
end

return Synth
