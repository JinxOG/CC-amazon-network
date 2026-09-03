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
end

local ok, err = pcall(base.run, supportJob)
if not ok then
    print("[SUPPORT] Fatal crash: " .. tostring(err))
    print("[SUPPORT] Rebooting in 20s...")
    sleep(20)
end
os.reboot()
