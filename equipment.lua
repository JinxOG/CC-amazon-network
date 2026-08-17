-- equipment.lua
-- Owns every equipped-upgrade transition on the miner.
--
-- The miner has two upgrade slots and three things it needs: an ender modem for
-- comms, a chunky upgrade for chunk loading, and a pickaxe for digging. It never
-- needs all three at once, so each phase sacrifices exactly one:
--
--   travel : modem + chunky    (self-loading, cannot dig)
--   mine   : modem + pickaxe   (placed loader holds the chunk)
--   retrieve: chunky + pickaxe (comms down; can dig AND stay loaded)
--
-- Losing comms is self-correcting. Losing chunk loading outside the base-loaded
-- area is an unrecoverable freeze. So retrieval always sacrifices the modem.

local equipment = {}

equipment.SLOTS = {
    SCANNER = 1,   -- geo scanner (placed and picked up per scan)
    LOADER  = 2,   -- the chunk-loader turtle carried as cargo
    TOOL    = 3,   -- whichever of pickaxe/chunky is currently stowed
    MODEM   = 4,   -- holds the modem only during the retrieval window
    COAL    = 14,
    FUEL_EC = 15,
    ORE_EC  = 16,
}

-- Registry names, verified in-world 2026-08-13. See
-- docs/superpowers/specs/chunkloader-footprint.md.
-- The chunky upgrade is Advanced Peripherals' Chunky Turtle, not the
-- `chunkloaders` mod -- that mod is not in this pack.
equipment.ITEMS = {
    PICKAXE       = "minecraft:diamond_pickaxe",
    CHUNKY        = "advancedperipherals:chunk_controller",
    MODEM         = "computercraft:wireless_modem_advanced",
    LOADER_TURTLE = "computercraft:turtle_advanced",
    SCANNER       = "advancedperipherals:geo_scanner",
}

local S, I = equipment.SLOTS, equipment.ITEMS

-- Upgrade kind for a registry name. Identity comes from the item itself, never
-- from what peripheral it happens to expose: peripheral.getType() returns nil
-- for the pickaxe side and so cannot tell a tool from an empty side.
local KIND_OF_ITEM = {
    [I.MODEM]   = "modem",
    [I.CHUNKY]  = "chunky",
    [I.PICKAXE] = "pickaxe",
}

-- Verified present in Task 1 Step 4b. Sides are never assumed: the swap dance
-- flips them every cycle, so everything here is side-agnostic.
local function equippedOn(side)
    local fn = (side == "left") and turtle.getEquippedLeft
                                 or turtle.getEquippedRight
    if not fn then return nil end
    local item = fn()
    return item and item.name or nil
end

local function kindOnSide(side)
    return KIND_OF_ITEM[equippedOn(side) or ""]
end

function equipment.sideOf(kind)
    for _, side in ipairs({ "left", "right" }) do
        if kindOnSide(side) == kind then return side end
    end
    return nil
end

local function pickaxeStowedSlot()
    for s = 1, 16 do
        local it = turtle.getItemDetail(s)
        if it and it.name == I.PICKAXE then return s end
    end
    return nil
end

local function findSlot(itemName)
    for s = 1, 16 do
        local it = turtle.getItemDetail(s)
        if it and it.name == itemName then return s end
    end
    return nil
end
equipment.findSlot = findSlot

local function emptySide()
    for _, side in ipairs({ "left", "right" }) do
        if kindOnSide(side) == nil and peripheral.getType(side) == nil then
            return side
        end
    end
    return nil
end

function equipment.state()
    return {
        left        = kindOnSide("left"),
        right       = kindOnSide("right"),
        pickaxeOn   = equipment.sideOf("pickaxe") ~= nil,
        invLoader   = findSlot(I.LOADER_TURTLE) ~= nil,
        invScanner  = findSlot(I.SCANNER)       ~= nil,
        invFuelEC   = turtle.getItemDetail(S.FUEL_EC) ~= nil,
        invOreEC    = turtle.getItemDetail(S.ORE_EC)  ~= nil,
    }
end

-- Cargo the miner must never be without, whatever phase it is in.
local function validateCargo()
    if not equipment.state().invScanner then return false, "scanner_missing" end
    local fe = turtle.getItemDetail(S.FUEL_EC)
    if not fe then return false, "fuel_ec_missing" end
    local oe = turtle.getItemDetail(S.ORE_EC)
    if not oe then return false, "ore_ec_missing" end
    return true
end

-- mode: "travel" (modem+chunky, loader in cargo) or "mine" (modem+pickaxe)
function equipment.validate(mode)
    if not equipment.sideOf("modem") then return false, "modem_not_equipped" end

    if mode == "travel" then
        if not equipment.sideOf("chunky") then return false, "chunky_not_equipped" end
        if not equipment.state().invLoader then return false, "loader_turtle_missing" end
    elseif mode == "mine" then
        if equipment.sideOf("chunky") then return false, "chunky_still_equipped" end
        if not equipment.sideOf("pickaxe") then return false, "pickaxe_not_equipped" end
    else
        return false, "unknown_mode"
    end

    return validateCargo()
end

-- Swap the item in `slot` onto `side`. Returns ok, reason.
--
-- Written as a plain if/else, NOT as `(side == "left") and turtle.equipLeft()
-- or turtle.equipRight()`. That idiom is broken for anything that can return
-- false: when equipLeft() fails, the `and` yields false and the `or` then runs
-- equipRight(), silently equipping onto the OPPOSITE side and reporting
-- success. In retrievalSwapOut (modem back onto the tool side) that fall-through
-- lands the modem on CHUNKY's side instead -- the miner is unloaded, in the
-- field, with the loader already dug up. Found by tests/test_full_job.lua.
-- The idiom also truncated `err` to one value, so every failure reported
-- "equip_failed:nil".
local function swap(slot, side)
    turtle.select(slot)
    local ok, err
    if side == "left" then
        ok, err = turtle.equipLeft()
    else
        ok, err = turtle.equipRight()
    end
    if not ok then return false, "equip_failed:" .. tostring(err) end
    return true
