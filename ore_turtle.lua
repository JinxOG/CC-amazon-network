-- ore_turtle.lua
-- Rename to startup.lua on any miner turtle.
-- Paired with a SUPPORT turtle (SUPPORT_FOLLOW, fuelManage=true).
--
-- Inventory layout:
--   Slot  1   advancedperipherals:geo_scanner  (placed, used, picked back up)
--   Slots 2-13  mining output  → dumped to ore E-chest after each sector
--   Slot 14   coal reserve     (slot-14 top-up before EC refuel)
--   Slot 15   fuel ender chest (self-refuel coal source)
--   Slot 16   ore ender chest  (→ RS storage)

local base  = require("turtle_base")
local proto = require("protocol")
local W     = require("waypoints")

-- ── Slots ────────────────────────────────────────────────────────────────────
local S_SCANNER = 1
local S_COAL    = 14
local S_FUEL_EC = 15
local S_ORE_EC  = 16
local PROTECTED = { [S_SCANNER]=true, [S_COAL]=true, [S_FUEL_EC]=true, [S_ORE_EC]=true }

-- ── Config ───────────────────────────────────────────────────────────────────
local SKY_Y        = 200   -- altitude for inter-sector sky travel
local FUEL_WARN    = 800   -- self-refuel threshold
local SCAN_RADIUS  = 16    -- geo scanner radius (blocks)
local SCANNER_NAME = "advancedperipherals:geo_scanner"
local MIN_ORE_Y    = 5     -- don't mine ores below this Y; bedrock starts at Y≤4

-- Y levels scanned per sector — each covers ±16 blocks vertically
local SCAN_LEVELS = { 80, 48, 16, 8 }

base.init(proto.ROLE.MINER)

-- ── Messaging ────────────────────────────────────────────────────────────────

local _servingFuel = false
local serveSupportFuel   -- forward declaration; assigned after dumpOres is defined

local function waitMsg(types, secs)
    local set = {}
    for _, t in ipairs(types) do set[t] = true end
    local deadline = os.epoch("utc") / 1000 + secs
    while os.epoch("utc") / 1000 < deadline do
        if base.isRecalled() then return nil end
        local remain = deadline - os.epoch("utc") / 1000
        if remain <= 0 then break end
        local msg = proto.receive(base.getSelfId(), math.max(0.5, remain))
        if msg then
            if not _servingFuel
                    and msg.type == proto.MSG.FUEL_LOW
                    and msg.from == base.getPartnerId() then
                serveSupportFuel(msg.payload)
            elseif set[msg.type] then
                return msg
            end
        end
    end
    return nil
end

-- ── Ore detection ────────────────────────────────────────────────────────────

local function isOre(name, tags)
    if name:find("ore") then return true end
    if type(tags) == "table" then
        for k in pairs(tags) do
            if type(k) == "string" and (k:find("ores") or k:find("ore")) then return true end
        end
    end
    return false
end

-- ── Fuel management ──────────────────────────────────────────────────────────

local function tryRefuelSlot14()
    turtle.select(S_COAL)
    if turtle.getItemCount() > 0 then turtle.refuel() end
end

local function checkFuel(jobId)
    if turtle.getFuelLevel() >= FUEL_WARN then return end
    tryRefuelSlot14()
    if turtle.getFuelLevel() >= FUEL_WARN then return end
    -- Support is at Y=100, never near the miner underground — safe to place EC
    turtle.select(S_FUEL_EC)
    if turtle.detectDown() then turtle.digDown() end
    turtle.placeDown()
    turtle.select(S_COAL)
    turtle.suckDown(32)
    turtle.refuel()
    turtle.select(S_FUEL_EC)
    turtle.digDown()
end

-- ── Inventory ────────────────────────────────────────────────────────────────

