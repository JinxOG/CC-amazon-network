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
local SURVEY_TRAVEL_Y = 95   -- 5 below support FOLLOW_Y=100; avoids vertical collision during survey
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
            elseif msg.type == proto.MSG.JOB_ABORT
                    and msg.from == base.getPartnerId() then
                -- Support was recalled independently and signalled us.
                -- Self-recall so existing isRecalled() checks fire recallReturn(),
                -- which sends MINE_RECALL back to the waiting support.
                print("[MINER] Support sent JOB_ABORT — self-recalling for coordinated return")
                base.setRecalled(true)
                return nil
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

-- Refuel at dock: place EC above (bay layout), suck coal, pick it back up.
local function minerDockRefuel()
    local ecItem = turtle.getItemDetail(S_FUEL_EC)
    if not ecItem then
        print(string.format("[FUEL] EC missing from slot %d — cannot refuel", S_FUEL_EC))
        return
    end
    turtle.select(S_FUEL_EC)
    if turtle.detectUp() then turtle.digUp() end
    if turtle.placeUp() then
        turtle.select(S_COAL)
        turtle.suckUp(64)
        turtle.refuel()
        turtle.select(S_FUEL_EC)
        turtle.digUp()
        print(string.format("[FUEL] EC refuel complete: %d fuel", turtle.getFuelLevel()))
    else
        print("[FUEL] Failed to place fuel EC above")
    end
end

base.setRefuelFn(minerDockRefuel)

-- Estimate fuel required to fly home from the current position.
local function fuelToReturn()
    local p  = base.getPos()
    local ah = W.ARRIVALS_HOLE
    local ascent  = math.max(0, SKY_Y - p.y)
    local lateral = math.abs(p.x - ah.x) + math.abs(p.z - ah.z)
    return math.ceil(ascent + lateral + 300)  -- 300 = descent + dock nav + margin
end

local function checkFuel(jobId)
    if turtle.getFuelLevel() >= FUEL_WARN then return end

    -- Step 1: burn slot-14 coal reserve
    tryRefuelSlot14()
    if turtle.getFuelLevel() >= FUEL_WARN then return end

    -- Step 2: try the fuel EC in slot 15
    local ecItem = turtle.getItemDetail(S_FUEL_EC)
    if ecItem then
        turtle.select(S_FUEL_EC)
        if turtle.detectDown() then turtle.digDown() end
        if turtle.placeDown() then
            turtle.select(S_COAL)
            local got = turtle.suckDown(32)
            if got then
                turtle.refuel()
            else
                print("[FUEL] EC chest is empty — no coal available")
                base.sendProgress("FUEL WARNING: EC chest empty, fuel=" .. turtle.getFuelLevel())
            end
            turtle.select(S_FUEL_EC)
            turtle.digDown()
        else
            print("[FUEL] Failed to place fuel EC")
        end
    else
        print(string.format("[FUEL] EC missing from slot %d — cannot refuel from chest", S_FUEL_EC))
        base.sendProgress("FUEL WARNING: EC missing from slot " .. S_FUEL_EC
                .. ", fuel=" .. turtle.getFuelLevel())
    end

    -- Step 3: assess post-refuel fuel level
    local fuel   = turtle.getFuelLevel()
    if fuel >= FUEL_WARN then return end  -- successfully topped up

    local needed = fuelToReturn()
    if fuel < needed then
        print(string.format("[FUEL] CRITICAL: %d fuel, need ~%d to return — aborting job", fuel, needed))
        base.sendProgress("FUEL CRITICAL: " .. fuel .. " fuel (need ~" .. needed
                .. " to return) — returning to base")
        base.setRecalled(true)
    else
        -- Enough to get home, but too low to keep mining comfortably — warn and continue.
        print(string.format("[FUEL] LOW: %d fuel (min %d to return) — continuing cautiously", fuel, needed))
        base.sendProgress("FUEL LOW: " .. fuel .. " fuel (min ~" .. needed .. " to return)")
    end
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

local function mineOreList(ores, jobId, sx, sz, sy)
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
        -- Immediate per-ore update so the dashboard reflects each mine in real time
        base.sendToServer(proto.MSG.SECTOR_SCAN,
            proto.payloadSectorScan(jobId, sx, sz, sy, {}, {[ore.name]=1}))
    end
    return mined, byType
end

-- ── Job handler ──────────────────────────────────────────────────────────────

