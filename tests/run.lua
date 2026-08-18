-- Discovers tests/test_*.lua, each returning { ["name"] = function(assert_eq) end }.
-- Every test gets a fresh stub install, so ordering cannot leak state.
package.path = "./?.lua;" .. package.path

local files = {
    "tests.test_stub",
    "tests.test_equipment",
    "tests.test_geofence",
    "tests.test_bypass_geofence",
    "tests.test_loader_state",
    "tests.test_loader_beacon",
    "tests.test_mine_phase",
    "tests.test_mine_flow",
    "tests.test_miner_hooks",
    "tests.test_delivery_support",
    "tests.test_full_job",
    -- Last: replaces os.epoch/os.startTimer/os.pullEvent/sleep/parallel to
    -- drive the control loop. It restores them per test, but running last
    -- means no other suite can be affected even if that ever regressed.
    "tests.test_control_loop",
    "tests.test_dock_refuel",
    "tests.test_field_refuel",
}

local passed, failed = 0, 0

local function assert_eq(got, want, msg)
    if got ~= want then
        error(string.format("%s: expected %s, got %s",
            msg or "assertion", tostring(want), tostring(got)), 2)
    end
end

for _, mod in ipairs(files) do
    local ok, suite = pcall(require, mod)
    if not ok then
        print(string.format("LOAD FAIL %s: %s", mod, suite))
        failed = failed + 1
    else
        for name, fn in pairs(suite) do
            local ran, err = pcall(fn, assert_eq)
            if ran then
                passed = passed + 1
                print("PASS  " .. name)
            else
                failed = failed + 1
                print("FAIL  " .. name .. "\n      " .. tostring(err))
            end
        end
    end
end

print(string.format("\n%d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
