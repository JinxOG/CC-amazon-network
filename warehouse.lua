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

-- Import ALL items currently in the ender chest back into RS storage.
-- Used to sweep up road debris the turtle dumped before signalling arrival.
local function clearEnderChest()
    local chest = peripheral.wrap(CFG.entangledChest)
    if not chest then
        log("WARNING: cannot wrap ender chest on side '" .. CFG.entangledChest .. "' — skipping clear")
        return 0
    end
    local slots = chest.list()
    if not slots or next(slots) == nil then
        log("Ender chest already empty — no clear needed")
        return 0
    end
    local totalCleared = 0
    for _, item in pairs(slots) do
        local moved = rsBridge.importItem(
            { name = item.name, count = item.count },
            CFG.entangledChest
        )
        local n = (type(moved) == "number") and moved or (moved and moved.count or 0)
        totalCleared = totalCleared + n
    end
    log(string.format("Cleared %d item(s) from ender chest into RS", totalCleared))
    return totalCleared
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

-- ─── Inbox buffer ────────────────────────────────────────────────────────────
-- Every incoming modem message is decoded and placed here so nothing is ever
-- dropped while we are busy serving a different turtle.
-- Structure: inbox[msgType] = { msg, msg, ... }

local inbox = {}

local function inboxPut(msg)
    if not inbox[msg.type] then inbox[msg.type] = {} end
    table.insert(inbox[msg.type], msg)
end

-- Pull the first buffered message of wantType (optionally from a specific turtle)
local function inboxGet(wantType, fromId)
    local bucket = inbox[wantType]
    if not bucket then return nil end
    for i, msg in ipairs(bucket) do
        if not fromId or msg.from == fromId then
            table.remove(bucket, i)
            return msg
        end
    end
    return nil
end

-- Decode one raw modem payload and route it:
--   ITEM_REQUEST → add to warehouse queue immediately
--   UPDATE_ALL   → run updater
--   anything else → put in inbox for later retrieval
local function routeMsg(raw)
    if not raw then return end
    local ok, msg = proto.decode(raw)
    if not ok then return end

    if msg.type == proto.MSG.UPDATE_ALL then
        log("UPDATE_ALL received — running updater then rebooting...")
        sleep(1)
        if fs.exists("updater.lua") then shell.run("updater")
        else os.reboot() end
        return
    end

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
        log("Queued " .. msg.from .. " at position " .. #queue)
        return
    end

    -- Everything else goes into the inbox for waitFor() to find
    inboxPut(msg)
end

-- Block until a message of wantType arrives from fromId (or anyone if nil).
-- All other messages received while waiting are buffered — never dropped.
local function waitFor(wantType, fromId, seconds)
    -- Check inbox first (message may have already arrived)
    local buffered = inboxGet(wantType, fromId)
    if buffered then return buffered end

    local deadline = os.epoch("utc") + seconds * 1000
    while os.epoch("utc") < deadline do
        -- Use a short timer so the deadline is checked even with no traffic
        local timer = os.startTimer(5)
        local ev, p1, _,_, p4 = os.pullEvent()
        if ev == "modem_message" then
            local raw = type(p4) == "table" and p4 or textutils.unserialise(p4)
            routeMsg(raw)
            local found = inboxGet(wantType, fromId)
            if found then return found end
        end
        -- timer event just lets the deadline re-check; continue looping
        os.cancelTimer(timer)
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
    local msg = waitFor(proto.MSG.DELIVERY_ARRIVED, current.turtleId, CFG.msgTimeout)
    if not msg then
        log("Timeout — skipping " .. current.turtleId)
        current = nil; serveNext(); return
    end
    -- No sleep needed: turtle dumps debris BEFORE sending DELIVERY_ARRIVED,
    -- so the EC is already fully loaded with debris when we get here.

    -- ── Phase 0: clear ender chest — sweep turtle debris into RS ────────────
    log("Clearing turtle debris from ender chest into RS...")
    clearEnderChest()

    -- ── Phase 1: export regular chests into entangled chest ──────────────────
    log("Exporting " .. current.chestsNeeded .. " regular chests via RS...")
    local loaded = loadChests(current.chestsNeeded)
    if loaded == 0 then
        log("ERROR: RS has no regular chests ('" .. CFG.regularChestItem .. "') — aborting")
        current = nil; serveNext(); return
    end

    local function sendChestsReady()
        sendToServer(proto.MSG.CHESTS_READY, current.turtleId, {
            jobId = current.jobId, count = loaded,
        })
    end
    sendChestsReady()

    -- Wait for turtle to place the chests.
    -- If the turtle re-sends DELIVERY_ARRIVED it missed CHESTS_READY — resend it.
    log("Waiting for CHESTS_PLACED...")
    local placed = false
    local chestDeadline = os.clock() + CFG.msgTimeout
    while os.clock() < chestDeadline do
        msg = waitFor(proto.MSG.CHESTS_PLACED, current.turtleId, 8)
        if msg then placed = true; break end
        -- Turtle re-pinged — it missed CHESTS_READY, send it again
        local reping = inboxGet(proto.MSG.DELIVERY_ARRIVED, current.turtleId)
        if reping then
            log("Turtle re-pinged — re-sending CHESTS_READY")
            sendChestsReady()
        end
    end
    if not placed then
        log("Timeout on CHESTS_PLACED — sweeping EC and aborting")
        clearEnderChest()   -- recover any stranded chests back to RS
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
        msg = waitFor(proto.MSG.BATCH_DONE, current.turtleId, CFG.msgTimeout)
        if not msg then
            log("Timeout on BATCH_DONE — sweeping EC and stopping early")
            clearEnderChest()
            break
        end
    end

    -- All batches pulled — tell turtle it's done filling
    sendToServer(proto.MSG.ITEMS_DONE, current.turtleId, { jobId = current.jobId })

    -- Wait for entangled chest to be cleared
    log("Waiting for ITEM_COLLECTED...")
    local collected = waitFor(proto.MSG.ITEM_COLLECTED, current.turtleId, CFG.msgTimeout)
    if not collected then
        log("Timeout on ITEM_COLLECTED — sweeping EC")
        clearEnderChest()
    end

    log("Job complete: " .. current.jobId)
    current = nil
    serveNext()
end

-- ─── Main loop ───────────────────────────────────────────────────────────────

local function main()
    log(string.format("Warehouse online v%s (RS bridge mode)", proto.VERSION))
    log("Entangled chest : " .. CFG.entangledChest)
    log("RS bridge       : " .. (peripheral.getName(rsBridge) or "found"))
    -- Sweep any items left in the EC from a previous session (crashed job, etc.)
    log("Startup EC sweep...")
    clearEnderChest()

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
            -- Try to serve from queue immediately (handles already-buffered ITEM_REQUESTs)
            serveNext()
            if current then
                -- serveNext() found something — loop back and handle it
            else
                -- Truly idle: block until next modem message, then route and try again
                local ev, _,_,_, p4 = os.pullEvent("modem_message")
                local raw = type(p4) == "table" and p4 or textutils.unserialise(p4)
                routeMsg(raw)
                serveNext()
            end
        end
    end
end

local ok, err = pcall(main)
if not ok then print("CRASH: " .. tostring(err)) end
