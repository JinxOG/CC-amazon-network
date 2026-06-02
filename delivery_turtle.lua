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

-- ─── Helpers ─────────────────────────────────────────────────────────────────

-- Wait for one of several message types (returns msg or nil on timeout)
local function waitForAny(types, seconds)
    local set = {}
    for _, t in ipairs(types) do set[t] = true end
    local deadline = os.clock() + seconds
    while os.clock() < deadline do
        local msg = proto.receive(base.getSelfId(), math.max(1, deadline - os.clock()))
        if msg and set[msg.type] then return msg end
    end
    return nil
end

-- Place a block below, digging first if blocked
local function placeDownClear()
    if turtle.detectDown() then turtle.digDown() end
    return turtle.placeDown()
end

-- Navigate to position and place a chest below
local function placeChestAt(x, y, z, chestSlot)
    base.move.to(x, y, z)
    turtle.select(chestSlot)
    placeDownClear()
end

-- Fill chest below from turtle inventory (slots 1-15), tracking how full it is.
-- Returns true if chest is full (no more room), false if items remain.
local function dropIntoChestBelow()
    local full = false
    for slot = 1, EC_SLOT - 1 do
        if turtle.getItemCount(slot) > 0 then
            turtle.select(slot)
            if not turtle.dropDown() then
                full = true  -- chest rejected — assume full
            end
        end
    end
    return full
end

-- ─── Job handler ─────────────────────────────────────────────────────────────

