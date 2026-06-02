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

    local ok, err = base.depart()
    if not ok then
        return base.sendFailed("departure_failed: " .. (err or "?"), true)
    end

    -- Signal delivery that we are underground and ready to travel together
    print("Sending SUPPORT_READY to " .. partnerId)
    local sig = proto.encode(proto.MSG.SUPPORT_READY, base.getSelfId(), partnerId, {})
    proto.send(base.getModem(), proto.CH_LOCAL, sig)

    -- ── Step 3: Travel underground to destination ─────────────────────────────
    -- Stay UNDERGROUND_Y, but stop 5 blocks short of the destination so the
    -- delivery turtle can descend and ascend at dest X,Z without hitting us.

    if dest then
        base.setStatus(proto.STATUS.TRAVELLING, job.id)

        -- Figure out which axis we travel along and offset 5 blocks back
        local startPos = base.getPos()
        local dx = dest.x - startPos.x
        local dz = dest.z - startPos.z
        local waitX, waitZ = dest.x, dest.z

        if math.abs(dx) >= math.abs(dz) then
            -- Mostly X travel — stay 5 blocks back in X
            waitX = dest.x + (dx > 0 and -5 or 5)
        else
            -- Mostly Z travel — stay 5 blocks back in Z
            waitZ = dest.z + (dz > 0 and -5 or 5)
        end

        base.sendProgress(string.format("Underground travel to %d,%d (holding at %d,%d)", dest.x, dest.z, waitX, waitZ))
        ok, err = base.move.to(waitX, UNDERGROUND_Y, waitZ)
        if not ok then
            print("Nav error: " .. (err or "?"))
            base.sendProgress("nav_error: " .. (err or "?"))
        end

        print(string.format("Holding at %d,%d,%d (clear of delivery descent)", waitX, UNDERGROUND_Y, waitZ))
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
