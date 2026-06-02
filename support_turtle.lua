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

    local ok, err = base.depart()
    if not ok then
        return base.sendFailed("departure_failed: " .. (err or "?"), true)
    end

    -- ── Step 3: Travel underground to destination ─────────────────────────────
    -- Mirror delivery turtle's route: stay at UNDERGROUND_Y the whole way

    if dest then
        base.setStatus(proto.STATUS.TRAVELLING, job.id)
        base.sendProgress(string.format("Underground travel to %d,%d", dest.x, dest.z))

        ok, err = base.move.to(dest.x, UNDERGROUND_Y, dest.z)
        if not ok then
            print("Nav error: " .. (err or "?"))
            base.sendProgress("nav_error: " .. (err or "?"))
        end

        print(string.format("Holding position near %d,%d,%d", dest.x, UNDERGROUND_Y, dest.z))
    else
        print("No destination — holding at current position.")
    end

    -- ── Step 4: Wait for delivery turtle to finish ────────────────────────────
    -- Poll server until partner goes idle (job complete) or offline

    base.setStatus(proto.STATUS.WORKING, job.id)
    base.sendProgress("Holding for " .. partnerId)

    while true do
        sleep(POLL_INTERVAL)
        local info = base.queryTurtle(partnerId, 5)
        if not info then
            print("No server response, retrying...")
        elseif not info.online then
            print("Partner offline. Returning to dock.")
            break
        elseif info.jobId == nil then
            print("Partner job complete. Returning to dock.")
            break
        end
    end

    -- ── Step 5: Return to dock ────────────────────────────────────────────────

    base.returnToDock()
    base.sendComplete()
end)
