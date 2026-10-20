-- snapshot / restore / fork (spec section 7.1).
-- A snapshot holds the world, every computer's disk, position, inventory and equipment, storage, the cloud store,
-- ender chests, the stand-in bridge's state, the clock and the random generators. Coroutines cannot be saved,
-- so a restore reboots every computer that was on, from its restored disk, and drops events still in flight and
-- faults still scheduled. That is stated in the report's ASSUMPTIONS whenever a restore happened.
local Sim = require("core.sim")
local World = require("world.world")
local Disk = require("core.disk")
local Heap = require("core.heap")
local Loading = require("world.chunks_loaded")
local Ender = require("periph.ender")
local JSON = require("core.json")
local luaser = require("core.luaser")
local Rng = require("core.rng")
local Computer = require("core.computer")

local function rng_state(r) return { seed = r.seed, a = r.a, b = r.b, c = r.c, d = r.d } end
local function load_rng(r, s) r.seed, r.a, r.b, r.c, r.d = s.seed, s.a, s.b, s.c, s.d end

local function slots_of(inv)
  local out = {}
  for s, stack in pairs(inv.slots or {}) do out[s] = stack end
  return out
end

local function dir_of(sim, name) return sim.run_dir .. "/snapshots/" .. name end

function Sim:snapshot(name)
  local sched = self.sched
  local dir = dir_of(self, name)
  Disk.new(self.run_dir):mkdir("snapshots")
  local D = Disk.new(dir)
  self:flush()
  self.world:save(dir .. "/world")

  local comps = {}
  for _, c in ipairs(sched.computers) do
    if c.disk then
      local src = c.disk_obj or Disk.new(c.disk, c.quota)
      src:copy_all_to(Disk.new(dir .. "/disks/" .. c.id))
    end
    local ts
    if c.tstate then
      ts = { inv = c.tstate.inv, selected = c.tstate.selected, fuel = c.tstate.fuel, equipped = c.tstate.equipped,
        dropped = c.tstate.dropped, block_name = c.tstate.block_name }
    end
    comps[#comps + 1] = { id = c.id, kind = c.kind, role = c.role, label = c.label,
      pos = c.pos and c.pos.x and { x = c.pos.x, y = c.pos.y, z = c.pos.z, facing = c.pos.facing } or nil,
      home_pos = c.home_pos, state = c.state, frozen = c.frozen, carried = c.carried, chunk_identity = c.chunk_identity,
      gen = c.gen, quota = c.quota, modems = c.spec and c.spec.modems, kv = c.spec and c.spec.kv, tstate = ts,
      booted_ms = c.booted_ms }
  end

  local containers = {}
  for key, ct in pairs(self.world.containers) do
    if ct.freq then containers[key] = { kind = "ender", freq = ct.freq, block = ct.block_name }
    elseif ct.plain then containers[key] = { kind = "chest", block = ct.block_name, slots = slots_of(ct.inventory) } end
  end
  local ender = { config = sched.ender.config, inventories = {} }
  for freq, inv in pairs(sched.ender.inventories) do ender.inventories[freq] = slots_of(inv) end

  local st = sched.standin
  local snap = {
    now = self.clock:now(), t0 = self.t0, seed = self.seed, action_scale = sched.action_scale,
    computers = comps, containers = containers, ender = ender,
    storage = sched.storage:state(), storage_flags = { stall_ms = sched.storage.stall_ms, offline = sched.storage.offline },
    kv = sched.kv.data,
    standin = { state = JSON.encode(st.state), pending = JSON.encode(st.pending), boot_id = st.boot_id,
      seq_high = JSON.encode(st.seq_high), continuity = st.continuity, down = st.down, extra_latency_ms = st.extra_latency_ms },
    radio = { rules = sched.radio.rules, next_rule = sched.radio.next_rule, rng = rng_state(sched.radio.rng) },
    rng = rng_state(self.rng),
    loading = { forced_load = sched.loading.forced_load, forced_unload = sched.loading.forced_unload, tickets = {} },
  }
  for identity, t in pairs(sched.loading.tickets) do
    snap.loading.tickets[identity] = { cx = t.cx, cz = t.cz, r = t.r, owner = t.owner and t.owner.id }
  end
  local f = assert(io.open(dir .. "/snapshot.lua", "wb")); f:write(luaser.dump(snap)); f:close()
  sched:trace("snapshot " .. name)
  return dir
end

