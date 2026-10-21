-- Runs the Python tests of the T2 scenario runner (sandbox/tests/test_t2_scenario.py) and reports each as a test.
local text
local function result()
  if not text then
    local p = io.popen("python sandbox/tests/test_t2_scenario.py -v 2>&1")
    text = p:read("*a"); p:close()
  end
  return text
end

local names = { "test_a_reply_with_no_number_is_retried", "test_a_dropped_connection_is_retried", "test_it_gives_up_after_eight_tries_and_says_what_it_saw", "test_the_ore_in_a_real_sector_line_is_counted" }

local tests = {}
for _, n in ipairs(names) do
  tests["t2 scenario runner: " .. n:gsub("^test_", ""):gsub("_", " ")] = function(t)
    local out = result()
    t.ok(out:find(n .. " ", 1, true) and out:find(n .. ".-%.%.%. ok"), "python test " .. n .. " did not pass:\n" .. out:sub(-1500))
  end
end
return tests
