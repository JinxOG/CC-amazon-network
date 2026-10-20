-- One simulated run: the clock, the scheduler, the world, and everything the computers share (radio,
-- storage, cloud store, ender chests, the stand-in bridge). Scenarios and tests drive a Sim.
local Clock = require("core.clock")
local Rng = require("core.rng")
local Scheduler = require("core.scheduler")
local Computer = require("core.computer")
local Disk = require("core.disk")
local Safety = require("core.safety")
local Radio = require("net.radio")
local Modem = require("periph.modem")
local GpsHost = require("periph.gps_host")
local KV = require("periph.kv_storage")
local Storage = require("periph.storage")
local Ender = require("periph.ender")
local Blocks = require("periph.blocks")
local Loading = require("world.chunks_loaded")
local Standin = require("bridge.standin")
local Turtle = require("cc.turtle")

local Sim = {}
Sim.__index = Sim

local TURTLE_ITEMS = { ["computercraft:turtle_advanced"] = true, ["computercraft:turtle_normal"] = true }

-- opts: world (World), run_dir, code_dir, seed, start_ms, storage (item list), config (checked for forbidden hosts)
function Sim.new(opts)
  Safety.check_config(opts.config or {}, "scenario")
  Safety.check_config(opts.run_dir or "", "run_dir")
  local self = setmetatable({}, Sim)
  self.run_dir = opts.run_dir
  self.seed = opts.seed or 1
  local disk = Disk.new(self.run_dir)
  disk:mkdir("computers")
  self.clock = Clock.new(opts.start_ms)
  self.rng = Rng.new(self.seed)
  local sched = Scheduler.new{ clock = self.clock, rng = self.rng, trace = self.run_dir .. "/trace.log" }
  self.sched = sched
  sched.sim = self
  sched.world = opts.world
  sched.code_dir = opts.code_dir
  sched.hooks = {}
  sched.radio = Radio.new{ sched = sched, rng = self.rng }
  sched.storage = Storage.new(opts.storage or {})
  sched.kv = KV.new(self.run_dir .. "/kv.lua")
  sched.ender = Ender.new(sched, sched.storage)
  sched.ender:configure("fuel", "endless", { item = "minecraft:coal" })
  sched.ender:configure("ore", "sink", { delay_ms = 5000 })
  sched.ender:install_hook(sched)
  sched.standin = Standin.new{ run_dir = self.run_dir, sched = sched }
  sched.loading = Loading.new{ world = opts.world, sched = sched }
  self.world = opts.world
  self.by_id, self.by_name = {}, {}
  self.t0 = self.clock:now()   -- fault times count from here; the runner moves it to the start of the scenario
  self.interventions = {}
  self.faults = {}
  self.initial_storage = {}
  for k, v in pairs(sched.storage.amounts) do self.initial_storage[k] = v end

  -- turtles carried as items can be placed in the world and picked up again
  local previous_place = sched.hooks.place
  sched.hooks.place = function(comp, stack, x, y, z, dir)
    if TURTLE_ITEMS[stack.name] and stack.computer_id then
      local target = self.by_id[stack.computer_id]
      if not target then return true, nil, "unknown turtle item" end
      local f = comp.pos.facing or 0
      target.pos = { x = x, y = y, z = z, facing = f }
      target.carried = nil
      if target.tstate then target.tstate.block_name = stack.name end
      self.world.occupants[x .. "," .. y .. "," .. z] = target
      sched.loading:update_pos(target)
      sched:trace(target.name .. " placed at " .. x .. "," .. y .. "," .. z)
      return true, false -- placed; the turtle is the block, nothing is written to the world
    end
    if previous_place then return previous_place(comp, stack, x, y, z, dir) end
    return false
  end
  sched.hooks.pickup = function(comp, occupant)
    if occupant.kind ~= "turtle" or not occupant.tstate then return nil end
    local p = occupant.pos
    self.world.occupants[p.x .. "," .. p.y .. "," .. p.z] = nil
    local stack = { name = occupant.tstate.block_name or "computercraft:turtle_advanced", count = 1,
      displayName = occupant.label or occupant.name, computer_id = occupant.id }
    occupant:shutdown()
    occupant.pos = {}
    occupant.carried = true
    sched.loading:release(occupant)
    sched:trace(occupant.name .. " picked up by " .. comp.name)
    return stack
  end

  -- a turtle next to a computer is a peripheral: turnOn / shutdown / reboot / isOn
  Blocks.occupant_descriptor = function(caller, occ)
    if occ.kind ~= "turtle" then return nil end
    local m = {}
    function m.turnOn() if occ.state == "off" then occ:boot() end return true end
    function m.shutdown() if occ.state ~= "off" then occ:shutdown() end return true end
    function m.reboot() if occ.state == "off" then occ:boot() else occ:reboot() end return true end
    function m.isOn() return occ.state ~= "off" end
    function m.getID() return occ.id end
    function m.getLabel() return occ.label end
    return { type = "turtle", methods = m }
  end
  return self
