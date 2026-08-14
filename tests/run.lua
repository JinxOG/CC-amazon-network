-- Discovers tests/test_*.lua, each returning { ["name"] = function(assert_eq) end }.
-- Every test gets a fresh stub install, so ordering cannot leak state.
package.path = "./?.lua;" .. package.path

local files = {
    "tests.test_stub",
    "tests.test_equipment",
    "tests.test_geofence",
    "tests.test_bypass_geofence",
    "tests.test_loader_state",
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
