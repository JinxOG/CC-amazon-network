-- Discovers tests/test_*.lua, each returning { ["name"] = function(assert_eq) end }.
-- Every test gets a fresh stub install, so ordering cannot leak state.
package.path = "./?.lua;" .. package.path

local files = {
    "tests.test_stub",
    "tests.test_logship",
    "tests.test_deploy_manifest",
    "tests.test_updater",
    "tests.test_stall_witness",
    "tests.test_crash_handlers",
    "tests.test_cloudstore",
    "tests.test_warehouse_rs",
    "tests.test_equipment",
    "tests.test_geofence",
    "tests.test_bypass_geofence",
    "tests.test_dig_room",
    "tests.test_shaft_sidestep",
    "tests.test_inbox",
    "tests.test_loader_state",
    "tests.test_ledger",
    "tests.test_loader_beacon",
    "tests.test_mine_phase",
    "tests.test_mine_flow",
    "tests.test_miner_hooks",
    "tests.test_resume_intent",
    "tests.test_delivery_support",
    "tests.test_full_job",
    -- Last: replaces os.epoch/os.startTimer/os.pullEvent/sleep/parallel to
    -- drive the control loop. It restores them per test, but running last
    -- means no other suite can be affected even if that ever regressed.
    "tests.test_control_loop",
    "tests.test_dock_refuel",
    "tests.test_field_refuel",
    "tests.test_server_recovery",
    "tests.test_server_zones",
    "tests.test_bridge_push_order",
    "tests.test_silent_waits",
    "tests.test_zone_phase",
    "tests.test_zone_ore",
    "tests.test_server_disk",
    "tests.test_minify",
    "tests.test_fence_refusal",
    "tests.test_gps3_journal",
    "tests.test_cc_local_limit",
    "tests.test_bay_types",
    "tests.test_bay_types_server",
    "tests.test_atc",
    "tests.test_atc_turtle",
}

-- Modules named on the command line run instead of the list (lua tests/run.lua tests.test_x ...).
-- Only the full list is the suite: six files (crash_handlers, inbox, control_loop,
-- bridge_push_order, silent_waits, zone_phase) still lean on globals an earlier
-- file set, and fail alone (2026-11-03). tests/mutate_logship.py runs the full list.
if arg and #arg > 0 then files = { table.unpack and table.unpack(arg) or unpack(arg) } end

local passed, failed = 0, 0

-- AN ASSERTION IS NOT AN ERROR (2026-11-02, W3, the mutation-harness card). A
-- failed assert_eq is raised as a marked value; anything else that stops a test
-- -- a nil call, a bad path, Lua 5.3 spelling on this 5.2 interpreter -- is an
-- ERROR, and is printed as one, so tests/mutate_logship.py can tell a test that
-- caught a mutant from a test that blew up. The assertion's line is unchanged.
local ASSERTION = {}
ASSERTION.__index = ASSERTION
ASSERTION.__tostring = function(e) return e.text end

local function assert_eq(got, want, msg)
    if got ~= want then
        local info = debug and debug.getinfo and debug.getinfo(2, "Sl")
        local where = info and (info.short_src .. ":" .. tostring(info.currentline) .. ": ") or ""
        error(setmetatable({ text = where .. string.format("%s: expected %s, got %s",
            msg or "assertion", tostring(want), tostring(got)) }, ASSERTION), 0)
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
                if getmetatable(err) == ASSERTION then
                    print("FAIL  " .. name .. "\n      " .. tostring(err))
                else
                    print("FAIL  " .. name .. "\n      ERROR " .. tostring(err))
                end
            end
        end
    end
end

print(string.format("\n%d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
