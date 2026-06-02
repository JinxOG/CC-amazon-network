-- warehouse.lua
-- Manages the entangled-chest delivery queue.
-- One job is served at a time to prevent chest conflicts between turtles.
--
-- Physical setup:
--   - This computer sits next to (or connected via wired modem to):
--       * The entangled chest  (shared with delivery turtles)
--       * A supply chest       (stocked with empty regular chests)
--       * One or more storage chests (containing items to deliver)
--   - An ender/wireless modem for network comms
--
-- Configure the peripheral names below, then install as startup.lua.

local proto = require("protocol")

-- ─── Peripheral scanner (run standalone to find names) ───────────────────────
-- Usage: lua warehouse.lua scan
if arg and arg[1] == "scan" then
    print("=== Peripherals visible to this computer ===")
    local names = peripheral.getNames()
    if #names == 0 then
        print("  (none found — check wired modem connections)")
    end
    for _, name in ipairs(names) do
        local ptype = peripheral.getType(name)
        local extra = ""
        if ptype == "inventory" or name:find("chest") then
            local p = peripheral.wrap(name)
            local ok, items = pcall(function() return p.list() end)
            if ok then
                local count = 0
                for _ in pairs(items) do count = count + 1 end
                extra = "  [" .. count .. " stacks]"
            end
        end
        print(string.format("  %-40s  %s%s", name, ptype or "?", extra))
    end
    print("")
    print("Paste the matching names into CFG at the top of warehouse.lua")
    return
end

-- ─── Config ──────────────────────────────────────────────────────────────────
-- Run peripheral.getNames() on this computer to find the right names.

local CFG = {
    entangledChest       = "entangled:chest_0",  -- entangled chest peripheral name
    supplyChest          = "minecraft:chest_0",  -- chest holding empty regular chests
    storageChests        = {                     -- chests holding items for delivery
        "minecraft:chest_1",
        "minecraft:chest_2",
    },
    regularChestItem     = "minecraft:chest",    -- item name for regular chest
    maxChestsPerDelivery = 6,                    -- hard cap per delivery
    batchSize            = 15,                   -- max stacks pushed per batch (turtle carry cap)
    msgTimeout           = 120,                  -- seconds to wait for turtle response
}

-- ─── State ───────────────────────────────────────────────────────────────────

local queue   = {}   -- { {jobId, turtleId, items, chestsNeeded}, ... }
local current = nil  -- job currently being served

-- ─── Helpers ─────────────────────────────────────────────────────────────────

local function log(s) print("[WH] " .. tostring(s)) end

