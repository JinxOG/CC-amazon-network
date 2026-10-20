-- Same scenario + same seed = the same run, byte for byte. Each run is a separate process.
local H = dofile("sandbox/tests/helpers.lua")

local function run(seed, dir)
  local cmd = string.format('bash sandbox/sim run sandbox/scenarios/smoke_short.lua --seed %d --run-dir "%s" 2>&1', seed, dir)
  local p = io.popen(cmd)
  local out = p:read("*a")
  p:close()
  return out
end

local runs = {}
local function get(seed, tag)
  local key = seed .. tag
  if not runs[key] then
    local dir = H.tmpdir() .. "/run"
    local out = run(seed, dir)
    runs[key] = { dir = dir, out = out, trace = H.read(dir .. "/trace.log") }
  end
  return runs[key]
end

return {
  ["same scenario and seed produce byte-identical trace.log"] = function(t)
    local a, b = get(42, "a"), get(42, "b")
    t.ok(a.trace and #a.trace > 1000, "first run wrote no trace:\n" .. a.out)
    t.ok(b.trace, "second run wrote no trace:\n" .. b.out)
    if a.trace ~= b.trace then
      local la, lb = {}, {}
      for l in a.trace:gmatch("[^\n]+") do la[#la + 1] = l end
      for l in b.trace:gmatch("[^\n]+") do lb[#lb + 1] = l end
      for i = 1, math.max(#la, #lb) do
        if la[i] ~= lb[i] then error("traces differ at line " .. i .. ":\n  " .. tostring(la[i]) .. "\n  " .. tostring(lb[i]), 0) end
      end
    end
    t.eq(a.trace, b.trace)
  end,

  ["different seeds produce different traces"] = function(t)
    local a, c = get(42, "a"), get(7, "c")
    t.ok(c.trace and #c.trace > 1000, "seed 7 wrote no trace:\n" .. c.out)
    t.ok(a.trace ~= c.trace, "seeds 42 and 7 gave the same trace")
  end,

  ["tables keyed by tables iterate in the same order in separate processes"] = function(t)
    local interp = H.read("sandbox/interp.txt"):gsub("%s+$", "")
    local script = H.tmpdir() .. "/order.lua"
    local f = assert(io.open(script, "wb"))
    f:write("local t={} for i=1,200 do t[{}]=i end local o={} for _,v in pairs(t) do o[#o+1]=v end print(table.concat(o,','))")
    f:close()
    local seen = {}
    for i = 1, 3 do
      local p = io.popen('""' .. interp .. '" "' .. script .. '""')
      seen[i] = p:read("*a"); p:close()
    end
    t.ok(#seen[1] > 100, "no output: " .. seen[1])
    t.eq(seen[1], seen[2]); t.eq(seen[1], seen[3])
  end,
}
