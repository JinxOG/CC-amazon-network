-- support_turtle.lua
-- Chunk-loader support turtle for DELIVER job pairs only.
-- Waits for the delivery turtle to reach the dispatch hole, then follows the
-- same underground route to keep the delivery turtle chunk-loaded.
-- Mining is solo since v1.9.0 (the miner carries its own chunk loader), so
-- this turtle no longer has a mining-support mode.

local base  = require("turtle_base")
local proto = require("protocol")


-- The two types the pre-departure wait accepts. Named so base.receive can leave
-- everything else queued instead of returning it here to be discarded.
local WAIT_FOR_HOLE = {
    [proto.MSG.HOLE_READY] = true,
    [proto.MSG.JOB_ABORT]  = true,
    -- Its delivery is still coming, held by the ATC (2026-11-16, the one change
    -- unfrozen in this file): each one restarts the wait below.
    [proto.MSG.HOLE_PENDING] = true,
}

base.setCanDig(false)
base.init(proto.ROLE.SUPPORT)
base.fuel.dockRefuel()

local function supportJob(job)
    local params      = job.params
    local partnerId   = params.partnerId
    local masterJobId = params.masterJobId
    -- dest is passed from the dispatcher for informational use; navigation is
    -- handled by following the delivery turtle's POSITION_UPDATE broadcasts.

    base.setPartnerId(partnerId)
    base.setStatus(proto.STATUS.WORKING, job.id)

    -- Mining no longer uses a support turtle: since v1.9.0 the miner carries its
    -- own chunk loader and places it at each sector. A SUPPORT_FOLLOW job with
    -- fuelManage set means a stale job survived the upgrade — fail it rather
    -- than fly out to shadow a miner that is not expecting a partner.
    if params.fuelManage then
        print("[SUPPORT] Stale mining-support job — mining is solo since v1.9.0")
        return base.sendFailed("mining_support_deprecated", false)
    end

    -- ── Step 0 (R2): ask for the way out with the delivery, from this dock ───
    -- The ATC lets the pair in as one unit; until then both wait on their docks.
    local booked, why = base.prebookDeparture()
    if not booked then
        print("[SUPPORT] Not let out with my delivery (" .. tostring(why) .. ") -- staying docked")
        if why == "recalled" then return base.sendFailed("recalled", false) end
        return base.sendFailed("departure_failed: " .. tostring(why), true)
    end

    -- ── Step 1: Wait for HOLE_READY from delivery turtle ─────────────────────
    -- Delivery sends this when it reaches the dispatch hole entrance

    base.sendProgress("Waiting for HOLE_READY from " .. partnerId)
    print("Waiting for hole signal from " .. partnerId .. "...")

    local signalReceived = false
    local aborted        = false
    -- Normal flow: 3 min. If rebooted mid-job (outside building), give delivery
    -- 10 min to restart, re-register, and reach the hole before giving up.
    local holeTimeout = base.isInsideBuilding(base.getPos()) and 180 or 600
    local deadline = os.epoch("utc") / 1000 + holeTimeout
    while os.epoch("utc") / 1000 < deadline do
        if base.isServerDown() then
            deadline = os.epoch("utc") / 1000 + holeTimeout   -- freeze while server unreachable
            sleep(2)
        end
        -- base.receive, not proto.receive: proto.receive returned the first
        -- message of ANY type and the type tests below discarded the rest --
        -- the same loss that caused the registration storm, and here it means a
        -- HOLE_READY that arrives a moment early is gone. Naming the two types
        -- this wait accepts leaves everything else queued for its own reader.
        -- Authorised by the spec owner's scoped Invariant H exception,
        -- 2026-09-02: three call sites, no other change.
        local msg = base.receive(5, WAIT_FOR_HOLE)
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
            elseif msg.type == proto.MSG.HOLE_PENDING then
                -- Still coming: give it the full wait again from now.
                deadline = os.epoch("utc") / 1000 + holeTimeout
            end
        end
    end

    if aborted then
        base.returnToDock()
        return base.sendFailed("partner_aborted_pre_hole", false)
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
    -- R4: when it last heard its delivery itself -- any message from it, its
    -- PAIR_ALIVE every 20 s among them. Only its delivery's word, or its silence,
    -- ends the follow; the server's online flag never does (side-e node_218).
    local PARTNER_SILENT_S = 300
    local heardAt = os.epoch("utc")

    while true do
        -- base.receive, not proto.receive. Left UNFILTERED, exactly as it was:
        -- this loop legitimately takes whatever the partner sends. The win is
        -- that control traffic is no longer eligible to be swallowed here --
        -- base.receive only ever returns job-plane messages, so a HEARTBEAT_ACK
        -- can no longer be absorbed by a following support turtle.
        -- POSITION_UPDATE is transient and never queued, so it still arrives
        -- live rather than stale. Authorised by the spec owner's scoped
        -- Invariant H exception, 2026-09-02: three call sites, no other change.
        local msg = base.receive(15)

        if base.isRecalled() then
            print("[SUPPORT] Recalled mid-follow — returning to dock")
            break
        end

        if msg and msg.from == partnerId then heardAt = os.epoch("utc") end
        heardAt = math.max(heardAt, base.partnerHeardAt())
        -- Hearing nobody at all (a radio blackout), its delivery's silence is no
        -- news: that time is nobody's silence, as at the ATC. Three supports left
        -- their deliveries in side test sim's 5-minute blackout before this.
        if os.epoch("utc") - base.heardAnyAt() > 10000 then heardAt = os.epoch("utc") end
        -- Its "come home", however it arrived (noted as it came in, R4).
        if not (msg and msg.type == proto.MSG.RETURN_TO_DOCK) and base.partnerHome() then
            msg = { type = proto.MSG.RETURN_TO_DOCK, from = partnerId, payload = {} }
        end

        if not msg then
            -- Its delivery says nothing for minutes while it waits for the
            -- warehouse: that is not news. Only a long silence from the delivery
            -- itself -- it sends PAIR_ALIVE every 20 s -- means it is gone: the
            -- last line, for a delivery that really died. Asked instead, the
            -- server answered "offline" for a delivery it had simply not heard
            -- since its own crash (T2 shakeout-side-e, 02:13:29).
            local silent = (os.epoch("utc") - heardAt) / 1000
            if silent > PARTNER_SILENT_S then
                print(string.format("Partner silent %ds -- taken for gone. Returning to dock.", math.floor(silent)))
                break
            end

        elseif msg.from == partnerId then

            -- ITS POSITION HEARD WHILE HOLDING IS ITS DESCENDED (R4, 2026-11-17). A
            -- delivery broadcasts its position only while it travels underground --
            -- none while it is up delivering -- so one heard now means it is on its
            -- way again. DESCENDED is sent once: lost in a radio loss, the support
            -- held on, its delivery went home alone and out of range, and the support
            -- went home alone 300 s later (sim w3_side_atc, node_55).
            if msg.type == proto.MSG.POSITION_UPDATE and ascending then
                ascending = false
                print("Delivery moving again -- resuming follow (its DESCENDED did not reach me)")
            end
            if msg.type == proto.MSG.POSITION_UPDATE and not ascending then
                -- To where delivery just was (1 block behind), by its own cells (base.followPartner)
                local pl = msg.payload
                if type(pl) == "table" and (type(pl.tail) == "table" or type(pl.prev) == "table") then
                    base.followPartner(pl)
                else
                    print("[SUPPORT] Invalid POSITION_UPDATE payload, skipping move")
                end

            elseif msg.type == proto.MSG.ASCENDING then
                -- Delivery going up to deliver — hold current position. Repeated
                -- every 10 s while it holds (side-h): said once.
                if not ascending then print("Delivery ascending — holding position") end
                ascending = true
                -- At the holding line it names its slot and its path (R3): come up
                -- behind it along its own dug cells, not wherever this one lagged.
                if msg.payload and msg.payload.slot then base.walkPartnerTrail() end
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
                -- Up its delivery's own cells first (T2 shakeout-side-h, node_219: its
                -- hold notice lost, it planned its own way from 6 cells off, into rock,
                -- and retraced 158 steps). The come-home carries the path too.
                base.walkPartnerTrail()
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
end

local ok, err = pcall(base.run, supportJob)
if not ok then
    print("[SUPPORT] Fatal crash: " .. tostring(err))
    print("[SUPPORT] Rebooting in 20s...")
    pcall(base.flushLogs)
    sleep(20)
end
os.reboot()
