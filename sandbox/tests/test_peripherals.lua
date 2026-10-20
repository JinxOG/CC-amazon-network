package.path = "sandbox/?.lua;" .. package.path
local Clock = require("core.clock")
local Rng = require("core.rng")
local Scheduler = require("core.scheduler")
local Computer = require("core.computer")
local World = require("world.world")
local Storage = require("periph.storage")
local Ender = require("periph.ender")
local KV = require("periph.kv_storage")
local RsBridge = require("periph.rs_bridge")
local TIMINGS = require("timings")
local H = dofile("sandbox/tests/helpers.lua")

local function setup()
  local sched = Scheduler.new{ clock = Clock.new(0), rng = Rng.new(9) }
  sched.world = World.new_empty()
  sched.storage = Storage.new({ { name = "minecraft:iron_ore", amount = 120, displayName = "Iron Ore" },
                                { name = "minecraft:coal", amount = 500, craftable = true } })
  sched.kv = KV.new(nil)
  sched.ender = Ender.new(sched, sched.storage)
  sched.ender:install_hook(sched)
  return sched
end

local function computer(sched, id, kind, startup, pos)
  local dir = H.tmpdir()
  H.write(dir .. "/startup.lua", startup)
  local c = Computer.new{ id = id, kind = kind, disk = dir, sched = sched, pos = pos or { x = 0, y = 64, z = 0, facing = 0 } }
  sched:add(c)
  return c
end

local function out(comp) local o = {} for i, l in ipairs(comp.output) do o[i] = l.text end return table.concat(o, "|") end

