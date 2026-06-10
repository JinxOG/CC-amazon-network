-- support_turtle.lua
-- Chunk-loader support turtle.
-- Waits for delivery turtle to reach the dispatch hole, then follows the
-- same underground route to keep the delivery turtle chunk-loaded.

local base  = require("turtle_base")
local proto = require("protocol")

-- OPT #63: removed unused UNDERGROUND_Y and POLL_INTERVAL locals

base.setCanDig(false)
base.init(proto.ROLE.SUPPORT)
base.fuel.dockRefuel()

base.run(function(job)
    local params      = job.params
    local partnerId   = params.partnerId
    local masterJobId = params.masterJobId
    -- dest is passed from the dispatcher for informational use; navigation is
    -- handled by following the delivery turtle's POSITION_UPDATE broadcasts.

    base.setPartnerId(partnerId)
    base.setStatus(proto.STATUS.WORKING, job.id)

    -- ── Mining support mode (fuelManage=true) ────────────────────────────────
    -- Slot 1: coal supply. Slot 2: fuel transfer EC (paired with miner's slot 15).
    -- Stays near dock; on FUEL_LOW loads coal into EC so miner can draw from it.
    if params.fuelManage then
        local COAL_SLOT   = 1
        local TRANSFER_EC = 2

        base.sendProgress("Mining fuel-manager ready for " .. partnerId)
        print("[SUPPORT] Mining mode — listening for FUEL_LOW from " .. partnerId)

        while true do
            if base.isRecalled() then
                print("[SUPPORT] Recalled — returning to dock")
                break
            end

            local msg = proto.receive(base.getSelfId(), 10)

            if not msg then
                local info = base.queryTurtle(partnerId, 5)
                if not info or not info.online or not info.jobId then
                    print("[SUPPORT] Partner done or offline — returning to dock")
                    break
                end

            elseif msg.from == partnerId and msg.type == proto.MSG.FUEL_LOW then
                print("[SUPPORT] FUEL_LOW — loading coal into transfer EC")
                -- Place the transfer EC, drop coal in, pick it up.
                -- Coal appears in miner's matching EC for it to suck out.
                turtle.select(TRANSFER_EC)
                if turtle.detectDown() then turtle.digDown() end
                if turtle.placeDown() then
                    turtle.select(COAL_SLOT)
                    turtle.dropDown(16)
                    turtle.select(TRANSFER_EC)
                    turtle.digDown()
                end
                base.signalPartner(proto.MSG.FUEL_READY, { jobId = job.id })
                print("[SUPPORT] Coal loaded into EC — FUEL_READY sent")
            end
        end

        base.returnToDock()
        base.sendComplete()
        return
    end

    -- ── Step 1: Wait for HOLE_READY from delivery turtle ─────────────────────
    -- Delivery sends this when it reaches the dispatch hole entrance

    base.sendProgress("Waiting for HOLE_READY from " .. partnerId)
    print("Waiting for hole signal from " .. partnerId .. "...")

    local signalReceived = false
    local aborted        = false
    local deadline = os.epoch("utc") / 1000 + 180
    while os.epoch("utc") / 1000 < deadline do
        if base.isServerDown() then
            deadline = os.epoch("utc") / 1000 + 180   -- freeze while server unreachable
            sleep(2)
        end
        local msg = proto.receive(base.getSelfId(), 5)
        if base.isRecalled() then
            print("[SUPPORT] Recalled while waiting — aborting")
            return base.sendFailed("recalled", false)
        end
        if msg and msg.from == partnerId then
            if msg.type == proto.MSG.HOLE_READY then
                print("HOLE_READY received — heading to dispatch hole!")
                signalReceived = true
                break
            elseif msg.type == proto.MSG.JOB_ABORT then
                print("JOB_ABORT received — delivery failed. Returning to dock.")
                aborted = true
                break
            end
        end
    end

    if aborted then
        base.returnToDock()
        return base.sendComplete()
    end

    if not signalReceived then
        -- Delivery partner never reached the hole (crashed, stuck, or wrong partner).
        -- Do NOT descend — that causes pile-ups with other pairs at the hole.
        -- Return to dock and fail the job so the server can re-queue it.
        print("No HOLE_READY signal after 180s — delivery partner timed out. Returning to dock.")
        base.returnToDock()
        return base.sendFailed("no_hole_ready_from_delivery", true)
    end

    -- ── Step 2: Depart depot via dispatch hole ────────────────────────────────
    -- base.depart() handles: navigate to staging → send SUPPORT_STAGED → descend

    -- Pre-flight fuel check
    base.fuel.dockRefuel()
    if base.fuel.isCritical() then
        print("[SUPPORT] Insufficient fuel to begin job — aborting")
        return base.sendFailed("insufficient_fuel", false)
    end

    local ok, err = base.depart()
    if not ok then
        return base.sendFailed("departure_failed: " .. (err or "?"), true)
    end

    -- ── Step 3+4: Follow delivery in real-time ───────────────────────────────
    -- Delivery broadcasts its previous position after every move on CH_LOCAL.
    -- Support moves to that position = always 1 block behind delivery.
    -- When delivery sends ASCENDING, support holds still (clear of descent path).
    -- When delivery sends DESCENDED, support resumes following.

    base.setStatus(proto.STATUS.TRAVELLING, job.id)
    base.sendProgress("Following " .. partnerId)
    print("Following " .. partnerId .. " (1 block behind)")

    local ascending = false

    while true do
        local msg = proto.receive(base.getSelfId(), 15)

        if base.isRecalled() then
            print("[SUPPORT] Recalled mid-follow — returning to dock")
            break
        end

        if not msg then
            -- Timeout — if server is down just wait, don't abandon partner
            if base.isServerDown() then
                sleep(2)
            else
                local info = base.queryTurtle(partnerId, 5)
                if not info or not info.online then
                    print("Partner offline. Returning to dock.")
                    break
                elseif not info.jobId then
                    print("Partner job complete. Returning to dock.")
                    break
                end
            end

        elseif msg.from == partnerId then

            if msg.type == proto.MSG.POSITION_UPDATE and not ascending then
                -- Move to where delivery just was (1 block behind)
                local prev = msg.payload.prev
                if prev and type(prev.x) == "number" and type(prev.y) == "number" and type(prev.z) == "number" then
                    base.move.to(prev.x, prev.y, prev.z)
                else
                    print("[SUPPORT] Invalid POSITION_UPDATE payload, skipping move")
                end

            elseif msg.type == proto.MSG.ASCENDING then
                -- Delivery going up to deliver — hold current position
                ascending = true
                print("Delivery ascending — holding position")
                base.sendProgress("Holding while delivery delivers")

            elseif msg.type == proto.MSG.DESCENDED then
                -- Delivery back underground — resume following
                ascending = false
                print("Delivery descended — resuming follow")

            elseif msg.type == proto.MSG.RETURN_TO_DOCK then
                -- Delivery is inside building but still near arrivals hole.
                -- Wait for it to clear the area before ascending.
                print("Delivery inside — waiting for it to clear arrivals hole...")
                sleep(8)
                print("Ascending and returning to dock independently")
                break

            elseif msg.type == proto.MSG.JOB_ABORT then
                print("JOB_ABORT received mid-job — returning to dock immediately.")
                break

            end
        end
    end

    -- ── Step 5: Return to dock ────────────────────────────────────────────────

    base.returnToDock()
    base.sendComplete()
end)
