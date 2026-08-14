-- nbt.lua — Task 1 Step 2: does the chunky upgrade survive place -> break -> re-place?
--
-- Run on a turtle with a PICKAXE equipped and a chunky turtle (a turtle item
-- carrying the chunk controller upgrade) in its inventory. Needs a clear block
-- in front of it.
--
-- If the recovered item is a bare turtle rather than a chunky one, the miner
-- would silently degrade to a useless loader after its first sector, so this
-- has to be checked before any code is written.

local LOADER = "computercraft:turtle_advanced"

local function findLoader()
    for s = 1, 16 do
        local it = turtle.getItemDetail(s)
        if it and it.name == LOADER then return s end
    end
    return nil
end

local function describe(slot, label)
    local d = turtle.getItemDetail(slot, true)
    if not d then print(label .. ": (empty)") return nil end
    print(label .. ":")
    print("   name        = " .. tostring(d.name))
    print("   displayName = " .. tostring(d.displayName))
    print("   count       = " .. tostring(d.count))
    return d
end

local slot = findLoader()
if not slot then
    print("!! no " .. LOADER .. " in inventory — add the chunky turtle and rerun")
    return
end

if turtle.detect() then
    print("!! something is already in front — clear it and rerun")
    return
end

print(("="):rep(40))
turtle.select(slot)
local before = describe(slot, "BEFORE place")

print("placing...")
if not turtle.place() then
    print("!! place failed")
    return
end
sleep(2)

print("breaking...")
if not turtle.dig() then
    print("!! dig failed — is a pickaxe equipped? The turtle may still be standing.")
    return
end
sleep(1)

local slot2 = findLoader()
if not slot2 then
    print("!! the turtle did not come back into inventory — look on the ground")
    return
end
local after = describe(slot2, "AFTER  break")

print(("="):rep(40))
if before and after and before.displayName == after.displayName then
    print("Assumption 2 holds: displayName survived place -> break.")
    print("(" .. tostring(after.displayName) .. ")")
else
    print("!! displayName CHANGED across place -> break:")
    print("!!   before: " .. tostring(before and before.displayName))
    print("!!   after : " .. tostring(after and after.displayName))
    print("!! If the recovered item is a plain turtle, ASSUMPTION 2 FAILED.")
end
print("Confirm visually too: hover the item and check it still says Chunky.")
