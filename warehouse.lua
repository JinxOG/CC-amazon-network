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

-- Wireless only, and loudly if there is none.
--
-- peripheral.find("modem") answers with a WIRED modem as happily as an ender
-- one, and an RS Bridge is normally attached over a wired modem. Wrapping the
-- wired one looks entirely healthy: modem.open succeeds on every channel,
-- nothing errors, RS works, the screen keeps printing -- and every transmit
-- goes onto the cable while the air is never heard.
--
-- This computer ran exactly that way for nine days: no log lines, no digests,
-- and UPDATE_ALL never arrived, so the operator had to run the updater by hand.
-- Found by W3 from a photograph of the screen, 2026-09-22.
--
-- Failing loudly matters more than the filter does. A silent wrong modem is
-- what cost the nine days; an error on the screen would have cost minutes.
local modem    = peripheral.find("modem", function(_, m)
    return type(m.isWireless) == "function" and m.isWireless()
end)
local rsBridge = peripheral.find("rsBridge")

if not modem then
    -- Name what IS attached, so nobody has to guess which modem is which.
    local seen = {}
    pcall(function()
        for _, nm in ipairs(peripheral.getNames()) do
            if peripheral.getType(nm) == "modem" then
                local w = peripheral.wrap(nm)
                local wireless = w and type(w.isWireless) == "function" and w.isWireless()
                seen[#seen + 1] = nm .. (wireless and " (wireless)" or " (wired)")
            end
        end
    end)
    error("Warehouse: no WIRELESS modem attached. Found: "
        .. (#seen > 0 and table.concat(seen, ", ") or "no modems at all")
        .. ". An ender modem is required -- a wired modem carries RS fine but "
        .. "cannot reach the fleet, and this computer was deaf for nine days "
        .. "that way.")
end
if not rsBridge then error("Warehouse: no rsBridge found — attach an Advanced Peripherals RS Bridge") end

modem.open(proto.CH_SERVER)
modem.open(proto.CH_BROADCAST)
modem.open(proto.CH_WAREHOUSE)

-- ─── Helpers ─────────────────────────────────────────────────────────────────

local function log(s) print("[WH] " .. tostring(s)) end

local function sendToServer(msgType, toId, payload)
    local msg = proto.encode(msgType, "warehouse", toId, payload)
    proto.send(modem, proto.CH_SERVER, msg)
end

-- Every rsBridge call goes through here.
--
-- The peripheral can throw, and did for two months: AdvancedPeripherals 0.7.44r
-- raised NoClassDefFoundError from ItemFilter.parse on every importItem, from
-- 26 June until 0.7.46r landed on 28 Aug. Unprotected, that error left
-- clearEnderChest, left main, and ended the program -- the bottom of this file
-- caught the crash and then simply exited, so the warehouse stayed dead until a
-- human noticed. Deliveries do not stall gracefully when the thing that serves
-- them is gone.
--
-- The mod bug is fixed. The exposure it revealed is ours, and it is not specific
-- to importItem: an RS network that unloads, a bridge that is broken by a player,
-- or the next mod regression all arrive the same way.
--
-- Returns the call's result, or nil plus a message. Never raises.
local function rsCall(method, ...)
    if not rsBridge then return nil, "no rsBridge" end
    local fn = rsBridge[method]
    if type(fn) ~= "function" then
        return nil, "rsBridge has no method '" .. tostring(method) .. "'"
    end
    local ok, res = pcall(fn, ...)
    if not ok then
        log(string.format("RS %s failed: %s", method, tostring(res)))
        return nil, tostring(res)
    end
    return res
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
            local moved = rsCall("importItem", { name = item.name, count = item.count }, CFG.entangledChest)
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
    local result = rsCall("exportItem", { name = CFG.regularChestItem, count = n }, CFG.entangledChest)
    local moved  = (type(result) == "number") and result or (result and result.count or 0)
    log("Loaded " .. moved .. "/" .. n .. " chests into entangled chest")
    return moved
end

local function exportItem(name, count)
    local result = rsCall("exportItem", { name = name, count = count }, CFG.entangledChest)
    return (type(result) == "number") and result or (result and result.count or 0)
end

local function checkStock(name, needed)
    local info = rsCall("getItem", { name = name })
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

-- ─── Storage digest for the dispatch server ──────────────────────────────────
--
-- The dispatch computer does NOT get the item list. Measured 2026-09-22: 469
-- items is 65.2 KB serialised, against roughly 8 KB for the largest thing on
-- the wire, and payload deafness is on record here from a 96 KB push that
-- dropped heartbeats on 2026-08-30. Sending that every half minute would spare
-- the server a peripheral call by handing it a recurring deserialise instead.
--
-- So it gets a digest: liveness, the two numbers that prove both computers see
-- the same storage network, and stock for the ore names it actually watches.
-- checkOreThresholds is its only consumer and reads nothing else. The full list
-- goes to the bridge (W3 ruling 2026-09-22); that half waits on a scope ruling
-- and is deliberately not built here.
-- Resolve a message name, tolerating the constant not existing yet -- and say
-- so when it does not.
--
-- The fallback is needed because a new message type and the code that sends it
-- cannot always ship in one release. But a SILENT fallback is how a renamed
-- type becomes a message nobody handles and nobody notices: on 2026-09-22 this
-- sender used STORAGE_SNAPSHOT while the server had been renamed to
-- STORAGE_DIGEST, and the digest would simply never have appeared. The message
-- would have been well-formed, delivered, and matched no handler.
--
-- That is the same shape as every other fault in this thread: a check whose
-- failure looks exactly like its success. So it still falls back, and it warns.
local function msgName(tbl, key)
    local v = tbl and tbl[key]
    if type(v) == "string" then return v, false end
    return key, true
end

local MSG_STORAGE_DIGEST,    digestNameFellBack = msgName(proto.MSG, "STORAGE_DIGEST")
local MSG_STORAGE_WATCHLIST, watchNameFellBack  = msgName(proto.MSG, "STORAGE_WATCHLIST")

-- W3 enforces these on receive. They are enforced here too: a contract policed
-- at only one end fails as a refusal log rather than as a message never sent.
local DIGEST_MAX_NAMES = 64
local DIGEST_MAX_BYTES = 4096

-- nil until the server sends one. Until then the digest carries the counts
-- alone, which is enough for liveness and for the same-network check.
local watchNames = nil

local function acceptWatchlist(names)
    if type(names) ~= "table" then return nil end
    local out = {}
    for _, n in ipairs(names) do
        if type(n) == "string" then
            out[#out + 1] = n
            if #out >= DIGEST_MAX_NAMES then break end
        end
    end
    return out
end

-- Returns the payload, and the oversize length if the full one was too big.
-- Dropping `ores` rather than the whole message is deliberate: the counts still
-- carry liveness and the same-network check, so an over-large watchlist
-- degrades the ore watchdog rather than the heartbeat.
local function digestPayload(itemCount, grandTotal, ores)
    local full = { itemCount = itemCount, grandTotal = grandTotal }
    if ores and next(ores) ~= nil then full.ores = ores end
    local size = #textutils.serialise(full)
    if size <= DIGEST_MAX_BYTES then return full, nil end
    return { itemCount = itemCount, grandTotal = grandTotal }, size
end

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

    -- ── The ore names the server wants stock for ────────────────────────────
    if msg.type == MSG_STORAGE_WATCHLIST then
        local names = acceptWatchlist(msg.payload and msg.payload.names)
        if names then
            watchNames = names
            log(string.format("Storage watchlist: %d name(s)", #names))
        end
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

local CRASH_LOG_FILE = "wh_crash.log"

-- The fleet-log outbox. Created inside main() rather than at load, so the
-- test seam never captures the global print of whatever required this file;
-- module-level so the crash handler at the bottom can flush it on the way down.
local _log = nil

-- ─── The full list, posted to the bridge ─────────────────────────────────────
--
-- The dashboard is the only consumer that needs 470 items with display names,
-- and the bridge serves the dashboard. Routing it through the dispatch server
-- would put 45 KB on its event loop to hand straight back out (spec owner,
-- 2026-09-22). So it goes here instead, and the dispatch server gets a digest.
--
-- ASYNC on purpose. http.request returns at once and the reply arrives as an
-- event; a blocking post of 45 KB would freeze this loop exactly the way the
-- storage poll froze the dispatch computer, and this machine is the one
-- running the delivery handshake.
local POST_URL           = "http://127.0.0.1:3000/storage"
local POST_STUCK_MS      = 30000
local CRAFTABLE_EVERY_MS = 600000

local craftableMap     = {}
local craftableNextAt  = 0
local postPending      = false
local postPendingSince = 0

-- storageTs is the moment RS was last read SUCCESSFULLY, never send time.
-- W5 arbitrates the two sources on newest read-time, so a stale reading
-- labelled with a fresh clock would win and show old stock as live.
local function buildPostBody(items, readTs, craftable)
    craftable = craftable or {}
    local out = {}
    for _, it in ipairs(items or {}) do
        if it.name then
            out[#out + 1] = {
                name        = it.name,
                displayName = it.displayName or it.name,
                amount      = tonumber(it.amount or it.count) or 0,
                craftable   = craftable[it.name] or false,
            }
        end
    end
    return textutils.serialiseJSON({ storage = out, storageTs = readTs, source = "warehouse" })
end

-- W5 asks that the reply be read rather than discarded: a 400 names its reason
-- and all four are worth logging. Matched rather than JSON-decoded because the
-- shape is two fixed fields and unserialiseJSON is not on every CC build.
local function readPostReply(body)
    if type(body) ~= "string" or body == "" then return false, "empty reply" end
    if body:find('"ok"%s*:%s*true') then return true, nil end
    return false, body:match('"error"%s*:%s*"([^"]*)"') or body:sub(1, 120)
end

local function postStorage(body, now)
    -- A lost reply event would otherwise wedge this flag forever and the panel
    -- would quietly stop updating with nothing reporting a fault.
    if postPending and (now - postPendingSince) > POST_STUCK_MS then
        postPending = false
        if _log then _log.pendingLevel = "WARN" end
        log("Storage post stuck >30s - clearing (reply event lost)")
        if _log then _log.pendingLevel = nil end
    end
    if postPending then return false end
    if type(http) ~= "table" or type(http.request) ~= "function" then return false end
    local ok = pcall(http.request, POST_URL, body, { ["Content-Type"] = "application/json" })
    if not ok then
        if _log then _log.pendingLevel = "WARN" end
        log("Storage post could not start - is HTTP enabled on this computer?")
        if _log then _log.pendingLevel = nil end
        return false
    end
    postPending, postPendingSince = true, now
    return true
end
-- ─── Temporary: storage-call timing probe ────────────────────────────────────
--
-- Times listItems on THIS computer so it can be compared against the dispatch
-- server's stalls for the same minute.
--
-- Why it exists: every number in the 29-second deaf-window investigation was
-- taken on the dispatch computer. Those measure how long *that computer waited*,
-- which is not the same quantity as how long the storage network took, and only
-- a second computer on the same network separates the two. If this reads ~40 ms
-- while the dispatch server reads 8-29 s, the network is fine and the problem is
-- that computer; if it reads seconds too, the network is the slow party and
-- moving the poll anywhere is pointless.
--
-- An enumeration is exactly the yield that destroys a delivery step, so it is
-- guarded three ways:
--   * it runs only with the state machine IDLE, nothing being served and nothing
--     queued -- the rule W6 committed to W3 on 2026-09-22;
--   * it backs off hard the moment a call is slow, so if the network really is
--     the slow party this probe cannot keep paying for the answer;
--   * it is temporary, and comes out when the card is decided.
local PROBE_EVERY_MS   = 30000   -- also the digest cadence (W3, provisional)
local PROBE_SLOW_MS    = 2000
local PROBE_BACKOFF_MS = 600000

local probeNextAt   = 0
local probeInterval = PROBE_EVERY_MS

-- Split out and pure so the guard can be tested without standing up a state
-- machine: the caller decides what "idle" means and passes it in.
local function probeDue(now, idle)
    if not idle then return false end
    return now >= probeNextAt
end

-- Chooses the next interval from how long the call took, and returns it so a
-- test can see the back-off rather than infer it.
local function probeRecord(now, ms)
    probeInterval = (ms >= PROBE_SLOW_MS) and PROBE_BACKOFF_MS or PROBE_EVERY_MS
    probeNextAt   = now + probeInterval
    return probeInterval
end

local function storageProbe(now)
    local idle = (state == S.IDLE) and (current == nil) and (#queue == 0)
    if not probeDue(now, idle) then
        -- Due, but a delivery is in flight, and an enumeration here destroys a
        -- handshake step. Say so: the server cannot otherwise tell "busy and
        -- deliberately quiet" from "stopped", and would resume polling itself
        -- at exactly the wrong moment.
        if now >= probeNextAt then
            sendToServer(MSG_STORAGE_DIGEST, nil, { keepalive = true })
            probeNextAt = now + probeInterval
        end
        return nil
    end

    local t0    = os.epoch("utc")
    local items = rsCall("listItems")
    local ms     = os.epoch("utc") - t0
    local readTs = t0 + ms   -- when RS was read, not when we send
    local n      = (type(items) == "table") and #items or -1

    -- Sum every amount as a fingerprint of the network, not just its size.
    --
    -- W3 asked the one question only this computer can answer: does the
    -- warehouse bridge see the SAME storage network the dispatch bridge sees?
    -- If it does not, a panel sourced from here shows a different system and
    -- nothing about it looks wrong. Item count alone is weak evidence -- two
    -- networks can hold a similar number of kinds of thing -- but count AND
    -- total quantity matching the dispatch server's own figures for the same
    -- minute is hard to reach by coincidence.
    local total = 0
    if type(items) == "table" then
        for _, it in ipairs(items) do
            total = total + (tonumber(it.amount or it.count) or 0)
        end
    end
    local nextIn = probeRecord(os.epoch("utc"), ms)

    if ms >= PROBE_SLOW_MS then
        -- A real level, so ?level=WARN finds the slow readings on their own.
        if _log then _log.pendingLevel = "WARN" end
        log(string.format("RS probe: listItems %dms items=%d total=%d - slow, next in %ds",
            ms, n, total, nextIn / 1000))
        if _log then _log.pendingLevel = nil end
    else
        log(string.format("RS probe: listItems %dms items=%d total=%d", ms, n, total))
    end

    -- Stock for the watched names only. Summed by name, because one name can
    -- appear more than once (NBT variants) and the server sums them the same
    -- way when it builds its own lookup.
    local ores = nil
    if watchNames and type(items) == "table" then
        local want = {}
        for _, nm in ipairs(watchNames) do want[nm] = true end
        ores = {}
        for _, it in ipairs(items) do
            if it.name and want[it.name] then
                ores[it.name] = (ores[it.name] or 0) + (tonumber(it.amount or it.count) or 0)
            end
        end
    end

    local payload, oversize = digestPayload(n, total, ores)
    if oversize then
        if _log then _log.pendingLevel = "WARN" end
        log(string.format("Storage digest %d bytes over the %d cap - sent counts only",
            oversize, DIGEST_MAX_BYTES))
        if _log then _log.pendingLevel = nil end
    end
    sendToServer(MSG_STORAGE_DIGEST, nil, payload)

    -- Craftability on its own long interval: listCraftableItems is the same
    -- class of call, and the answer only moves when someone adds a recipe or a
    -- machine -- minutes to days, not seconds.
    if now >= craftableNextAt then
        local craft = rsCall("listCraftableItems")
        craftableNextAt = os.epoch("utc") + CRAFTABLE_EVERY_MS
        if type(craft) == "table" then
            local m = {}
            for _, it in ipairs(craft) do if it.name then m[it.name] = true end end
            craftableMap = m
        end
    end

    -- The dashboard copy. Only on a read that actually succeeded: a body built
    -- from nil would post an empty network as though the storage were empty.
    if type(items) == "table" then
        postStorage(buildPostBody(items, readTs, craftableMap), os.epoch("utc"))
    end
    return ms
end

local function main()
    -- Forward this computer's log to the fleet log. The shared half is W3's
    -- logship (1.9.93); until now nothing on this machine reported anything,
    -- so a frozen state machine or a destroyed handshake step was found out
    -- only from a delivery that never arrived.
    --
    -- pcall'd on purpose, against the manifest test's preference for a plain
    -- require. A plain require that fails stops this file before its own crash
    -- handler runs, and before it can receive the UPDATE_ALL that would
    -- deliver the missing module: the 2026-09-10 fleet outage, on the one
    -- machine nobody can see. logship is in this role's manifest and in
    -- COMMON, so the manifest is right either way -- this only decides what a
    -- stale disk costs. Losing the log is survivable; losing the warehouse
    -- is not.
    local okLS, logship = pcall(require, "logship")
    if okLS then
        _log = logship.new({
            source = "warehouse",
            send   = function(lines, bootId)
                sendToServer(proto.MSG.TURTLE_LOG, nil, { lines = lines, bootId = bootId })
            end,
        })
    else
        log("WARNING: logship unavailable (" .. tostring(logship) .. ") — this "
            .. "computer's log is NOT reaching the fleet log. Run the updater.")
    end
    log(string.format("Warehouse online v%s (RS bridge / state-machine mode)", proto.VERSION))
    -- Named out loud, because the alternative is a digest that never arrives
    -- and a server that reports nothing wrong.
    if digestNameFellBack or watchNameFellBack then
        if _log then _log.pendingLevel = "WARN" end
        log(string.format("Storage message names not in protocol.lua (digest=%s, watchlist=%s)"
            .. " - using literals; the server may not handle them",
            tostring(digestNameFellBack), tostring(watchNameFellBack)))
        if _log then _log.pendingLevel = nil end
    end
    -- Replay the last crash, same as central_server does. Without it the reason
    -- lives in a file nobody opens and the operator sees only that deliveries
    -- stopped.
    pcall(function()
        if not fs.exists(CRASH_LOG_FILE) then return end
        local f = fs.open(CRASH_LOG_FILE, "r")
        if not f then return end
        local lines = {}
        for line in f.readLine do table.insert(lines, line) end
        f.close()
        if #lines > 0 then
            log("Restarted after a crash — last: " .. lines[#lines])
            if #lines > 1 then log(#lines .. " crashes recorded in " .. CRASH_LOG_FILE) end
        end
    end)
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
        local ev, p1, p2, p3, p4 = os.pullEvent()
        if ev == "modem_message" then
            local raw = type(p4) == "table" and p4 or textutils.unserialise(p4)
            routeMsg(raw)

        -- The bridge reply. W5 asks that it be read rather than discarded: a
        -- 400 names its reason, and a post that is being refused every cycle
        -- would otherwise look exactly like one that is working.
        elseif (ev == "http_success" or ev == "http_failure") and p1 == POST_URL then
            postPending = false
            -- CC delivers a non-2xx as http_failure, with the response handle
            -- when there is one, so the stated reason survives either path.
            local handle = (ev == "http_success") and p2 or p3
            local body
            if handle then
                pcall(function() body = handle.readAll() end)
                pcall(function() handle.close() end)
            end
            local ok, why = readPostReply(body)
            if not ok then
                if _log then _log.pendingLevel = "WARN" end
                log("Storage post refused: " .. tostring(why or p2))
                if _log then _log.pendingLevel = nil end
            end
        end
        -- Always tick after any event — state machine advances on messages AND time
        tick()
        storageProbe(os.epoch("utc"))
        if _log then _log:tick() end

        -- Re-arm unconditionally, whatever woke us.
        --
        -- This was re-armed ONLY inside its own `p1 == tickTimer` branch. Lose
        -- that one event -- any yield destroys whatever arrives during it, timer
        -- events included, and clearEnderChest and UPDATE_ALL both sleep -- and
        -- the loop has no pending timer. It then advances only when a message
        -- happens to arrive: timeouts stop firing and an idle warehouse freezes
        -- while looking perfectly healthy. Byte-for-byte the fault that left
        -- all 15 turtles alive and deaf on 2026-09-04, fixed the same way the
        -- server (6f7d1c6) and the turtles (1.9.80) were. W3 found it here.
        os.cancelTimer(tickTimer)
        tickTimer = os.startTimer(1)
    end
end

-- ─── Test seam ───────────────────────────────────────────────────────────────
--
-- Requiring this file otherwise enters main() and never returns, which is why it
-- has had no coverage at all. Setting _G.__CC_WAREHOUSE_TEST before the require
-- hands back the internals instead of starting. Production never sets it, so the
-- run loop below is entered exactly as before.
if _G.__CC_WAREHOUSE_TEST then
    return {
        rsCall          = rsCall,
        clearEnderChest = clearEnderChest,
        loadChests      = loadChests,
        exportItem      = exportItem,
        checkStock      = checkStock,
        chestsNeeded    = chestsNeeded,
        CFG             = CFG,
        CRASH_LOG_FILE  = CRASH_LOG_FILE,
        main            = main,
        probeDue        = probeDue,
        probeRecord     = probeRecord,
        storageProbe    = storageProbe,
        acceptWatchlist = acceptWatchlist,
        buildPostBody   = buildPostBody,
        readPostReply   = readPostReply,
        POST_URL        = POST_URL,
        msgName         = msgName,
        digestPayload   = digestPayload,
        DIGEST_MAX_NAMES = DIGEST_MAX_NAMES,
        DIGEST_MAX_BYTES = DIGEST_MAX_BYTES,
        PROBE_SLOW_MS   = PROBE_SLOW_MS,
        PROBE_EVERY_MS  = PROBE_EVERY_MS,
        PROBE_BACKOFF_MS = PROBE_BACKOFF_MS,
    }
end

-- Restart on crash, matching central_server.
--
-- This used to print "CRASH:" and exit. The warehouse then stayed dead until a
-- human noticed deliveries had stopped -- which is how a two-month-old mod bug
-- in importItem went unattributed. §4 gives the Storage layer the failure mode
-- "deliveries stall; nothing is lost"; a process that is simply gone does not
-- stall, it disappears, and the difference is invisible from the outside.
--
-- Rebooting rather than re-calling main() is deliberate: it re-wraps every
-- peripheral handle, which is the thing most likely to be stale after a fault.
while true do
    local ok, err = pcall(main)
    if ok then break end
    -- A real level field, so ?level=ERROR finds the one line that matters.
    if _log then _log.pendingLevel = "ERROR" end
    print("[FATAL] warehouse crashed: " .. tostring(err))
    if _log then _log.pendingLevel = nil end
    pcall(function()
        local f = fs.open(CRASH_LOG_FILE, "a")
        if f then
            f.writeLine(string.format("[%d] main crashed: %s",
                os.epoch and os.epoch("utc") or 0, tostring(err)))
            f.close()
        end
    end)
    print("Rebooting in 5 seconds...")
    -- The loop's interval flush never runs again. Send what the outbox holds
    -- now -- the crash line above most of all -- or it dies with this boot.
    if _log then pcall(function() _log:flush() end) end
    sleep(5)
    os.reboot()
end
