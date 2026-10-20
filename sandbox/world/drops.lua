-- What digging a block with a turtle's pickaxe gives, from the derived table in sandbox/data/drops_sakurapack.json
-- (made by sandbox/tools/derive_drops.py from the loot tables of the SakuraPack client instance; see that file's
-- "about"). Unverified until a local test server confirms it, and the table is from the client mod set.
--
-- roll(block, rng) -> a list of { name, count } (empty: the block drops nothing), or nil when the table has no usable
-- entry for the block (no loot table found, or one the tool could not evaluate), in which case the caller keeps its
-- old rule. Randomness comes from `rng` only when a count is a range or a drop has a chance below 1.
local JSON = require("core.json")

local Drops = {}
local blocks

local function load()
  if blocks then return blocks end
  blocks = {}
  local f = io.open("sandbox/data/drops_sakurapack.json", "rb")
  if not f then return blocks end
  local ok, doc = pcall(JSON.decode, f:read("*a"), nil, false)
  f:close()
  if ok and type(doc) == "table" and type(doc.blocks) == "table" then blocks = doc.blocks end
  return blocks
end

function Drops.roll(block, rng)
  local b = load()[block]
  if not b or not b.source or b.unhandled then return nil end
  local out = {}
  for _, d in ipairs(b.drops or {}) do
    local take = true
    if d.chance < 1 then take = rng:next() < d.chance end
    if take then
      local n = d.min
      if d.max > d.min then n = rng:int(d.min, d.max) end
      if n > 0 then out[#out + 1] = { name = d.item, count = n } end
    end
  end
  return out
end

-- Is this item something an ore block drops? True for the ore blocks themselves (a name with "ore" in it) and for the
-- items ore blocks give when dug (raw_iron, diamond, redstone, ...), so reports can count "ore" under real drops.
local ore_items
function Drops.is_ore_item(name)
  if name:find("ore", 1, true) then return true end
  if not ore_items then
    ore_items = {}
    for id, b in pairs(load()) do
      if id:find("ore", 1, true) and b.drops then for _, d in ipairs(b.drops) do ore_items[d.item] = true end end
    end
  end
  return ore_items[name] == true
end

return Drops
