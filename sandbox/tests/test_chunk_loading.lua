package.path = "sandbox/?.lua;" .. package.path
local Clock = require("core.clock")
local Rng = require("core.rng")
local Scheduler = require("core.scheduler")
local Computer = require("core.computer")
local World = require("world.world")
local Loading = require("world.chunks_loaded")
local H = dofile("sandbox/tests/helpers.lua")

local CHUNKY = "advancedperipherals:chunk_controller"

local function setup()
  local sched = Scheduler.new{ clock = Clock.new(0), rng = Rng.new(6), trace = H.tmpdir() .. "/trace.log" }
  local world = World.new_empty({ base_loaded = { { -24, -24, 23, 23 } } })
  sched.world = world
  sched.loading = Loading.new{ world = world, sched = sched }
  return sched
end

local function turtle(sched, id, x, z, startup, chunky, identity)
  local dir = H.tmpdir()
  H.write(dir .. "/startup.lua", startup or "print('up') sleep(1000)")
  local c = Computer.new{ id = id, kind = "turtle", disk = dir, sched = sched, pos = { x = x, y = 64, z = z, facing = 1 } }
  c.tstate = { inv = {}, selected = 1, fuel = 100, equipped = chunky and { left = CHUNKY } or {}, dropped = {}, block_name = "x" }
  c.chunk_identity = identity
  sched:add(c)
  return c
end

local function out(comp) local o = {} for i, l in ipairs(comp.output) do o[i] = l.text end return table.concat(o, "|") end

return {
  ["base area is always loaded"] = function(t)
    local L = setup().loading
    t.ok(L:is_loaded(0, 0)); t.ok(L:is_loaded(-2, -2)); t.ok(L:is_loaded(1, 1))
    t.ok(not L:is_loaded(2, 0)); t.ok(not L:is_loaded(-3, 0))
  end,

  ["a chunky turtle loads its own chunk"] = function(t)
    local sched = setup()
    local c = turtle(sched, 1, 200, 200, nil, true)
    sched.loading:update_pos(c)
    t.ok(sched.loading:is_loaded(12, 12))
    t.eq(c.state, "off", "boot is the runner's job; the turtle was never frozen")
  end,

  ["a placed loader loads 3x3 around it"] = function(t)
    local sched = setup()
    sched.loading:add_ticket("loader-A", 10, 10, 1)
    for dx = -1, 1 do for dz = -1, 1 do t.ok(sched.loading:is_loaded(10 + dx, 10 + dz)) end end
    t.ok(not sched.loading:is_loaded(12, 10)); t.ok(not sched.loading:is_loaded(10, 8))
  end,

  ["leaving loaded ground shuts a computer down"] = function(t)
    local sched = setup()
    local c = turtle(sched, 1, 31, 0, "print('start'); turtle.forward(); print('moved')")
    sched.loading:recompute()
    c:boot()
    sched:run{ until_ms = 5000 }
    t.eq(c.state, "off")
    t.eq(out(c), "start", "nothing should run after the chunk unloaded")
    t.eq(c.pos.x, 32)
  end,

  ["reloading boots it from startup"] = function(t)
    local sched = setup()
    local c = turtle(sched, 1, 31, 0, "print('boot'); turtle.forward(); sleep(5)")
    c:boot(); sched:run{ until_ms = 5000 }
    t.eq(c.state, "off")
    sched.loading:add_ticket("loader-B", 2, 0, 0)
    t.ok(c.state ~= "off", "should have booted again")
    t.eq(out(c), "boot|boot")
  end,

  ["two copies of one loader hold only one ticket"] = function(t)
    local sched = setup()
    local a = turtle(sched, 1, 400, 0, nil, true, "uuid-1")
    local b = turtle(sched, 2, 800, 0, nil, true, "uuid-1")
    sched.loading:update_pos(a)
    t.ok(sched.loading:is_loaded(25, 0))
    sched.loading:update_pos(b)
    t.ok(sched.loading:is_loaded(50, 0), "the last placed copy holds the ticket")
    t.ok(not sched.loading:is_loaded(25, 0), "the first copy lost its ticket")
  end,

  ["forced unload overrides everything"] = function(t)
    local sched = setup()
    sched.loading:force_unload({ -24, -24, 23, 23 })
    t.ok(not sched.loading:is_loaded(0, 0))
    sched.loading:clear_forced()
    t.ok(sched.loading:is_loaded(0, 0))
  end,
}
