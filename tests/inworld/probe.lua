-- probe.lua — Task 1 Step 3 (runtime equip swap) and Step 4b (detection surface).
--
-- Run on a turtle with:
--   * an ender modem equipped on ONE side
--   * a pickaxe equipped on the OTHER side
--   * the chunk controller item loose in any inventory slot
--
-- Answers three things equipment.lua cannot be written without:
--   1. what peripheral.getType() reports for each equipped upgrade
--   2. whether turtle.getEquippedLeft/Right exist (they would let us identify
--      upgrades by registry name instead of inferring the pickaxe by elimination)
--   3. whether the chunky upgrade can be equipped and unequipped at runtime,
--      and whether pickaxe + chunky can be held simultaneously
--
-- It restores the original loadout before exiting. If it cannot, it says so
-- loudly rather than leaving the turtle in a half-swapped state.

local CHUNKY = "advancedperipherals:chunk_controller"

local function line() print(("-"):rep(40)) end

local function dump(label)
    print(string.format("%s  L=%s  R=%s", label,
        tostring(peripheral.getType("left")),
        tostring(peripheral.getType("right"))))
    if turtle.getEquippedLeft then
        local l = turtle.getEquippedLeft()
        local r = turtle.getEquippedRight()
        print("   getEquipped L: " .. (l and l.name or "nil")
              .. "  R: " .. (r and r.name or "nil"))
    end
end

local function findSlot(name)
    for s = 1, 16 do
        local it = turtle.getItemDetail(s)
        if it and it.name == name then return s end
    end
    return nil
end

line()
print("=== 1. detection surface ===")
dump("initial:")
print("turtle.getEquippedLeft  present: " .. tostring(turtle.getEquippedLeft ~= nil))
print("turtle.getEquippedRight present: " .. tostring(turtle.getEquippedRight ~= nil))
print("peripheral.find('modem'): " .. tostring(peripheral.find("modem") ~= nil))

line()
print("=== 2. what is carried ===")
for s = 1, 16 do
    local it = turtle.getItemDetail(s)
    if it then print(string.format("  slot %2d: %s x%d", s, it.name, it.count)) end
end

local slot = findSlot(CHUNKY)
if not slot then
    print("!! no " .. CHUNKY .. " in inventory — put one in a slot and rerun")
    return
end

-- Swap into whichever side is NOT the modem, so comms survive the test.
local modemSide = (peripheral.getType("left") == "modem") and "left" or nil
if not modemSide and peripheral.getType("right") == "modem" then modemSide = "right" end
if not modemSide then
    print("!! no modem equipped on either side — equip one and rerun")
    return
end
local toolSide = (modemSide == "left") and "right" or "left"
local equipFn  = (toolSide == "left") and turtle.equipLeft or turtle.equipRight

line()
print("=== 3. equip swap: chunky -> " .. toolSide .. " (displacing the pickaxe) ===")
turtle.select(slot)
local ok, err = equipFn()
print("equip returned: " .. tostring(ok) .. "  " .. tostring(err))
dump("after swap:")
local back = turtle.getItemDetail(slot)
print("slot " .. slot .. " now holds: " .. (back and back.name or "nil")
      .. "   <- should be the pickaxe if the swap worked")

line()
print("=== 4. swap back ===")
turtle.select(slot)
local ok2, err2 = equipFn()
print("equip returned: " .. tostring(ok2) .. "  " .. tostring(err2))
dump("restored:")
local final = turtle.getItemDetail(slot)
print("slot " .. slot .. " now holds: " .. (final and final.name or "nil")
      .. "   <- should be the chunk controller again")

line()
if not (ok and ok2) then
    print("!! ASSUMPTION 3 FAILED — runtime equip swap does not work here.")
    print("!! Stop and re-plan; the whole solo-miner design rests on this.")
else
    print("Assumption 3 holds: the upgrade swaps at runtime in both directions.")
end
if final and final.name ~= CHUNKY then
    print("!! loadout NOT restored — fix by hand before using this turtle.")
end
