-- delivery_turtle.lua
-- Rename to startup.lua on any delivery/worker turtle.
-- Route: dock → dispatch hole → underground travel → ascend at destination
--        → entangled chest delivery → descend → arrivals hole → dock

local base  = require("turtle_base")
local proto = require("protocol")

local UNDERGROUND_Y = 60   -- Y level for all underground travel

-- Slot reserved for the entangled chest (always kept here)
local EC_SLOT = 16

-- Max regular chests per delivery (must match warehouse CFG.maxChestsPerDelivery)
local MAX_CHESTS = 6

base.init(proto.ROLE.DELIVERY)

-- FORCE_REFUEL: scan slots 1-15 for the fuel ender chest (slot 16 is the delivery
-- EC and must never be placed for refueling). Place it, suck coal, refuel, pick up.
base.setRefuelFn(function()
    local function isEC(item)
        if not item then return false end
        local n = item.name:lower()
        return n:find("ender") or n:find("entangled")
    end
    for s = 1, EC_SLOT - 1 do
        if isEC(turtle.getItemDetail(s)) then
            turtle.select(s)
            if turtle.detectDown() then turtle.digDown() end
            if turtle.placeDown() then
                turtle.select(1)
                turtle.suckDown(64)
                turtle.refuel()
                turtle.select(s)
                turtle.digDown()
                print(string.format("[FUEL] EC refuel (slot %d): %d fuel", s, turtle.getFuelLevel()))
            end
            return
        end
    end
    print("[FUEL] No fuel EC found in slots 1-15 — trying dock chest")
    base.fuel.dockRefuel()
end)

-- ─── Helpers ─────────────────────────────────────────────────────────────────

-- Wait for one of several message types (returns msg or nil on timeout)
local function waitForAny(types, seconds)
    local set = {}
    for _, t in ipairs(types) do set[t] = true end
    local deadline = os.epoch("utc") / 1000 + seconds
    while os.epoch("utc") / 1000 < deadline do
        if base.isRecalled() then return nil end
        if base.isServerDown() then
            deadline = os.epoch("utc") / 1000 + seconds
            sleep(2)
        else
            local msg = proto.receive(base.getSelfId(), math.max(1, deadline - os.epoch("utc") / 1000))
            if msg and set[msg.type] then return msg end
        end
    end
    return nil
end

-- Place a block below, digging first if blocked
local function placeDownClear()
    if turtle.detectDown() then turtle.digDown() end
    return turtle.placeDown()
end

-- Pick up the entangled chest below (best-effort) and verify it landed in EC_SLOT.
-- If the turtle isn't centred over it, the EC can be left behind — warn loudly.
local function pickUpECAndVerify()
    turtle.select(EC_SLOT)
    turtle.digDown()
    local item = turtle.getItemDetail(EC_SLOT)
    if not item or not item.name:find("ender") then
        print("[DELIVERY] WARNING: EC pickup may have failed — slot " .. EC_SLOT
            .. " does not contain ender chest")
    end
end

-- Navigate to position and place a chest below
local function placeChestAt(x, y, z, chestSlot)
    base.move.to(x, y, z)
    turtle.select(chestSlot)
    local placed, reason = placeDownClear()
    if not placed then
        print("[DELIVERY] Failed to place chest: " .. (reason or "?"))
    end
end

-- Build a set of slots that must NEVER be dropped or placed.
-- Called once at job start — catches all ender chests (fuel, delivery, etc.)
-- and any other non-deliverable items already in the turtle.
local function buildProtectedSlots()
    local protected = {}
    for s = 1, 16 do
        local it = turtle.getItemDetail(s)
        if it then
            local n = it.name:lower()
            -- Protect ender/entangled chests and tools (non-stackable items)
            if n:find("ender") or n:find("entangled") or it.maxCount == 1 then
                protected[s] = true
                print(string.format("  Protected slot %d: %s", s, it.name))
            end
        end
    end
    return protected
end

-- ─── Ender chest slot guardian ───────────────────────────────────────────────
--
-- The turtle carries two ender chests: delivery (slot 16) and fuel (some other
-- slot). Both have the same item name so we fingerprint each by NBT at DISPATCH
-- and track them independently. Only the delivery chest may ever be in EC_SLOT.
--
-- Four mandatory checkpoints:
--   1. DISPATCH    — hard abort if delivery chest not in slot 16
--   2. PRE-PLACE   — hard abort if delivery chest missing before placing
--   3. PRE-RETURN  — hard abort if delivery chest not recovered after digging
--   4. ARRIVAL     — warn-only log after returning to dock

