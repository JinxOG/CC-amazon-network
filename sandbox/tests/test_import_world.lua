-- Runs the Python tests of the world importer (sandbox/tests/test_import_world.py) and reports each as a test.
local function run()
  local p = io.popen("python sandbox/tests/test_import_world.py -v 2>&1")
  local text = p:read("*a")
  p:close()
  return text
end

local text
local function result() text = text or run(); return text end

local names = { "test_importer_runs_without_the_network", "test_importer_finds_every_turtle",
  "test_importer_copies_every_computer_disk", "test_importer_reads_a_turtles_inventory_and_upgrades",
  "test_chunky_upgrade_is_reported_under_its_item_name", "test_carried_loaders_become_computers_of_their_own",
  "test_the_world_copy_is_untouched", "test_ender_chest_frequencies_and_the_clock" }

local tests = {}
for _, n in ipairs(names) do
  local label = "importer: " .. n:gsub("^test_", ""):gsub("_", " ")
  tests[label] = function(t)
    local out = result()
    t.ok(out:find(n, 1, true) and out:find(n .. ".-%.%.%. ok"), "python test " .. n .. " did not pass:\n" .. out:sub(-1500))
  end
end
return tests