local modem = peripheral.find("modem")
if not modem then error("Warehouse: no modem found") end
modem.open(proto.CH_SERVER)   -- receives from server (warehouse is on CH_WAREHOUSE from server's view)
modem.open(proto.CH_WAREHOUSE)

local function sendToServer(msgType, toId, payload)
    local msg = proto.encode(msgType, "warehouse", toId, payload)
    proto.send(modem, proto.CH_SERVER, msg)
end

-- Count how many regular chests an item list needs
local function chestsNeeded(items)
    local totalStacks = 0
    for _, count in pairs(items) do
        totalStacks = totalStacks + math.ceil(count / 64)
    end
    return math.min(CFG.maxChestsPerDelivery, math.max(1, math.ceil(totalStacks / 27)))
end

-- Push N empty regular chests from supply chest → entangled chest
local function loadChests(n)
    local supply = peripheral.wrap(CFG.supplyChest)
    if not supply then log("ERROR: supply chest not found: " .. CFG.supplyChest); return 0 end
    local loaded = 0
    for slot, stack in pairs(supply.list()) do
        if loaded >= n then break end
        if stack.name == CFG.regularChestItem then
            local amount = math.min(stack.count, n - loaded)
            local moved  = supply.pushItems(CFG.entangledChest, slot, amount)
            loaded = loaded + moved
        end
    end
    log("Loaded " .. loaded .. "/" .. n .. " chests into entangled")
    return loaded
end

-- Flatten items table into a list of {name, count} for batch iteration
local function flattenItems(items)
    local flat = {}
    for name, count in pairs(items) do
        -- Split into 64-per-stack entries
        local remaining = count
        while remaining > 0 do
            local batch = math.min(remaining, 64)
            table.insert(flat, { name = name, count = batch })
            remaining = remaining - batch
        end
    end
    return flat
end

-- Push up to batchSize stacks from storage chests → entangled chest
-- Returns number of stacks actually pushed, and whether more remain
local function loadBatch(flatItems, startIdx)
    local pushed   = 0
    local idx      = startIdx
    while idx <= #flatItems and pushed < CFG.batchSize do
        local entry   = flatItems[idx]
        local needed  = entry.count
        local fulfilled = false
        for _, storageName in ipairs(CFG.storageChests) do
            if needed <= 0 then break end
            local storage = peripheral.wrap(storageName)
            if storage then
                for slot, stack in pairs(storage.list()) do
                    if needed <= 0 then break end
                    if stack.name == entry.name then
                        local amount = math.min(stack.count, needed)
                        local moved  = storage.pushItems(CFG.entangledChest, slot, amount)
                        needed = needed - moved
                    end
                end
            end
        end
        if needed > 0 then
            log("WARNING: short " .. needed .. "x " .. entry.name)
        end
        pushed = pushed + 1
        idx    = idx + 1
    end
    log("Batch loaded: " .. pushed .. " stacks (items " .. startIdx .. "-" .. (idx-1) .. ")")
    return pushed, idx
end

-- Wait for a specific message type from the current turtle (with timeout)
local function waitFor(msgType, seconds)
    local deadline = os.epoch("utc") + seconds * 1000
    while os.epoch("utc") < deadline do
        local remaining = (deadline - os.epoch("utc")) / 1000
        local ev, p1, p2, p3, p4 = os.pullEventRaw("modem_message")
        if ev == "modem_message" then
            local raw = type(p4) == "table" and p4 or textutils.unserialise(p4)
            if raw then
                local ok, msg = proto.decode(raw)
                if ok and msg.type == msgType
                and (not current or msg.from == current.turtleId) then
                    return msg
                end
                -- Still handle other queue messages while waiting
                if ok and msg.type == proto.MSG.ITEM_REQUEST then
                    local p = msg.payload
                    local n = chestsNeeded(p.items or {})
                    table.insert(queue, {
                        jobId        = p.jobId,
                        turtleId     = msg.from,
                        items        = p.items or {},
                        chestsNeeded = n,
                    })
                    sendToServer(proto.MSG.WAREHOUSE_QUEUED, msg.from, {
                        jobId    = p.jobId,
                        position = #queue,
                        chests   = n,
                    })
                    log("Queued (while waiting): " .. msg.from .. " pos=" .. #queue)
                end
            end
        end
    end
    return nil  -- timeout
end

-- ─── Queue ───────────────────────────────────────────────────────────────────

local function serveNext()
    if current or #queue == 0 then return end
    current = table.remove(queue, 1)
    log("Now serving: " .. current.turtleId .. " job=" .. current.jobId
        .. " chests=" .. current.chestsNeeded)
    -- Turtle may already be at destination waiting — send WAREHOUSE_QUEUED pos=0 as "you're next"
    sendToServer(proto.MSG.WAREHOUSE_QUEUED, current.turtleId, {
        jobId    = current.jobId,
        position = 0,
        chests   = current.chestsNeeded,
    })
end

-- ─── Main job handler (runs synchronously for one job) ───────────────────────

local function handleCurrentJob()
    if not current then return end
    log("Waiting for DELIVERY_ARRIVED from " .. current.turtleId)

    -- Wait for turtle to arrive at destination
    local msg = waitFor(proto.MSG.DELIVERY_ARRIVED, CFG.msgTimeout)
    if not msg then
        log("Timeout waiting for arrival of " .. current.turtleId .. " — skipping job")
        current = nil
        serveNext()
        return
    end

    -- ── Phase 1: Load and send regular chests ────────────────────────────────
    log("Turtle arrived. Loading " .. current.chestsNeeded .. " chests...")
    local loaded = loadChests(current.chestsNeeded)
    if loaded == 0 then
        log("ERROR: no regular chests in supply — aborting job")
        current = nil; serveNext(); return
    end

    sendToServer(proto.MSG.CHESTS_READY, current.turtleId, {
        jobId = current.jobId,
        count = loaded,
    })

    -- Wait for turtle to place the chests
    log("Waiting for CHESTS_PLACED...")
    msg = waitFor(proto.MSG.CHESTS_PLACED, CFG.msgTimeout)
    if not msg then
        log("Timeout waiting for CHESTS_PLACED — aborting")
        current = nil; serveNext(); return
    end

    -- ── Phase 2: Send items in batches ───────────────────────────────────────
    local flatItems = flattenItems(current.items)
    local idx       = 1
    log("Sending " .. #flatItems .. " stacks in batches of " .. CFG.batchSize)

    while idx <= #flatItems do
        local pushed, nextIdx = loadBatch(flatItems, idx)
        idx = nextIdx

        local isLast = idx > #flatItems
        if isLast then
            sendToServer(proto.MSG.ITEMS_DONE, current.turtleId, { jobId = current.jobId })
        else
            sendToServer(proto.MSG.ITEMS_READY, current.turtleId, { jobId = current.jobId })
        end

        if not isLast then
            -- Wait for turtle to pull batch before loading the next one
            log("Waiting for BATCH_DONE...")
            msg = waitFor(proto.MSG.BATCH_DONE, CFG.msgTimeout)
            if not msg then
                log("Timeout waiting for BATCH_DONE — aborting remaining batches")
                break
            end
        end
    end

    -- ── Phase 3: Wait for turtle to confirm entangled chest is clear ──────────
    log("Waiting for ITEM_COLLECTED...")
    waitFor(proto.MSG.ITEM_COLLECTED, CFG.msgTimeout)

    log("Job complete: " .. current.jobId)
    current = nil
    serveNext()
end

-- ─── Main loop ───────────────────────────────────────────────────────────────

local function main()
    log("Warehouse online. Channels: " .. proto.CH_SERVER .. " / " .. proto.CH_WAREHOUSE)
    log("Entangled chest : " .. CFG.entangledChest)
    log("Supply chest    : " .. CFG.supplyChest)
    log("Storage chests  : " .. #CFG.storageChests)

    -- Verify peripherals
    if not peripheral.isPresent(CFG.entangledChest) then
        log("WARNING: entangled chest not found — check CFG.entangledChest")
    end
    if not peripheral.isPresent(CFG.supplyChest) then
        log("WARNING: supply chest not found — check CFG.supplyChest")
    end

    while true do
        -- If we have a current job to serve, drive it to completion
        if current then
            handleCurrentJob()
        else
            -- Wait for next ITEM_REQUEST
            local ev, p1, p2, p3, p4 = os.pullEvent("modem_message")
            local raw = type(p4) == "table" and p4 or textutils.unserialise(p4)
            if raw then
                local ok, msg = proto.decode(raw)
                if ok and msg.type == proto.MSG.ITEM_REQUEST then
                    local p = msg.payload
                    local n = chestsNeeded(p.items or {})
                    table.insert(queue, {
                        jobId        = p.jobId,
                        turtleId     = msg.from,
                        items        = p.items or {},
                        chestsNeeded = n,
                    })
                    sendToServer(proto.MSG.WAREHOUSE_QUEUED, msg.from, {
                        jobId    = p.jobId,
                        position = #queue,
                        chests   = n,
                    })
                    log("Queued " .. msg.from .. " pos=" .. #queue)
                    serveNext()
                end
            end
        end
    end
end

local ok, err = pcall(main)
if not ok then print("CRASH: " .. tostring(err)) end
