-- Seeded generator: xorshift128 on 32-bit words (bit32), no integer types needed.
-- Never uses math.random, so a run depends only on its seed.
local Rng = {}
Rng.__index = Rng

local band, bxor, lshift, rshift = bit32.band, bit32.bxor, bit32.lshift, bit32.rshift

local function mix(x) -- 32-bit integer finaliser
  x = bxor(x, rshift(x, 16)); x = band(x * 0x45d9f3b, 0xffffffff)
  x = bxor(x, rshift(x, 16)); x = band(x * 0x45d9f3b, 0xffffffff)
  return bxor(x, rshift(x, 16))
end

local function hash_label(seed, label) -- FNV-1a over the seed and label
  local h = 2166136261
  local s = string.format("%.0f:%s", seed, label)
  for i = 1, #s do
    h = bxor(h, s:byte(i))
    h = band(h * 16777619, 0xffffffff)
  end
  return h
end

function Rng.new(seed)
  local self = setmetatable({ seed = seed }, Rng)
  local lo = seed % 4294967296
  local hi = math.floor(seed / 4294967296) % 4294967296
  self.a = mix(lo + 0x9e3779b9)
  self.b = mix(hi + 0x7f4a7c15)
  self.c = mix(self.a + self.b + 0x85ebca6b)
  self.d = mix(self.c + 0xc2b2ae35)
  if self.a == 0 and self.b == 0 and self.c == 0 and self.d == 0 then self.d = 1 end
  return self
end

local function next32(self)
  local t = bxor(self.a, lshift(self.a, 11))
  self.a, self.b, self.c = self.b, self.c, self.d
  self.d = bxor(self.d, rshift(self.d, 19), t, rshift(t, 8))
  return self.d
end

function Rng:next()
  local hi = rshift(next32(self), 5)  -- 27 bits
  local lo = rshift(next32(self), 6)  -- 26 bits
  return (hi * 67108864 + lo) / 9007199254740992
end

function Rng:int(lo, hi)
  return lo + math.floor(self:next() * (hi - lo + 1))
end

function Rng:fork(label)
  local h = hash_label(self.seed, label)
  return Rng.new(self.seed * 31 % 4503599627370496 + h)
end

return Rng
