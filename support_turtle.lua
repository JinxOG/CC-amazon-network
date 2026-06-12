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
    -- Mining support: follows 1 block behind via POSITION_UPDATE.
    -- When support fuel drops below threshold, signals miner to prepare coal.
    -- Miner dumps ores, fills slots 2-13 with coal from its EC, signals FUEL_READY.
    -- Support sucks coal forward from miner, refuels, signals FUEL_FILLED.
    if params.fuelManage then
        local SUPPORT_FUEL_WARN = 800
        local FOLLOW_Y          = 100   -- altitude support hovers at while tracking miner

        -- No pre-ascent. POSITION_UPDATEs from the miner guide us in real time.
        -- Phase 1 (following): track the miner's full X,Y,Z.
        -- Phase 2 (mining): once miner dips below FOLLOW_Y after reaching sky,
        --   lock to FOLLOW_Y and track X,Z only — miner is underground.
        local _reachedSky    = false   -- true after miner has been near SKY_Y
        local _miningMode    = false   -- true once miner first descends below FOLLOW_Y
        local _skyReturn     = false   -- true when MINE_RECALL received; use sky return path
        local _recalling     = false   -- true when MINE_RECALL received; stay at FOLLOW_Y until miner ascends
        local lastUpdateTime = os.epoch("utc") / 1000

        local p = base.getPos()
        if not base.isInsideBuilding(p) then
            -- Rebooted mid-job outside the building. The miner will shortly
            -- call recallReturn() which sends MINE_RECALL. Skip depart;
            -- enter the follow loop already in recall mode.
            base.setStatus(proto.STATUS.WORKING, job.id)
            base.sendProgress("Rebooted mid-job — awaiting miner MINE_RECALL")
            print("[SUPPORT] Rebooted outside building — entering recovery follow mode")
            _miningMode = true
            _skyReturn  = true
            _recalling  = true
            lastUpdateTime = os.epoch("utc") / 1000   -- reset so stale clock starts at loop entry, not block entry
        else
            base.fuel.dockRefuel()
            if base.fuel.isCritical() then
                print("[SUPPORT] Insufficient fuel — aborting")
                return base.sendFailed("insufficient_fuel", false)
            end

            -- Wait for miner to reach the hole
            base.sendProgress("Waiting for HOLE_READY from miner " .. partnerId)
            print("[SUPPORT] Waiting for HOLE_READY from " .. partnerId .. "...")
            local signalReceived = false
            local holeDeadline = os.epoch("utc") / 1000 + 180
            while os.epoch("utc") / 1000 < holeDeadline do
                if base.isRecalled() then
                    return base.sendFailed("recalled", false)
                end
                local msg = proto.receive(base.getSelfId(), 5)
                if msg and msg.from == partnerId and msg.type == proto.MSG.HOLE_READY then
                    signalReceived = true
                    break
                end
            end

            if not signalReceived then
                base.returnToDock()
                return base.sendFailed("no_hole_ready_from_miner", true)
            end

            local ok, err = base.depart(true)
            if not ok then
                return base.sendFailed("departure_failed: " .. (err or "?"), true)
            end

            base.setStatus(proto.STATUS.TRAVELLING, job.id)
            base.sendProgress("Following miner")
            print(string.format("[SUPPORT] Tracking %s", partnerId))
        end

        while true do
            if base.isRecalled() then
                if _miningMode or _recalling then
                    -- Server RECALL arrives via cancelJob(linkedJob) while miner is
                    -- underground. Don't return independently — treat it like MINE_RECALL
                    -- and wait for the miner to lead us back via POSITION_UPDATE /
                    -- RETURN_TO_DOCK.  The miner will send MINE_RECALL shortly.
                    _skyReturn = true
                    _recalling = true
                else
                    print("[SUPPORT] Recalled — returning to dock")
                    _skyReturn = _miningMode
                    break
                end
            end

            -- ── Field fuel check ─────────────────────────────────────────────
            -- Miner will ascend to 1 block below support to deliver coal.
            if turtle.getFuelLevel() < SUPPORT_FUEL_WARN then
                print("[SUPPORT] Fuel low — signalling miner to ascend for refuel")
                local myPos = base.getPos()
                base.signalPartner(proto.MSG.FUEL_LOW, {
                    jobId = job.id,
                    pos   = { x = myPos.x, y = myPos.y, z = myPos.z },
                })
                -- Wait for miner to ascend and load coal (needs travel time)
                local fuelDeadline = os.epoch("utc") / 1000 + 120
                local ready = false
                while os.epoch("utc") / 1000 < fuelDeadline do
                    local m = proto.receive(base.getSelfId(), 5)
                    if m and m.from == partnerId
                            and m.type == proto.MSG.FUEL_READY then
                        ready = true; break
                    end
                end
                if ready then
                    -- Miner is directly below at FOLLOW_Y-1; suck coal down from it
                    turtle.select(1)
                    while turtle.getFuelLevel() < SUPPORT_FUEL_WARN + 400 do
                        if not turtle.suckDown(64) then break end
                        turtle.refuel()
                    end
                    base.signalPartner(proto.MSG.FUEL_FILLED, { jobId = job.id })
                    print("[SUPPORT] Refueled to " .. turtle.getFuelLevel())
                else
                    print("[SUPPORT] Refuel timeout — miner did not arrive")
                end
            end

            local msg = proto.receive(base.getSelfId(), 15)

            if not msg then
                if base.isServerDown() then
                    sleep(2)
                else
                    local info = base.queryTurtle(partnerId, 5)
                    if not info or not info.online then
                        print("[SUPPORT] Partner offline — returning to dock")
                        break
                    elseif not _miningMode and not info.jobId then
                        -- In mining mode the server clears jobId on cancel before the
                        -- miner can send MINE_RECALL — don't leave; wait for the signal.
                        print("[SUPPORT] Partner job complete — returning to dock")
                        break
                    end
                    local staleSec = os.epoch("utc") / 1000 - lastUpdateTime
                    if _miningMode and staleSec > 300 then
                        print("[SUPPORT] No miner update for 5min in mining mode — returning")
                        _skyReturn = true
                        break
                    end
                end

            elseif msg.from == partnerId then
                if msg.type == proto.MSG.POSITION_UPDATE then
                    local prev = msg.payload.prev
                    lastUpdateTime = os.epoch("utc") / 1000
                    if prev and type(prev.x) == "number" then
                        if not _miningMode then
                            if prev.y >= 190 then _reachedSky = true end
                            if _reachedSky and prev.y < FOLLOW_Y then
                                _miningMode = true
                                print("[SUPPORT] Miner descended to mine — locking to Y=" .. FOLLOW_Y)
                            end
                        end
                        -- In mining mode the miner fires hundreds of POSITION_UPDATEs
                        -- during inter-sector flight. Drain all queued ones so support
                        -- jumps to the miner's LATEST position instead of replaying
                        -- every intermediate step (which causes severe lag/misalignment).
                        if _miningMode then
                            while true do
                                local nxt = proto.receive(base.getSelfId(), 0.05)
                                if not nxt then break end
                                if nxt.from == partnerId then
                                    if nxt.type == proto.MSG.POSITION_UPDATE then
                                        prev = nxt.payload.prev
                                        lastUpdateTime = os.epoch("utc") / 1000
                                    elseif nxt.type == proto.MSG.RETURN_TO_DOCK then
                                        print("[SUPPORT] Miner returning (drain) — docking")
                                        _skyReturn = true
                                        goto mine_done
                                    elseif nxt.type == proto.MSG.JOB_ABORT then
                                        print("[SUPPORT] JOB_ABORT (drain) — docking")
                                        goto mine_done
                                    elseif nxt.type == proto.MSG.MINE_RECALL then
                                        print("[SUPPORT] Mine recalled (drain) — waiting at meeting altitude")
                                        _skyReturn  = true
                                        _recalling  = true
                                        -- Break drain so main loop can handle the recall transition
                                        break
                                    end
                                end
                            end
                        end
                        -- When recalling: transition to real-Y follow once miner reaches FOLLOW_Y
                        if _recalling and _miningMode and prev.y >= FOLLOW_Y then
                            _miningMode = false
                            print("[SUPPORT] Miner at meeting altitude — ascending together")
                        end
                        local targetY = _miningMode and FOLLOW_Y or prev.y
                        base.move.to(prev.x, targetY, prev.z)
                    end

                elseif msg.type == proto.MSG.RETURN_TO_DOCK then
                    print("[SUPPORT] Miner returning — returning via sky path")
                    _skyReturn = true
                    break

                elseif msg.type == proto.MSG.JOB_ABORT then
                    print("[SUPPORT] JOB_ABORT — returning to dock")
                    break

                elseif msg.type == proto.MSG.MINE_RECALL then
                    print("[SUPPORT] Mine recalled — waiting at meeting altitude for miner")
                    _skyReturn = true
                    _recalling = true
                    -- Don't break — keep receiving POSITION_UPDATEs so we track miner X,Z
                    -- at FOLLOW_Y until miner ascends up to meet us, then follow real Y up
                end
            end
        end
        ::mine_done::

        if _skyReturn then
            base.returnToDockFromSky()
        else
            base.returnToDock()
        end
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
