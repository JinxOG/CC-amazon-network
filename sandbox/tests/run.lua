-- Runs every sandbox/tests/test_*.lua. Usage: sandbox/sim test [pattern]
-- Each test file returns { ["name"] = function(t) ... end }.
package.path = "sandbox/?.lua;" .. package.path
local helpers = dofile("sandbox/tests/helpers.lua")
local pattern = arg[1]

local files = {}
local p = io.popen("ls sandbox/tests/test_*.lua")
for f in p:lines() do files[#files + 1] = f end
p:close()
table.sort(files)

local pass, fail = 0, 0
for _, file in ipairs(files) do
  if not pattern or file:find(pattern, 1, true) then
    local ok, tests = pcall(dofile, file)
    if not ok then
      print("FAIL " .. file .. ": " .. tostring(tests)); fail = fail + 1
    else
      local names = {}
      for name in pairs(tests) do names[#names + 1] = name end
      table.sort(names)
      for _, name in ipairs(names) do
        local ok2, err = pcall(tests[name], helpers)
        if ok2 then print("PASS " .. name); pass = pass + 1
        else print("FAIL " .. name .. ": " .. tostring(err)); fail = fail + 1 end
      end
    end
  end
end
print(string.format("sandbox/sim test: %d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
