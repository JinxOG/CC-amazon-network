-- Checks the interpreter against the three tests of spec section 13.
-- Run from the repo root: sandbox/sim check
local failed = false

-- 1. parse every fleet file
local p = io.popen("ls *.lua")
for name in p:lines() do
  local f, err = loadfile(name)
  if f then print("PARSE ok " .. name) else print("PARSE FAIL " .. name .. " " .. tostring(err)); failed = true end
end
p:close()

-- 2. numbers print the way CC prints them
if tostring(3/1) == "3" and tostring(10/4) == "2.5" then print("NUMBER ok")
else print("NUMBER FAIL " .. tostring(3/1) .. " " .. tostring(10/4)); failed = true end

-- 3. pairs order is the same in every process
local t = {}
for i = 1, 1000 do t["k" .. i] = i end
local parts = {}
for k in pairs(t) do parts[#parts + 1] = k end
local s = table.concat(parts, ",")
local h = 5381
for i = 1, #s do h = (h * 33 + s:byte(i)) % 4294967296 end
print(string.format("ORDER %08x", h))

os.exit(failed and 1 or 0)