end

-- chunky -> pickaxe. Called only once the placed loader is confirmed holding
-- the chunk; the caller owns that ordering.
function equipment.toMineMode()
    local pSlot = pickaxeStowedSlot()
    if not pSlot then
        if equipment.sideOf("chunky") then return false, "pickaxe_missing" end
        return true   -- already in mine mode
    end
    local chunkySide = equipment.sideOf("chunky")
    if not chunkySide then return false, "chunky_not_equipped" end
    local ok, reason = swap(pSlot, chunkySide)
    if not ok then return false, reason end
    return equipment.validate("mine")
end

-- pickaxe -> chunky. Safe to call while the placed loader still holds the
-- chunk; do it before retrieving so travel mode is restored first.
function equipment.toTravelMode()
    local cSlot = findSlot(I.CHUNKY)
    if not cSlot then
        if equipment.sideOf("chunky") then return true end
        return false, "chunky_missing"
    end
    -- The pickaxe occupies whichever side is not the modem.
    local modemSide = equipment.sideOf("modem")
    if not modemSide then return false, "modem_not_equipped" end
    local toolSide = (modemSide == "left") and "right" or "left"
    local ok, reason = swap(cSlot, toolSide)
    if not ok then return false, reason end
    return true
end

-- Retrieval step 1: modem -> chunky, so pickaxe AND chunky are both on.
-- Comms go down here. This is deliberate and must be reported before calling.
function equipment.retrievalSwapIn()
    local cSlot = findSlot(I.CHUNKY)
    if not cSlot then return false, "chunky_missing" end
    local modemSide = equipment.sideOf("modem")
    if not modemSide then return false, "modem_not_equipped" end
    local ok, reason = swap(cSlot, modemSide)
    if not ok then return false, reason end
    if not equipment.sideOf("chunky") then return false, "chunky_equip_verify_failed" end
    return true
end

-- Retrieval step 2: pickaxe -> modem. Chunky stays on throughout.
function equipment.retrievalSwapOut()
    local mSlot = findSlot(I.MODEM)
    if not mSlot then return false, "modem_item_missing" end
    local chunkySide = equipment.sideOf("chunky")
    if not chunkySide then return false, "chunky_not_equipped" end
    local toolSide = (chunkySide == "left") and "right" or "left"
    local ok, reason = swap(mSlot, toolSide)
    if not ok then return false, reason end
    if not equipment.sideOf("modem") then return false, "modem_equip_verify_failed" end
    if not equipment.sideOf("chunky") then return false, "chunky_lost_during_swap" end
    return true
end

-- modem -> pickaxe, chunky stays on throughout. Reaches retrieval mode
-- (chunky+pickaxe) from the chunky+modem state equipment.reconcile() leaves
-- behind when a reboot lands mid-retrieval with both sides full: reconcile()
-- displaces the pickaxe rather than the modem there (chunk safety outranks
-- digging, correctly), but that leaves nothing able to swap the modem back
-- off on its own. This is that missing transition, symmetric to
-- retrievalSwapIn/retrievalSwapOut but starting from "chunky already on"
-- instead of "modem+pickaxe already on".
function equipment.toRetrieveMode()
    local pSlot = pickaxeStowedSlot()
    if not pSlot then
        if equipment.sideOf("pickaxe") then return true end -- already there
        return false, "pickaxe_missing"
    end
    local modemSide = equipment.sideOf("modem")
    if not modemSide then return false, "modem_not_equipped" end
    local ok, reason = swap(pSlot, modemSide)
    if not ok then return false, reason end
    if not equipment.sideOf("pickaxe") then return false, "pickaxe_equip_verify_failed" end
    if not equipment.sideOf("chunky") then return false, "chunky_lost_during_swap" end
    return true
end

-- Boot self-heal. A reboot inside the retrieval window leaves the modem in
-- inventory and no comms; without this the turtle is stranded until a player
-- intervenes. Chunk safety is restored before comms, because being unloaded is
-- unrecoverable while being offline is not.
function equipment.reconcile()
    local chunkyFailed = false
    if not equipment.sideOf("chunky") then
        local cSlot = findSlot(I.CHUNKY)
        if cSlot then
            -- A chunky item is carried but not equipped: this is the case
            -- reconcile() exists for, and we must know whether the fix
            -- actually landed, not just attempt it and move on.
            local side = emptySide()
            local ok = false
            if side then ok = swap(cSlot, side) end
            if not ok or not equipment.sideOf("chunky") then
                chunkyFailed = true
            end
        end
        -- cSlot == nil means no chunky item is carried at all (genuinely
        -- absent, or -- impossible here since we're inside `not sideOf` --
        -- already equipped). Nothing to recover, so that is not a failure.
    end
    if not equipment.sideOf("modem") then
        local mSlot = findSlot(I.MODEM)
        local side  = emptySide()
        if mSlot and side then
            swap(mSlot, side)
        elseif mSlot then
            -- Both sides full and no modem on either: displace the pickaxe,
            -- which is the only upgrade safe to stow while outside.
            local pSlot = pickaxeStowedSlot()
            if pSlot == nil then
                local chunkySide = equipment.sideOf("chunky")
                local toolSide   = (chunkySide == "left") and "right" or "left"
                swap(mSlot, toolSide)
            end
        end
    end
    if chunkyFailed then return false, "chunky_unrecoverable" end
    if not equipment.sideOf("modem") then return false, "modem_unrecoverable" end
    return true
end

return equipment
