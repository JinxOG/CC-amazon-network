-- warehouse.lua
-- Manages the entangled-chest delivery queue.
-- Uses an RS (Refined Storage) bridge to pull items and regular chests
-- directly from the RS network — no manual storage chests needed.
--
-- Physical setup:
--   Computer adjacent to (or wired to):
--     * rsBridge        — Advanced Peripherals RS Bridge block
--     * entangled chest — shared with delivery turtles
--   Plus an ender/wireless modem for network comms.

local proto = require("protocol")

-- ─── Peripheral scanner ───────────────────────────────────────────────────────
-- Usage: lua warehouse.lua scan
if arg and arg[1] == "scan" then
    print("=== Peripherals visible to this computer ===")
    local names = peripheral.getNames()
    if #names == 0 then
        print("  (none — check wired modem connections)")
    end
    for _, name in ipairs(names) do
        local ptype = peripheral.getType(name) or "?"
        print(string.format("  %-45s  %s", name, ptype))
    end
    print("\nPaste the matching names into CFG at the top of warehouse.lua")
    return
end

-- ─── Config ──────────────────────────────────────────────────────────────────

local CFG = {
    entangledChest       = "top",             -- ender chest side (enderstorage:ender_chest)
    regularChestItem     = "minecraft:chest", -- item exported for delivery containers
    maxChestsPerDelivery = 6,
    batchSize            = 15,   -- max stacks per item batch (turtle carry cap)
    msgTimeout           = 120,  -- seconds to wait for turtle response
}

-- ─── Peripherals ─────────────────────────────────────────────────────────────

local modem    = peripheral.find("modem")
local rsBridge = peripheral.find("rsBridge")

if not modem    then error("Warehouse: no modem found")     end
if not rsBridge then error("Warehouse: no rsBridge found — attach an Advanced Peripherals RS Bridge") end

modem.open(proto.CH_SERVER)
modem.open(proto.CH_WAREHOUSE)

-- ─── State ───────────────────────────────────────────────────────────────────

local queue   = {}
local current = nil

-- ─── Helpers ─────────────────────────────────────────────────────────────────

local function log(s) print("[WH] " .. tostring(s)) end

local function sendToServer(msgType, toId, payload)
    local msg = proto.encode(msgType, "warehouse", toId, payload)
    proto.send(modem, proto.CH_SERVER, msg)
end

-- How many regular chests does this item list need?
local function chestsNeeded(items)
    local totalStacks = 0
    for _, count in pairs(items) do
        totalStacks = totalStacks + math.ceil(count / 64)
    end
    return math.min(CFG.maxChestsPerDelivery, math.max(1, math.ceil(totalStacks / 27)))
end

-- Export N regular chests from RS → entangled chest
local function loadChests(n)
    local result = rsBridge.exportItem(
        { name = CFG.regularChestItem, count = n },
        CFG.entangledChest
    )
    local moved = (type(result) == "number") and result or (result and result.count or 0)
    log("Loaded " .. moved .. "/" .. n .. " chests into entangled chest")
    return moved
end

-- Export one item stack from RS → entangled chest
-- Returns number actually moved
local function exportItem(name, count)
    local result = rsBridge.exportItem(
        { name = name, count = count },
        CFG.entangledChest
    )
    return (type(result) == "number") and result or (result and result.count or 0)
end

-- Check RS has enough of an item; warn if short
local function checkStock(name, needed)
    local info = rsBridge.getItem({ name = name })
    local have = info and info.amount or 0
    if have < needed then
        log(string.format("WARNING: need %d x %s but RS only has %d", needed, name, have))
    end
    return have
end

