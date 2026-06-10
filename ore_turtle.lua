-- ore_turtle.lua
-- Rename to startup.lua on any miner turtle.
-- Paired with a SUPPORT turtle (SUPPORT_FOLLOW, fuelManage=true).
--
-- Inventory layout:
--   Slot  1   advancedperipherals:geo_scanner  (placed, used, picked back up)
--   Slots 2-13  mining output  → dumped to ore E-chest after each sector
--   Slot 14   coal reserve     (support drops coal here; miner refuels from here)
--   Slot 15   fuel ender chest (backup fuel)
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
local FUEL_WARN    = 800   -- signal partner when fuel drops below this
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
                serveSupportFuel(msg.payload and msg.payload.jobId)
            elseif set[msg.type] then
                return msg
            end
        end
    end
    return nil
end

-- ── Ore detection ────────────────────────────────────────────────────────────

local function isOre(name, tags)
    if name:find("_ore") then return true end
    if type(tags) == "table" then
        for k in pairs(tags) do
            if type(k) == "string" and k:find("ores") then return true end
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
    -- Draw coal directly from the on-board fuel EC (slot 15)
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

-- Called when support signals FUEL_LOW. Miner dumps ores, fills slots 2-13
-- with coal from its fuel EC, signals FUEL_READY so support can suck directly,
-- then waits for FUEL_FILLED before sweeping leftovers to slot 14 and resuming.
serveSupportFuel = function(jobId)
    if _servingFuel then return end
    _servingFuel = true
    print("[MINER] Support fuel low — preparing coal")

    -- Clear non-protected slots and load them with coal
    dumpOres()
    turtle.select(S_FUEL_EC)
    if turtle.detectDown() then turtle.digDown() end
    turtle.placeDown()
    for s = 2, 13 do
        turtle.select(s)
        turtle.suckDown(64)
    end
    turtle.select(S_FUEL_EC)
    turtle.digDown()

    -- Signal support to suck (uses direct receive to avoid re-entrant waitMsg)
    base.signalPartner(proto.MSG.FUEL_READY, { jobId = jobId })
    local deadline = os.epoch("utc") / 1000 + 20
    while os.epoch("utc") / 1000 < deadline do
        local msg = proto.receive(base.getSelfId(), 3)
        if msg and msg.type == proto.MSG.FUEL_FILLED
                and msg.from == base.getPartnerId() then
            break
        end
    end

    sweepCoalToSlot14()
    _servingFuel = false
    print("[MINER] Support refuel done")
end

-- ── Geo Scanner ──────────────────────────────────────────────────────────────

-- Place scanner below, scan, pick up. Returns list of absolute ore positions.
-- Scanner is placed at (turtle.x, turtle.y-1, turtle.z), so relative coords
-- are offset: abs = (turtle.x + rel.x, (turtle.y-1) + rel.y, turtle.z + rel.z)
local function scanSector()
    local item = turtle.getItemDetail(S_SCANNER)
    if not item or item.name ~= SCANNER_NAME then
        print("[MINER] geo scanner missing from slot 1 — skipping scan")
        return {}
    end

    turtle.select(S_SCANNER)
    if turtle.detectDown() then turtle.digDown() end
    if not turtle.placeDown() then return {} end

    local sc = peripheral.wrap("bottom")
    if not sc then
        turtle.select(S_SCANNER); turtle.digDown(); return {}
    end

    local raw = sc.scan(SCAN_RADIUS)
    turtle.select(S_SCANNER)
    turtle.digDown()
    if not raw then return {} end

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
    return ores
end

-- ── Mining ───────────────────────────────────────────────────────────────────

-- Navigate to an ore block: travel horizontally at current Y first to avoid
-- punching long diagonal tunnels, then descend. move.to digs all obstacles
-- including the ore block itself, mining it as part of travel.
local function navToOre(ore, jobId)
    checkFuel(jobId)
    local p = base.getPos()
    -- Horizontal leg at current Y
    base.move.to(ore.x, p.y, ore.z)
    checkFuel(jobId)
    -- Vertical leg to ore Y (digs the ore block)
    base.move.to(ore.x, ore.y, ore.z)
end

local function mineOreList(ores, jobId)
    -- Sort nearest-first to minimise travel distance
    local p = base.getPos()
    table.sort(ores, function(a, b)
        local da = math.abs(a.x-p.x) + math.abs(a.y-p.y) + math.abs(a.z-p.z)
        local db = math.abs(b.x-p.x) + math.abs(b.y-p.y) + math.abs(b.z-p.z)
        return da < db
    end)

    local mined = 0
    for _, ore in ipairs(ores) do
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

    base.setStatus(proto.STATUS.TRAVELLING, jobId)
    base.sendProgress("Departing for mining zone")

    -- Ascend to sky travel altitude
    checkFuel(jobId)
    local p = base.getPos()
    base.move.to(p.x, SKY_Y, p.z)

    -- ── Sector loop ──────────────────────────────────────────────────────────
    while true do
        if base.isRecalled() then
            base.sendFailed("recalled", true)
            return
        end

        -- Request next sector from server
        base.sendToServer(proto.MSG.SECTOR_REQUEST, proto.payloadSectorRequest(jobId))
        local msg = waitMsg({ proto.MSG.SECTOR_ASSIGN, proto.MSG.MINE_COMPLETE }, 20)

        if not msg then
            base.sendFailed("sector_request_timeout", true)
            return
        end

        if msg.type == proto.MSG.MINE_COMPLETE then
            break
        end

        -- Travel to sector center at sky level, then descend to scan Y
        local sx = msg.payload.sectorX
        local sz = msg.payload.sectorZ
        local sy = msg.payload.scanY or 56

        base.setStatus(proto.STATUS.TRAVELLING, jobId)
        base.sendProgress(string.format("Travelling to sector %d,%d", sx, sz))
        checkFuel(jobId)
        base.move.to(sx, SKY_Y, sz)
        checkFuel(jobId)
        base.move.to(sx, sy, sz)

        -- Scan sector
        base.setStatus(proto.STATUS.WORKING, jobId)
        base.sendProgress(string.format("Scanning sector %d,%d at Y=%d", sx, sz, sy))
        local ores = scanSector()

        -- Mine all found ores
        local count = 0
        if #ores > 0 then
            base.sendProgress(string.format("Found %d ore blocks — mining", #ores))
            count = mineOreList(ores, jobId)
            totalOre = totalOre + count
            dumpOres()
        end

        -- Rise back to sky level before moving to next sector
        checkFuel(jobId)
        base.move.to(base.getPos().x, SKY_Y, base.getPos().z)

        -- Report sector complete
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
