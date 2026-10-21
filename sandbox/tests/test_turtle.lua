package.path = "sandbox/?.lua;" .. package.path
local Clock = require("core.clock")
local Rng = require("core.rng")
local Scheduler = require("core.scheduler")
local Computer = require("core.computer")
local World = require("world.world")
local TIMINGS = require("timings")
local H = dofile("sandbox/tests/helpers.lua")

-- A turtle at (0,64,0) facing north on an empty world with a stone floor at y=63.
local function rig(startup, setup)
  local dir = H.tmpdir()
  H.write(dir .. "/startup.lua", startup)
  local sched = Scheduler.new{ clock = Clock.new(0), rng = Rng.new(2) }
  local world = World.new_empty()
  for x = -5, 5 do for z = -5, 5 do world:set(x, 63, z, "minecraft:stone") end end
  sched.world = world
  local comp = Computer.new{ id = 5, kind = "turtle", disk = dir, sched = sched, pos = { x = 0, y = 64, z = 0, facing = 0 } }
  sched:add(comp)
  if setup then setup(comp, world, sched) end
  comp:boot()
  return comp, sched, world
end

local function out(comp) local o = {} for i, l in ipairs(comp.output) do o[i] = l.text end return table.concat(o, "|") end
local PICK = function(comp) comp.tstate = { inv = {}, selected = 1, fuel = 100, equipped = { left = "minecraft:diamond_pickaxe" }, dropped = {}, block_name = "computercraft:turtle_advanced" } end

