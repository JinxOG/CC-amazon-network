-- Runs the Python tests of the T2 run tool's HTTP-rule check (sandbox/tests/test_t2_rules.py) and reports each as a test.
local text
local function result()
  if not text then
    local p = io.popen("python sandbox/tests/test_t2_rules.py -v 2>&1")
    text = p:read("*a"); p:close()
  end
  return text
end

local names = { "test_the_live_copy_rules_are_refused", "test_rewriting_makes_them_safe_and_keeps_the_rest",
  "test_allowing_private_addresses_is_refused", "test_allowing_everything_else_is_refused",
  "test_another_port_on_localhost_is_refused", "test_an_extra_allowed_host_is_refused",
  "test_the_start_function_checks_before_starting", "test_the_pin_reads_the_version_of_the_commit_it_pins",
  "test_pin_refuses_anything_but_a_full_commit_id", "test_the_run_tool_has_every_command_its_cli_offers" }

local tests = {}
for _, n in ipairs(names) do
  tests["t2 run tool: " .. n:gsub("^test_", ""):gsub("_", " ")] = function(t)
    local out = result()
    t.ok(out:find(n .. " ", 1, true) and out:find(n .. ".-%.%.%. ok"), "python test " .. n .. " did not pass:\n" .. out:sub(-1500))
  end
end
return tests
