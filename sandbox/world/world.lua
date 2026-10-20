-- Sparse block world. Blocks live in per-chunk tables; a block that was never touched falls back to
-- the world's `terrain` rule (if it has one), so a "stone below y=60" world costs nothing until it is dug.
--   chunk.blocks[index] = "minecraft:stone"  a block
--                       = false              air that was dug out of default terrain
--                       = nil                untouched: use the terrain rule (or air)
local luaser = require("core.luaser")
local Disk = require("core.disk")

local World = {}
World.__index = World

local MIN_Y = -64

local function chunk_key(cx, cz) return cx .. "," .. cz end

local function index_of(x, y, z)
  return (y - MIN_Y) * 256 + (z % 16) * 16 + (x % 16)
end

function World.new_empty(meta)
  -- occupants: "x,y,z" -> the turtle standing there. containers: "x,y,z" -> chest-like object with
  -- :put(stack) -> moved and :take(n, name) -> stack. Neither is saved with the blocks.
  return setmetatable({ chunks = {}, absent = {}, meta_t = meta or {}, dir = nil, occupants = {}, containers = {} }, World)
end

function World.open(dir)
  local w = World.new_empty()
  local f = assert(io.open(dir .. "/meta.lua", "rb"), "no meta.lua in " .. dir)
  local text = f:read("*a"); f:close()
  w.meta_t = assert(luaser.parse(text))
  w.dir = dir
  return w
end

function World:meta() return self.meta_t end

-- Turns this world into a copy of `other` (a snapshot restore), keeping the object that everything points at.
function World:replace_with(other)
  self.chunks, self.absent, self.meta_t, self.dir = other.chunks, other.absent, other.meta_t, other.dir
  self.occupants, self.containers, self.block_periph = {}, {}, nil
end

function World:chunk_of(x, z) return math.floor(x / 16), math.floor(z / 16) end

local function default_block(terrain, y)
  if not terrain then return nil end
  if y == terrain.bottom then return "minecraft:bedrock" end
  if y > terrain.bottom and y <= terrain.stone_top then return "minecraft:stone" end
  if y > terrain.stone_top and y < terrain.soil_top then return "minecraft:dirt" end
  if y == terrain.soil_top then return "minecraft:grass_block" end
  return nil
end

local function chunk_path(self, cx, cz) return self.dir .. "/chunks/" .. cx .. "_" .. cz .. ".txt" end

local function load_chunk(self, cx, cz)
  local key = chunk_key(cx, cz)
  local c = self.chunks[key]
  if c then return c end
  if self.dir and not self.absent[key] then
    local f = io.open(chunk_path(self, cx, cz), "rb")
    if f then
      c = { blocks = {} }
      for idx, name in f:read("*a"):gmatch("(%d+)\t([^\n]*)\n") do
        if name == "-" then c.blocks[tonumber(idx)] = false else c.blocks[tonumber(idx)] = name end
      end
      f:close()
      self.chunks[key] = c
      return c
    end
    self.absent[key] = true
  end
  return nil
end

function World:get(x, y, z)
  local cx, cz = self:chunk_of(x, z)
  local c = load_chunk(self, cx, cz)
  if c then
    local v = c.blocks[index_of(x, y, z)]
    if v ~= nil then return v or nil end
  end
  return default_block(self.meta_t.terrain, y)
end

function World:set(x, y, z, name)
  local cx, cz = self:chunk_of(x, z)
  local c = load_chunk(self, cx, cz)
  if not c then
    c = { blocks = {} }
    self.chunks[chunk_key(cx, cz)] = c
  end
  local idx = index_of(x, y, z)
  if name == nil then
    if default_block(self.meta_t.terrain, y) ~= nil then c.blocks[idx] = false else c.blocks[idx] = nil end
  else
    c.blocks[idx] = name
  end
end

-- Reads every chunk file of the folder this world was opened from.
function World:load_all()
  if not self.dir then return end
  local D = Disk.new(self.dir)
  for _, file in ipairs(D:list("chunks") or {}) do
    local cx, cz = file:match("^(-?%d+)_(-?%d+)%.txt$")
    if cx then load_chunk(self, tonumber(cx), tonumber(cz)) end
  end
end

function World:save(dir)
  self:load_all()
  local D = Disk.new(dir)
  D:mkdir("chunks")
  local f = assert(io.open(dir .. "/meta.lua", "wb"))
  f:write(luaser.dump(self.meta_t)); f:close()
  for key, c in pairs(self.chunks) do
    local cx, cz = key:match("^(-?%d+),(-?%d+)$")
    local idxs = {}
    for idx in pairs(c.blocks) do idxs[#idxs + 1] = idx end
    table.sort(idxs)
    local path = dir .. "/chunks/" .. cx .. "_" .. cz .. ".txt"
    if #idxs == 0 then os.remove(path)
    else
      local out = {}
      for i, idx in ipairs(idxs) do out[i] = idx .. "\t" .. (c.blocks[idx] or "-") .. "\n" end
      local cf = assert(io.open(path, "wb")); cf:write(table.concat(out)); cf:close()
    end
  end
  self.dir = dir
  self.absent = {}
end

-- A checksum of everything explicitly stored (and the metadata), for comparing worlds.
function World:digest()
  self:load_all()
  local keys = {}
  for key in pairs(self.chunks) do keys[#keys + 1] = key end
  table.sort(keys)
  local h = 2166136261
  local function feed(s)
    for i = 1, #s do h = bit32.band(bit32.bxor(h, s:byte(i)) * 16777619, 0xffffffff) end
  end
  feed(luaser.dump(self.meta_t))
  for _, key in ipairs(keys) do
    local c = self.chunks[key]
    local idxs = {}
    for idx in pairs(c.blocks) do idxs[#idxs + 1] = idx end
    table.sort(idxs)
    if #idxs > 0 then
      feed(key)
      for _, idx in ipairs(idxs) do feed(idx .. ":" .. (c.blocks[idx] or "-") .. ";") end
    end
  end
  return string.format("%08x", h)
end

return World
