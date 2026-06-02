-- warehouse_test.lua
-- Quick test for the warehouse setup. Run on the warehouse computer:
--   warehouse_test
--
-- Tests: RS bridge found, ender chest reachable, item export works.

local ENDER_CHEST   = "top"           -- change to match your setup
local TEST_ITEM     = "minecraft:chest"
local TEST_COUNT    = 1

local pass = 0
local fail = 0

local function ok(msg)
    print("  [PASS] " .. msg)
    pass = pass + 1
end

local function err(msg)
    print("  [FAIL] " .. msg)
    fail = fail + 1
end

print("=== Warehouse Test ===")
print("")

-- 1. RS bridge
print("[1] RS bridge...")
local rs = peripheral.find("rsBridge")
if rs then
    ok("rsBridge found")
else
    err("rsBridge NOT found — attach Advanced Peripherals RS Bridge block")
end

-- 2. Ender chest
print("[2] Ender chest on '" .. ENDER_CHEST .. "'...")
local ec = peripheral.wrap(ENDER_CHEST)
if ec then
    ok("Ender chest found (" .. (peripheral.getType(ENDER_CHEST) or "?") .. ")")
else
    err("Nothing on side '" .. ENDER_CHEST .. "' — check placement or update ENDER_CHEST in this file")
end

-- 3. Export test
print("[3] Export " .. TEST_COUNT .. "x " .. TEST_ITEM .. " via RS bridge...")
if rs and ec then
    local before = 0
    for _, s in pairs(ec.list()) do before = before + s.count end

    local moved = rs.exportItem({ name = TEST_ITEM, count = TEST_COUNT }, ENDER_CHEST)

    if type(moved) == "string" then
        err("RS bridge error: " .. moved)
    elseif type(moved) == "number" and moved > 0 then
        ok(moved .. " item(s) appeared in ender chest")
        -- Clean up — pull them back via RS import
        local cleaned = rs.importItem({ name = TEST_ITEM, count = moved }, ENDER_CHEST)
        print("  (cleaned up: pulled " .. tostring(cleaned) .. " back to RS)")
    else
        err("Exported 0 items — check RS network has '" .. TEST_ITEM .. "' in stock")
    end
else
    err("Skipped (missing RS bridge or chest)")
end

-- 4. Summary
print("")
print(string.format("=== %d passed  %d failed ===", pass, fail))
if fail == 0 then
    print("Warehouse is ready.")
else
    print("Fix the failed checks then re-run.")
end
