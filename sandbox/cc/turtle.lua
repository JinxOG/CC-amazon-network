-- The turtle API on the world model, with CC timing and CC's refusals.
-- Fidelity fixes are carried over from tests/stub_cc.lua (copy in sandbox/vendor/stub_cc_copy.lua):
--   * the plain getItemDetail has no displayName/tags/nbt; only the detailed form does
--   * drop() onto nothing loses the items; onto a container puts them inside it
--   * dig() needs a pickaxe equipped; refuel burns only what fills the tank
--   * transferTo never manufactures items or overflows a 64-stack
--   * equip swaps the slot's item with the equipped upgrade
local CCEnv = require("cc.env")
local TIMINGS = require("timings")

local M = {}

local FUEL_LIMIT = 100000
local FUEL_PER_ITEM = {
  ["minecraft:coal"] = 80, ["minecraft:charcoal"] = 80, ["minecraft:coal_block"] = 800,
  ["minecraft:lava_bucket"] = 1000, ["minecraft:blaze_rod"] = 120,
}
local UPGRADES = {
  ["minecraft:diamond_pickaxe"] = true,
  ["minecraft:netherite_pickaxe"] = true,
  ["computercraft:wireless_modem_advanced"] = true,
  ["computercraft:wireless_modem_normal"] = true,
  ["advancedperipherals:chunk_controller"] = true,
}
local Drops = require("world.drops")
local DROPS = {
  ["minecraft:stone"] = "minecraft:cobblestone",
  ["minecraft:grass_block"] = "minecraft:dirt",
  ["minecraft:deepslate"] = "minecraft:cobbled_deepslate",
}
local NOT_BLOCKS = { "pickaxe$", "sword$", "shovel$", "axe$", "hoe$", ":coal$", ":charcoal$", ":diamond$", ":emerald$",
  "ingot$", "nugget$", "^[%w_]+:raw_", "dust$", ":stick$", "bucket$", "wireless_modem", "chunk_controller" }

-- facing: 0 north (-z), 1 east (+x), 2 south (+z), 3 west (-x)
local DX = { [0] = 0, 1, 0, -1 }
local DZ = { [0] = -1, 0, 1, 0 }

local function pretty(name)
  local path = name:match(":(.+)$") or name
  return (path:gsub("_", " "):gsub("(%a)([%w]*)", function(a, b) return a:upper() .. b end))
end

local function copy_stack(s, count)
  local o = {}
  for k, v in pairs(s) do o[k] = v end
  o.count = count or s.count
  return o
end

local function is_pickaxe(name) return name and name:find("_pickaxe$") ~= nil end

local function placeable(name)
  for _, p in ipairs(NOT_BLOCKS) do if name:find(p) then return false end end
  return true
end

local function key(x, y, z) return x .. "," .. y .. "," .. z end

-- Moving a turtle, from the simulator (teleport, import) or from itself, keeps the occupancy map true.
function M.set_pos(comp, x, y, z, facing)
  local world = comp.sched.world
  local p = comp.pos
  if world and world.occupants then
    if p.x then world.occupants[key(p.x, p.y, p.z)] = nil end
    world.occupants[key(x, y, z)] = comp
  end
  p.x, p.y, p.z = x, y, z
  if facing ~= nil then p.facing = facing end
  if comp.sched.loading then comp.sched.loading:update_pos(comp) end
end

