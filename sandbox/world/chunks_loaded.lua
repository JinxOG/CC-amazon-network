-- Which chunks are loaded, and what happens to computers when theirs is not.
-- A chunk is loaded when it is in the base's always-loaded area, inside a loader's ticket, or holds/is
-- near a turtle with the chunky upgrade (a ticket that moves with the turtle). A computer in an unloaded
-- chunk is shut down; when the chunk loads again it boots from startup.lua (CC:Tweaked's behaviour).
local Loading = {}
Loading.__index = Loading

local CHUNKY = "advancedperipherals:chunk_controller"
Loading.CHUNKY_RADIUS = 1 -- 3x3 chunks; listed in ASSUMPTIONS

local function key(cx, cz) return cx .. "," .. cz end

function Loading.new(opts)
  local self = setmetatable({}, Loading)
  self.world, self.sched = opts.world, opts.sched
  self.tickets = {}        -- identity -> {cx, cz, r}; one per identity, the last placed wins
  self.forced_load, self.forced_unload = {}, {}
  self.base = {}           -- chunk rectangles
  for _, a in ipairs((self.world:meta().base_loaded) or {}) do
    self.base[#self.base + 1] = { math.floor(a[1] / 16), math.floor(a[2] / 16), math.floor(a[3] / 16), math.floor(a[4] / 16) }
  end
  return self
end

local function in_rect(r, cx, cz) return cx >= r[1] and cx <= r[3] and cz >= r[2] and cz <= r[4] end

function Loading:is_loaded(cx, cz)
  for _, r in ipairs(self.forced_unload) do if in_rect(r, cx, cz) then return false end end
  for _, r in ipairs(self.forced_load) do if in_rect(r, cx, cz) then return true end end
  for _, r in ipairs(self.base) do if in_rect(r, cx, cz) then return true end end
  for _, t in pairs(self.tickets) do
    if math.abs(cx - t.cx) <= t.r and math.abs(cz - t.cz) <= t.r then return true end
  end
  return false
end

-- A loader's ticket. Setting it again for the same identity replaces the old one.
function Loading:add_ticket(identity, cx, cz, radius)
  self.tickets[identity] = { cx = cx, cz = cz, r = radius or 1 }
  self:recompute()
end

function Loading:remove_tickets(identity)
  self.tickets[identity] = nil
  self:recompute()
end

function Loading:force_load(rect_blocks) self.forced_load[#self.forced_load + 1] = self:rect(rect_blocks); self:recompute() end
function Loading:force_unload(rect_blocks) self.forced_unload[#self.forced_unload + 1] = self:rect(rect_blocks); self:recompute() end
function Loading:clear_forced() self.forced_load, self.forced_unload = {}, {}; self:recompute() end

function Loading:rect(a)
  return { math.floor(a[1] / 16), math.floor(a[2] / 16), math.floor(a[3] / 16), math.floor(a[4] / 16) }
end

local function chunk_of_comp(comp)
  local p = comp.pos
  if not p or not p.x then return nil end
  return math.floor(p.x / 16), math.floor(p.z / 16)
end

-- Applies the current loading to one computer: shut it down if it stands in an unloaded chunk,
-- boot it again if the chunk is back and it was frozen by this.
function Loading:apply(comp)
  local cx, cz = chunk_of_comp(comp)
  if not cx then return end
  local loaded = self:is_loaded(cx, cz)
  if not loaded and comp.state ~= "off" then
    comp.frozen = true
    self.sched:trace(comp.name .. " chunk-unloaded " .. cx .. "," .. cz)
    comp:shutdown()
  elseif loaded and comp.frozen then
    comp.frozen = nil
    self.sched:trace(comp.name .. " chunk-reloaded " .. cx .. "," .. cz)
    comp:boot()
  end
end

function Loading:recompute()
  for _, comp in ipairs(self.sched.computers) do self:apply(comp) end
end

-- Called when a computer moved (or changed equipment). A chunky turtle's ticket follows it.
function Loading:update_pos(comp, equipment_changed)
  local st = comp.tstate
  if st then
    local chunky = st.equipped.left == CHUNKY or st.equipped.right == CHUNKY
    local identity = comp.chunk_identity or ("computer:" .. comp.id)
    local cx, cz = chunk_of_comp(comp)
    local t = self.tickets[identity]
    if chunky and cx and (not t or t.cx ~= cx or t.cz ~= cz or t.owner ~= comp) then
      self.tickets[identity] = { cx = cx, cz = cz, r = comp.chunk_radius or Loading.CHUNKY_RADIUS, owner = comp }
      self:recompute()
      return
    elseif not chunky and t and t.owner == comp then
      self.tickets[identity] = nil
      self:recompute()
      return
    end
  end
  self:apply(comp)
end

return Loading