-- Slots that hold OTHER ender chests (e.g. fuel chest) — never moved to EC_SLOT.
-- Populated at DISPATCH by scanning slots 1-15 for ender chests.
local otherECSlots = {}

-- NBT fingerprint of the delivery ender chest, captured at DISPATCH.
-- Used to distinguish it from the fuel chest if they swap slots.
local deliveryECNBT = nil

local function isECItem(item)
    if not item then return false end
    local n = item.name:lower()
    return n:find("ender") or n:find("entangled")
end

-- Returns true if slot s holds the DELIVERY ender chest specifically.
-- Falls back to "any ender chest not in otherECSlots" when NBT unavailable.
local function isDeliveryEC(s)
    local item = turtle.getItemDetail(s)
    if not isECItem(item) then return false end
    if otherECSlots[s] then return false end   -- known fuel/other chest slot
    if deliveryECNBT then
        -- Compare NBT to fingerprint (detailed mode)
        local detail = turtle.getItemDetail(s, true)
        if detail and detail.nbt then
            return textutils.serialise(detail.nbt) == deliveryECNBT
        end
        -- No NBT returned — trust the otherECSlots exclusion instead
    end
    return true
end

-- Scan slots 1-15 at DISPATCH: record any ender chests that are NOT in EC_SLOT
-- as "other" (fuel) chests so checkEC never mistakes them for the delivery chest.
local function captureECFingerprints()
    otherECSlots = {}
    -- Capture delivery chest NBT from EC_SLOT
    local detail = turtle.getItemDetail(EC_SLOT, true)
    if detail and detail.nbt then
        deliveryECNBT = textutils.serialise(detail.nbt)
        print(string.format("[EC] Delivery chest NBT fingerprint captured (slot %d)", EC_SLOT))
    else
        deliveryECNBT = nil
        print(string.format("[EC] No NBT for delivery chest — using slot exclusion only"))
    end
    -- Record all other ender chests
    for s = 1, 15 do
        if isECItem(turtle.getItemDetail(s)) then
            otherECSlots[s] = true
            print(string.format("[EC] Other ender chest locked in slot %d (fuel/secondary)", s))
        end
    end
end

local function checkEC(label, hard)
    -- Step 1: check EC_SLOT
    if isDeliveryEC(EC_SLOT) then
        local it = turtle.getItemDetail(EC_SLOT)
        print(string.format("[EC:%s] ✓ slot %d OK (%s)", label, EC_SLOT, it and it.name or "?"))
        return true
    end

    -- Step 2: search for delivery chest in other slots (skip known other-EC slots)
    local foundSlot = nil
    for s = 1, 16 do
        if s ~= EC_SLOT and not otherECSlots[s] and isDeliveryEC(s) then
            foundSlot = s; break
        end
    end

    if not foundSlot then
        if hard then
            print(string.format("[EC:%s] ✗ DELIVERY ENDER CHEST NOT FOUND — aborting", label))
        else
            print(string.format("[EC:%s] ✗ delivery chest not in inventory (on ground?)", label))
        end
        return not hard
    end

    -- Step 3: move delivery chest to EC_SLOT
    if turtle.getItemCount(EC_SLOT) > 0 then
        -- Evict whatever is in EC_SLOT to a free slot
        local evicted = false
        for free = 1, 15 do
            if free ~= foundSlot and not otherECSlots[free] and turtle.getItemCount(free) == 0 then
                turtle.select(EC_SLOT)
                turtle.transferTo(free)
                print(string.format("[EC:%s] Evicted slot %d → slot %d", label, EC_SLOT, free))
                evicted = true; break
            end
        end
        if not evicted then
            print(string.format("[EC:%s] ✗ cannot evict slot %d — no free slot", label, EC_SLOT))
            if hard then return false end
        end
    end

    turtle.select(foundSlot)
    turtle.transferTo(EC_SLOT)
    print(string.format("[EC:%s] Moved delivery chest: slot %d → slot %d", label, foundSlot, EC_SLOT))

    if isDeliveryEC(EC_SLOT) then
        print(string.format("[EC:%s] ✓ slot %d confirmed", label, EC_SLOT))
        return true
    else
        print(string.format("[EC:%s] ✗ transfer failed!", label))
        return not hard
    end
end

-- Drop delivery items into chest below, skipping protected slots.
-- Returns true if turtle still has undelivered items (chest full).
local function dropIntoChestBelow(protected)
    local stillHasItems = false
    for slot = 1, 16 do
        if not protected[slot] and turtle.getItemCount(slot) > 0 then
            turtle.select(slot)
            if not turtle.dropDown() then
                stillHasItems = true  -- chest rejected — full
            end
        end
    end
    return stillHasItems