function M.install(comp, E)
  if comp.kind ~= "turtle" then return end
  local sched = comp.sched
  local world = sched.world
  comp.pos = comp.pos or { x = 0, y = 64, z = 0, facing = 0 }
  local st = comp.tstate
  if not st then
    st = { inv = {}, selected = 1, fuel = FUEL_LIMIT, equipped = {}, dropped = {}, block_name = "computercraft:turtle_advanced" }
    comp.tstate = st
    if world and world.occupants then world.occupants[key(comp.pos.x, comp.pos.y, comp.pos.z)] = comp end
  end
  local sync_modem = require("periph.modem").track_equipment(comp)
  comp.on_equipment_changed = function(c)
    sync_modem(c)
    if sched.loading then sched.loading:update_pos(c, true) end
  end
  local T = {}

  local function scale() return sched.action_scale or 1 end
  -- an action that takes game time: other events arriving meanwhile are lost, as in CC
  -- the name of the API function being called, so the turtle_reboot fault can hit a chosen action
  local current_action
  local function timed(ms, fn)
    local action = current_action
    return CCEnv.main_thread_call(comp, ms * scale(), function()
      local r = table.pack(fn())
      local armed = comp.reboot_on_action
      if armed and action and action:sub(1, #armed) == armed then
        -- the action's effect has happened, but the program never hears of it: the nastiest moment to reboot
        comp.reboot_on_action = nil
        sched:trace(comp.name .. " fault: reboot during " .. action)
        comp:reboot()
      end
      return (table.unpack or unpack)(r, 1, r.n)
    end)
  end

  local function pos_ahead(dir)
    local p = comp.pos
    if dir == "up" then return p.x, p.y + 1, p.z end
    if dir == "down" then return p.x, p.y - 1, p.z end
    local f = p.facing
    if dir == "back" then return p.x - DX[f], p.y, p.z - DZ[f] end
    return p.x + DX[f], p.y, p.z + DZ[f]
  end

  local function block_at(x, y, z)
    local occ = world.occupants and world.occupants[key(x, y, z)]
    if occ and occ ~= comp then return occ.tstate and occ.tstate.block_name or "computercraft:computer_advanced" end
    return world:get(x, y, z)
  end

  local function protected(x, y, z)
    for _, b in ipairs(world:meta().protected or {}) do
      if x >= b[1] and x <= b[4] and y >= b[2] and y <= b[5] and z >= b[3] and z <= b[6] then return true end
    end
    return false
  end

  -- gravity: when a block is removed, sand, gravel and concrete powder above it fall until they rest on something (a
  -- turtle counts as solid). Instant here; in the game it takes a couple of ticks. Unverified - needs the local test server.
  local function gravity_block(name)
    return name ~= nil and (name == "minecraft:sand" or name == "minecraft:red_sand" or name == "minecraft:gravel"
      or name:find("concrete_powder$") ~= nil)
  end
  local no_gravity = os.getenv("SANDBOX_NO_GRAVITY") ~= nil   -- experiments only: how much does gravity change a job
  local function settle(x, y, z)
    if no_gravity then return end
    local yy = y + 1
    while true do
      local n = world:get(x, yy, z)
      if (world.occupants and world.occupants[key(x, yy, z)]) or not gravity_block(n) then break end
      world:set(x, yy, z, nil)
      local land = yy
      while land - 1 >= -64 and block_at(x, land - 1, z) == nil do land = land - 1 end
      world:set(x, land, z, n)
      yy = yy + 1
    end
  end

  -- item entities lying on the ground (overflow from a dig, drops with no inventory to receive them)
  local function ground_put(x, y, z, stack)
    local list = world.items[key(x, y, z)]
    if not list then list = {}; world.items[key(x, y, z)] = list end
    list[#list + 1] = { name = stack.name, count = stack.count }
  end

  -- inventory --------------------------------------------------------------------------------
  local function max_count(s) return s.maxCount or 64 end

  -- two stacks merge only when they are the same item with the same data (an ender chest's frequency,
  -- a turtle's identity), not merely the same name
  local function same_item(a, b)
    return a.name == b.name and a.frequency == b.frequency and a.computer_id == b.computer_id
      and a.displayName == b.displayName
  end

  -- Picked-up items go into the inventory starting at the SELECTED slot and wrapping round: first onto
  -- matching stacks, then into empty slots (this is why a dug-up chest lands where the turtle was pointing).
  local function store(stack)  -- returns the part that did not fit
    local left = stack.count
    local start = st.selected
    for pass = 1, 2 do
      for k = 0, 15 do
        local s = (start - 1 + k) % 16 + 1
        local i = st.inv[s]
        if left > 0 then
          if pass == 1 and i and same_item(i, stack) and i.count < max_count(i) then
            local n = math.min(left, max_count(i) - i.count); i.count = i.count + n; left = left - n
          elseif pass == 2 and not i then
            local n = math.min(left, max_count(stack)); st.inv[s] = copy_stack(stack, n); left = left - n
          end
        end
      end
    end
    return left
  end

  local function slot_arg(s, fname)
    s = s or st.selected
    if type(s) ~= "number" or s < 1 or s > 16 or s ~= math.floor(s) then
      error(string.format("bad argument #1 to '%s' (slot number %s out of range)", fname, tostring(s)), 3)
    end
    return s
  end

  function T.select(s) s = slot_arg(s, "select"); return timed(TIMINGS.select_ms or TIMINGS.turtle_cmd_ms, function() st.selected = s; return true end) end
  function T.getSelectedSlot() return st.selected end
  function T.getItemCount(s) local i = st.inv[slot_arg(s, "getItemCount")]; return i and i.count or 0 end
  function T.getItemSpace(s)
    s = slot_arg(s, "getItemSpace"); local i = st.inv[s]
    return (i and max_count(i) or 64) - (i and i.count or 0)
  end
  function T.getItemDetail(s, detailed)
    s = slot_arg(s, "getItemDetail")
    local i = st.inv[s]
    if not i then return nil end
    local d = { name = i.name, count = i.count }
    if detailed then
      d.displayName = i.displayName or pretty(i.name)
      d.maxCount = max_count(i)
      d.tags = i.tags or {}
      d.nbt = i.nbt
      d.damage = i.damage
    end
    return d
  end
  function T.getFuelLevel() return st.fuel end
  function T.getFuelLimit() return FUEL_LIMIT end

  function T.transferTo(dest, n)
    dest = slot_arg(dest, "transferTo")
    return timed(TIMINGS.turtle_cmd_ms, function()
      if dest == st.selected then return true end
      local src = st.inv[st.selected]
      if not src then return false end
      n = n or src.count
      if n <= 0 then return true end
      local d = st.inv[dest]
      if d and not same_item(d, src) then return false end
      n = math.min(n, src.count)
      local space = max_count(src) - (d and d.count or 0)
      if space <= 0 then return false end
      local moved = math.min(n, space)
      if d then d.count = d.count + moved else st.inv[dest] = copy_stack(src, moved) end
      src.count = src.count - moved
      if src.count <= 0 then st.inv[st.selected] = nil end
      return true
    end)
  end

  function T.compareTo(slot)
    slot = slot_arg(slot, "compareTo")
    local a, b = st.inv[st.selected], st.inv[slot]
    if not a and not b then return true end
    return a ~= nil and b ~= nil and a.name == b.name
  end

  function T.refuel(n)
    return timed(TIMINGS.turtle_cmd_ms, function()
      local i = st.inv[st.selected]
      if not i then return false, "No items to combust" end
      local per = FUEL_PER_ITEM[i.name]
      if not per then return false, "Items not combustible" end
      -- burns only the items needed to reach the limit; the rest stay in the slot
      local need = math.ceil((FUEL_LIMIT - st.fuel) / per)
      local burn = math.min(i.count, n or i.count, need)
      st.fuel = math.min(st.fuel + burn * per, FUEL_LIMIT)
      i.count = i.count - burn
      if i.count <= 0 then st.inv[st.selected] = nil end
      return true
    end)
  end

  -- equipment --------------------------------------------------------------------------------
  local function equip(side)
    return timed(TIMINGS.turtle_cmd_ms, function()
      local item, cur = st.inv[st.selected], st.equipped[side]
      if item and not UPGRADES[item.name] then return false, "Not a valid upgrade" end
      st.equipped[side] = item and item.name or nil
      st.inv[st.selected] = cur and { name = cur, count = 1 } or nil
      if comp.on_equipment_changed then comp.on_equipment_changed(comp) end
      return true
    end)
  end
  function T.equipLeft() return equip("left") end
  function T.equipRight() return equip("right") end
  local function equipped_detail(side)
    local name = st.equipped[side]
    if not name then return nil end
    return { name = name, count = 1 }
  end
  function T.getEquippedLeft() return equipped_detail("left") end
  function T.getEquippedRight() return equipped_detail("right") end

  -- sensing ----------------------------------------------------------------------------------
  local function detect(dir)
    return timed(TIMINGS.turtle_cmd_ms, function()
      local x, y, z = pos_ahead(dir)
      return block_at(x, y, z) ~= nil
    end)
  end
  local function inspect(dir)
    return timed(TIMINGS.turtle_cmd_ms, function()
      local x, y, z = pos_ahead(dir)
      local b = block_at(x, y, z)
      if b then return true, { name = b, state = {}, tags = {} } end
      return false, "No block to inspect"
    end)
  end
  function T.detect() return detect("forward") end
  function T.detectUp() return detect("up") end
  function T.detectDown() return detect("down") end
  function T.inspect() return inspect("forward") end
  function T.inspectUp() return inspect("up") end
  function T.inspectDown() return inspect("down") end

  -- movement ---------------------------------------------------------------------------------
  local function move(dir, ms)
    -- a move that cannot happen (a block in the way, no fuel) fails after about 120 ms in real CC (T2 probe), not 400
    local bx, by, bz = pos_ahead(dir)
    if st.fuel <= 0 or protected(bx, by, bz) or block_at(bx, by, bz) ~= nil then ms = TIMINGS.blocked_move_ms or ms end
    return timed(ms, function()
      if st.fuel <= 0 then return false, "Out of fuel" end
      local x, y, z = pos_ahead(dir)
      if protected(x, y, z) then return false, "Movement obstructed" end
      if block_at(x, y, z) ~= nil then return false, "Movement obstructed" end
      st.fuel = st.fuel - 1
      M.set_pos(comp, x, y, z)
      return true
    end)
  end
  function T.forward() return move("forward", TIMINGS.move_ms) end
  function T.back() return move("back", TIMINGS.move_ms) end
  function T.up() return move("up", TIMINGS.up_ms) end
  function T.down() return move("down", TIMINGS.down_ms) end
  function T.turnLeft()
    return timed(TIMINGS.turn_ms, function() comp.pos.facing = (comp.pos.facing - 1) % 4; return true end)
  end
  function T.turnRight()
    return timed(TIMINGS.turn_ms, function() comp.pos.facing = (comp.pos.facing + 1) % 4; return true end)
  end

  -- digging and placing ----------------------------------------------------------------------
  local dig_rng
  local function dig(dir)
    -- real CC: breaking a block takes the full animation (384 ms for stone); a dig with nothing there fails in one tick
    local dx, dy, dz = pos_ahead(dir)
    return timed(block_at(dx, dy, dz) and TIMINGS.dig_ms or (TIMINGS.dig_air_ms or TIMINGS.turtle_cmd_ms), function()
      if not is_pickaxe(st.equipped.left) and not is_pickaxe(st.equipped.right) then return false, "No tool to dig with" end
      local x, y, z = pos_ahead(dir)
      local b = block_at(x, y, z)
      if not b then return false, "Nothing to dig here" end
      if b == "minecraft:bedrock" or protected(x, y, z) then return false, "Cannot break block" end
      local occupant = world.occupants and world.occupants[key(x, y, z)]
      if occupant then
        local picked = sched.hooks and sched.hooks.pickup and sched.hooks.pickup(comp, occupant)
        if not picked then return false, "Cannot break block" end
        local left = store(picked)
        if left > 0 then st.dropped[#st.dropped + 1] = { name = picked.name, count = left } end
        return true
      end
      local container = world.containers and world.containers[key(x, y, z)]
      local drops
      if container and container.as_item then drops = { container:as_item() }
      else
        dig_rng = dig_rng or sched.rng:fork("dig:" .. comp.name)
        drops = Drops.roll(b, dig_rng) or { { name = DROPS[b] or b, count = 1 } }
      end
      world:set(x, y, z, nil)
      if world.containers then world.containers[key(x, y, z)] = nil end
      for _, drop in ipairs(drops) do
        local left = store(drop)
        if left > 0 then
          st.dropped[#st.dropped + 1] = { name = drop.name, count = left }
          ground_put(x, y, z, { name = drop.name, count = left })   -- the overflow lies where the block was
        end
      end
      settle(x, y, z)
      return true
    end)
  end
  function T.dig() return dig("forward") end
  function T.digUp() return dig("up") end
  function T.digDown() return dig("down") end

  local function place(dir)
    return timed(TIMINGS.place_ms, function()
      local i = st.inv[st.selected]
      if not i then return false, "No items to place" end
      if not placeable(i.name) then return false, "Cannot place item here" end
      local x, y, z = pos_ahead(dir)
      if block_at(x, y, z) ~= nil then return false, "Cannot place block here" end
      if protected(x, y, z) then return false, "Cannot place block here" end
      local placed_name, err = i.name, nil
      if sched.hooks and sched.hooks.place then
        local handled, hname, herr = sched.hooks.place(comp, copy_stack(i, 1), x, y, z, dir)
        if handled then
          if hname == nil then return false, herr or "Cannot place block here" end
          placed_name = hname
        end
      end
      if placed_name then world:set(x, y, z, placed_name) end
      i.count = i.count - 1
      if i.count <= 0 then st.inv[st.selected] = nil end
      return true
    end)
  end
  function T.place() return place("forward") end
  function T.placeUp() return place("up") end
  function T.placeDown() return place("down") end

  function T.attack() return timed(TIMINGS.attack_ms, function() return false, "Nothing to attack here" end) end
  T.attackUp, T.attackDown = T.attack, T.attack

  -- containers: suck and drop ----------------------------------------------------------------
  local function drop(dir, n)
    return timed(TIMINGS.drop_ms or TIMINGS.turtle_cmd_ms, function()
      local i = st.inv[st.selected]
      if not i then return false, "No items to drop" end
      local moved = math.min(n or i.count, i.count)
      if moved <= 0 then return false, "No items to drop" end
      local x, y, z = pos_ahead(dir)
      local container = world.containers and world.containers[key(x, y, z)]
      if container then
        moved = container:put(copy_stack(i, moved))
        if moved <= 0 then return false, "No space for items" end
      else
        -- no inventory there: the items hit the ground (item entities a later suck can pick up)
        st.dropped[#st.dropped + 1] = { name = i.name, count = moved }
        ground_put(x, y, z, { name = i.name, count = moved })
      end
      i.count = i.count - moved
      if i.count <= 0 then st.inv[st.selected] = nil end
      return true
    end)
  end
  function T.drop(n) return drop("forward", n) end
  function T.dropUp(n) return drop("up", n) end
  function T.dropDown(n) return drop("down", n) end

  local function suck(dir, n)
    return timed(TIMINGS.suck_ms or TIMINGS.turtle_cmd_ms, function()
      local x, y, z = pos_ahead(dir)
      local container = world.containers and world.containers[key(x, y, z)]
      if not container then
        -- item entities in the cell in front
        local list = world.items[key(x, y, z)]
        local dest = st.inv[st.selected]
        if not list or #list == 0 then return false, "No items to take" end
        local room = (dest and max_count(dest) or 64) - (dest and dest.count or 0)
        local first = list[1]
        if room <= 0 or (dest and dest.name ~= first.name) then return false, "No space for items" end
        local take = math.min(n or 64, room, first.count)
        first.count = first.count - take
        if first.count <= 0 then table.remove(list, 1) end
        if dest then dest.count = dest.count + take else st.inv[st.selected] = { name = first.name, count = take } end
        return true
      end
      local dest = st.inv[st.selected]
      local room = (dest and max_count(dest) or 64) - (dest and dest.count or 0)
      if room <= 0 then return false, "No space for items" end
      local stack = container:take(math.min(n or 64, room), dest and dest.name or nil)
      if not stack or stack.count <= 0 then return false, "No items to take" end
      if dest then dest.count = dest.count + stack.count else st.inv[st.selected] = stack end
      return true
    end)
  end
  function T.suck(n) return suck("forward", n) end
  function T.suckUp(n) return suck("up", n) end
  function T.suckDown(n) return suck("down", n) end

  comp.action_counts = comp.action_counts or {}
  for name, fn in pairs(T) do
    T[name] = function(...)
      current_action = name
      local counts = comp.action_counts
      counts[name] = (counts[name] or 0) + 1   -- how many times the program called each turtle function (read by scenarios)
      return fn(...)
    end
  end

  E.turtle = CCEnv.api(comp, "turtle", T)
end

return M
