-- Digging gives what the block's loot table says (sandbox/data/drops_sakurapack.json, derived from the modpack).
package.path = "sandbox/?.lua;" .. package.path
local Drops = require("world.drops")
local Rng = require("core.rng")

return {
  ["a plain ore drops one raw item"] = function(t)
    local d = Drops.roll("minecraft:iron_ore", Rng.new(1))
    t.eq(#d, 1); t.eq(d[1].name, "minecraft:raw_iron"); t.eq(d[1].count, 1)
  end,

  ["a ranged drop stays inside its range and varies"] = function(t)
    local rng, seen = Rng.new(5), {}
    for _ = 1, 200 do
      local c = Drops.roll("minecraft:lapis_ore", rng)[1].count
      t.ok(c >= 4 and c <= 9, "lapis count " .. c)
      seen[c] = true
    end
    local n = 0
    for _ in pairs(seen) do n = n + 1 end
    t.ok(n >= 4, "only " .. n .. " different counts in 200 digs")
  end,

  ["a table with no pools drops nothing"] = function(t)
    local d = Drops.roll("born_in_chaos_v1:infected_diamond_ore", Rng.new(1))
    t.eq(#d, 0)
  end,

  ["a block with no loot table found, or one that could not be evaluated, is left to the old rule"] = function(t)
    t.eq(Drops.roll("bigreactors:yellorite_ore", Rng.new(1)), nil)
    t.eq(Drops.roll("minecraft:oak_leaves", Rng.new(1)), nil)       -- depends on shears / state: unhandled
    t.eq(Drops.roll("somemod:never_heard_of_it", Rng.new(1)), nil)
  end,

  ["the same seed rolls the same drops"] = function(t)
    local a, b = Rng.new(9), Rng.new(9)
    for _ = 1, 20 do t.eq(Drops.roll("minecraft:deepslate_redstone_ore", a)[1].count, Drops.roll("minecraft:deepslate_redstone_ore", b)[1].count) end
  end,

  ["raw drops count as ore items; stone does not"] = function(t)
    t.ok(Drops.is_ore_item("minecraft:raw_iron")); t.ok(Drops.is_ore_item("minecraft:diamond")); t.ok(Drops.is_ore_item("minecraft:iron_ore"))
    t.ok(not Drops.is_ore_item("minecraft:cobblestone"))
  end,
}