end

-- ─── Job handler ─────────────────────────────────────────────────────────────

base.run(function(job)
    local params = job.params
    if not params.destination or not params.destination.x or not params.destination.z then
        return base.sendFailed("invalid destination params", false)
    end
    local d      = params.destination
    base.setPartnerId(params.partnerId)

    -- ── Step 1: Queue with warehouse, depart immediately ─────────────────────
    -- Send ITEM_REQUEST to get a queue slot. Turtle carries only the entangled
    -- chest so there is nothing to wait for — depart as soon as queued.

    base.setStatus(proto.STATUS.LOADING, job.id)
    base.sendProgress("Queuing with warehouse")

    -- ── CHECKPOINT 1: DISPATCH ───────────────────────────────────────────────
    -- Fingerprint all ender chests so we never confuse delivery vs fuel chest.
    captureECFingerprints()
    -- Hard check — delivery ender chest MUST be in slot 16 before we do anything.
    if not checkEC("DISPATCH", true) then
        return base.sendFailed("ec_not_in_slot_" .. EC_SLOT .. "_at_dispatch", false)
    end

    -- Scan inventory now and lock down all ender chests + tools.
    -- These slots are NEVER dropped or treated as delivery items.
    print("Scanning protected slots...")
    local protected = buildProtectedSlots()

    -- Send queue request to warehouse via server
    base.sendToServer(proto.MSG.ITEM_REQUEST, {
        jobId = job.id,
        items = params.items or {},
    })

    -- Wait briefly for WAREHOUSE_QUEUED acknowledgment
    local qMsg = waitForAny({ proto.MSG.WAREHOUSE_QUEUED }, 30)
    if not qMsg then
        print("Warehouse did not acknowledge queue — proceeding anyway")
    else
        local pos = qMsg.payload.position or 0
        print(string.format("Warehouse queued at position %d", pos))
    end

    -- ── Step 2: Depart depot via dispatch hole ────────────────────────────────

    local ok, err = base.depart()
    if not ok then
        return base.sendFailed("departure_failed: " .. (err or "?"), true)
    end

    -- ── Step 3: Travel underground to destination X,Z ─────────────────────────

    base.setStatus(proto.STATUS.TRAVELLING, job.id)
    base.sendProgress(string.format("Underground travel to %d,%d", d.x, d.z))

    ok, err = base.move.to(d.x, UNDERGROUND_Y, d.z)
    if not ok then
        return base.sendFailed("underground nav failed: " .. (err or "?"), true)
    end

    -- ── Step 4: Ascend to delivery Y ─────────────────────────────────────────

    local savedPartnerId = base.getPartnerId()
    base.setPartnerId(nil)
    if savedPartnerId then
        base.signalPartnerDirect(proto.MSG.ASCENDING, savedPartnerId, {})
    end

    -- After clearing partnerId for the ascent, all subsequent failure paths must
    -- restore it before sendFailed so the support receives JOB_ABORT and returns.
    local function failDelivery(reason, recoverable)
        if savedPartnerId then base.setPartnerId(savedPartnerId) end
        return base.sendFailed(reason, recoverable)
    end

    base.sendProgress(string.format("Ascending to delivery point Y=%d", d.y))
    ok, err = base.move.to(d.x, d.y, d.z)
    if not ok then
        return failDelivery("ascent failed: " .. (err or "?"), true)
    end

    -- ── Step 5: Entangled chest delivery ─────────────────────────────────────

    base.setStatus(proto.STATUS.WORKING, job.id)
    base.sendProgress("Arrived at destination — setting up delivery")

    -- ── CHECKPOINT 2: PRE-PLACE ──────────────────────────────────────────────
    -- Hard check — must have ender chest in slot 16 before placing it.
    if not checkEC("PRE-PLACE", true) then
        return failDelivery("ec_missing_before_place", true)
    end

    -- Place entangled chest below
    turtle.select(EC_SLOT)
    local ecPlaced, ecReason = placeDownClear()
    if not ecPlaced then
        -- Continue anyway — the batch timeout will catch a stalled handshake.
        print("[DELIVERY] Failed to place entangled chest: " .. (ecReason or "?"))
    end

    -- ── Inventory dump — clear road debris into ender chest ──────────────────
    -- The turtle digs through terrain during travel and accumulates blocks.
    -- Dump everything that isn't a protected item (ender chests, tools) into
    -- the placed ender chest so the warehouse can sweep it into RS storage.
    print("Dumping road debris into ender chest...")
    local dumped = 0
    for slot = 1, 16 do
        if not protected[slot] and turtle.getItemCount(slot) > 0 then
            turtle.select(slot)
            if turtle.dropDown() then
                dumped = dumped + 1
            end
        end
    end
    print("Dumped " .. dumped .. " slot(s) of debris into ender chest")

    -- Tell warehouse we're here.
    -- Include items list in payload so the warehouse can auto-queue us if
    -- our earlier ITEM_REQUEST was lost (e.g. warehouse reboot, network blip).
    local function sendArrived()
        base.sendToServer(proto.MSG.DELIVERY_ARRIVED, {
            jobId = job.id,
            items = params.items or {},
        })
    end
    sendArrived()

    -- Wait for our turn (warehouse may be serving another turtle).
    -- Re-ping every 5s with DELIVERY_ARRIVED (contains items for auto-queue).
    -- Re-send ITEM_REQUEST every 60s as a belt-and-suspenders fallback.
    base.sendProgress("Waiting for warehouse queue...")
    local chestsReady    = false
    local chestCount     = 0
    local deadline       = os.epoch("utc") / 1000 + 600   -- 10 min max queue wait
    local lastIReq       = os.epoch("utc") / 1000
    local waitTick       = 0
    while os.epoch("utc") / 1000 < deadline do
        if base.isServerDown() then
            deadline = os.epoch("utc") / 1000 + 600   -- freeze deadline during outage
            sleep(2)
        end
        local msg = waitForAny({
            proto.MSG.CHESTS_READY,
            proto.MSG.WAREHOUSE_QUEUED,
            proto.MSG.JOB_ABORT,
        }, 5)
        if not msg then
            if base.isRecalled() then
                print("[WH] Recalled while waiting for warehouse — aborting wait")
                pickUpECAndVerify()
                return failDelivery("recalled_while_waiting_for_warehouse", false)
            end
            -- Re-ping warehouse (keeps DELIVERY_ARRIVED fresh in inbox;
            -- also re-queues us if our ITEM_REQUEST was never received)
            sendArrived()
            waitTick = waitTick + 1
            print(string.format(
                "[WH] Waiting for warehouse... %ds remaining (ping #%d)",
                math.max(0, math.floor(deadline - os.epoch("utc") / 1000)), waitTick))
            -- Belt-and-suspenders: re-send ITEM_REQUEST every 60s in case
            -- the warehouse lost our queue slot (e.g. it rebooted)
            if os.epoch("utc") / 1000 - lastIReq >= 60 then
                base.sendToServer(proto.MSG.ITEM_REQUEST, {
                    jobId = job.id,
                    items = params.items or {},
                })
                lastIReq = os.epoch("utc") / 1000
                print("[WH] Re-sent ITEM_REQUEST (safety re-queue)")
            end
        elseif msg.type == proto.MSG.JOB_ABORT then
            -- Pick up entangled chest and abort
            pickUpECAndVerify()
            return base.sendFailed("job_aborted_at_destination", false)
        elseif msg.type == proto.MSG.WAREHOUSE_QUEUED then
            local pos = msg.payload.position or "?"
            print(string.format("[WH] Queue position: %s", tostring(pos)))
            base.sendProgress("Queue position: " .. tostring(pos))
        elseif msg.type == proto.MSG.CHESTS_READY then
            chestCount  = msg.payload.count or 1
            chestsReady = true
            break
        end
    end

    if not chestsReady then
        pickUpECAndVerify()
        return failDelivery("warehouse_chest_timeout", true)
    end

    print(string.format("Pulling %d regular chests from entangled chest", chestCount))

    -- Pull regular chests out of entangled chest into slots 1+
    turtle.select(1)   -- ensure suckDown fills from slot 1, not slot 16
    local pulled = 0
    for _ = 1, chestCount do
        if turtle.suckDown(1) then pulled = pulled + 1 end
    end
    print("Pulled " .. pulled .. " regular chests into inventory")

    -- Place regular chests in a row along Z+1..Z+N from destination
    local chestPositions = {}
    for i = 1, pulled do
        -- Find a regular chest in inventory — skip any protected slot
        local chestSlot = nil
        for s = 1, 16 do
            if not protected[s] then
                local it = turtle.getItemDetail(s)
                if it and it.name:find("chest") then
                    chestSlot = s; break
                end
            end
        end
        if not chestSlot then
            print("No regular chest found in inventory — stopping placement")
            break
        end

        local cx = d.x
        local cy = d.y
        local cz = d.z + i   -- place chests along Z axis from destination

        placeChestAt(cx, cy, cz, chestSlot)
        table.insert(chestPositions, { x = cx, y = cy, z = cz })
        print("Placed chest " .. i .. " at " .. cx .. "," .. cy .. "," .. cz)
    end

    -- Tell warehouse chests are placed
    local function sendChestsPlaced()
        base.sendToServer(proto.MSG.CHESTS_PLACED, {
            jobId = job.id,
            count = #chestPositions,
        })
    end
    sendChestsPlaced()
    print("Chests placed — waiting for warehouse to send items...")

    -- ── Phase 2: Receive items in batches, fill chests ────────────────────────

    base.sendProgress("Receiving items from warehouse")
    local chestIdx = 1   -- tracks which chest we are currently filling
    local batchDeadline = os.epoch("utc") / 1000 + 300  -- 5 minute max for full delivery

    while true do
        local msg = waitForAny({
            proto.MSG.ITEMS_READY,
            proto.MSG.ITEMS_DONE,
            proto.MSG.JOB_ABORT,
        }, 10)

        if base.isRecalled() then
            print("Recalled — picking up EC and returning to dock")
            break
        elseif not msg then
            if os.epoch("utc") / 1000 > batchDeadline then
                print("[WH] Batch phase timed out — aborting delivery")
                base.move.to(d.x, d.y, d.z)
                pickUpECAndVerify()
                return failDelivery("batch_phase_timeout", true)
            end
            -- Re-ping warehouse in case CHESTS_PLACED was missed
            sendChestsPlaced()
            print("Still waiting for warehouse items...")
        elseif msg.type == proto.MSG.JOB_ABORT then
            print("Warehouse aborted job — cleaning up and returning")
            break
        elseif msg.type == proto.MSG.ITEMS_DONE then
            print("All items received from warehouse")
            break
        else
            -- ITEMS_READY: pull batch from ender chest into turtle inventory
            base.move.to(d.x, d.y, d.z)
            turtle.select(1)
            while turtle.suckDown() do end

            -- Fresh batch — start distributing from the first chest again
            chestIdx = 1

            -- Distribute items across placed regular chests
            while chestIdx <= #chestPositions do
                local cp = chestPositions[chestIdx]
                base.move.to(cp.x, cp.y, cp.z)

                local stillHasItems = dropIntoChestBelow(protected)
                if stillHasItems then
                    chestIdx = chestIdx + 1
                else
                    break
                end
            end

            base.sendToServer(proto.MSG.BATCH_DONE, { jobId = job.id })
        end
    end

    -- ── Phase 3: Clean up — pick up entangled chest, signal done ─────────────

    base.move.to(d.x, d.y, d.z)
    -- Select EC_SLOT before digging so the ender chest drops directly back
    -- into slot 16 (works because EC_SLOT was emptied by placeDownClear)
    turtle.select(EC_SLOT)
    turtle.digDown()   -- ender chest should land in slot 16

    -- ── CHECKPOINT 3: PRE-RETURN ─────────────────────────────────────────────
    -- Hard check — ender chest MUST be recovered and in slot 16 before we leave.
    if not checkEC("PRE-RETURN", true) then
        -- Try once more — digDown may have missed (turtle not centred)
        sleep(0.5)
        turtle.select(EC_SLOT)
        turtle.digDown()
        if not checkEC("PRE-RETURN-RETRY", true) then
            return failDelivery("ec_not_recovered_after_delivery", true)
        end
    end

    if not base.isRecalled() then
        base.sendToServer(proto.MSG.ITEM_COLLECTED, { jobId = job.id })
        base.sendProgress("Delivery complete")
    end

    -- ── Step 6: Descend back to underground travel level ─────────────────────

    ok, err = base.move.to(d.x, UNDERGROUND_Y, d.z)
    if not ok then
        print("Warning: could not fully descend — attempting return anyway")
    end

    if savedPartnerId and not base.isRecalled() then
        base.setPartnerId(savedPartnerId)
        base.signalPartner(proto.MSG.DESCENDED, {})
    end

    -- ── Step 7: Return via arrivals hole ─────────────────────────────────────

    ok, err = base.returnToDock()
    if not ok then
        print("Warning: return route issue: " .. (err or "?"))
    end

    -- ── CHECKPOINT 4: ARRIVAL ────────────────────────────────────────────────
    checkEC("ARRIVAL", false)

    if not base.isRecalled() then
        base.sendComplete({ destination = d })
    end
end)