-- Rebuilds this sim from the snapshot folder `dir`.
function Sim:restore_from(dir)
  local sched = self.sched
  local f = assert(io.open(dir .. "/snapshot.lua", "rb"), "no snapshot at " .. dir)
  local snap = assert(luaser.parse(f:read("*a"))); f:close()

  -- take everything down
  for _, c in ipairs(sched.computers) do if c.state ~= "off" then c:shutdown() end end
  sched.computers, self.by_id, self.by_name = {}, {}, {}
  sched.heap = Heap.new()
  sched.hooks.pickup_cleanup = nil

  -- world
  local w = World.open(dir .. "/world")
  w:load_all()
  w.dir = nil
  self.world:replace_with(w)
  sched.world = self.world
  sched.loading = Loading.new{ world = self.world, sched = sched }
  sched.loading.forced_load, sched.loading.forced_unload = snap.loading.forced_load, snap.loading.forced_unload

  self.clock:reset(snap.now)
  self.t0 = snap.t0
  sched.action_scale = snap.action_scale

  -- shared state
  sched.storage:load_state(snap.storage)
  sched.storage.stall_ms, sched.storage.offline = snap.storage_flags.stall_ms or 0, snap.storage_flags.offline or false
  sched.kv.data, sched.kv.count = snap.kv, 0
  for _ in pairs(snap.kv) do sched.kv.count = sched.kv.count + 1 end
  sched.kv.dirty = true
  sched.ender.config, sched.ender.inventories = snap.ender.config, {}
  for freq, slots in pairs(snap.ender.inventories) do sched.ender:inventory(freq).slots = slots end
  load_rng(sched.radio.rng, snap.radio.rng)
  sched.radio.rules, sched.radio.next_rule = snap.radio.rules, snap.radio.next_rule
  load_rng(self.rng, snap.rng)

  local st = sched.standin
  st.state = JSON.decode(snap.standin.state, JSON.NULL, true)
  st.pending = JSON.decode(snap.standin.pending, JSON.NULL, true)
  st.seq_high = JSON.decode(snap.standin.seq_high, JSON.NULL, true)
  st.boot_id, st.continuity = snap.standin.boot_id, snap.standin.continuity
  st.down, st.extra_latency_ms = snap.standin.down or false, snap.standin.extra_latency_ms or 0

  -- containers placed in the world
  for key, ct in pairs(snap.containers) do
    if ct.kind == "ender" then self.world.containers[key] = sched.ender:container(ct.freq, ct.block)
    else
      local c = Ender.plain_chest(ct.block)
      c.inventory.slots = ct.slots
      self.world.containers[key] = c
    end
  end

  -- computers
  local to_boot = {}
  for _, cs in ipairs(snap.computers) do
    local spec = { id = cs.id, kind = cs.kind, role = cs.role, label = cs.label, pos = cs.pos, modems = cs.modems, kv = cs.kv,
      carried = cs.carried }
    if cs.tstate then spec.turtle = { inv = cs.tstate.inv, equipped = cs.tstate.equipped, fuel = cs.tstate.fuel } end
    -- start from the saved disk, not whatever the old computer left behind
    if cs.kind ~= "gps_host" then
      local old = Disk.new(self.run_dir .. "/computers/" .. cs.id)
      old:real_rmdir(old.root)
    end
    local c = self:add_computer(spec)
    c.home_pos, c.chunk_identity, c.quota = cs.home_pos, cs.chunk_identity, cs.quota
    if cs.tstate then
      c.tstate.selected, c.tstate.dropped, c.tstate.block_name = cs.tstate.selected, cs.tstate.dropped or {}, cs.tstate.block_name
    end
    if cs.kind ~= "gps_host" then
      c.disk_obj = nil
      Disk.new(dir .. "/disks/" .. cs.id):copy_all_to(Disk.new(c.disk, c.quota))
    end
    c.gen = cs.gen
    c.frozen = cs.frozen
    if cs.state ~= "off" and not cs.frozen then to_boot[#to_boot + 1] = c end
    if cs.kind == "gps_host" and cs.state == "off" then c:shutdown() end
  end

  -- loader tickets come back with their owners
  for identity, t in pairs(snap.loading.tickets) do
    sched.loading.tickets[identity] = { cx = t.cx, cz = t.cz, r = t.r, owner = t.owner and self.by_id[t.owner] }
  end

  for _, c in ipairs(to_boot) do
    if c.kind ~= "gps_host" then c:boot() end
  end
  self.restored = true
  self.extra_assumptions = self.extra_assumptions or {}
  table.insert(self.extra_assumptions, "A snapshot was restored: every computer that was on rebooted from its saved disk, and events in flight and faults still scheduled were dropped (coroutines cannot be saved).")
  sched:trace("restore from " .. dir)
end

function Sim:restore(name)
  self:restore_from(dir_of(self, name))
end

-- A new run, started from a snapshot; the original is left untouched.
function Sim:fork(name)
  self.fork_count = (self.fork_count or 0) + 1
  local run_dir = string.format("%s-fork%d", self.run_dir, self.fork_count)
  local child = Sim.new{ world = World.new_empty(), run_dir = run_dir, code_dir = self.sched.code_dir, seed = self.seed,
    start_ms = self.clock:now() }
  child.scenario, child.scenario_path, child.code_spec = self.scenario, self.scenario_path, self.code_spec
  child:restore_from(dir_of(self, name))
  return child
end

return true