-- Wait for a specific message from the current turtle (or any while queueing)
local function waitFor(wantType, seconds)
    local deadline = os.epoch("utc") + seconds * 1000
    while os.epoch("utc") < deadline do
        local ev, _,_,_, p4 = os.pullEventRaw("modem_message")
        if ev == "modem_message" then
            local raw = type(p4) == "table" and p4 or textutils.unserialise(p4)
            if raw then
                local ok, msg = proto.decode(raw)
                if ok then
                    if msg.type == wantType
                    and (not current or msg.from == current.turtleId) then
                        return msg
                    end
                    -- Handle new queue arrivals while waiting
                    if msg.type == proto.MSG.ITEM_REQUEST then
                        local p = msg.payload
                        local n = chestsNeeded(p.items or {})
                        table.insert(queue, {
                            jobId        = p.jobId,
                            turtleId     = msg.from,
                            items        = p.items or {},
                            chestsNeeded = n,
                        })
                        sendToServer(proto.MSG.WAREHOUSE_QUEUED, msg.from, {
                            jobId = p.jobId, position = #queue, chests = n,
                        })
                        log("Queued (waiting): " .. msg.from .. " pos=" .. #queue)
                    end
                end
            end
        end
    end
    return nil
end

-- ─── Queue ───────────────────────────────────────────────────────────────────

local function serveNext()
    if current or #queue == 0 then return end
    current = table.remove(queue, 1)
    log("Serving: " .. current.turtleId .. "  job=" .. current.jobId
        .. "  chests=" .. current.chestsNeeded)
    sendToServer(proto.MSG.WAREHOUSE_QUEUED, current.turtleId, {
        jobId = current.jobId, position = 0, chests = current.chestsNeeded,
    })
end

-- ─── Job handler ─────────────────────────────────────────────────────────────

local function handleCurrentJob()
    if not current then return end

    -- Wait for turtle to arrive at destination
    log("Waiting for DELIVERY_ARRIVED from " .. current.turtleId .. "...")
    local msg = waitFor(proto.MSG.DELIVERY_ARRIVED, CFG.msgTimeout)
    if not msg then
        log("Timeout — skipping " .. current.turtleId)
        current = nil; serveNext(); return
    end

    -- ── Phase 1: export regular chests into entangled chest ──────────────────
    log("Exporting " .. current.chestsNeeded .. " regular chests via RS...")
    local loaded = loadChests(current.chestsNeeded)
    if loaded == 0 then
        log("ERROR: RS has no regular chests ('" .. CFG.regularChestItem .. "') — aborting")
        current = nil; serveNext(); return
    end

    sendToServer(proto.MSG.CHESTS_READY, current.turtleId, {
        jobId = current.jobId, count = loaded,
    })

    -- Wait for turtle to place the chests
    log("Waiting for CHESTS_PLACED...")
    msg = waitFor(proto.MSG.CHESTS_PLACED, CFG.msgTimeout)
    if not msg then
        log("Timeout on CHESTS_PLACED — aborting")
        current = nil; serveNext(); return
    end

    -- ── Phase 2: export items in batches ─────────────────────────────────────
    -- Flatten items into a list of {name, count} respecting batchSize
    local batches = {}
    local batch   = {}
    local bStacks = 0
    for itemName, totalCount in pairs(current.items) do
        checkStock(itemName, totalCount)
        local remaining = totalCount
        while remaining > 0 do
            local stackCount = math.min(remaining, 64)
            table.insert(batch, { name = itemName, count = stackCount })
            bStacks   = bStacks + 1
            remaining = remaining - stackCount
            if bStacks >= CFG.batchSize then
                table.insert(batches, batch)
                batch   = {}
                bStacks = 0
            end
        end
    end
    if #batch > 0 then table.insert(batches, batch) end

    log(string.format("Sending %d item batch(es) of up to %d stacks each",
        #batches, CFG.batchSize))

    -- Always send ITEMS_READY for every batch (including the last) so the
    -- turtle always pulls before we signal done. ITEMS_DONE is sent after
    -- the final BATCH_DONE confirming the ender chest is empty.
    for i, b in ipairs(batches) do
        -- Export this batch into the entangled chest
        for _, entry in ipairs(b) do
            local moved = exportItem(entry.name, entry.count)
            if moved < entry.count then
                log(string.format("Short: %d/%d %s", moved, entry.count, entry.name))
            end
        end

        sendToServer(proto.MSG.ITEMS_READY, current.turtleId, { jobId = current.jobId })
        log(string.format("Batch %d/%d sent — waiting for BATCH_DONE...", i, #batches))
        msg = waitFor(proto.MSG.BATCH_DONE, CFG.msgTimeout)
        if not msg then
            log("Timeout on BATCH_DONE — stopping early")
            break
        end
    end

    -- All batches pulled — tell turtle it's done filling
    sendToServer(proto.MSG.ITEMS_DONE, current.turtleId, { jobId = current.jobId })

    -- Wait for entangled chest to be cleared
    log("Waiting for ITEM_COLLECTED...")
    waitFor(proto.MSG.ITEM_COLLECTED, CFG.msgTimeout)

    log("Job complete: " .. current.jobId)
    current = nil
    serveNext()
end

-- ─── Main loop ───────────────────────────────────────────────────────────────

local function main()
    log("Warehouse online (RS bridge mode)")
    log("Entangled chest : " .. CFG.entangledChest)
    log("RS bridge       : " .. (peripheral.getName(rsBridge) or "found"))

    local ecType = peripheral.getType(CFG.entangledChest)
    if not ecType then
        log("WARNING: no chest found on side '" .. CFG.entangledChest .. "' — check placement")
    else
        log("Ender chest      : " .. ecType .. " (" .. CFG.entangledChest .. ")")
    end

    while true do
        if current then
            handleCurrentJob()
        else
            local ev, _,_,_, p4 = os.pullEvent("modem_message")
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
                        jobId = p.jobId, position = #queue, chests = n,
                    })
                    log("Queued " .. msg.from .. " at position " .. #queue)
                    serveNext()
                end
            end
        end
    end
end

local ok, err = pcall(main)
if not ok then print("CRASH: " .. tostring(err)) end