end

function Sim:flush()
  self.sched.standin:flush()
  self.sched.kv:flush()
  self.sched:flush()
end

-- Adds a computer. spec: id, kind ("computer"|"turtle"|"gps_host"), role, label, pos {x,y,z,facing},
-- modems {sides}, kv {side}, blocks {{side=, block=}} (peripheral blocks placed beside it),
-- turtle {inv=, equipped=, fuel=}, carried (a turtle that starts as an item: not in the world)
function Sim:add_computer(spec)
  local comp
  if spec.kind == "gps_host" then
    comp = GpsHost.place(self.sched, spec.id, spec.pos.x, spec.pos.y, spec.pos.z, spec.label)
  else
    local dir = self.run_dir .. "/computers/" .. spec.id
    Disk.new(dir)
    comp = Computer.new{ id = spec.id, label = spec.label, kind = spec.kind or "computer", disk = dir, sched = self.sched,
      pos = spec.pos or {} }
    comp.role = spec.role
    self.sched:add(comp)
    for _, side in ipairs(spec.modems or {}) do Modem.place(comp, side) end
    for _, side in ipairs(spec.kv or {}) do KV.attach(comp, side) end
    for _, b in ipairs(spec.blocks or {}) do
      local x, y, z = Blocks.neighbour(comp, b.side)
      self.world:set(x, y, z, b.block)
      if b.freq then
        self.world.containers[x .. "," .. y .. "," .. z] = self.sched.ender:container(b.freq, b.block)
      end
    end
    if comp.kind == "turtle" then
      local t = spec.turtle or {}
      comp.tstate = { inv = t.inv or {}, selected = 1, fuel = t.fuel or 100000, equipped = t.equipped or {}, dropped = {},
        block_name = "computercraft:turtle_advanced" }
      if spec.carried then
        comp.carried = true
        comp.pos = {}
      else
        self.world.occupants[comp.pos.x .. "," .. comp.pos.y .. "," .. comp.pos.z] = comp
      end
      require("periph.modem").track_equipment(comp)
    end
  end
  self.by_id[spec.id] = comp
  self.by_name[comp.name] = comp
  return comp
end

function Sim:dispatch(cmd) return self.sched.standin:dispatch(cmd) end

function Sim:watch_log(pattern) return self.sched.standin:watch_log(pattern) end

-- A scenario's own check. A failed expectation is recorded (and shown in the report), not thrown.
function Sim:expect(cond, message)
  self.expectations = self.expectations or {}
  self.expectations[#self.expectations + 1] = { ok = cond and true or false, message = message,
    at_ms = self.clock:now() }
  return cond and true or false
end

function Sim:run_for(ms) return self.sched:run{ until_ms = self.clock:now() + ms } end

-- Runs until cond() is true or timeout_ms of simulated time passes. Returns true if cond held.
function Sim:run_until(cond, timeout_ms)
  local limit = self.clock:now() + timeout_ms
  while self.clock:now() < limit do
    if cond() then return true end
    local step = math.min(1000, limit - self.clock:now())
    self.sched:run{ until_ms = self.clock:now() + step }
  end
  return cond() and true or false
end

function Sim:status()
  local rows = {}
  for _, c in ipairs(self.sched.computers) do
    rows[#rows + 1] = { name = c.name, role = c.role, state = c.state, pos = c.pos }
  end
  return rows
end

return Sim