return {
  ["scan returns relative positions within radius"] = function(t)
    local sched = setup()
    -- a scanner block at (0,63,0) below a turtle at (0,64,0)
    sched.world:set(0, 63, 0, "advancedperipherals:geo_scanner")
    sched.world:set(2, 63, -1, "minecraft:iron_ore")
    sched.world:set(-3, 60, 4, "minecraft:stone")
    sched.world:set(20, 63, 0, "minecraft:diamond_ore") -- outside radius 5
    local c = computer(sched, 1, "turtle", [[
      local sc = peripheral.wrap("bottom")
      local r = sc.scan(5)
      local found = {}
      for _, b in ipairs(r) do found[#found + 1] = b.name .. "@" .. b.x .. "," .. b.y .. "," .. b.z end
      table.sort(found); print(#r, table.concat(found, ";"))
      print(type(r[1].tags))
    ]])
    c:boot(); sched:run{ until_ms = 10000 }
    t.eq(out(c), "2\tminecraft:iron_ore@2,0,-1;minecraft:stone@-3,-3,4|table")
  end,

  ["scan yields for scan_ms"] = function(t)
    local sched = setup()
    sched.world:set(0, 63, 0, "advancedperipherals:geo_scanner")
    local c = computer(sched, 1, "turtle", [[ local a = os.epoch("utc"); peripheral.wrap("bottom").scan(2); print(os.epoch("utc") - a) ]])
    c:boot(); sched:run{ until_ms = 10000 }
    t.eq(out(c), tostring(TIMINGS.scan_ms))
  end,

  ["scan refuses a radius above the maximum"] = function(t)
    local sched = setup()
    sched.world:set(0, 63, 0, "advancedperipherals:geo_scanner")
    local c = computer(sched, 1, "turtle", [[ print(pcall(peripheral.wrap("bottom").scan, 17)) ]])
    c:boot(); sched:run{ until_ms = 10000 }
    t.ok(out(c):find("^false\t.*maximum"), out(c))
  end,

  ["listItems returns the storage contents with all four fields"] = function(t)
    local sched = setup()
    sched.world:set(1, 64, 0, "advancedperipherals:rs_bridge") -- to the computer's right (facing north)
    local c = computer(sched, 2, "computer", [[
      local rs = peripheral.find("rsBridge")
      local a = os.epoch("utc")
      local items = rs.listItems()
      print(#items, os.epoch("utc") - a)
      local i = items[2]
      print(i.name, i.amount, i.count, i.displayName)
    ]])
    c:boot(); sched:run{ until_ms = 10000 }
    t.eq(out(c), "2\t" .. TIMINGS.rs_list_ms .. "|minecraft:iron_ore\t120\t120\tIron Ore")
  end,

  ["rs_stall and rs_offline change listItems"] = function(t)
    local sched = setup()
    sched.world:set(1, 64, 0, "advancedperipherals:rs_bridge")
    sched.storage.stall_ms = 5000
    local c = computer(sched, 2, "computer", [[
      local rs = peripheral.find("rsBridge"); local a = os.epoch("utc"); rs.listItems(); print(os.epoch("utc") - a)
      print(pcall(rs.listItems))
    ]])
    c:boot(); sched:run{ until_ms = 6000 }
    sched.storage.offline = true
    sched:run{ until_ms = 20000 }
    t.eq(out(c):match("^(%d+)"), tostring(TIMINGS.rs_list_ms + 5000))
    t.ok(out(c):find("false\t.*not connected"), out(c))
  end,

  ["kv survives a server reboot"] = function(t)
    local sched = setup()
    local c = computer(sched, 3, "computer", [[
      local kv = peripheral.wrap("back")
      local prior = kv.get("z:one")
      print(tostring(prior))
      kv.put("z:one", "value-one"); kv.put("z:two", "value-two")
      if not prior then os.reboot() end
    ]])
    KV.attach(c, "back")
    c:boot(); sched:run{ until_ms = 30000 }
    t.eq(out(c), "nil|value-one")
  end,

  ["kv list returns only matching keys through the index and rejects oversize values"] = function(t)
    local sched = setup()
    local c = computer(sched, 3, "computer", [[
      local kv = peripheral.wrap("back")
      kv.put("z:a", "1"); kv.put("z:b", "2"); kv.put("ix:c", "3"); kv.delete("z:a")
      print(table.concat(kv.list(), ","))
      print(pcall(kv.put, "big", string.rep("x", 500001)))
    ]])
    KV.attach(c, "back")
    c:boot(); sched:run{ until_ms = 30000 }
    t.ok(out(c):find("^ix:c,z:b|false\t.*exceeds limit"), out(c))
  end,

  ["kv saves to a file and reloads"] = function(t)
    local path = H.tmpdir() .. "/kv.lua"
    local kv = KV.new(path); kv:put("a", "1"); kv:put("b", "2"); kv:flush()
    local back = KV.new(path)
    t.eq(back:get("b"), "2"); t.eq(#back:keys(), 2)
  end,

  ["fuel ender chest never runs out"] = function(t)
    local sched = setup()
    sched.ender:configure("fuel", "endless", { item = "minecraft:coal" })
    sched.world:set(0, 63, 0, "minecraft:stone")
    local c = computer(sched, 4, "turtle", [[
      turtle.select(1); print(turtle.placeDown(), turtle.suckDown(), turtle.getItemCount(1))
    ]])
    c.tstate = { inv = { [1] = { name = "enderstorage:ender_chest", count = 1, frequency = "fuel" } }, selected = 1, fuel = 10,
      equipped = {}, dropped = {}, block_name = "x" }
    c.pos.y = 65
    -- nothing below at y=64: place there
    c:boot(); sched:run{ until_ms = 10000 }
    t.eq(out(c), "true\ttrue\t64")
    -- and again, many times
    local inv = sched.ender:inventory("fuel")
    for _ = 1, 1000 do t.ok(inv:take(64, "minecraft:coal"), "ran dry") end
  end,

  ["ore dropped in the ore chest arrives in storage after the delay"] = function(t)
    local sched = setup()
    sched.ender:configure("ore", "sink", { delay_ms = 5000 })
    local c = computer(sched, 4, "turtle", [[
      turtle.select(1); turtle.placeDown(); turtle.select(2); print(turtle.dropDown()); print(os.epoch("utc"))
    ]])
    c.tstate = { inv = { [1] = { name = "enderstorage:ender_chest", count = 1, frequency = "ore" },
                         [2] = { name = "minecraft:iron_ore", count = 30 } },
      selected = 1, fuel = 10, equipped = {}, dropped = {}, block_name = "x" }
    c.pos.y = 65
    c:boot(); sched:run{ until_ms = 3000 }
    t.eq(sched.storage:amount("minecraft:iron_ore"), 120, "not yet")
    sched:run{ until_ms = 20000 }
    t.eq(sched.storage:amount("minecraft:iron_ore"), 150)
    t.eq(c.tstate.dropped[1], nil, "nothing should be lost on the ground")
  end,

  ["warehouse can export to and clear an ender chest on top"] = function(t)
    local sched = setup()
    -- chest block above the warehouse computer, RS bridge to its right
    sched.world:set(0, 65, 0, "enderstorage:ender_chest")
    sched.world.containers["0,65,0"] = sched.ender:container("delivery", "enderstorage:ender_chest")
    sched.world:set(1, 64, 0, "advancedperipherals:rs_bridge")
    local c = computer(sched, 5, "computer", [[
      local rs = peripheral.find("rsBridge"); local ec = peripheral.wrap("top")
      print(rs.exportItem({ name = "minecraft:coal", count = 100 }, "top"))
      print(ec.size(), ec.list()[1].name, ec.list()[1].count)
      print(rs.importItem({ name = "minecraft:coal", count = 40 }, "top"))
      print(rs.getItem({ name = "minecraft:coal" }).amount)
    ]])
    c:boot(); sched:run{ until_ms = 20000 }
    t.eq(out(c), "100|27\tminecraft:coal\t64|40|440")
  end,

  ["a chest block is a peripheral and a container for turtles"] = function(t)
    local sched = setup()
    local c = computer(sched, 6, "turtle", [[
      turtle.select(1); turtle.place(); turtle.select(2); turtle.drop(10)
      local chest = peripheral.wrap("front")
      print(peripheral.getType("front"), chest.list()[1].count)
      turtle.select(3); print(turtle.suck(4), turtle.getItemCount(3))
    ]])
    c.tstate = { inv = { [1] = { name = "minecraft:chest", count = 1 }, [2] = { name = "minecraft:coal", count = 30 }, [3] = { name = "minecraft:coal", count = 0 } },
      selected = 1, fuel = 10, equipped = {}, dropped = {}, block_name = "x" }
    c.tstate.inv[3] = nil
    c:boot(); sched:run{ until_ms = 20000 }
    t.eq(out(c), "minecraft:chest\t10|true\t4")
  end,
}