local function mineJob(job)
    local jobId    = job.id
    local totalOre = 0

    -- Shared coordinated sky return: keeps partnerId set (POSITION_UPDATEs
    -- broadcasting) so the support chunk-loads the miner the entire way home.
    -- Signals MINE_RECALL so support enters follow mode, leads it to Y=100,
    -- waits for alignment, then ascends together to SKY_Y and arrivals hole.
    -- Clears partnerId only once both turtles are at the hole.
    local function coordinatedSkyReturn()
        dumpOres()
        checkFuel(jobId)
        base.signalPartner(proto.MSG.MINE_RECALL, {})
        local p = base.getPos()
        base.move.to(p.x, 100, p.z)
        sleep(5)
        base.move.to(p.x, SKY_Y, p.z)
        base.move.to(W.ARRIVALS_HOLE.x, SKY_Y, W.ARRIVALS_HOLE.z)
        base.signalPartner(proto.MSG.RETURN_TO_DOCK, {})
        base.setPartnerId(nil)
        base.returnToDockFromSky()
    end

    local function recallReturn(failReason, failRecoverable)
        coordinatedSkyReturn()
        base.sendFailed(failReason or "recalled", failRecoverable ~= nil and failRecoverable or false)
    end

    base.setPartnerId(job.params.partnerId)
    local startPos = base.getPos()
    if not base.isInsideBuilding(startPos) then
        base.sendProgress("Rebooted mid-job — coordinated sky return")
        recallReturn("reboot_recovery", true)
        return
    end
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

    local useSkyTravel = false  -- true after first mine sector; switches to SKY_Y=200

    while msg and msg.type == proto.MSG.SECTOR_ASSIGN do
        if base.isRecalled() then
            recallReturn()
            return
        end

        local sx         = msg.payload.sectorX
        local sz         = msg.payload.sectorZ
        local surveyMode = msg.payload.surveyMode == true
        local modeTag    = surveyMode and "[SURVEY] " or ""

        base.setStatus(proto.STATUS.TRAVELLING, jobId)
        base.sendProgress(string.format("%sTravelling to sector %d,%d", modeTag, sx, sz))

        -- Survey sectors and the first mine sector use SURVEY_TRAVEL_Y=95 so the
        -- miner never ascends through FOLLOW_Y=100 where support hovers.
        -- From mine sector 2 onwards, use SKY_Y=200 (full altitude).
        checkFuel(jobId)
        local travelY = (surveyMode or not useSkyTravel) and SURVEY_TRAVEL_Y or SKY_Y
        if not surveyMode then useSkyTravel = true end
        -- Fly lateral-then-vertical when descending: reach sector X,Z at current
        -- altitude first so the support (1 block below in phase-1 follow) is
        -- horizontally offset before we descend. Without this, the support blocks
        -- the first descent from SKY_Y=200 to SURVEY_TRAVEL_Y=95.
        local curPos = base.getPos()
        if curPos.y > travelY then
            base.move.to(sx, curPos.y, sz)
        end
        base.move.to(sx, travelY, sz)

        -- Scan every depth level; only mine if not in survey mode.
        -- seenOres deduplicates across depth levels: scan spheres overlap
        -- (Y=16 covers Y 0-32, Y=8 covers Y -8 to 24 — 24-block overlap),
        -- so the same ore block appears in multiple raw scan results.
        local count       = 0
        local sectorFound = {}   -- {[name]=count} from geo scan (deduplicated)
        local sectorMined = {}   -- {[name]=count} actually mined (0 during survey)
        local seenOres    = {}   -- "x,y,z" → true; prevents double-counting
        for i, sy in ipairs(SCAN_LEVELS) do
            checkFuel(jobId)
            base.move.to(sx, sy, sz)
            base.setStatus(proto.STATUS.WORKING, jobId)
            base.sendProgress(string.format("%sScanning %d,%d depth %d/%d (Y=%d)",
                modeTag, sx, sz, i, #SCAN_LEVELS, sy))
            local rawOres = scanSector()
            -- Deduplicate: only keep ore blocks not seen at a previous depth level.
            local ores      = {}
            local scanFound = {}
            for _, o in ipairs(rawOres) do
                local key = o.x .. "," .. o.y .. "," .. o.z
                if not seenOres[key] then
                    seenOres[key] = true
                    table.insert(ores, o)
                    scanFound[o.name]    = (scanFound[o.name]    or 0) + 1
                    sectorFound[o.name] = (sectorFound[o.name] or 0) + 1
                end
            end
            -- Report scan results immediately so the dashboard updates in real time.
            if next(scanFound) then
                base.sendToServer(proto.MSG.SECTOR_SCAN,
                    proto.payloadSectorScan(jobId, sx, sz, sy, scanFound))
            end
            -- During survey: report ores found but do not mine them
            if #ores > 0 and not surveyMode then
                base.sendProgress(string.format("Mining %d ores at Y=%d", #ores, sy))
                local c, byType = mineOreList(ores, jobId, sx, sz, sy)
                count = count + c
                for name, n in pairs(byType) do
                    sectorMined[name] = (sectorMined[name] or 0) + n
                end
            end
            if base.isRecalled() then break end
        end

        if count > 0 or inventoryFull() then dumpOres() end
        totalOre = totalOre + count

        -- Report done; server immediately replies with next SECTOR_ASSIGN or MINE_COMPLETE
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
    base.sendProgress(string.format("All sectors done — %d ore mined. Returning.", totalOre))
    coordinatedSkyReturn()
    base.sendComplete({ oreCount = totalOre })
end

base.run(mineJob)
