package.path = "sandbox/?.lua;" .. package.path
local Rng = require("core.rng")
local Clock = require("core.clock")
local Heap = require("core.heap")

local function seq(r, n) local o = {} for i = 1, n do o[i] = r:next() end return table.concat(o, ",") end

return {
  ["same seed same sequence"] = function(t)
    t.eq(seq(Rng.new(42), 50), seq(Rng.new(42), 50))
    t.ok(seq(Rng.new(42), 50) ~= seq(Rng.new(43), 50), "different seeds matched")
  end,
  ["different labels fork different sequences"] = function(t)
    local r = Rng.new(7)
    t.ok(seq(r:fork("a"), 20) ~= seq(r:fork("b"), 20), "labels matched")
    t.eq(seq(r:fork("a"), 20), seq(Rng.new(7):fork("a"), 20), "fork not deterministic")
  end,
  ["int stays in range over 10000 draws"] = function(t)
    local r, seen = Rng.new(1), {}
    for _ = 1, 10000 do
      local v = r:int(3, 7)
      t.ok(v >= 3 and v <= 7 and v == math.floor(v), "out of range: " .. v)
      seen[v] = true
    end
    for v = 3, 7 do t.ok(seen[v], "never drew " .. v) end
  end,
  ["next stays in [0,1)"] = function(t)
    local r = Rng.new(99)
    for _ = 1, 10000 do local v = r:next() t.ok(v >= 0 and v < 1, "bad " .. v) end
  end,
  ["clock refuses to go backwards"] = function(t)
    local c = Clock.new(1000)
    t.eq(c:now(), 1000)
    c:set(2000); t.eq(c:now(), 2000)
    t.raises(function() c:set(1999) end, "backwards")
  end,
  ["heap pops in time order"] = function(t)
    local h = Heap.new()
    for _, v in ipairs({ 50, 10, 30, 20, 40 }) do h:push(v, "i" .. v) end
    t.eq(h:peek_time(), 10)
    local out = {}
    while h:peek_time() do local time = h:pop() out[#out + 1] = time end
    t.eq(table.concat(out, ","), "10,20,30,40,50")
    t.eq(h:peek_time(), nil)
  end,
  ["heap breaks ties by insertion order"] = function(t)
    local h = Heap.new()
    for i = 1, 20 do h:push(5, i) end
    for i = 1, 20 do local _, item = h:pop() t.eq(item, i) end
  end,
}
