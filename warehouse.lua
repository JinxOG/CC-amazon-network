-- warehouse.lua
-- Manages the entangled-chest delivery queue.
-- Uses an RS (Refined Storage) bridge to pull items and regular chests
-- directly from the RS network.
--
-- Architecture: event-driven state machine.
-- The main loop never blocks waiting for one specific message; instead every
-- incoming message is routed to an inbox and tick() advances the current job's
-- state on every event. This prevents phantom queue entries, duplicate service,
-- and long waits caused by missed messages.

local proto = require("protocol")

-- ─── Peripheral scanner ───────────────────────────────────────────────────────
if arg and arg[1] == "scan" then
    print("=== Peripherals visible to this computer ===")
    local names = peripheral.getNames()
    if #names == 0 then print("  (none)") end
    for _, name in ipairs(names) do
        print(string.format("  %-45s  %s", name, peripheral.getType(name) or "?"))
    end
    print("\nPaste matching names into CFG at the top of warehouse.lua")
    return
end

-- ─── Config ──────────────────────────────────────────────────────────────────

local CFG = {
    entangledChest       = "top",
    regularChestItem     = "minecraft:chest",
    maxChestsPerDelivery = 6,
    batchSize            = 15,    -- max stacks per item batch
    msgTimeout           = 120,   -- seconds for mid-job steps (CHESTS_PLACED, BATCH_DONE, etc.)
    arrivalTimeout       = 1800,  -- seconds to wait for DELIVERY_ARRIVED (covers server outages)
}

-- ─── Peripherals ─────────────────────────────────────────────────────────────

local modem    = peripheral.find("modem")
local rsBridge = peripheral.find("rsBridge")

if not modem    then error("Warehouse: no modem found") end
if not rsBridge then error("Warehouse: no rsBridge found — attach an Advanced Peripherals RS Bridge") end

modem.open(proto.CH_SERVER)
modem.open(proto.CH_WAREHOUSE)

-- ─── Helpers ─────────────────────────────────────────────────────────────────

local function log(s) print("[WH] " .. tostring(s)) end

local function sendToServer(msgType, toId, payload)
    local msg = proto.encode(msgType, "warehouse", toId, payload)
    proto.send(modem, proto.CH_SERVER, msg)
end

local function chestsNeeded(items)
    local totalStacks = 0
    for _, count in pairs(items) do
        totalStacks = totalStacks + math.ceil(count / 64)
    end
    return math.min(CFG.maxChestsPerDelivery, math.max(1, math.ceil(totalStacks / 27)))
end

local function clearEnderChest()
    local chest = peripheral.wrap(CFG.entangledChest)
    if not chest then
        log("WARNING: cannot wrap ender chest on '" .. CFG.entangledChest .. "'")
        return 0
    end
    local total = 0
    -- Verification loop: 1 initial pass + up to 3 retries. RS storage being full
    -- or an un-insertable item can leave residue that contaminates the next batch.
    for attempt = 1, 4 do
        local slots = chest.list()
        if not slots or next(slots) == nil then
            if attempt == 1 then log("Ender chest already empty — no clear needed") end
            return total
        end
        for _, item in pairs(slots) do
            local moved = rsBridge.importItem({ name = item.name, count = item.count }, CFG.entangledChest)
            total = total + ((type(moved) == "number") and moved or (moved and moved.count or 0))
        end
        if attempt < 4 then sleep(1) end
    end
    -- Final check after all attempts
    local remaining = chest.list()
    if remaining and next(remaining) ~= nil then
        log("WARNING: EC not fully cleared after 4 attempts — residue may contaminate next batch")
    end
    log(string.format("Cleared %d item(s) from ender chest into RS", total))
    return total
end

local function loadChests(n)
    local result = rsBridge.exportItem({ name = CFG.regularChestItem, count = n }, CFG.entangledChest)
    local moved  = (type(result) == "number") and result or (result and result.count or 0)
    log("Loaded " .. moved .. "/" .. n .. " chests into entangled chest")
    return moved
end

local function exportItem(name, count)
    local result = rsBridge.exportItem({ name = name, count = count }, CFG.entangledChest)
    return (type(result) == "number") and result or (result and result.count or 0)
end