local function sweepCoalToSlot14()
    for s = 2, 13 do
        local it = turtle.getItemDetail(s)
        if it and it.name:find("coal") then
            local space = turtle.getItemSpace(S_COAL)
            if space > 0 then
                turtle.select(s)
                turtle.transferTo(S_COAL, math.min(it.count, space))
            end
        end
    end
end

local function dumpOres()
    sweepCoalToSlot14()
    turtle.select(S_ORE_EC)
    if turtle.detectDown() then turtle.digDown() end
    turtle.placeDown()
    for s = 1, 16 do
        if not PROTECTED[s] and turtle.getItemCount(s) > 0 then
            turtle.select(s)
            turtle.dropDown()
        end
    end
    turtle.select(S_ORE_EC)
    turtle.digDown()
end

local function inventoryFull()
    local free = 0
    for s = 2, 13 do
        if turtle.getItemCount(s) == 0 then free = free + 1 end
    end
    return free < 2
end

-- ── Support field refuel ──────────────────────────────────────────────────────

serveSupportFuel = function(payload)
    if _servingFuel then return end
    _servingFuel = true
    local jobId      = payload and payload.jobId
    local supportPos = payload and payload.pos
    print("[MINER] Support fuel low — ascending for refuel")

    local miningPos = base.getPos()
    dumpOres()

    if supportPos then
        print(string.format("[MINER] Ascending to support at %d,%d,%d",
            supportPos.x, supportPos.y, supportPos.z))
        base.move.to(supportPos.x, supportPos.y - 1, supportPos.z)
    end

    -- Load coal from fuel EC into slots 2-13 for support to suck
    turtle.select(S_FUEL_EC)
    if turtle.detectDown() then turtle.digDown() end
    turtle.placeDown()
    for s = 2, 13 do
        turtle.select(s)
        turtle.suckDown(64)
    end
    turtle.select(S_FUEL_EC)
    turtle.digDown()

    base.signalPartner(proto.MSG.FUEL_READY, { jobId = jobId })
    print("[MINER] Coal ready — waiting for support to refuel")
    local deadline = os.epoch("utc") / 1000 + 30
    while os.epoch("utc") / 1000 < deadline do
        local msg = proto.receive(base.getSelfId(), 3)
        if msg and msg.type == proto.MSG.FUEL_FILLED
                and msg.from == base.getPartnerId() then
            break
        end
    end

    sweepCoalToSlot14()
    print("[MINER] Refuel done — descending back to mining position")
    base.move.to(miningPos.x, miningPos.y, miningPos.z)
    _servingFuel = false
    print("[MINER] Resumed mining")
end

-- ── Geo Scanner ──────────────────────────────────────────────────────────────

