-- support_turtle.lua
-- Rename to startup.lua on any support/chunk-loader turtle.
-- Waits for worker to exit building before departing.
-- Follows worker underground, returns via arrivals hole.

local base  = require("turtle_base")
local proto = require("protocol")

local FOLLOW_DISTANCE = 16   -- max Manhattan distance before moving closer
local POLL_INTERVAL   = 3    -- seconds between partner position checks
local UNDERGROUND_Y   = 67   -- floor level — below this means worker is outside

base.setCanDig(false)
base.init(proto.ROLE.SUPPORT)
base.fuel.dockRefuel()

base.run(function(job)
    local params      = job.params
    local partnerId   = params.partnerId
    local masterJobId = params.masterJobId

    base.setPartnerId(partnerId)
    base.setStatus(proto.STATUS.WORKING, job.id)

    -- ── Step 1: Wait for HOLE_READY signal from delivery turtle ─────────────
    -- Delivery turtle sends this when it reaches the dispatch hole entrance

    base.sendProgress("Waiting for HOLE_READY signal from " .. partnerId)
    print("Waiting for hole signal from " .. partnerId .. "...")

    -- Listen on CH_LOCAL for the signal (timeout 3 minutes)
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
        logWarn("No HOLE_READY signal received — departing anyway.")
    end

    -- ── Step 2: Depart depot via dispatch hole ────────────────────────────────

    local ok, err = base.depart()
    if not ok then
        return base.sendFailed("departure_failed: " .. (err or "?"), true)
    end

    base.sendProgress("Following " .. partnerId)
    print(string.format("Following %s (master: %s)", partnerId, masterJobId))

    -- ── Step 3: Follow loop ───────────────────────────────────────────────────

    while true do
        base.fuel.refuel()

        local info = base.queryTurtle(partnerId, 5)

        if not info then
            print("No server response, retrying...")
            sleep(POLL_INTERVAL)

        elseif not info.online then
            print("Partner offline. Returning to dock.")
            break

        elseif info.jobId == nil then
            print("Partner idle. Job complete.")
            break

        elseif info.position then
            local p   = info.position
            local pos = base.getPos()
            local dist = math.abs(p.x - pos.x)
                       + math.abs(p.y - pos.y)
                       + math.abs(p.z - pos.z)

            if dist > FOLLOW_DISTANCE then
                -- Stay 4 blocks behind partner
                local tx, ty, tz = p.x, p.y, p.z
                if     pos.x < p.x then tx = p.x - 4
                elseif pos.x > p.x then tx = p.x + 4
                elseif pos.z < p.z then tz = p.z - 4
                elseif pos.z > p.z then tz = p.z + 4
                end

                local moveOk, moveErr = base.move.to(tx, ty, tz)
                if not moveOk then
                    print("Nav error: " .. (moveErr or "?"))
                    base.sendProgress("nav_error: " .. (moveErr or "?"))
                end
            end

            sleep(POLL_INTERVAL)
        else
            sleep(POLL_INTERVAL)
        end
    end

    -- ── Step 4: Return to dock ────────────────────────────────────────────────

    base.returnToDock()
    base.sendComplete()
end)