local function checkStock(name, needed)
    local info = rsBridge.getItem({ name = name })
    local have = info and info.amount or 0
    if have < needed then
        log(string.format("WARNING: need %d x %s but RS only has %d", needed, name, have))
        return false, have
    end
    return true, have
end

-- ─── Inbox ───────────────────────────────────────────────────────────────────
-- Incoming messages (except ITEM_REQUEST, UPDATE_ALL, JOB_ABORT) are buffered
-- here so tick() can pull them when the state machine is ready.

local inbox = {}

local function inboxPut(msg)
    if not inbox[msg.type] then inbox[msg.type] = {} end
    table.insert(inbox[msg.type], msg)
end

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

-- ─── State Machine ───────────────────────────────────────────────────────────

local queue   = {}   -- [{jobId, turtleId, items, chestsNeeded}]
local current = nil  -- job entry being served right now

local S = {
    IDLE        = "IDLE",
    WAIT_ARRIVE = "WAIT_ARRIVE",  -- waiting for DELIVERY_ARRIVED from turtle
    WAIT_PLACED = "WAIT_PLACED",  -- chests loaded, waiting for CHESTS_PLACED
    SEND_BATCH  = "SEND_BATCH",   -- export next item batch (immediate transition)
    WAIT_BATCH  = "WAIT_BATCH",   -- batch exported, waiting for BATCH_DONE
    WAIT_DONE   = "WAIT_DONE",    -- all items sent, waiting for ITEM_COLLECTED
}

local state      = S.IDLE
local stateTs    = 0      -- os.epoch("utc") when we entered current state
local lastHeartbeatLog = 0  -- last time we logged the "still alive" heartbeat
local lastLoaded = 0      -- chests loaded (kept for CHESTS_READY re-pings)
local batches    = {}     -- item batches queued for delivery
local batchIdx   = 0      -- index of batch currently being sent

local function enterState(s)
    state   = s
    stateTs = os.epoch("utc")
end

-- Re-broadcast every waiting turtle's current position. Called whenever the
-- queue advances so turtles don't display a stale enqueue-time position.
local function broadcastQueuePositions()
    for i, entry in ipairs(queue) do
        sendToServer(proto.MSG.WAREHOUSE_QUEUED, entry.turtleId, {
            jobId    = entry.jobId,
            position = i,
            chests   = entry.chestsNeeded,
        })
    end
end

local function abortCurrent(reason)
    if current then
        log(string.format("Abort [%s]: %s — sweeping EC", current.jobId, reason))
        -- Proactively recall the turtle so it fails fast instead of waiting for
        -- its own batch deadline. Routed via the server (fwdToTurtle by jobId),
        -- same path as CHESTS_READY etc., so the payload must carry the jobId.
        sendToServer(proto.MSG.RECALL, current.turtleId, {
            jobId  = current.jobId,
            reason = reason or "warehouse_abort",
        })
        clearEnderChest()
        current = nil
    end
    batches  = {}
    batchIdx = 0
    broadcastQueuePositions()
    enterState(S.IDLE)
end

-- ─── Message router ───────────────────────────────────────────────────────────
-- Called for every incoming modem message.
-- Handles urgent messages (UPDATE_ALL, JOB_ABORT, ITEM_REQUEST) immediately;
-- everything else goes to the inbox for tick() to consume.