local function scanSector()
    local item = turtle.getItemDetail(S_SCANNER)
    if not item or item.name ~= SCANNER_NAME then
        print("[SCAN] ERROR: geo scanner not in slot 1 (found: " .. tostring(item and item.name) .. ")")
        return {}
    end

    turtle.select(S_SCANNER)
    if turtle.detectDown() then turtle.digDown() end
    if not turtle.placeDown() then
        print("[SCAN] ERROR: failed to place geo scanner below")
        return {}
    end
    print("[SCAN] Scanner placed — wrapping peripheral...")
    sleep(0.5)

    local sc = peripheral.wrap("bottom")
    if not sc then
        print("[SCAN] ERROR: peripheral.wrap('bottom') returned nil")
        turtle.select(S_SCANNER); turtle.digDown(); return {}
    end
    print("[SCAN] Scanning radius " .. SCAN_RADIUS .. "...")

    local raw = sc.scan(SCAN_RADIUS)
    turtle.select(S_SCANNER)
    turtle.digDown()

    if not raw then
        print("[SCAN] ERROR: sc.scan() returned nil")
        return {}
    end
    print("[SCAN] Raw scan: " .. #raw .. " blocks")

    local p    = base.getPos()
    local ores = {}
    for _, b in ipairs(raw) do
        if isOre(b.name, b.tags) then
            table.insert(ores, {
                name = b.name,
                x    = p.x + b.x,
                y    = (p.y - 1) + b.y,
                z    = p.z + b.z,
            })
        end
    end
    print("[SCAN] Found " .. #ores .. " ore blocks")
    return ores
end

-- ── Mining ───────────────────────────────────────────────────────────────────

local function navToOre(ore, jobId)
    checkFuel(jobId)
    local p = base.getPos()
    base.move.to(ore.x, p.y, ore.z)
    checkFuel(jobId)
    base.move.to(ore.x, ore.y, ore.z)
end

local function mineOreList(ores, jobId)
    -- Greedy nearest-neighbour: re-sort after every mine so the miner stays
    -- in a vein until it's exhausted before jumping to a distant one.
    -- Skip ores below MIN_ORE_Y — the scanner at Y=8 can still detect them
    -- but navigating there risks hitting indestructible bedrock.
    local remaining = {}
    for _, o in ipairs(ores) do
        if o.y >= MIN_ORE_Y then table.insert(remaining, o) end
    end

    local mined = 0
    local byType = {}
    while #remaining > 0 do
        if base.isRecalled() then break end
        local p = base.getPos()
        table.sort(remaining, function(a, b)
            local da = math.abs(a.x-p.x) + math.abs(a.y-p.y) + math.abs(a.z-p.z)
            local db = math.abs(b.x-p.x) + math.abs(b.y-p.y) + math.abs(b.z-p.z)
            return da < db
        end)
        local ore = table.remove(remaining, 1)
        if inventoryFull() then dumpOres() end
        navToOre(ore, jobId)
        byType[ore.name] = (byType[ore.name] or 0) + 1
        mined = mined + 1
    end
    return mined, byType
end

-- ── Job handler ──────────────────────────────────────────────────────────────

local function mineJob(job)
    local jobId    = job.id
    local totalOre = 0

    -- Coordinated recall: dump ores, signal support to use sky return, then
    -- ascend to Y=100 (letting support drain the last POSITION_UPDATEs to that
    -- position), clear partnerId, then ascend to sky and dock via sky path.
    local function recallReturn()
        dumpOres()
        checkFuel(jobId)
        -- Signal support to stop locking to FOLLOW_Y and wait for miner at meeting altitude.
        -- partnerId is kept set so POSITION_UPDATEs keep firing and support can follow.
        base.signalPartner(proto.MSG.MINE_RECALL, {})
        local p = base.getPos()
        -- Ascend to meeting altitude (FOLLOW_Y=100). Support is already at Y=100 locking
        -- to that level, so it tracks our X,Z as we climb — they meet at the same altitude.
        base.move.to(p.x, 100, p.z)
        sleep(5)                          -- let support complete final X,Z alignment
        -- Lead support up to sky altitude and across to arrivals hole, still broadcasting.
        base.move.to(p.x, SKY_Y, p.z)
        base.move.to(W.ARRIVALS_HOLE.x, SKY_Y, W.ARRIVALS_HOLE.z)
        -- Tell support to descend independently — it is at arrivals at SKY_Y now.
        base.signalPartner(proto.MSG.RETURN_TO_DOCK, {})
        base.setPartnerId(nil)            -- stop broadcasting
        -- We are already at arrivals at SKY_Y; returnToDockFromSky just descends.
        base.returnToDockFromSky()
        base.sendFailed("recalled", false)
    end

    base.setPartnerId(job.params.partnerId)
    base.setStatus(proto.STATUS.TRAVELLING, jobId)
    base.sendProgress("Departing for mining zone")

    local ok, err = base.depart(true)  -- stay at floor level, ascend directly
    if not ok then
        base.sendFailed("departure_failed: " .. (err or "?"), true)
        return
    end

    -- Ascend straight up — POSITION_UPDATEs fire on every step so support
    -- can follow in real-time (prev is always the already-vacated block).
    checkFuel(jobId)
    local p = base.getPos()
    base.move.to(p.x, SKY_Y, p.z)

    -- ── Sector loop ──────────────────────────────────────────────────────────
    -- Request first sector. Thereafter: mine → SECTOR_DONE → request next.
    -- Only ascend to SKY_Y when a new sector is actually assigned, so there is
    -- no wasteful sky climb on the final sector before returning home.

    base.sendToServer(proto.MSG.SECTOR_REQUEST, proto.payloadSectorRequest(jobId))
    local msg = waitMsg({ proto.MSG.SECTOR_ASSIGN, proto.MSG.MINE_COMPLETE }, 20)

    while msg and msg.type == proto.MSG.SECTOR_ASSIGN do
        if base.isRecalled() then
            recallReturn()
            return
        end

        local sx = msg.payload.sectorX
        local sz = msg.payload.sectorZ

        base.setStatus(proto.STATUS.TRAVELLING, jobId)
        base.sendProgress(string.format("Travelling to sector %d,%d", sx, sz))

        -- Fly to sector at sky level (miner may already be at SKY_Y on first sector)
        checkFuel(jobId)
        base.move.to(sx, SKY_Y, sz)

        -- Scan and mine every depth level
        local count       = 0
        local sectorFound = {}   -- {[name]=count} from geo scan (sent via SECTOR_SCAN)
        local sectorMined = {}   -- {[name]=count} actually mined
        for i, sy in ipairs(SCAN_LEVELS) do
            checkFuel(jobId)
            base.move.to(sx, sy, sz)
            base.setStatus(proto.STATUS.WORKING, jobId)
            base.sendProgress(string.format("Scanning %d,%d depth %d/%d (Y=%d)",
                sx, sz, i, #SCAN_LEVELS, sy))
            local ores = scanSector()
            -- Report scan results immediately so the dashboard updates in real time.
            local scanFound = {}
            for _, o in ipairs(ores) do
                scanFound[o.name]    = (scanFound[o.name]    or 0) + 1
                sectorFound[o.name] = (sectorFound[o.name] or 0) + 1
            end
            if next(scanFound) then
                base.sendToServer(proto.MSG.SECTOR_SCAN,
                    proto.payloadSectorScan(jobId, sx, sz, sy, scanFound))
            end
            if #ores > 0 then
                base.sendProgress(string.format("Mining %d ores at Y=%d", #ores, sy))
                local c, byType = mineOreList(ores, jobId)
                count = count + c
                for name, n in pairs(byType) do
                    sectorMined[name] = (sectorMined[name] or 0) + n
                end
                -- Report per-depth mined count so the MINED column updates in real time
                if next(byType) then
                    base.sendToServer(proto.MSG.SECTOR_SCAN,
                        proto.payloadSectorScan(jobId, sx, sz, sy, {}, byType))
                end
            end
            if base.isRecalled() then break end
        end

        if count > 0 or inventoryFull() then dumpOres() end
        totalOre = totalOre + count

        -- Report done and request next sector immediately (miner is underground —
        -- only ascend to SKY_Y if another sector is actually assigned)
        base.sendToServer(proto.MSG.SECTOR_DONE,
            proto.payloadSectorDone(jobId, sx, sz, count, sectorFound, sectorMined))

        msg = waitMsg({ proto.MSG.SECTOR_ASSIGN, proto.MSG.MINE_COMPLETE }, 20)
        if not msg then
            if base.isRecalled() then
                recallReturn()
            else
                base.sendFailed("sector_request_timeout", true)
            end
            return
        end
    end

    -- ── Return home ──────────────────────────────────────────────────────────
    -- Miner is at the last sector's deepest scan level — returnToDock navigates
    -- from here directly (no wasteful ascent to SKY_Y first).
    base.sendProgress(string.format("All sectors done — %d ore mined. Returning.", totalOre))
    base.signalPartner(proto.MSG.RETURN_TO_DOCK, {})
    base.returnToDock()
    base.sendComplete({ oreCount = totalOre })
end

base.run(mineJob)