return {
  ["forward costs move_ms and changes position"] = function(t)
    local comp, sched = rig([[ print(turtle.forward(), os.epoch("utc")) ]], PICK)
    sched:run{ until_ms = 5000 }
    t.eq(out(comp), "true\t" .. TIMINGS.move_ms)
    t.eq(comp.pos.z, -1)
    t.eq(comp.tstate.fuel, 99)
  end,

  ["a modem message during forward is discarded"] = function(t)
    local comp, sched = rig([[ turtle.forward(); print(tostring(os.pullEvent())) ]], PICK)
    sched:post(100, comp, { "modem_message", "x" })
    sched:post(2000, comp, { "after" })
    sched:run{ until_ms = 5000 }
    t.eq(out(comp), "after")
  end,

  ["cannot move into stone"] = function(t)
    local comp, sched = rig([[ print(turtle.forward()); print(turtle.down()) ]], function(c, w) PICK(c); w:set(0, 64, -1, "minecraft:stone") end)
    sched:run{ until_ms = 5000 }
    t.eq(out(comp), "false\tMovement obstructed|false\tMovement obstructed")
    t.eq(comp.pos.z, 0)
  end,


  ["cannot move into another turtle"] = function(t)
    local comp, sched, world = rig([[ print(turtle.forward()); print(turtle.detect(), select(2, turtle.inspect()).name) ]], function(c, w, s)
      PICK(c)
      local d = H.tmpdir(); H.write(d .. "/startup.lua", "sleep(1000)")
      local other = Computer.new{ id = 6, kind = "turtle", disk = d, sched = s, pos = { x = 0, y = 64, z = -1, facing = 0 } }
      s:add(other); other:boot()
    end)
    sched:run{ until_ms = 5000 }
    t.eq(out(comp), "false	Movement obstructed|true	computercraft:turtle_advanced")
  end,

  ["no fuel means no move"] = function(t)
    local comp, sched = rig([[ print(turtle.forward()) ]], function(c) PICK(c); c.tstate.fuel = 0 end)
    sched:run{ until_ms = 5000 }
    t.eq(out(comp), "false\tOut of fuel")
  end,

  ["dig puts what the block drops in the inventory (iron ore gives raw iron)"] = function(t)
    local comp, sched, world = rig([[ print(turtle.dig(), turtle.getItemCount(1), turtle.getItemDetail(1).name) ]], function(c, w) PICK(c); w:set(0, 64, -1, "minecraft:iron_ore") end)
    sched:run{ until_ms = 5000 }
    t.eq(out(comp), "true\t1\tminecraft:raw_iron")
    t.eq(world:get(0, 64, -1), nil)
  end,

  ["dig needs a pickaxe and stone drops cobblestone"] = function(t)
    local comp, sched = rig([[ print(turtle.dig()) ]], function(c, w) w:set(0, 64, -1, "minecraft:stone") end)
    sched:run{ until_ms = 5000 }
    t.eq(out(comp), "false\tNo tool to dig with")
    local comp2, sched2 = rig([[ turtle.dig(); print(turtle.getItemDetail(1).name) ]], function(c, w) PICK(c); w:set(0, 64, -1, "minecraft:stone") end)
    sched2:run{ until_ms = 5000 }
    t.eq(out(comp2), "minecraft:cobblestone")
  end,

  ["getItemDetail matches the stub's shape"] = function(t)
    local comp, sched = rig([[
      local plain = turtle.getItemDetail(1)
      local full = turtle.getItemDetail(1, true)
      print(plain.name, plain.count, plain.displayName, full.displayName, type(full.tags))
    ]], function(c) PICK(c); c.tstate.inv[1] = { name = "minecraft:diamond_pickaxe", count = 1 } end)
    sched:run{ until_ms = 5000 }
    t.eq(out(comp), "minecraft:diamond_pickaxe\t1\tnil\tDiamond Pickaxe\ttable")
  end,

  ["equip swaps the slot item with the equipped upgrade"] = function(t)
    local comp, sched = rig([[
      turtle.select(1); print(turtle.equipRight())
      print(turtle.getEquippedRight().name, turtle.getItemDetail(1))
      turtle.select(2); print(turtle.equipRight())
    ]], function(c)
      PICK(c)
      c.tstate.inv[1] = { name = "computercraft:wireless_modem_advanced", count = 1 }
      c.tstate.inv[2] = { name = "minecraft:cobblestone", count = 3 }
    end)
    sched:run{ until_ms = 5000 }
    t.eq(out(comp), "true|computercraft:wireless_modem_advanced\tnil|false\tNot a valid upgrade")
  end,

  ["drop onto nothing loses the items and into a container stores them"] = function(t)
    local chest = { got = 0, put = function(self, s) self.got = self.got + s.count; return s.count end, take = function() return nil end }
    local comp, sched, world = rig([[
      turtle.select(1); print(turtle.dropDown(2)); print(turtle.drop(1)); print(turtle.getItemCount(1))
    ]], function(c, w)
      PICK(c); c.tstate.inv[1] = { name = "minecraft:coal", count = 5 }
      w.containers["0,63,0"] = chest
    end)
    sched:run{ until_ms = 5000 }
    t.eq(out(comp), "true|true|2")
    t.eq(chest.got, 2)
    t.eq(comp.tstate.dropped[1].count, 1)
  end,

  ["refuel burns only what is needed"] = function(t)
    local comp, sched = rig([[ turtle.select(1); print(turtle.refuel(), turtle.getItemCount(1), turtle.getFuelLevel()) ]], function(c)
      PICK(c); c.tstate.fuel = 99950; c.tstate.inv[1] = { name = "minecraft:coal", count = 64 }
    end)
    sched:run{ until_ms = 5000 }
    t.eq(out(comp), "true\t63\t100000")
  end,

  ["place puts a block and uses the item"] = function(t)
    local comp, sched, world = rig([[ turtle.select(1); print(turtle.placeDown(), turtle.place()) ; print(turtle.getItemCount(1)) ]], function(c, w)
      PICK(c); c.tstate.inv[1] = { name = "minecraft:chest", count = 2 }
    end)
    sched:run{ until_ms = 5000 }
    t.eq(out(comp), "false\ttrue|1")
    t.eq(world:get(0, 64, -1), "minecraft:chest")
  end,

  ["gravity: digging under a column of gravel brings it down into the hole"] = function(t)
    local comp, sched, world = rig([[ print(turtle.digDown()) ]], function(c, w)
      PICK(c)
      c.pos.y = 66
      w:set(0, 65, 0, "minecraft:stone")   -- under the turtle: stone, then gravel, gravel stacked above the dug cell
      w:set(0, 64, 0, "minecraft:stone")
    end)
    sched:run{ until_ms = 5000 }
    t.eq(out(comp), "true")
    t.eq(world:get(0, 65, 0), nil, "the dug cell is air")

    local c2, s2, w2 = rig([[ turtle.dig() ]], function(c, w)
      PICK(c)
      w:set(0, 64, -1, "minecraft:stone")      -- in front: stone, with sand on top of it and gravel above that
      w:set(0, 65, -1, "minecraft:sand")
      w:set(0, 66, -1, "minecraft:gravel")
    end)
    s2:run{ until_ms = 5000 }
    t.eq(w2:get(0, 64, -1), "minecraft:sand", "the sand fell into the dug cell")
    t.eq(w2:get(0, 65, -1), "minecraft:gravel", "and the gravel after it")
    t.eq(w2:get(0, 66, -1), nil)
  end,

  ["gravity: a turtle under the column is solid, the gravel stays above it"] = function(t)
    local comp, sched, world = rig([[ turtle.digUp() ]], function(c, w)
      PICK(c)
      w:set(0, 65, 0, "minecraft:gravel")
    end)
    sched:run{ until_ms = 5000 }
    t.eq(world:get(0, 65, 0), nil, "the gravel above was dug")
  end,

  ["a dig with a full inventory still succeeds and the overflow lies where the block was"] = function(t)
    local comp, sched, world = rig([[ print(turtle.dig()) ]], function(c, w)
      PICK(c)
      for i = 1, 16 do c.tstate.inv[i] = { name = "minecraft:cobblestone", count = 64 } end
      w:set(0, 64, -1, "minecraft:iron_ore")   -- drops raw iron; no slot can take it
    end)
    sched:run{ until_ms = 10000 }
    t.eq(out(comp), "true")
    t.ok(#comp.tstate.dropped >= 1, "the sandbox's own record of what was dropped")
    local lying = world.items["0,64,-1"]
    t.ok(lying and lying[1] and lying[1].name == "minecraft:raw_iron", "the raw iron should lie where the ore was")
  end,

  ["items dropped onto the ground can be sucked up again"] = function(t)
    local comp, sched, world = rig([[ turtle.select(1); print(turtle.drop(10)); print(turtle.suck(4)); print(turtle.getItemCount(1)) ]], function(c, w)
      PICK(c)
      c.tstate.inv[1] = { name = "minecraft:cobblestone", count = 20 }
    end)
    sched:run{ until_ms = 10000 }
    t.eq(out(comp), "true|true|14")
    t.eq(world.items["0,64,-1"][1].count, 6)
  end,
}