local function routeMsg(raw)
    if not raw then return end
    local ok, msg = proto.decode(raw)
    if not ok then return end

    -- ── Hard reboot ─────────────────────────────────────────────────────────
    if msg.type == proto.MSG.UPDATE_ALL then
        log("UPDATE_ALL — rebooting...")
        sleep(1)
        if fs.exists("updater.lua") then shell.run("updater") else os.reboot() end
        return
    end

    -- ── Server abort: stale job not known to server ─────────────────────────
    -- Sent by server when fwdToTurtle can't find the job (e.g. after reboot).
    -- Immediately clears current and returns to IDLE so the real turtle's
    -- ITEM_REQUEST (which IS in the queue) gets served next.
    if msg.type == proto.MSG.JOB_ABORT then
        if current and msg.payload.jobId == current.jobId then
            log("Server abort for job " .. current.jobId)
            abortCurrent("server abort")
        end
        return
    end

    -- ── Queue new delivery ───────────────────────────────────────────────────
    -- Deduplicate: the same (jobId) must never appear in the queue twice.
    -- Turtles can send duplicate ITEM_REQUESTs when they miss the WAREHOUSE_QUEUED
    -- acknowledgement or when the turtle resumes after a server reboot.
    if msg.type == proto.MSG.ITEM_REQUEST then
        local p = msg.payload
        if current and current.jobId == p.jobId then
            -- Already serving this job — turtle probably re-sent on reconnect.
            -- Re-send WAREHOUSE_QUEUED (position=0) so it knows it's being served.
            log("Duplicate ITEM_REQUEST for " .. p.jobId .. " (serving) — ignored")
            sendToServer(proto.MSG.WAREHOUSE_QUEUED, msg.from, {
                jobId = p.jobId, position = 0, chests = current.chestsNeeded,
            })
            return
        end
        for _, e in ipairs(queue) do
            if e.jobId == p.jobId then
                log("Duplicate ITEM_REQUEST for " .. p.jobId .. " (queued) — ignored")
                return
            end
        end
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
        log(string.format("Queued %s (job %s) at position %d", msg.from, p.jobId, #queue))
        return
    end

    -- ── DELIVERY_ARRIVED: auto-queue if ITEM_REQUEST was lost ───────────────
    -- Turtles include their items list in DELIVERY_ARRIVED so we can queue them
    -- even if their original ITEM_REQUEST never arrived (warehouse reboot, blip).
    -- If they are already queued or being served this is a no-op.
    if msg.type == proto.MSG.DELIVERY_ARRIVED then
        local p = msg.payload
        if p.items then
            -- De-dup by BOTH turtleId AND jobId. A turtle whose job was cancelled
            -- and re-issued (same turtle, new jobId) must not be blocked by a stale
            -- queue entry — replace it so it isn't served with the wrong jobId.
            local existingIdx = nil
            for i, e in ipairs(queue) do
                if e.turtleId == msg.from then existingIdx = i; break end
            end
            if existingIdx then
                if queue[existingIdx].jobId ~= p.jobId then
                    queue[existingIdx] = {
                        jobId        = p.jobId,
                        turtleId     = msg.from,
                        items        = p.items,
                        chestsNeeded = chestsNeeded(p.items),
                    }
                    log(string.format("Replaced stale queue entry for %s with new job %s",
                        msg.from, tostring(p.jobId)))
                end
                -- same turtle + same jobId already queued: no-op
            elseif not (current and current.turtleId == msg.from and current.jobId == p.jobId) then
                local n = chestsNeeded(p.items)
                table.insert(queue, {
                    jobId        = p.jobId,
                    turtleId     = msg.from,
                    items        = p.items,
                    chestsNeeded = n,
                })
                sendToServer(proto.MSG.WAREHOUSE_QUEUED, msg.from, {
                    jobId = p.jobId, position = #queue, chests = n,
                })
                log(string.format("Auto-queued %s (job %s) — ITEM_REQUEST was lost",
                    msg.from, tostring(p.jobId)))
            end
        end
        -- Fall through to inboxPut so state machine can consume it in WAIT_ARRIVE
    end

    -- ── Mid-job messages from unknown jobs ───────────────────────────────────
    -- If the warehouse rebooted, it has no record of in-progress jobs.
    -- Turtles stuck in Phase 2 will keep re-sending CHESTS_PLACED.
    -- Send JOB_ABORT so they clean up and return to dock instead of looping forever.
    local midJobTypes = {
        [proto.MSG.CHESTS_PLACED] = true,
        [proto.MSG.BATCH_DONE]    = true,
        [proto.MSG.ITEM_COLLECTED]= true,
    }
    if midJobTypes[msg.type] then
        local jobId = msg.payload and msg.payload.jobId
        local knownJob = (current and current.jobId == jobId)
        if not knownJob then
            for _, e in ipairs(queue) do
                if e.jobId == jobId then knownJob = true; break end
            end
        end
        if not knownJob then
            log(string.format("Unknown job %s in %s — sending JOB_ABORT to %s",
                tostring(jobId), msg.type, msg.from))
            sendToServer(proto.MSG.JOB_ABORT, msg.from, { jobId = jobId })
            return
        end
    end

    -- ── Everything else → inbox ──────────────────────────────────────────────
    inboxPut(msg)
end

-- ─── State machine tick ───────────────────────────────────────────────────────
-- Called after every event (modem message or timer).
-- Advances the current job one step based on inbox contents and elapsed time.

local function tick()
    local now = os.epoch("utc")

    -- ── Heartbeat: periodic "still alive in state X" log ──────────────────────
    local nowSec = now / 1000
    if nowSec - lastHeartbeatLog > 30 then
        log(string.format("alive | state=%s | queue=%d | current=%s",
            state, #queue, current and current.turtleId or "none"))
        lastHeartbeatLog = nowSec
    end

    -- ── IDLE: pick up next job ────────────────────────────────────────────────
    if state == S.IDLE then
        if #queue == 0 then return end
        current = table.remove(queue, 1)
        log(string.format("Serving: %s  job=%s  chests=%d",
            current.turtleId, current.jobId, current.chestsNeeded))
        sendToServer(proto.MSG.WAREHOUSE_QUEUED, current.turtleId, {
            jobId = current.jobId, position = 0, chests = current.chestsNeeded,
        })
        -- Queue advanced — refresh positions for everyone still waiting behind us.
        broadcastQueuePositions()
        enterState(S.WAIT_ARRIVE)

    -- ── WAIT_ARRIVE: turtle travelling to destination ─────────────────────────
    elseif state == S.WAIT_ARRIVE then
        local msg = inboxGet(proto.MSG.DELIVERY_ARRIVED, current.turtleId)
        if msg then
            log("Turtle arrived — clearing EC and loading chests...")
            clearEnderChest()
            lastLoaded = loadChests(current.chestsNeeded)
            if lastLoaded == 0 then
                log("ERROR: RS has no regular chests ('" .. CFG.regularChestItem .. "')")
                abortCurrent("no chests in RS"); return
            end
            sendToServer(proto.MSG.CHESTS_READY, current.turtleId, {
                jobId = current.jobId, count = lastLoaded,
            })
            log("CHESTS_READY sent — waiting for CHESTS_PLACED")
            enterState(S.WAIT_PLACED)
        elseif now - stateTs > CFG.arrivalTimeout * 1000 then
            abortCurrent("arrival timeout (>" .. CFG.arrivalTimeout .. "s)")
        end

    -- ── WAIT_PLACED: chests loaded, turtle placing them ───────────────────────
    elseif state == S.WAIT_PLACED then
        -- DELIVERY_ARRIVED re-ping means turtle missed CHESTS_READY — resend.
        local reping = inboxGet(proto.MSG.DELIVERY_ARRIVED, current.turtleId)
        if reping then
            log("Re-ping — re-sending CHESTS_READY")
            sendToServer(proto.MSG.CHESTS_READY, current.turtleId, {
                jobId = current.jobId, count = lastLoaded,
            })
        end
        local msg = inboxGet(proto.MSG.CHESTS_PLACED, current.turtleId)
        if msg then
            -- Build item batch list
            batches = {}
            local batch, bStacks = {}, 0
            for itemName, totalCount in pairs(current.items) do
                local ok, have = checkStock(itemName, totalCount)
                -- Stock shortfall: only batch up what RS actually has so we never
                -- promise more than we can export. Skip entirely if there's none.
                local deliverable = ok and totalCount or have
                if not ok then
                    log(string.format("Stock short for %s — delivering %d of %d (have %d)",
                        itemName, deliverable, totalCount, have))
                end
                local remaining = deliverable
                while remaining > 0 do
                    local sc = math.min(remaining, 64)
                    table.insert(batch, { name = itemName, count = sc })
                    bStacks = bStacks + 1
                    remaining = remaining - sc
                    if bStacks >= CFG.batchSize then
                        table.insert(batches, batch); batch = {}; bStacks = 0
                    end
                end
            end
            if #batch > 0 then table.insert(batches, batch) end
            log(string.format("Chests placed — %d item batch(es) to send", #batches))
            batchIdx = 0
            enterState(S.SEND_BATCH)
        elseif now - stateTs > CFG.msgTimeout * 1000 then
            abortCurrent("CHESTS_PLACED timeout")
        end

    -- ── SEND_BATCH: export a batch and notify turtle (no waiting) ─────────────
    -- Transitions immediately: either to WAIT_BATCH (more batches) or WAIT_DONE.
    elseif state == S.SEND_BATCH then
        batchIdx = batchIdx + 1
        if batchIdx > #batches then
            sendToServer(proto.MSG.ITEMS_DONE, current.turtleId, { jobId = current.jobId })
            log("All batches done — waiting for ITEM_COLLECTED")
            enterState(S.WAIT_DONE)
        else
            local b = batches[batchIdx]
            for _, entry in ipairs(b) do
                local moved = exportItem(entry.name, entry.count)
                if moved < entry.count then
                    log(string.format("Short: %d/%d %s", moved, entry.count, entry.name))
                end
            end
            sendToServer(proto.MSG.ITEMS_READY, current.turtleId, { jobId = current.jobId })
            log(string.format("Batch %d/%d exported — waiting for BATCH_DONE", batchIdx, #batches))
            enterState(S.WAIT_BATCH)
        end

    -- ── WAIT_BATCH: turtle pulling batch items from EC ────────────────────────
    elseif state == S.WAIT_BATCH then
        -- CHESTS_PLACED re-ping means turtle missed ITEMS_READY — resend.
        if inboxGet(proto.MSG.CHESTS_PLACED, current.turtleId) then
            log("Re-ping — re-sending ITEMS_READY (batch " .. batchIdx .. ")")
            sendToServer(proto.MSG.ITEMS_READY, current.turtleId, { jobId = current.jobId })
        end
        if inboxGet(proto.MSG.BATCH_DONE, current.turtleId) then
            enterState(S.SEND_BATCH)
        elseif now - stateTs > CFG.msgTimeout * 1000 then
            abortCurrent("BATCH_DONE timeout")
        end

    -- ── WAIT_DONE: turtle picking up EC, job finishing ────────────────────────
    elseif state == S.WAIT_DONE then
        -- CHESTS_PLACED re-ping means turtle missed ITEMS_DONE — resend.
        if inboxGet(proto.MSG.CHESTS_PLACED, current.turtleId) then
            log("Re-ping — re-sending ITEMS_DONE")
            sendToServer(proto.MSG.ITEMS_DONE, current.turtleId, { jobId = current.jobId })
        end
        if inboxGet(proto.MSG.ITEM_COLLECTED, current.turtleId) then
            log("Job complete: " .. current.jobId)
            current = nil; batches = {}; batchIdx = 0
            enterState(S.IDLE)
        elseif now - stateTs > CFG.msgTimeout * 1000 then
            log("ITEM_COLLECTED timeout — sweeping EC")
            clearEnderChest()
            current = nil; enterState(S.IDLE)
        end
    end
end

-- ─── Main loop ───────────────────────────────────────────────────────────────

local function main()
    log(string.format("Warehouse online v%s (RS bridge / state-machine mode)", proto.VERSION))
    log("Entangled chest : " .. CFG.entangledChest)
    log("RS bridge       : " .. (peripheral.getName(rsBridge) or "found"))
    log("Startup EC sweep...")
    clearEnderChest()

    local ecType = peripheral.getType(CFG.entangledChest)
    if not ecType then
        log("WARNING: no chest on side '" .. CFG.entangledChest .. "' — check placement")
    else
        log("Ender chest     : " .. ecType)
    end
    log("State machine ready.")

    -- 1-second timer keeps the state machine ticking even with no modem traffic
    -- (advances timeouts and SEND_BATCH transitions without needing a message).
    local tickTimer = os.startTimer(1)

    while true do
        local ev, p1, _, _, p4 = os.pullEvent()
        if ev == "modem_message" then
            local raw = type(p4) == "table" and p4 or textutils.unserialise(p4)
            routeMsg(raw)
        elseif ev == "timer" and p1 == tickTimer then
            tickTimer = os.startTimer(1)
        end
        -- Always tick after any event — state machine advances on messages AND time
        tick()
    end
end

local ok, err = pcall(main)
if not ok then print("CRASH: " .. tostring(err)) end
