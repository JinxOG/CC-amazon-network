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
            -- Handle support fuel requests inline during any wait
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
    -- broad name match catches modded ores (create:zinc_ore, thermal:tin_ore, etc.)
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
    if turtle.getItemCount() > 0 then
        turtle.refuel()
    end
end

local function checkFuel(jobId)
    if turtle.getFuelLevel() >= FUEL_WARN then return end
    tryRefuelSlot14()
    if turtle.getFuelLevel() >= FUEL_WARN then return end
    -- Draw coal from on-board fuel EC (support is at Y=100, never near miner)
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
--
-- Support stays at Y=100 tracking miner X,Z. When support is low on fuel it
-- sends FUEL_LOW with its position. Miner saves its position, dumps ores,
-- ascends to 1 block below support, loads coal from EC into slots 2-13,
-- signals FUEL_READY. Support sucks down from above. Miner then returns
-- to its saved mining position and resumes.

serveSupportFuel = function(payload)
    if _servingFuel then return end
    _servingFuel = true
    local jobId     = payload and payload.jobId
    local supportPos = payload and payload.pos
    print("[MINER] Support fuel low — ascending for refuel")

    -- Save mining position to return to after refuel
    local miningPos = base.getPos()

    -- Dump ores before ascending
    dumpOres()

    -- Ascend to 1 block below support so it can suckDown
    if supportPos then
        print(string.format("[MINER] Ascending to support at %d,%d,%d",
            supportPos.x, supportPos.y, supportPos.z))
        base.move.to(supportPos.x, supportPos.y - 1, supportPos.z)
    end

    -- Fill slots 2-13 with coal from fuel EC
    turtle.select(S_FUEL_EC)
    if turtle.detectDown() then turtle.digDown() end
    turtle.placeDown()
    for s = 2, 13 do
        turtle.select(s)
        turtle.suckDown(64)
    end
    turtle.select(S_FUEL_EC)
    turtle.digDown()

    -- Signal support to suck coal down from miner
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

    -- Return to saved mining position
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

    -- Give the peripheral a tick to register before wrapping
    sleep(0.5)

    local sc = peripheral.wrap("bottom")
    if not sc then
        print("[SCAN] ERROR: peripheral.wrap('bottom') returned nil — scanner not registering")
        turtle.select(S_SCANNER); turtle.digDown(); return {}
    end
    print("[SCAN] Peripheral wrapped — scanning radius " .. SCAN_RADIUS .. "...")

    local raw = sc.scan(SCAN_RADIUS)
    turtle.select(S_SCANNER)
    turtle.digDown()

    if not raw then
        print("[SCAN] ERROR: sc.scan() returned nil")
        return {}
    end
    print("[SCAN] Raw scan returned " .. #raw .. " blocks")

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
    print("[SCAN] Found " .. #ores .. " ore blocks in scan")
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
    -- Greedy nearest-neighbour: re-sort after every mine so the miner drains
    -- one vein completely before jumping to a distant one
    local remaining = {}
    for _, o in ipairs(ores) do table.insert(remaining, o) end

    local mined = 0
    while #remaining > 0 do
        local p = base.getPos()
        table.sort(remaining, function(a, b)
            local da = math.abs(a.x-p.x) + math.abs(a.y-p.y) + math.abs(a.z-p.z)
            local db = math.abs(b.x-p.x) + math.abs(b.y-p.y) + math.abs(b.z-p.z)
            return da < db
        end)
        local ore = table.remove(remaining, 1)
        if inventoryFull() then dumpOres() end
        navToOre(ore, jobId)
        mined = mined + 1
    end
    return mined
end

-- ── Job handler ──────────────────────────────────────────────────────────────

local function mineJob(job)
    local jobId   = job.id
    local totalOre = 0

    base.setPartnerId(job.params.partnerId)
    base.setStatus(proto.STATUS.TRAVELLING, jobId)
    base.sendProgress("Departing for mining zone")

    -- Depart via dispatch hole (same handshake as delivery)
    local ok, err = base.depart()
    if not ok then
        base.sendFailed("departure_failed: " .. (err or "?"), true)
        return
    end

    -- Support is 1 block above in the hole after descending together.
    -- Step sideways 1 block to clear the hole column, then ascend to sky.
    -- Support independently rises to Y=100 from the hole — different column.
    checkFuel(jobId)
    local p = base.getPos()
    base.move.to(p.x + 1, p.y, p.z)
    checkFuel(jobId)
    base.move.to(p.x + 1, SKY_Y, p.z)

    -- ── Sector loop ──────────────────────────────────────────────────────────
    while true do
        if base.isRecalled() then
            base.sendFailed("recalled", true)
            return
        end

        base.sendToServer(proto.MSG.SECTOR_REQUEST, proto.payloadSectorRequest(jobId))
        local msg = waitMsg({ proto.MSG.SECTOR_ASSIGN, proto.MSG.MINE_COMPLETE }, 20)

        if not msg then
            base.sendFailed("sector_request_timeout", true)
            return
        end

        if msg.type == proto.MSG.MINE_COMPLETE then
            break
        end

        local sx = msg.payload.sectorX
        local sz = msg.payload.sectorZ
        local sy = msg.payload.scanY or 56

        base.setStatus(proto.STATUS.TRAVELLING, jobId)
        base.sendProgress(string.format("Travelling to sector %d,%d", sx, sz))
        checkFuel(jobId)
        base.move.to(sx, SKY_Y, sz)
        checkFuel(jobId)
        base.move.to(sx, sy, sz)

        base.setStatus(proto.STATUS.WORKING, jobId)
        base.sendProgress(string.format("Scanning sector %d,%d at Y=%d", sx, sz, sy))
        local ores = scanSector()

        local count = 0
        if #ores > 0 then
            base.sendProgress(string.format("Found %d ore blocks — mining", #ores))
            count = mineOreList(ores, jobId)
            totalOre = totalOre + count
            dumpOres()
        end

        checkFuel(jobId)
        base.move.to(base.getPos().x, SKY_Y, base.getPos().z)

        base.sendToServer(proto.MSG.SECTOR_DONE,
            proto.payloadSectorDone(jobId, sx, sz, count))
    end

    -- ── Return home ──────────────────────────────────────────────────────────
    base.sendProgress(string.format("All sectors done — %d ore mined. Returning.", totalOre))
    base.signalPartner(proto.MSG.RETURN_TO_DOCK, {})
    base.returnToDock()
    base.sendComplete({ oreCount = totalOre })
end

base.run(mineJob)
