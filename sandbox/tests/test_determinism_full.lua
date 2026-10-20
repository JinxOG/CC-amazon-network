-- A full two-miner job, twice, in separate processes: trace.log must be byte-identical. The short scenario in
-- test_determinism.lua passed while a full job drifted (review 1): tables keyed by tables iterated in an order that
-- followed memory addresses, which move between processes. The interpreter now allocates at fixed addresses.
local H = dofile("sandbox/tests/helpers.lua")

local function run(dir)
  local p = io.popen(string.format('bash sandbox/sim run sandbox/scenarios/smoke_two_miners.lua --seed 7 --run-dir "%s" 2>&1', dir))
  local out = p:read("*a"); p:close()
  return out, H.read(dir .. "/trace.log")
end

return {
  ["a full two-miner job twice gives a byte-identical trace.log"] = function(t)
    local oa, a = run(H.tmpdir() .. "/run")
    local ob, b = run(H.tmpdir() .. "/run")
    t.ok(a and #a > 1000000, "first run wrote no real trace:\n" .. oa)
    t.ok(oa:find("PASS", 1, true) and ob:find("PASS", 1, true), "the job did not complete:\n" .. oa .. ob)
    if a ~= b then
      local la, lb = {}, {}
      for l in a:gmatch("[^\n]+") do la[#la + 1] = l end
      for l in b:gmatch("[^\n]+") do lb[#lb + 1] = l end
      for i = 1, math.max(#la, #lb) do
        if la[i] ~= lb[i] then error("traces differ at line " .. i .. ":\n  " .. tostring(la[i]) .. "\n  " .. tostring(lb[i]), 0) end
      end
    end
    t.eq(a, b)
  end,
}
