-- support_turtle.lua
-- Chunk-loader support turtle.
-- Waits for delivery turtle to reach the dispatch hole, then follows the
-- same underground route to keep the delivery turtle chunk-loaded.

local base  = require("turtle_base")
local proto = require("protocol")


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

    -- ── Mining support mode (fuelManage=true) ────────────────────────────────
    -- Mining support: follows 1 block behind via POSITION_UPDATE.
    -- When support fuel drops below threshold, burns on-board coal from slots 13-14.
    -- If coal is exhausted, sends JOB_ABORT to miner and returns to dock.
    if params.fuelManage then
        local SUPPORT_FUEL_WARN = 800
        -- Per-pair altitude slot keeps concurrent mine pairs vertically separated.
        -- travelYOffset=0 means slot 0 (default); each additional slot adds 10.
        local FOLLOW_Y          = 180 + (params.travelYOffset or 0)

        -- No pre-ascent. POSITION_UPDATEs from the miner guide us in real time.
        -- Phase 1 (following): track the miner's full X,Y,Z.
        -- Phase 2 (mining): once miner dips below FOLLOW_Y after reaching sky,
        --   lock to FOLLOW_Y and track X,Z only — miner is underground.
        local _reachedSky    = false   -- true after miner has been near SKY_Y
        local _miningMode    = false   -- true once miner first descends below FOLLOW_Y
        local _skyReturn     = false   -- true when MINE_RECALL received; use sky return path
        local _recalling     = false   -- true when MINE_RECALL received; stay at FOLLOW_Y until miner ascends
        local _jobFailed     = false   -- true if support ran out of coal; suppresses sendComplete
        local lastUpdateTime = os.epoch("utc") / 1000

        local p = base.getPos()
        if not base.isInsideBuilding(p) then
            -- Rebooted mid-job outside the building. The miner will shortly
            -- call recallReturn() which sends MINE_RECALL. Skip depart;
            -- enter the follow loop already in recall mode.
            base.setStatus(proto.STATUS.WORKING, job.id)
            base.sendProgress("Rebooted mid-job — awaiting miner MINE_RECALL")
            print("[SUPPORT] Rebooted outside building — entering recovery follow mode")
            -- _miningMode stays false: the partner-complete check
            -- (not _miningMode and not info.jobId) must be active so the support
            -- returns home within 15s after the miner docks, instead of waiting
            -- for the 5-minute _miningMode stale fallback.
            _skyReturn  = true
            _recalling  = true
            lastUpdateTime = os.epoch("utc") / 1000   -- reset so stale clock starts at loop entry, not block entry
        else
            base.fuel.dockRefuel()
            base.fuel.dockFillCoal()
            if base.fuel.isCritical() then
                print("[SUPPORT] Insufficient fuel — aborting")
                return base.sendFailed("insufficient_fuel", false)
            end

            -- Wait for miner to reach the hole
            base.sendProgress("Waiting for HOLE_READY from miner " .. partnerId)
            print("[SUPPORT] Waiting for HOLE_READY from " .. partnerId .. "...")
            local signalReceived = false
            local holeHeld     = {}
            local holeDeadline = os.epoch("utc") / 1000 + 600
            while os.epoch("utc") / 1000 < holeDeadline do
                if base.isRecalled() then
                    -- Signal miner before leaving so it starts its return
                    base.signalPartner(proto.MSG.MINE_RECALL, {})
                    sleep(3)
                    return base.sendFailed("recalled", false)
                end
                local msg = base.receive(5)
                if msg then
                    if msg.from == partnerId and msg.type == proto.MSG.HOLE_READY then
                        signalReceived = true
                        break
                    end
                    -- Held, not re-queued inline: pushing back inside the loop
                    -- would be re-popped immediately and spin.
                    holeHeld[#holeHeld + 1] = msg
                end
            end
            for i = 1, #holeHeld do base.pushJobInbox(holeHeld[i]) end

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
                    -- Not yet in mining mode (still following miner to zone or waiting).
                    -- Always use sky return even here — ground return gets stuck on terrain.
                    print("[SUPPORT] Recalled — returning to dock")
                    _skyReturn = true
                    break
                end
            end

            -- ── Field fuel check ─────────────────────────────────────────────
            -- Support carries coal in slots 13-14 for field self-refueling.
            if turtle.getFuelLevel() < SUPPORT_FUEL_WARN then
                if not base.fuel.selfRefuel() then
                    print("[SUPPORT] Coal exhausted — fuel-exhaustion return")
                    -- Reliable: the miner has no other cue that we are leaving.
                    base.signalPartnerReliable(proto.MSG.JOB_ABORT, {}, { attempts = 3, interval = 2 })
                    _skyReturn = true
                    _jobFailed = true
                    break
                end
                print("[SUPPORT] Self-refueled to " .. turtle.getFuelLevel())
            end

            -- ── Partner liveness ─────────────────────────────────────────────
            -- Gated on how long the PARTNER has been quiet, not on an empty
            -- receive. These checks used to live inside `if not msg`, but the
            -- server ACKs our heartbeat every 5s, so a 15s receive window
            -- practically never returned nil — the checks below were unreachable
            -- and a support that missed RETURN_TO_DOCK hovered indefinitely.
            local quietSec = os.epoch("utc") / 1000 - lastUpdateTime
            if quietSec >= 15 and not base.isServerDown() then
                local info = nil
                for _try = 1, 3 do
                    info = base.queryTurtle(partnerId, 5)
                    if info and info.online then break end
                    sleep(3)
                end
                if not info or not info.online then
                    print("[SUPPORT] Partner offline after 3 queries — returning to dock")
                    _skyReturn = _miningMode or _recalling
                    break
                elseif not _miningMode and not info.jobId then
                    -- Job ID clears at MINE_COMPLETE while miner may still be
                    -- mid-ascent. Only break immediately if NOT recalling — the
                    -- miner will send RETURN_TO_DOCK once it reaches SKY_Y.
                    if _recalling then
                        -- Stay put. The 5-min stale timeout below is the last resort.
                        print("[SUPPORT] Miner job done, still ascending — holding for RETURN_TO_DOCK")
                    else
                        print("[SUPPORT] Partner job complete — returning to dock")
                        break
                    end
                end
                if (_miningMode or _recalling) and quietSec > 300 then
                    print("[SUPPORT] No miner update for 5min — returning")
                    _skyReturn = true
                    break
                end
            end

            local msg = base.receive(15)

            if msg and msg.from == partnerId then
                -- Any partner traffic counts as liveness, not just POSITION_UPDATE.
                lastUpdateTime = os.epoch("utc") / 1000
                if msg.type == proto.MSG.POSITION_UPDATE then
                    local prev = msg.payload.prev
                    if prev and type(prev.x) == "number" then
                        if not _miningMode then
                            if prev.y >= 190 then _reachedSky = true end
                            if _reachedSky and prev.y < FOLLOW_Y then
                                _miningMode = true
                                print("[SUPPORT] Miner descended to mine — locking to Y=" .. FOLLOW_Y)
                            end
                        end
                        -- Drain after every POSITION_UPDATE. During sky flight the miner
                        -- sends 300+ updates; draining prevents RETURN_TO_DOCK from being
                        -- dropped past the 256-event CC queue limit. In survey mode,
                        -- draining catches MINE_RECALL queued behind recent updates so
                        -- support applies xOffset=1 before moving (prevents blocking miner).
                        do
                            local drained = {}
                            while true do
                                local nxt = base.receive(0.05)
                                if not nxt then break end
                                if nxt.from ~= partnerId then
                                    drained[#drained + 1] = nxt
                                elseif nxt.from == partnerId then
                                    if nxt.type == proto.MSG.POSITION_UPDATE then
                                        prev = nxt.payload.prev
                                        lastUpdateTime = os.epoch("utc") / 1000
                                        -- Track sky altitude inside drain so CC queue overflow
                                        -- during long fuel waits can't cause us to miss Y≥190.
                                        if not _miningMode and prev and type(prev.y) == "number" then
                                            if prev.y >= 190 then _reachedSky = true end
                                            if _reachedSky and prev.y < FOLLOW_Y then
                                                _miningMode = true
                                                print("[SUPPORT] Miner descended to mine (drain) — locking to Y=" .. FOLLOW_Y)
                                            end
                                        end
                                    elseif nxt.type == proto.MSG.RETURN_TO_DOCK then
                                        print("[SUPPORT] Miner returning (drain) — docking")
                                        _skyReturn = true
                                        goto mine_done
                                    elseif nxt.type == proto.MSG.JOB_ABORT then
                                        print("[SUPPORT] JOB_ABORT (drain) — docking")
                                        goto mine_done
                                    elseif nxt.type == proto.MSG.MINE_RECALL then
                                        print("[SUPPORT] Mine recalled (drain) — clearing column")
                                        _skyReturn  = true
                                        _recalling  = true
                                        local rp = nxt.payload and nxt.payload.pos
                                        local sp  = base.getPos()
                                        base.move.to(rp and (rp.x+1) or (sp.x+1), sp.y,
                                                     rp and rp.z or sp.z)
                                        base.signalPartner(proto.MSG.MINE_CLEAR, {})
                                        print("[SUPPORT] Column cleared (drain) — ACK sent")
                                        break
                                    end
                                end
                            end
                            -- Anything not from the partner goes back rather than
                            -- being swallowed by the drain.
                            for i = 1, #drained do base.pushJobInbox(drained[i]) end
                        end
                        -- When recalling: transition to sky-follow once miner reaches FOLLOW_Y
                        if _recalling and _miningMode and prev.y >= FOLLOW_Y then
                            _miningMode = false
                            print("[SUPPORT] Miner at meeting altitude — ascending together")
                        end
                        local targetY = _miningMode and FOLLOW_Y or prev.y
                        -- Three-phase recall follow:
                        --   Phase 1 — underground + vertical (prev.y < 200):
                        --     xOffset=1 (1 block east) keeps support clear of miner's column
                        --     and chunk-loads the ascent path.
                        --   Phase 2 — sky altitude (prev.y >= 200):
                        --     xOffset=0 → support moves to miner's exact previous position
                        --     = 1 block behind in the flight direction. Step-by-step 1:1
                        --     follow means queue depth stays at 0-1 (no overflow).
                        --     Natural repositioning happens on the first Y=200 update as
                        --     support transitions from east-offset to directly behind.
                        --   Phase 3 — non-recall delivery follow: xOffset=0 (normal).
                        -- xOffset=1 (east) while recalling and below sky altitude — keeps
                        -- support clear of the miner's vertical column during both the
                        -- underground ascent (_miningMode=true) and the vertical leg
                        -- (_miningMode=false, prev.y < 200). At sky altitude (prev.y >= 200)
                        -- switch to xOffset=0 so support trails 1 block directly behind.
                        local xOffset = (_recalling and prev.y < 200) and 1 or 0
                        local tx, tz = prev.x + xOffset, prev.z
                        local ok = base.move.to(tx, targetY, tz)
                        if not ok then
                            -- Terrain blocked horizontal travel at FOLLOW_Y.
                            -- Escape upward by 30 blocks so the path clears, then
                            -- the next POSITION_UPDATE descends back once past the obstacle.
                            print(string.format("[SUPPORT] Terrain blocked at Y=%d — escaping to Y=%d",
                                targetY, targetY + 30))
                            base.move.to(tx, targetY + 30, tz)
                        end
                        base.pushPosition()  -- throttled: sends position to server at most once per 2s
                    end

                elseif msg.type == proto.MSG.RETURN_TO_DOCK then
                    print("[SUPPORT] Miner returning — returning via sky path")
                    _skyReturn = true
                    break

                elseif msg.type == proto.MSG.JOB_ABORT then
                    print("[SUPPORT] JOB_ABORT — returning to dock")
                    break

                elseif msg.type == proto.MSG.MINE_CLEAR then
                    -- Duplicate ACK (miner retried MINE_RECALL); already positioned east.
                    -- No action needed; miner will stop retrying when it receives our ACK.

                elseif msg.type == proto.MSG.MINE_RECALL then
                    print("[SUPPORT] Mine recalled — clearing miner column")
                    _skyReturn = true
                    _recalling = true
                    -- Step east relative to miner's reported position so the column is
                    -- guaranteed clear before we ACK. Uses miner's payload.pos if present
                    -- (new protocol); falls back to own position + 1 (old behaviour).
                    local rp = msg.payload and msg.payload.pos
                    local sp = base.getPos()
                    base.move.to(rp and (rp.x+1) or (sp.x+1), sp.y, rp and rp.z or sp.z)
                    base.signalPartner(proto.MSG.MINE_CLEAR, {})
                    print("[SUPPORT] Column cleared — ACK sent to miner")
                end
            end
        end
        ::mine_done::

        if _skyReturn then
            -- Miner cleared the arrivals hole right before sending RETURN_TO_DOCK.
            -- Both turtles are at Y=200 above the hole simultaneously; support has
            -- canDig=false so if miner is in the shaft it cannot push through.
            -- 5s gives ~15 blocks of shaft clearance at 3 blocks/sec — plenty of margin.
            sleep(5)
            base.setSkyReturn(true)
            base.returnToDockFromSky()
            base.setSkyReturn(false)
        else
            base.returnToDock()
        end
        if _jobFailed then
            base.sendFailed("support_fuel_exhausted", true)
        elseif base.isRecalled() then
            -- The control loop no longer reports on our behalf, so a recalled
            -- job must be reported as failed here — not completed.
            base.sendFailed("recalled", true)
        else
            base.sendComplete()
        end
        return
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
    local held = {}
    while os.epoch("utc") / 1000 < deadline do
        if base.isServerDown() then
            deadline = os.epoch("utc") / 1000 + holeTimeout   -- freeze while server unreachable
            sleep(2)
        end
        local msg = base.receive(5)
        if base.isRecalled() then
            print("[SUPPORT] Recalled while waiting — aborting")
            for i = 1, #held do base.pushJobInbox(held[i]) end
            return base.sendFailed("recalled", false)
        end
        if msg then
            if msg.from == partnerId and msg.type == proto.MSG.HOLE_READY then
                print("HOLE_READY received — heading to dispatch hole!")
                signalReceived = true
                break
            elseif msg.from == partnerId and msg.type == proto.MSG.JOB_ABORT then
                print("JOB_ABORT received — delivery failed. Returning to dock.")
                aborted = true
                break
            else
                held[#held + 1] = msg
            end
        end
    end
    for i = 1, #held do base.pushJobInbox(held[i]) end

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

    local ascending      = false
    local lastPartnerMsg = os.epoch("utc") / 1000

    while true do
        if base.isRecalled() then
            print("[SUPPORT] Recalled mid-follow — returning to dock")
            break
        end

        -- Partner liveness, gated on partner silence rather than on an empty
        -- receive. The server ACKs our heartbeat every 5s, so `if not msg` was
        -- effectively unreachable and these checks never ran.
        if os.epoch("utc") / 1000 - lastPartnerMsg >= 15 and not base.isServerDown() then
            local info = base.queryTurtle(partnerId, 5)
            if not info or not info.online then
                print("Partner offline. Returning to dock.")
                break
            elseif not info.jobId then
                print("Partner job complete. Returning to dock.")
                break
            end
        end

        local msg = base.receive(15)

        if msg and msg.from == partnerId then
            lastPartnerMsg = os.epoch("utc") / 1000

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
    if base.isRecalled() then
        -- The control loop no longer reports on our behalf, so a recalled job
        -- must be reported as failed here — not completed.
        base.sendFailed("recalled", true)
    else
        base.sendComplete()
    end
end

local ok, err = pcall(base.run, supportJob)
if not ok then
    print("[SUPPORT] Fatal crash: " .. tostring(err))
    print("[SUPPORT] Rebooting in 20s...")
    sleep(20)
end
os.reboot()