base.run(function(job)
    local params = job.params
    local d      = params.destination
    base.setPartnerId(params.partnerId)

    -- ── Step 1: Queue with warehouse, depart immediately ─────────────────────
    -- Send ITEM_REQUEST to get a queue slot. Turtle carries only the entangled
    -- chest so there is nothing to wait for — depart as soon as queued.

    base.setStatus(proto.STATUS.LOADING, job.id)
    base.sendProgress("Queuing with warehouse")

    -- Delivery ender chest must be in slot 16 (reserved).
    -- The turtle may carry multiple ender chests (e.g. one for fuel) so we
    -- use a fixed slot to avoid picking the wrong colour combination.
    local ecItem = turtle.getItemDetail(EC_SLOT)
    if not ecItem then
        return base.sendFailed("no_ender_chest_in_slot_" .. EC_SLOT, false)
    end
    print("Delivery ender chest: slot " .. EC_SLOT .. " (" .. ecItem.name .. ")")

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

    base.sendProgress(string.format("Ascending to delivery point Y=%d", d.y))
    ok, err = base.move.to(d.x, d.y, d.z)
    if not ok then
        return base.sendFailed("ascent failed: " .. (err or "?"), true)
    end

    -- ── Step 5: Entangled chest delivery ─────────────────────────────────────

    base.setStatus(proto.STATUS.WORKING, job.id)
    base.sendProgress("Arrived at destination — setting up delivery")

    -- Place entangled chest below
    turtle.select(EC_SLOT)
    placeDownClear()

    -- Tell warehouse we're here
    base.sendToServer(proto.MSG.DELIVERY_ARRIVED, { jobId = job.id })

    -- Wait for our turn (warehouse may be serving another turtle)
    base.sendProgress("Waiting for warehouse queue...")
    local chestsReady = false
    local chestCount  = 0
    local deadline    = os.clock() + 600   -- 10 min max queue wait
    while os.clock() < deadline do
        local msg = waitForAny({
            proto.MSG.CHESTS_READY,
            proto.MSG.WAREHOUSE_QUEUED,
            proto.MSG.JOB_ABORT,
        }, 20)
        if not msg then
            -- Ping warehouse again
            base.sendToServer(proto.MSG.DELIVERY_ARRIVED, { jobId = job.id })
        elseif msg.type == proto.MSG.JOB_ABORT then
            -- Pick up entangled chest and abort
            turtle.select(EC_SLOT); turtle.digDown()
            return base.sendFailed("job_aborted_at_destination", false)
        elseif msg.type == proto.MSG.WAREHOUSE_QUEUED then
            local pos = msg.payload.position or "?"
            base.sendProgress("Queue position: " .. tostring(pos))
        elseif msg.type == proto.MSG.CHESTS_READY then
            chestCount  = msg.payload.count or 1
            chestsReady = true
            break
        end
    end

    if not chestsReady then
        turtle.select(EC_SLOT); turtle.digDown()
        return base.sendFailed("warehouse_chest_timeout", true)
    end

    print(string.format("Pulling %d regular chests from entangled chest", chestCount))

    -- Pull regular chests out of entangled chest (they go into slots 1-15)
    local pulled = 0
    for _ = 1, chestCount do
        if turtle.suckDown(1) then pulled = pulled + 1 end
    end

    -- Place regular chests in a row along Z+1..Z+N from destination
    local chestPositions = {}
    for i = 1, pulled do
        -- Find a regular chest in inventory (not entangled)
        local chestSlot = nil
        for s = 1, EC_SLOT - 1 do
            local it = turtle.getItemDetail(s)
            if it and it.name:find("chest")
            and not it.name:lower():find("ender")
            and not it.name:lower():find("entangled") then
                chestSlot = s; break
            end
        end
        if not chestSlot then break end

        local cx = d.x
        local cy = d.y
        local cz = d.z + i   -- place chests along Z axis from destination

        placeChestAt(cx, cy, cz, chestSlot)
        table.insert(chestPositions, { x = cx, y = cy, z = cz })
        print("Placed chest " .. i .. " at " .. cx .. "," .. cy .. "," .. cz)
    end

    -- Tell warehouse chests are placed
    base.sendToServer(proto.MSG.CHESTS_PLACED, {
        jobId = job.id,
        count = #chestPositions,
    })

    -- ── Phase 2: Receive items in batches, fill chests ────────────────────────

    base.sendProgress("Receiving items from warehouse")
    local chestIdx = 1   -- which regular chest we are currently filling

    while true do
        local msg = waitForAny({
            proto.MSG.ITEMS_READY,
            proto.MSG.ITEMS_DONE,
        }, 120)

        if not msg then
            print("Timeout waiting for items — aborting fill")
            break
        end

        if msg.type == proto.MSG.ITEMS_DONE then
            print("All items received from warehouse")
            break
        end

        -- ITEMS_READY: go pull the batch from entangled chest
        base.move.to(d.x, d.y, d.z)
        while turtle.suckDown() do end   -- pull all into turtle inventory

        -- Distribute into placed regular chests
        for _, cp in ipairs(chestPositions) do
            if chestIdx > #chestPositions then break end
            base.move.to(cp.x, cp.y, cp.z)
            local isFull = dropIntoChestBelow()
            if not isFull then
                -- Chest has space — stay here for next batch too
                break
            else
                chestIdx = chestIdx + 1
            end
        end

        -- Confirm batch received
        base.sendToServer(proto.MSG.BATCH_DONE, { jobId = job.id })
    end

    -- ── Phase 3: Clean up — pick up entangled chest, signal done ─────────────

    base.move.to(d.x, d.y, d.z)
    turtle.digDown()   -- picks up entangled chest back into inventory

    base.sendToServer(proto.MSG.ITEM_COLLECTED, { jobId = job.id })
    base.sendProgress("Delivery complete")

    -- ── Step 6: Descend back to underground travel level ─────────────────────

    ok, err = base.move.to(d.x, UNDERGROUND_Y, d.z)
    if not ok then
        print("Warning: could not fully descend — attempting return anyway")
    end

    if savedPartnerId then
        base.setPartnerId(savedPartnerId)
        base.signalPartner(proto.MSG.DESCENDED, {})
    end

    -- ── Step 7: Return via arrivals hole ─────────────────────────────────────

    ok, err = base.returnToDock()
    if not ok then
        print("Warning: return route issue: " .. (err or "?"))
    end

    base.sendComplete({ destination = d })
end)
