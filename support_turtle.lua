-- support_turtle.lua
-- Chunk-loader support turtle.
-- Waits for delivery turtle to reach the dispatch hole, then follows the
-- same underground route to keep the delivery turtle chunk-loaded.

local base  = require("turtle_base")
local proto = require("protocol")

local UNDERGROUND_Y = 60
local POLL_INTERVAL = 5    -- seconds between job-complete checks

base.setCanDig(false)
base.init(proto.ROLE.SUPPORT)
base.fuel.dockRefuel()

base.run(function(job)
    local params      = job.params
    local partnerId   = params.partnerId
    local masterJobId = params.masterJobId
    local dest        = params.destination   -- {x,y,z} passed from dispatcher

    base.setPartnerId(partnerId)
    base.setStatus(proto.STATUS.WORKING, job.id)

    -- Debug: print all received params
    print("Params received:")
    print("  partnerId=" .. tostring(partnerId))
    print("  masterJobId=" .. tostring(masterJobId))
    if dest then
        print(string.format("  dest=%d,%d,%d", dest.x, dest.y, dest.z))
    else
        print("  dest=NIL (server may need update)")
    end

    -- ── Step 1: Wait for HOLE_READY from delivery turtle ─────────────────────
    -- Delivery sends this when it reaches the dispatch hole entrance

    base.sendProgress("Waiting for HOLE_READY from " .. partnerId)
    print("Waiting for hole signal from " .. partnerId .. "...")

    local signalReceived = false
    local deadline = os.clock() + 180
    while os.clock() < deadline do
        local msg = proto.receive(base.getSelfId(), 5)
        if msg and msg.type == proto.MSG.HOLE_READY and msg.from == partnerId then
            print("HOLE_READY received — heading to dispatch hole!")
            signalReceived = true
            break
        end
    end

    if not signalReceived then
        print("No HOLE_READY signal — departing anyway.")
    end

    -- ── Step 2: Depart depot via dispatch hole ────────────────────────────────
    -- base.depart() handles: navigate to staging → send SUPPORT_STAGED → descend

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

        if not msg then
            -- Timeout — check if partner finished or went offline
            local info = base.queryTurtle(partnerId, 5)
            if not info or not info.online then
                print("Partner offline. Returning to dock.")
                break
            elseif not info.jobId then
                print("Partner job complete. Returning to dock.")
                break
            end

        elseif msg.from == partnerId then

            if msg.type == proto.MSG.POSITION_UPDATE and not ascending then
                -- Move to where delivery just was (1 block behind)
                local prev = msg.payload.prev
                if prev then
                    base.move.to(prev.x, prev.y, prev.z)
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

            end
        end
    end

    -- ── Step 5: Return to dock ────────────────────────────────────────────────

    base.returnToDock()
    base.sendComplete()
end)
