-- turtle_base.lua
-- Shared foundation for all turtle roles.
-- Handles: registration, dock assignment, heartbeat, movement, fuel, routing.

local proto = require("protocol")
local W     = require("waypoints")

-- geofence.lua is not installed on every turtle role (delivery/support don't
-- ship it — see install.lua). pcall so those roles behave exactly as before.
local ok_gf, _geofence = pcall(require, "geofence")
if not ok_gf then _geofence = nil end

local base = {}

-- ─── Config ──────────────────────────────────────────────────────────────────

local CFG = {
    HEARTBEAT_INTERVAL  = 5,
    FUEL_CRITICAL       = 200,
    FUEL_RESERVE        = 500,   -- conservative pre-departure reserve (full warehouse run)
    MOVE_RETRIES        = 3,
    REGISTER_RETRIES    = 10,
    REGISTER_TIMEOUT    = 5,
    GPS_TIMEOUT         = 3,
    GPS_RESYNC_INTERVAL = 50,   -- re-sync GPS every N moves
    FLOOR_Y             = 67,   -- building floor Y; turtles are "inside" at or above this
}

-- x/z bounding box of the depot building (used for "inside the building" checks).
local BUILDING = { minX = 143, maxX = 228, minZ = -2817, maxZ = -2782 }

-- ─── Internal State ──────────────────────────────────────────────────────────

local _self = {
    id         = nil,
    role       = nil,
    dock       = nil,    -- assigned dock from waypoints
    partnerId  = nil,
    partnerSlot = nil,   -- the holding slot its delivery named (base.atc.preferSlot)
    partnerLeft = false, -- its delivery said it went down without it (PARTNER_LEFT)
    status     = proto.STATUS.IDLE,
    jobId      = nil,
    modem      = nil,
    pos        = { x = 0, y = 0, z = 0 },
    facing     = 0,      -- 0=north(-z) 1=east(+x) 2=south(+z) 3=west(-x)
    moveCount  = 0,
    busy       = false,
    canDig      = true,   -- false for turtles without a pickaxe (e.g. support)
    serverDown  = false,  -- true while server is unreachable; pauses movement + freezes deadlines
    recalled    = false,  -- set by RECALL handler; causes waitForAny to exit the job runner
    inSkyReturn = false,  -- true during sky return; bypasses serverDown freeze (path is fixed)
    autonomousReturn = false,  -- true while navigating home without the server (see setAutonomousReturn)
    -- Solo-miner telemetry, carried on every heartbeat. nil for every other
    -- role (nothing else calls base.setPhase), which is exactly the shape
    -- proto.payloadHeartbeat's backward-compatibility contract requires.
    phase       = nil,
    chunk       = nil,   -- { cx=, cz= } the miner is working in
    commsGap    = nil,   -- true while a deliberate modem-off window is expected
}

-- ─── Logging ───────────────────────────────────────────────────

-- The outbox itself lives in logship.lua.
--
-- It used to live here, which meant the warehouse and admin computers -- which
-- forward no logs at all -- would each have needed their own copy of five rules
-- that were paid for by five separate outages. Re-typing them is how one copy
-- quietly loses one of them, so they live in one file now and this one consumes
-- them like everybody else. Every comment that used to be here is there, next
-- to the code it governs.
--
-- Created at the TOP of this file, before anything else can print, because it
-- replaces the global print. The transport is attached further down, once
-- comms.toServer exists to carry a batch.
local logship = require("logship")
local _log = logship.new({ source = "turtle" })

-- pendingLevel is set for the duration of one print() so the queue records the
-- level as a real FIELD. Only log() knows it: by the time a line reaches print
-- it is text, and the bridge would have to recover it with a regex. W5 keeps
-- that regex for the bare print() calls elsewhere that never had a level to
-- lose -- but a parsed level and a known one should not be the same thing, or
-- `grep WARN` quietly answers for only half the fleet.
local function log(level, msg)
    _log.pendingLevel = level
    print(string.format("[%s][%s] %s", _self.id or "?", level, msg))
    _log.pendingLevel = nil
end
local function logInfo(m)  log("INFO",  m) end
local function logWarn(m)  log("WARN",  m) end
local function logError(m) log("ERROR", m) end

-- ─── Public Accessors ────────────────────────────────────────────────────────

function base.getSelfId()        return _self.id         end
function base.getModem()         return _self.modem      end
function base.getPos()           return { x=_self.pos.x, y=_self.pos.y, z=_self.pos.z } end
-- Tracked heading: 0=north(-z) 1=east(+x) 2=south(+z) 3=west(-x).
-- mine_flow's pos() hook REQUIRES this: turtle.place() drops the carried chunk
-- loader one block AHEAD, and "ahead" cannot be derived from x/y/z alone. A
-- wrong facing here puts the loader in the wrong chunk, which is the one
-- placement error that cannot be undone without a pickaxe we aren't holding.
function base.getFacing()        return _self.facing     end
function base.getDock()          return _self.dock       end
-- A TURTLE KEEPS ITS DOCK (2026-11-18, T2 shakeout-24h-b). It learned its dock only
-- from REGISTER_ACK and kept it nowhere: node_481, rebooted while the server was
-- deaf, flew home not knowing where home was, said "No dock assigned, staying put"
-- in the arrivals column and held ARR 38 min. dock.dat holds the last dock the
-- server gave it (".dat": a copied turtle's disk never carries it); a reboot starts
-- from it, and the server's next assignment replaces it.
local DOCK_FILE = "dock.dat"
function base.saveDock(d)
    if type(d) ~= "table" or not d.x then return false end
    local ok = pcall(function()
        local f = fs.open(DOCK_FILE, "w")
        if not f then error("no file", 0) end
        f.write(textutils.serialise({ x = d.x, y = d.y, z = d.z, bay = d.bay, row = d.row }))
        f.close()
    end)
    return ok
end
function base.loadSavedDock()
    if not (fs.exists and fs.exists(DOCK_FILE)) then return false end
    local ok, d = pcall(function()
        local f = fs.open(DOCK_FILE, "r")
        local text = f.readAll(); f.close()
        return textutils.unserialise(text)
    end)
    if ok and type(d) == "table" and tonumber(d.x) and tonumber(d.z) then
        _self.dock = d
        return true
    end
    return false
end
function base.getPartnerId()     return _self.partnerId  end
-- pairMate (R4): the job's partner, kept while partnerId is cleared for the ascent.
-- pairJob: the pair's job id -- the delivery's own job -- that a partner's JOB_ABORT carries (firstSight).
-- Kept when the partner is cleared and restored around a failure (delivery_turtle).
function base.setPartnerId(id, pairJob)   _self.partnerId = id; _self.partnerSlot = nil; _self.partnerLeft = false
    if pairJob then _self.pairJobId = pairJob end
                                 _self.partnerHome = false; _self.partnerHeardAt = os.epoch("utc"); _self.pairCancelled = false
                                 if id ~= nil then _self.pairMate = id end end
-- R4: when its partner was last heard, and whether it said "come home" (firstSight).
function base.partnerHeardAt()   return _self.partnerHeardAt or 0 end
-- When this turtle last heard any radio message at all (R4: silence from a partner
-- means something only while others are heard; in a blackout everyone is silent).
function base.heardAnyAt()       return _self.heardAnyAt or os.epoch("utc") end
function base.partnerHome()      return _self.partnerHome == true end
function base.partnerLeft()      return _self.partnerLeft == true end
function base.setCanDig(val)     _self.canDig = val      end
function base.isServerDown()     return _self.serverDown  end
function base.isRecalled()       return _self.recalled    end
function base.setRecalled(v)     _self.recalled = v       end
function base.setSkyReturn(v)    _self.inSkyReturn = v    end

-- Exempts movement from the serverDown hold below for a solo miner navigating
-- home on its own (GPS beacons, not the server). Every other role leaves this
-- false permanently, so tryMove's hold behaves exactly as it does today for
-- delivery/support/warehouse turtles.
function base.setAutonomousReturn(v) _self.autonomousReturn = v end

-- A ROLE'S OWN FITNESS CHECK. A role that can be unfit to work -- a miner
-- missing its ore chest, or with a loader still standing in the world -- sets a
-- function returning "ok" or the reason it cannot work. It is reported in
-- REGISTER and in every heartbeat, and the server benches or releases the
-- turtle on it: released the moment it is fixed, with no reboot.
function base.setHardwareCheck(fn) _self.hardwareCheck = fn end

-- The contents of update_failed.txt, which updater.lua writes when it refuses
-- to reboot into a broken update and deletes after a good one. nil when absent.
-- Capped: it is a REGISTER field, not a file transfer.
function base.readUpdateFailed()
    if not fs.exists("update_failed.txt") then return nil end
    local f = fs.open("update_failed.txt", "r")
    if not f then return nil end
    local body = f.readAll()
    f.close()
    return body and body:sub(1, 400) or nil
end

-- nil unless a check is set AND the turtle is idle. Idle ONLY: a working miner's
-- ore chest is legitimately out of its slot while it dumps, and a check taken
-- then would report that as missing hardware and bench a healthy turtle.
function base.hardwareVerdict()
    if not _self.hardwareCheck or _self.busy or _self.status ~= proto.STATUS.IDLE then
        return nil
    end
    local ok, v = pcall(_self.hardwareCheck)
    if ok and type(v) == "string" then return v end
    return nil
end
function base.isAutonomousReturn()   return _self.autonomousReturn end

-- Optional predicate consulted by tryMove's serverDown hold, once per sleep
-- cycle: returning true releases the hold for that move.
--
-- The hold exists so the server never loses track of a turtle it cannot talk
-- to. For a solo miner with a chunk loader placed in the world that trade goes
-- the other way: waiting out a long outage in the field leaves a chunk
-- force-loaded and the turtle stranded, and the miner can navigate home
-- perfectly well without the server (GPS comes from beacons). Nothing else
-- installs one -- delivery, support and warehouse turtles leave it nil and
-- their hold loop is exactly what it has always been.
local _serverDownEscape = nil
function base.setServerDownEscape(fn) _serverDownEscape = fn end

-- Solo-miner phase telemetry piggy-backed onto the heartbeat, so the server
-- keeps seeing the miner's phase/chunk between MINE_PHASE messages and can
-- tell a deliberate comms gap from a failure even if the MINE_PHASE report
-- itself is the message that got lost. Only the miner calls this; every other
-- role leaves all three nil, so payloadHeartbeat produces exactly the payload
-- it always has for them (pinned by tests/test_mine_phase.lua).
function base.setPhase(phase, chunk, commsGap)
    _self.phase    = phase
    _self.chunk    = chunk
    _self.commsGap = commsGap
end

-- Exposed so the miner can set/clear the anchor around placed-loader work.
-- nil on roles that don't ship geofence.lua (see the pcall require above).
base.geofence = _geofence

local _customRefuelFn = nil
function base.setRefuelFn(fn)    _customRefuelFn = fn    end

-- Optional wrapper that guarantees a pickaxe is equipped for the duration of
-- the function it is handed: wrapper(what, fn).
--
-- fuel.refuelFromChest PLACES the fuel ender chest and then digs it back up. A
-- solo miner in travel mode has chunky where the pickaxe would be, so that dig
-- silently fails and the chest is left standing in the world -- the miner can
-- then never refuel again, which is a permanent field freeze, not "item loss".
-- base.setRefuelFn already protects the FORCE_REFUEL path; this is the same
-- protection for the fuel.ensureFuel path in the control loop, which is the
-- critical one.
--
-- Only ore_turtle installs one (equipment.toRetrieveMode / retrievalSwapOut are
-- miner-only concepts). Delivery, support and warehouse turtles leave this nil
-- and ensureFuel calls refuelFromChest directly, exactly as before -- they carry
-- a permanent pickaxe (or, for support, cannot dig at all, which this wrapper
-- could not change anyway).
local _digToolWrapper = nil
function base.setDigToolWrapper(fn) _digToolWrapper = fn end

function base.isInsideBuilding(pos)
    return pos.y >= CFG.FLOOR_Y
        and pos.x >= BUILDING.minX and pos.x <= BUILDING.maxX
        and pos.z >= BUILDING.minZ and pos.z <= BUILDING.maxZ
end

-- Within 32 blocks of the building's footprint, at ANY height: the dispatch and
-- arrivals holes are one-block shafts that turtles queue in, and the sky return
-- comes down a column over the arrivals hole. Nothing may step sideways here.
function base.nearDepot(pos)
    local m = 32
    return pos.x >= BUILDING.minX - m and pos.x <= BUILDING.maxX + m
        and pos.z >= BUILDING.minZ - m and pos.z <= BUILDING.maxZ + m
end


-- ─── Comms ───────────────────────────────────────────────────────────────────

local comms = {}

-- The one definition of which channels this turtle listens on. comms.init and
-- base.recoverModem both open exactly this list, so a re-acquired modem can
-- never end up subscribed to a different set than the original.
local CHANNELS = { proto.CH_BROADCAST, proto.CH_LOCAL }

-- This turtle's own private channel -- STEP 1 of the per-turtle rollout.
--
-- Step 1 opened it IN ADDITION to CH_PRIVATE, because the server still sent
-- every private reply there. Step 2 (1.9.111) moved the server's sends onto it.
--
-- Computed once at load from the COMPUTER ID and reported in REGISTER, so the
-- server knows where to send.
--
-- STEP 3, 1.9.112: a turtle that HAS its own channel no longer opens
-- CH_PRIVATE at all, which is what finally takes the shared channel off the
-- air. Measured on step 2 (1.9.111), idle fleet: loss fell from 17.29% to
-- 0.16%, eleven of fifteen turtles losing nothing.
--
-- A turtle with OWN_CHANNEL == nil -- an id outside the valid range -- is
-- served on the shared channel forever and must keep it open or it goes deaf.
-- (Spec owner, 2026-09-16.)
--
-- THE ROLLBACK HAZARD, and the net under it. A server rolled back to before
-- 1.9.111 sends every private reply on CH_PRIVATE. A step-3 turtle is not
-- listening there, so it would never hear its REGISTER_ACK and would sit
-- unregistered for ever -- the whole fleet, silently. So registration failing
-- twice reopens the shared channel (reopenSharedChannel below). It costs one
-- extra open on a turtle that was going deaf anyway, and it is the difference
-- between a rollback being survivable and being a fleet outage.
local OWN_CHANNEL = nil
do
    local cid = nil
    pcall(function() cid = os.getComputerID() end)
    OWN_CHANNEL = proto.privateChannelFor(cid)
    if OWN_CHANNEL then
        CHANNELS[#CHANNELS + 1] = OWN_CHANNEL
    end
end
do
    if OWN_CHANNEL == nil then
        CHANNELS[#CHANNELS + 1] = proto.CH_PRIVATE
    end
end
function base._channels() return CHANNELS end        -- test seam
function base._ownChannel() return OWN_CHANNEL end   -- test seam

-- The rollback net. Adds CH_PRIVATE back and opens it on the live modem, once.
-- Called by register() after two attempts with no ACK: either the server is
-- down (harmless, the channel sits idle) or it is older than 1.9.111 and is
-- answering on the shared channel, which is the case this exists for.
local _sharedReopened = false
function base.reopenSharedChannel()
    if _sharedReopened or OWN_CHANNEL == nil then return false end
    _sharedReopened = true
    CHANNELS[#CHANNELS + 1] = proto.CH_PRIVATE
    local ok = pcall(function()
        if _self.modem and not _self.modem.isOpen(proto.CH_PRIVATE) then
            _self.modem.open(proto.CH_PRIVATE)
        end
    end)
    logWarn(string.format(
        "No ACK on channel %d after two attempts — reopening the shared channel %d. "
        .. "A server older than 1.9.111 answers there.", OWN_CHANNEL, proto.CH_PRIVATE))
    return ok
end
function base._sharedReopened() return _sharedReopened end   -- test seam

-- ─── Shared inbox (Invariant G) ──────────────────────────────────────────────
--
-- Invariant G has mandated base.receive since it was written. It never existed:
-- every waiter called proto.receive directly, and on 2026-09-02 that took the
-- fleet down for 11.8 hours.
--
-- THE MECHANISM. proto.receive returns the FIRST message addressed to this
-- turtle, whatever its type. register() waits for a REGISTER_ACK, so any other
-- message arriving first -- a HEARTBEAT_ACK, of which fifteen turtles produce a
-- steady stream -- comes back instead, fails the `reply.type == REGISTER_ACK`
-- test, and is DISCARDED along with the attempt. The real ACK then arrives while
-- nothing is waiting for it and is discarded in turn. register() retries, adds
-- traffic, and makes the next collision more likely: retries beget retries.
--
-- The server was answering correctly throughout. It logged "Re-registered" for
-- every attempt, which only happens on the success path -- the ACK was sent and
-- then thrown away at the receiver. That is why Invariant G says ACK loops make
-- loss VISIBLE, not absent: the hazard is receiver-side.
--
-- THE FIX. Nothing is ever discarded. Every waiter routes what it did not ask
-- for into one of two inboxes instead of dropping it, so a message can arrive
-- for a waiter that has not asked yet and still be there when it does.
--
--   _ctrlInbox  HEARTBEAT_ACK, REGISTER_ACK, RECALL, UPDATE_ALL, FORCE_REFUEL
--   _jobInbox   everything else -- job assignment and worker coordination
--
-- Control types are separated because HEARTBEAT_ACK is the only proof the server
-- is alive. If a job handler absorbed one, _missedHeartbeats would climb to
-- MAX_MISSED, serverDown would trip, and tryMove() would freeze all movement --
-- presenting as a fleet-wide freeze rather than a messaging fault, which looks
-- nothing like the actual cause.
--
-- THE MEMBERSHIP RULE, and it is exact: CTRL_TYPES is the set of messages the
-- CONTROL LOOP acts on. Nothing else may be in it, and nothing the control loop
-- handles may be left out -- because the control loop is the only thing that
-- drains this queue, and _jobInbox is drained only by whichever handler happens
-- to be waiting. JOB_ASSIGN was the omission: routed while the control loop sat
-- inside pumpFor, it landed in _jobInbox where no job handler ever asks for it,
-- and a turtle silently declined work it had already been given.
local CTRL_TYPES = {
    [proto.MSG.HEARTBEAT_ACK] = true,
    [proto.MSG.REGISTER_ACK]  = true,
    [proto.MSG.RECALL]        = true,
    [proto.MSG.UPDATE_ALL]    = true,
    [proto.MSG.FORCE_REFUEL]  = true,
    [proto.MSG.JOB_ASSIGN]    = true,
    -- The control loop acts on it, so the membership rule above REQUIRES it
    -- here. Left out, it would land in _jobInbox where no handler asks for
    -- it, and the reboot would silently never happen.
    [proto.MSG.REBOOT]        = true,
    [proto.MSG.RE_REGISTER]   = true,
    [proto.MSG.ATC_HELLO]     = true,   -- the control loop answers it (atc.report)
}

-- Types that are only meaningful LIVE and must never be queued.
--
-- Both are continuous streams where a stale copy is worse than none: a placed
-- loader broadcasts its liveness beacon to every turtle every 5 seconds, and a
-- delivery turtle streams its position to its partner. Queuing either fills the
-- job inbox on turtles whose handlers do not drain it -- and a support turtle
-- acting on a stale position would fly to where its partner used to be.
--
-- This is type-specific knowledge in a generic router, which is a cost. It is
-- the same cost CTRL_TYPES already pays, and the alternative is an overflow
-- warning every 5 seconds on every turtle in the fleet.
local TRANSIENT_TYPES = {
    [proto.MSG.LOADER_BEACON]   = true,
    -- Noted on sight (base.reportFailed's repeat stops); nothing waits for it.
    [proto.MSG.JOB_FAILED_ACK]  = true,
    [proto.MSG.JOB_COMPLETE_ACK] = true,
    [proto.MSG.POSITION_UPDATE] = true,
    -- The chunk gate's question and answer (base.awaitSupportInChunk): asked again until
    -- answered, so a late copy is worth nothing -- a support acting on a stale one would
    -- walk back to where its delivery used to be.
    [proto.MSG.SUPPORT_WHERE]   = true,
    [proto.MSG.SUPPORT_HERE]    = true,
    -- An ATC answer is for the step waiting on it right now; a late one is noise.
    [proto.MSG.ATC_REPLY]       = true,
    -- A delivery's "I am here" (R4): read live by its following support; never
    -- queued, so a support waiting on its dock for HOLE_READY is not filled with them.
    [proto.MSG.PAIR_ALIVE]      = true,
}

local _ctrlInbox, _jobInbox = {}, {}

-- Bounded so a worker that stops draining an inbox cannot grow it without limit.
-- Dropping the OLDEST is deliberate: a stale RECALL or a superseded assignment is
-- worth less than the message that just arrived, and an unbounded queue on a
-- 1 MB computer is its own outage.
local INBOX_MAX = 64

-- Rate-limited: an inbox that nobody drains overflows on every single arrival,
-- and a warning per arrival would bury the log it is trying to appear in. Log
-- space on these computers is scarce enough that shipping fewer lines per node
-- was itself a fix (1.9.61/1.9.67).
local _lastOverflowLog = 0

local function inboxPush(q, msg)
    q[#q + 1] = msg
    local dropped = 0
    while #q > INBOX_MAX do
        table.remove(q, 1)
        dropped = dropped + 1
    end
    if dropped > 0 then
        local now = os.epoch("utc")
        if now - _lastOverflowLog >= 60000 then
            _lastOverflowLog = now
            logWarn("Inbox overflow — oldest messages dropped; a handler is not draining")
        end
    end
end

-- Route a decoded message to its inbox. The single place that decides which
-- queue a message belongs in.
local function routeMessage(msg)
    if TRANSIENT_TYPES[msg.type] then return end
    inboxPush(CTRL_TYPES[msg.type] and _ctrlInbox or _jobInbox, msg)
end
base.routeMessage = routeMessage

-- Pop the first message matching wantType (or any, when wantType is nil).
--
-- HOLD, NEVER PUSH BACK INLINE. Non-matching messages go into a local `held`
-- table and are re-queued only after the scan finishes. Pushing one back inline
-- would have this loop re-pop what it had just queued, spinning the CPU without
-- ever blocking -- learned the hard way in the design this replaces.
-- wantType may be nil (anything), a type string, or a SET of types. The set form
-- exists so a caller waiting on several types does not have to pop-and-requeue
-- what it did not want, which is the inline push-back that spins the CPU.
local function wantMatches(msg, wantType)
    if wantType == nil then return true end
    if type(wantType) == "table" then return wantType[msg.type] == true end
    return msg.type == wantType
end

local function inboxPop(q, wantType)
    local held, found = {}, nil
    while #q > 0 do
        local msg = table.remove(q, 1)
        if found == nil and wantMatches(msg, wantType) then
            found = msg
        else
            held[#held + 1] = msg
        end
    end
    for i = 1, #held do q[#q + 1] = held[i] end
    return found
end

-- Take everything queued and leave the queue empty.
--
-- Hands the caller a detached table rather than letting it iterate the live one,
-- because dispatching a control message can re-enter the inbox: a queued
-- HEARTBEAT_ACK can trip re-registration, and register() waits on receiveCtrl.
-- A dispatcher walking the live queue would then be racing itself over the same
-- table.
local function inboxDrain(q)
    local out = {}
    for i = 1, #q do out[i] = q[i]; q[i] = nil end
    return out
end

-- The control plane's drain. Called once per control-loop iteration; see the
-- comment at its call site for what happened when nothing called it.
function base.drainCtrl() return inboxDrain(_ctrlInbox) end

-- ONE RADIO MESSAGE IS TAKEN ONCE.
--
-- base.run puts the control loop and the job under parallel.waitForAny, and
-- both wait with an unfiltered os.pullEvent -- so parallel hands EVERY
-- modem_message to BOTH of them. Before 1.9.109 each one acted on its copy: a
-- sector order arriving while the job waited in pumpFor was returned to the job
-- AND filed in the job inbox by the control loop. Every miner held a spare copy
-- of its first order and ran one order behind the server for the whole job
-- (21 of 22 jobs, job_0037..job_0059); the server's record of what each miner
-- held was one order ahead of the truth, and two miners were sent into one
-- column (job_0058 failed on it). Control messages were likewise handled twice
-- while a job waited.
--
-- So whichever coroutine sees a message first takes it; the other skips it,
-- and a waiting pumpFor still checks its inbox, because the first may have
-- filed the message there.
--
-- WHY NOT A SINGLE CONSUMER (the job reading only its inbox, never the radio).
-- It needs no key list, but it drops messages: the control loop spends time
-- inside FILTERED yields (sleep, the fuel path, turtle movement), and an event
-- that arrives during a filtered yield is destroyed for that coroutine. Today
-- the job's own wait still sees it and takes it. With a single consumer
-- nothing would. Do not "simplify" this back.
--
-- THE KEY is sender, sequence number and timestamp. Every sender builds a new
-- message for every send, retries included (protocol.lua stamps a fresh seq on
-- each encode), so a genuine resend always has a new key and is delivered. The
-- sequence restarts at zero when a computer boots; the millisecond timestamp
-- keeps a post-restart message from matching a pre-restart one.
--
-- THE LIST is short on purpose. Both coroutines see an event in the same
-- parallel round, before any later event, so the key only has to survive one
-- round. A key that has been forgotten reads as NEW: running out of room can
-- only ever deliver a message twice (today's behaviour), never drop one.
local RECENT_MAX = 16
local _recentKeys, _recentSet = {}, {}
local function firstSight(msg)
    -- AN OLD PARTNER'S ABORT IS NOT TAKEN (sim w3_side_atc on 4d2617c, 2026-11-24). node_56's support
    -- job was cancelled in a radio blackout it never heard; carrying on, it timed out and sent its old
    -- partner node_34 a JOB_ABORT. node_34, on another job with another support, took it and ended that
    -- job at its destination. From a turtle, a JOB_ABORT is its current partner's to send.
    -- About its CURRENT job only (Head Engineer, 2026-11-24): an abort that names a job must name this
    -- one or its pair's; one from a turtle that names none must be its current partner's.
    if msg.type == proto.MSG.JOB_ABORT then
        local about = type(msg.payload) == "table" and msg.payload.jobId or nil
        local fromTurtle = type(msg.from) == "string" and msg.from:find("^node_") ~= nil
        local why
        if about ~= nil and about ~= _self.jobId and about ~= _self.pairJobId then
            why = string.format("about %s, not my job (%s)", tostring(about), tostring(_self.jobId))
        elseif fromTurtle and _self.partnerId and msg.from ~= _self.partnerId then
            why = string.format("not my partner (%s)", tostring(_self.partnerId))
        end
        if why then
            logWarn(string.format("JOB_ABORT from %s %s -- not taken", tostring(msg.from), why))
            return false
        end
    end
    -- What a support's delivery says about itself is noted HERE, the one place
    -- both loops pass every message through: its holding slot (ASCENDING /
    -- RETURN_TO_DOCK) and that it went down without the support (PARTNER_LEFT).
    -- Noted in the job's pump only, a PARTNER_LEFT that arrived while the job
    -- slept between ATC asks was read by the control loop, filed in the job inbox
    -- the booking wait never reads, and the support went down after a delivery
    -- that had gone (sandbox/scenarios/w3_atc_partner_left.lua, 2026-11-12).
    if msg.from ~= nil and msg.from == _self.partnerId then
        -- R4: ANY WORD FROM ITS PARTNER, AND ITS "COME HOME", ARE NOTED HERE, where
        -- every message passes whichever loop reads it. A support paused or mid-move
        -- missed its delivery's PAIR_ALIVE (live-only) and its RETURN_TO_DOCK (sent
        -- once) while the delivery went home without it (sim w3_pair_server_crash).
        _self.partnerHeardAt = os.epoch("utc")
        -- ITS DELIVERY ASKS WHERE IT IS (base.awaitSupportInChunk): answered on sight,
        -- whatever it is doing. Answered only by the follow loop, a support still
        -- coming down the dispatch shaft never answered, and its delivery, standing at
        -- the shaft's foot -- the cell the support had to come down into -- waited for
        -- it for good (sim w3_pair_chunk_lag). The follow loop also walks up behind.
        if msg.type == proto.MSG.SUPPORT_WHERE and _self.role == proto.ROLE.SUPPORT then
            pcall(base.signalPartnerDirect, proto.MSG.SUPPORT_HERE, msg.from,
                { x = _self.pos.x, y = _self.pos.y, z = _self.pos.z })
        end
        if msg.type == proto.MSG.RETURN_TO_DOCK then
            _self.partnerHome = true
            -- R3: tell it this one heard, so it stops repeating it.
            pcall(base.signalPartnerDirect, proto.MSG.HOME_HEARD, msg.from, {})   -- base.: atc is declared further down
        end
        -- R3: its path, to walk up behind it -- from the hold notice or, that lost,
        -- from the come-home (T2 shakeout-side-h, node_219).
        if (msg.type == proto.MSG.ASCENDING or msg.type == proto.MSG.RETURN_TO_DOCK)
           and type(msg.payload) == "table" and type(msg.payload.trail) == "table" then
            _self.partnerTrail = msg.payload.trail
        end
        if (msg.type == proto.MSG.ASCENDING or msg.type == proto.MSG.RETURN_TO_DOCK)
           and type(msg.payload) == "table" and tonumber(msg.payload.slot) then
            _self.partnerSlot = tonumber(msg.payload.slot)
        elseif msg.type == proto.MSG.PARTNER_LEFT then
            _self.partnerLeft = true
        elseif msg.type == proto.MSG.JOB_ABORT and _self.role == proto.ROLE.DELIVERY
               and not (_self.pos.y == CFG.FLOOR_Y and base.isInsideBuilding(_self.pos)) then
            -- OUT IN THE WORLD A DELIVERY DOES NOT NEED ITS SUPPORT (2026-11-14). A
            -- support that missed HOLE_READY in a radio loss gave up and sent this;
            -- its delivery, already at the destination, took it as the end of the
            -- job -- "job_aborted_at_destination", not recoverable -- and the order
            -- failed for good (sim w3_side_atc). It goes on alone, as one that went
            -- down alone does. The warehouse's JOB_ABORT is not its partner's.
            logWarn(string.format("Support %s gave up (%s) while I am out -- carrying on alone",
                tostring(msg.from), tostring(type(msg.payload) == "table" and msg.payload.reason or "?")))
            _self.partnerId = nil
            return false
        end
    end
    -- R3: its support heard "come home" -- even after this delivery's job (and so
    -- its partnerId) is over.
    if msg.type == proto.MSG.HOME_HEARD and _self.callHome and msg.from == _self.callHome.to then
        _self.callHome = nil
    end
    -- A JOB_FAILED the server has: stop repeating it (base.reportFailed).
    if msg.type == proto.MSG.JOB_FAILED_ACK and type(msg.payload) == "table" and msg.payload.failId
       and _self.failsOut then
        _self.failsOut[msg.payload.failId] = nil
    end
    -- ANOTHER TURTLE SHARES MY ID (the server's PARK, duplicate_id): stay where I am until a
    -- person has removed one of us (tryMove waits); both copies hear it on the shared channel.
    if msg.type == proto.MSG.PARK and msg.from == "server" and not _self.parked then
        _self.parked = true
        logWarn("PARKED: " .. tostring(type(msg.payload) == "table" and msg.payload.reason or "the server says another turtle shares my id")
            .. " -- staying where I am")
    end
    if msg.type == proto.MSG.UNPARK and msg.from == "server" and _self.parked then
        _self.parked = false
        logInfo("UNPARKED: my duplicate is seen to -- moving again")
    end
    -- A JOB_COMPLETE the server has: stop repeating it (base.sendComplete).
    if msg.type == proto.MSG.JOB_COMPLETE_ACK and type(msg.payload) == "table" and msg.payload.jobId
       and _self.completesOut then
        _self.completesOut[msg.payload.jobId] = nil
    end
    -- R2: a pair called off by the server, noted whichever loop reads it, so a
    -- delivery waiting on its dock to be let out stops waiting.
    if msg.type == proto.MSG.PAIR_CANCEL and type(msg.payload) == "table" and msg.payload.jobId ~= nil
       and msg.payload.jobId == _self.jobId then
        _self.pairCancelled = true
    end
    -- Live-only types are never queued, so the control loop's copy is simply
    -- dropped and the job's wait must still get its own. Claiming one here
    -- starved mine_flow's beacon wait: the control loop saw every beacon first.
    if TRANSIENT_TYPES[msg.type] then return true end
    local key = tostring(msg.from) .. "|" .. tostring(msg.seq) .. "|" .. tostring(msg.ts)
    if _recentSet[key] then return false end
    _recentSet[key] = true
    _recentKeys[#_recentKeys + 1] = key
    while #_recentKeys > RECENT_MAX do
        _recentSet[table.remove(_recentKeys, 1)] = nil
    end
    return true
end
base._firstSight   = firstSight
base._recentCount  = function() return #_recentKeys end
base._RECENT_MAX   = RECENT_MAX

-- Pull one event, decode it, and route anything that is not what the caller
-- asked for. Returns the matching message, or nil on timeout.
--
-- Every waiter uses this, which is what makes the guarantee hold: whichever
-- coroutine happens to see an event first, the message reaches the queue it
-- belongs to rather than being dropped on the floor by a filter that did not
-- want it.
local function pumpFor(q, wantType, timeout)
    local ready = inboxPop(q, wantType)
    if ready then return ready end

    -- A non-positive timeout means "poll, do not wait". Returning here rather
    -- than arming a zero-length timer keeps a caller that only wants to drain
    -- the queue from yielding at all -- and a yield inside a job handler is
    -- exactly the kind of surprise this module exists to remove.
    if timeout ~= nil and timeout <= 0 then return nil end

    local timer = timeout and os.startTimer(timeout) or nil
    while true do
        local event, p1, p2, p3, p4 = os.pullEvent()
        if event == "modem_message" then
            local parsed = type(p4) == "table" and p4 or textutils.unserialise(p4)
            if parsed then
                local valid, msg = proto.decode(parsed)
                if valid and (msg.to == _self.id or msg.to == "broadcast") then
                    if firstSight(msg) then
                        if wantMatches(msg, wantType)
                           and ((CTRL_TYPES[msg.type] and q == _ctrlInbox)
                                or (not CTRL_TYPES[msg.type] and q == _jobInbox)) then
                            return msg
                        end
                        routeMessage(msg)
                    end
                    -- Also when the other coroutine took it first: it may have
                    -- filed it in the very queue this wait is reading.
                    local ready2 = inboxPop(q, wantType)
                    if ready2 then return ready2 end
                end
            end
        elseif event == "timer" and timer and p1 == timer then
            return nil
        end
    end
end

-- The call Invariant G requires. Job handlers and worker coordination use this
-- instead of proto.receive; control traffic is never returned here.
--
-- It also remembers what the job last asked for, until a message is actually
-- handed over. That is how a reconnecting turtle can tell the server whether it
-- is WAITING for a sector order -- see base.isAwaiting and register().
--
-- Kept across a timeout on purpose. ore_turtle's waitMsg sleeps between calls
-- while the server is unreachable, and that sleep is exactly when the turtle
-- re-registers; "inside base.receive right now" would read false at the one
-- moment the answer matters. Only a delivered message proves the wait is over.
local AWAIT_ANY   = {}      -- sentinel: a receive with no type filter
local _jobAwaiting = nil
function base.receive(timeout, wantType)
    _jobAwaiting = (wantType == nil) and AWAIT_ANY or wantType
    local msg = pumpFor(_jobInbox, wantType, timeout)
    if msg ~= nil then _jobAwaiting = nil end
    return msg
end

-- True if the job's last unanswered receive would accept a message of type t.
function base.isAwaiting(t)
    local w = _jobAwaiting
    if w == nil then return false end
    if w == AWAIT_ANY then return true end
    if type(w) == "table" then return w[t] == true end
    return w == t
end

-- Control-plane equivalent, for register() waiting on its own ACK.
function base.receiveCtrl(timeout, wantType)
    return pumpFor(_ctrlInbox, wantType, timeout)
end

-- Test seam: inbox depths, so a test can assert nothing was silently dropped.
function base.inboxSizes() return #_ctrlInbox, #_jobInbox end


-- Consecutive comms.toServer failures; reset by any successful send or by a
-- successful modem recovery.
local _sendFailures = 0
local SEND_FAILURES_BEFORE_RECOVER = 3

function comms.init()
    _self.modem = peripheral.find("modem")
    if not _self.modem then
        -- A miner rebooted inside the retrieval swap window has its modem in
        -- inventory, not equipped. Recover it rather than erroring out, which
        -- would strand the turtle in the field until a player intervened.
        local ok, equipment = pcall(require, "equipment")
        if ok and equipment then
            logWarn("No modem equipped — attempting equipment reconciliation")
            local healed, reason = equipment.reconcile()
            if healed then
                _self.modem = peripheral.find("modem")
                logInfo("Modem recovered from inventory.")
            else
                logError("Equipment reconciliation failed: " .. tostring(reason))
            end
        end
    end
    if not _self.modem then
        error("No modem found. Attach a wireless or ender modem.")
    end
    proto.openChannels(_self.modem, CHANNELS)
    if OWN_CHANNEL then
        logInfo("Modem ready. Private channel " .. OWN_CHANNEL
            .. " open; the shared channel is not (step 3).")
    else
        -- Loud on purpose: this turtle will never move off the shared channel.
        logWarn("Modem ready, but NO private channel -- computer id gives "
            .. "a channel outside 0-" .. proto.CH_MAX
            .. ". Staying on the shared channel.")
    end
end

-- Re-acquire the modem after an equipment swap moved it, and re-open the
-- channels on it.
--
-- This is not optional bookkeeping. equipment.retrievalSwapIn puts chunky on
-- the MODEM's side, and retrievalSwapOut puts the modem back on the side
-- OPPOSITE chunky -- i.e. the side the pickaxe was on. So the modem changes
-- side on every loader retrieval. _self.modem is a wrapper bound to a side
-- name, set once in comms.init, and the channel list was opened on that
-- instance: without this the miner would go permanently deaf and mute after
-- its first retrieval (no HEARTBEAT_ACK -> serverDown, no SECTOR_ASSIGN, no
-- RECALL, no LOADER_BEACON -> the next placeLoader fails closed on
-- loader_no_beacon).
--
-- Unconditional by design. Re-finding the modem and re-opening channels that
-- may already be open is a no-op, so this is correct whether or not a
-- re-equipped modem counts as a new peripheral instance with its channels
-- closed -- a distinction that cannot be verified outside a running world.
function base.recoverModem()
    local m = peripheral.find("modem")
    if not m then
        logWarn("recoverModem: no modem equipped")
        return false
    end
    _self.modem = m
    local ok, err = pcall(proto.openChannels, m, CHANNELS)
    if not ok then
        logWarn("recoverModem: could not open channels: " .. tostring(err))
        return false
    end
    _sendFailures = 0
    return true
end

local _lastSendWarn = 0
function comms.toServer(msgType, payload)
    local msg = proto.encode(msgType, _self.id, "server", payload)
    -- A solo miner deliberately unequips its modem during the loader-retrieval
    -- swap (equipment.retrievalSwapIn: chunk loading outranks comms). That
    -- DETACHES this wrapped peripheral, and calling a detached peripheral's
    -- method RAISES rather than returning false. Unprotected, that error came
    -- out of sendHeartbeat inside controlLoop and killed the whole
    -- parallel.waitForAny runner -- i.e. the running job -- every single time a
    -- miner retrieved its loader. A send that cannot go out is not fatal for
    -- any role: the message is simply lost, exactly as if the server were not
    -- listening. Throttled warn so a genuinely broken modem is still visible
    -- without a line every heartbeat during an expected gap.
    --
    -- Returns true if the message went out and false if it could not. Callers
    -- used to have no way to know, and two of them needed to: the log outbox,
    -- which threw away every batch it flushed during a modem swap, and the stall
    -- witness, which judged "no radio" from the modem HANDLE -- and the handle
    -- is never cleared by a swap, so it said "radio on" for a turtle with none.
    -- The result of the send is the only thing that actually knows.
    local ok, err = pcall(proto.send, _self.modem, proto.CH_SERVER, msg)
    if ok then
        _sendFailures = 0
        return true
    end
    _sendFailures = _sendFailures + 1
    local now = os.epoch("utc")
    if now - _lastSendWarn > 30000 then
        _lastSendWarn = now
        logWarn("Send failed (modem detached or missing?): " .. tostring(err))
    end
    -- Escalate rather than warning forever: repeated failures mean the wrapper
    -- is stale (a swap moved the modem to the other side) far more often than
    -- they mean the radio is broken, and warning is not a fix. Cheap and
    -- idempotent, so trying it costs nothing when the modem really is gone.
    if _sendFailures >= SEND_FAILURES_BEFORE_RECOVER then
        _sendFailures = 0
        pcall(base.recoverModem)
    end
    return false
end

-- The transport, attached now that comms.toServer exists.
--
-- ready() is what makes a flush issued before the modem is recovered a complete
-- no-op rather than a batch handed to a nil peripheral: the lines stay queued
-- and go out on the flush after recovery, which is the behaviour a turtle that
-- deliberately unequips its modem mid-job depends on.
_log:setTransport({
    -- Two ways to know the radio is off, because there are two ways for it to be.
    --
    -- A DECLARED gap -- ore_turtle sets commsGap before retrievalSwapIn -- is
    -- known in advance, so the outbox does not even try: the lines stay queued
    -- and leave on the flush after the modem comes back.
    --
    -- An UNDECLARED one is only discovered by trying. `_self.modem ~= nil` cannot
    -- see it: a swap leaves the handle in place, detached, and the jobs 0039-0042
    -- audit found 190 lines lost exactly that way -- ready() said yes, the batch
    -- came off the queue, the transmit raised, and it was gone. So send returns
    -- comms.toServer's result, and a false puts the batch back.
    ready = function() return _self.modem ~= nil and not _self.commsGap end,
    send  = function(lines, bootId)
        return comms.toServer(proto.MSG.TURTLE_LOG, { lines = lines, bootId = bootId })
    end,
})

local function flushLogQueue() return _log:flush() end

-- Public, for two reasons beyond testing.
--
-- A role's crash handler prints the fatal error and then reboots, and the
-- control loop that would have flushed it is already dead -- so the single most
-- valuable line a turtle ever writes is the one least likely to reach the log.
-- A crash path can now call this before it reboots.
function base.flushLogs() return flushLogQueue() end

-- Test seam. The production setter is inside sendHeartbeat, where the stall
-- is actually detected; this exists so the retry can be driven without
-- standing up a heartbeat, a registration and two 15-second boundaries.
function base.markLogSuspect() _log:markSuspect() end

-- Test seam. The production reader is the control loop's flush trigger,
-- which cannot be reached without standing up the whole loop.
function base.logUrgent() return _log:urgent() end

-- Throttled position push: sends current position as STATUS_UPDATE at most once
-- per 2 seconds. Intended for support turtles which move constantly but never
-- call sendProgress(). Without this the server only learns position via heartbeats
-- (every 5s), leaving the map up to 15+ blocks behind.
local _lastPositionPush = 0
function base.pushPosition()
    local now = os.epoch("utc")
    if now - _lastPositionPush < 2000 then return end
    _lastPositionPush = now
    comms.toServer(proto.MSG.STATUS_UPDATE, proto.payloadStatusUpdate(
        _self.jobId, _self.status, nil, base.getPos()))
end

-- ─── Position ────────────────────────────────────────────────────────────────

-- ─── Journal (GPS 3, release A) ─────────────────────────────────────────────
-- Every physical move and turn goes through jMove / jTurn, which write the
-- intent to journal.dat first; applyMove and move.turn* write the settled state
-- after. At boot the journal is CHECKED against GPS and the measured facing; it
-- changes nothing the turtle does. "No move without GPS" is unchanged and the
-- facing is still measured on every boot.
--
-- Why only a check (sandbox, 2026-10-22, w3_gps3_journal_restore): the first
-- design took the facing from the journal and skipped the measurement. A miner
-- picked up and put back in the same block, turned, agreed on position, took the
-- journal's (wrong) facing, turned to "face" its loader, missed it and left it
-- behind -- before any step could check it. A check on the first step needs GPS,
-- and a flying miner has its modem swapped for the chunk loader: it parked at
-- y=200 with no modem. A journal cannot tell a crash from a hand put-back, so it
-- must never be trusted for facing without a measurement.
--
-- What the check gives: on every boot with GPS, whether the journal's position
-- (settled by fuel) and facing agree with the measured ones -- the evidence
-- release B (moving on a journal without GPS) needs, and the user's call.
--
-- The write is atomic: journal.tmp, then delete journal.dat and move the temp
-- file onto it. A crash during the temp write leaves .dat exact (the move had
-- not started); a crash between the delete and the move leaves a complete
-- temp file. Anything unreadable is no journal. A journal fault never stops a
-- move.
--
-- A source-pin test (tests/test_gps3_journal.lua) fails on any raw
-- turtle.forward/back/up/down/turnLeft/turnRight outside these two wrappers, in
-- every file the updater ships.
local JOURNAL_FILE, JOURNAL_TMP = "journal.dat", "journal.tmp"
local JOURNAL_MOVES = { forward = true, back = true, up = true, down = true }
local JOURNAL_TURNS = { turnLeft = true, turnRight = true }
local FACING_NAMES  = { [0] = "north", [1] = "east", [2] = "south", [3] = "west" }
local _journalFaulted = false

local function writeJournal(pending)
    local ok, err = pcall(function()
        local rec = textutils.serialise({
            v = 1, x = _self.pos.x, y = _self.pos.y, z = _self.pos.z,
            facing = _self.facing, facingKnown = _self.facingKnown == true,
            posFixed = _self.posFixed == true, fuel = turtle.getFuelLevel(),
            pending = pending, t = os.epoch("utc"),
        })
        local h = fs.open(JOURNAL_TMP, "w")
        if not h then error("cannot open " .. JOURNAL_TMP, 0) end
        h.write(rec)
        h.close()
        if fs.exists(JOURNAL_FILE) then fs.delete(JOURNAL_FILE) end
        fs.move(JOURNAL_TMP, JOURNAL_FILE)
    end)
    if not ok and not _journalFaulted then
        _journalFaulted = true
        logWarn("Journal write failed -- moves go on; the boot check will have nothing to check: "
            .. tostring(err))
    end
end

local function readJournalFile(path)
    local h = fs.open(path, "r")
    if not h then return nil end
    local s = h.readAll()
    h.close()
    local ok, rec = pcall(textutils.unserialise, s)
    if not ok or type(rec) ~= "table" then return nil end
    for _, k in ipairs({ "x", "y", "z", "facing" }) do
        if type(rec[k]) ~= "number" then return nil end
    end
    if rec.pending ~= nil and not (JOURNAL_MOVES[rec.pending] or JOURNAL_TURNS[rec.pending]) then
        return nil
    end
    return rec
end

local function readJournal()
    local ok, rec = pcall(function()
        if fs.exists(JOURNAL_FILE) then return readJournalFile(JOURNAL_FILE) end
        if fs.exists(JOURNAL_TMP)  then return readJournalFile(JOURNAL_TMP)  end
        return nil
    end)
    return ok and rec or nil
end

-- The only raw move. Intent first, so a crash mid-move leaves it on disk; a
-- move that fails settles at once. A successful one is settled by applyMove.
local function jMove(dir)
    -- (D): inside the zone near the base, a turtle holding a path never steps into a
    -- cell it has not booked (base.atc.pathAllow asks the ATC for a detour cell first).
    local a = base.atc
    if a and a.path and a.pathAllow and not a.pathAllow(dir) then return false, "detour refused by the ATC" end
    writeJournal(dir)
    local ok, err = turtle[dir]()
    if not ok then writeJournal(nil) end
    return ok, err
end

-- The only raw turn. Settled by move.turnLeft/turnRight; the turns made while
-- measuring facing are never settled, which is right -- the facing is unknown.
-- The turns detectFacing makes while it looks for a free side (detectFacing
-- and digOutForFacing turn right only): counted so the boot check compares the
-- journal with the facing the turtle had BEFORE them. Not counted, rock ahead
-- underground read as a journal fault -- 3 of 5 dumping miners at the 11-03
-- restart, 90 and 180 degrees, nobody had touched them.
local _measureTurns = nil
local function jTurn(dir)
    writeJournal(dir)
    if _measureTurns and dir == "turnRight" then _measureTurns = _measureTurns + 1 end
    return turtle[dir]()
end

-- One step's change in position, for a facing.
local function stepDelta(facing, dir)
    if dir == "up" then return 0, 1, 0 end
    if dir == "down" then return 0, -1, 0 end
    local dx, dz = 0, 0
    if     facing == 0 then dz = -1
    elseif facing == 1 then dx = 1
    elseif facing == 2 then dz = 1
    else                    dx = -1 end
    if dir == "back" then dx, dz = -dx, -dz end
    return dx, 0, dz
end

-- What the journal claims, read at boot BEFORE anything moves or burns fuel:
-- { x, y, z, facing } (facing nil when it cannot be known), or nil and why not.
-- A pending move is settled by fuel: every move costs exactly 1, so one lower
-- means it happened; equal or higher (a refuel only happens standing still)
-- means it did not. A pending turn leaves the position and loses the facing.
local function journalClaim()
    local j = readJournal()
    if not j then return nil, "no readable journal" end
    if not j.posFixed then return nil, "it was written without a GPS fix" end
    local facing = j.facingKnown and j.facing or nil
    if j.pending == nil then return { x = j.x, y = j.y, z = j.z, facing = facing } end
    if JOURNAL_TURNS[j.pending] then return { x = j.x, y = j.y, z = j.z, facing = nil } end
    local now = turtle.getFuelLevel()
    if type(now) ~= "number" or type(j.fuel) ~= "number" then
        return nil, "fuel cannot settle the last move"
    end
    if now >= j.fuel then return { x = j.x, y = j.y, z = j.z, facing = facing } end
    if now == j.fuel - 1 and facing then
        local dx, dy, dz = stepDelta(j.facing, j.pending)
        return { x = j.x + dx, y = j.y + dy, z = j.z + dz, facing = facing }
    end
    return nil, string.format("fuel is %s after a move journaled at %s", tostring(now), tostring(j.fuel))
end

-- After the boot fix and facing measurement: one line saying whether the
-- journal agreed. The loud lines are the VALIDATION signal (rulings 2026-10-22):
-- a position more than 1 block off, or a facing that differs from the measured.
local function checkJournal(claim, why)
    if not claim then
        logInfo("Journal: nothing to check (" .. tostring(why) .. ")")
        return
    end
    local p = _self.pos
    local off = math.abs(claim.x - p.x) + math.abs(claim.y - p.y) + math.abs(claim.z - p.z)
    local where = string.format("journal %d,%d,%d, GPS %d,%d,%d", claim.x, claim.y, claim.z, p.x, p.y, p.z)
    -- Against the facing it booted with, not the one after detectFacing's turns.
    local booted = _self.bootFacing or _self.facing
    local facingOk = claim.facing == nil or not _self.facingKnown or claim.facing == booted
    if off == 1 then
        logWarn("Journal: 1 block from GPS (" .. where .. ")")
    elseif off > 1 then
        logWarn(string.format("JOURNAL DISAGREES WITH GPS by %d (%s)", off, where))
    end
    if not facingOk then
        logWarn(string.format("JOURNAL FACING DIFFERS: journal %s, measured %s at %d,%d,%d (put back turned by hand, or a journal fault)",
            FACING_NAMES[claim.facing] or tostring(claim.facing), FACING_NAMES[booted] or tostring(booted),
            p.x, p.y, p.z))
    end
    if off == 0 and facingOk then
        logInfo(string.format("Journal: agrees with GPS at %d,%d,%d, facing %s", p.x, p.y, p.z,
            claim.facing and _self.facingKnown and FACING_NAMES[claim.facing]
                or (claim.facing and "not measured" or "not journaled (mid-turn)")))
    end
end

local function gpsSync()
    local x, y, z = gps.locate(CFG.GPS_TIMEOUT)
    if x then
        x, y, z = math.floor(x), math.floor(y), math.floor(z)
        -- A FIX FAR FROM WHERE IT STANDS WAITS FOR A SECOND (T2 shakeout-payload-h; Head
        -- Engineer ruling 2026-11-24). node_235, standing still, took a belief 71 blocks off
        -- in one resync -- 23 of them in y -- and drove on it into the holding line's
        -- approach: 10 give-ups behind it. More than a block from a measured belief, the fix
        -- is taken only once a second agrees with it; both are logged. (gps.locate does not
        -- say how many hosts answered.)
        local p = _self.pos
        if _self.posFixed and p and math.abs(x - p.x) + math.abs(y - p.y) + math.abs(z - p.z) > 1 then
            local x2, y2, z2 = gps.locate(CFG.GPS_TIMEOUT)
            if x2 then x2, y2, z2 = math.floor(x2), math.floor(y2), math.floor(z2) end
            if not x2 or math.abs(x2 - x) + math.abs(y2 - y) + math.abs(z2 - z) > 1 then
                logWarn(string.format("GPS jump not taken: believed %d,%d,%d, a fix said %d,%d,%d, a second said %s",
                    p.x, p.y, p.z, x, y, z, x2 and string.format("%d,%d,%d", x2, y2, z2) or "nothing"))
                return false
            end
            logWarn(string.format("GPS jump taken: believed %d,%d,%d, two fixes said %d,%d,%d and %d,%d,%d",
                p.x, p.y, p.z, x, y, z, x2, y2, z2))
        end
        _self.pos = { x=x, y=y, z=z }
        _self.posFixed = true
        return true
    else
        logWarn("GPS locate failed — continuing with dead-reckoned position")
        return false
    end
end

-- Public GPS resync — corrects position drift before precision bay navigation.
function base.gpsSync()
    local ok = gpsSync()
    if ok then
        logInfo(string.format("GPS resync: %d,%d,%d", _self.pos.x, _self.pos.y, _self.pos.z))
    else
        logWarn("GPS resync failed — continuing with dead-reckoned position")
    end
    return ok
end

-- Detect actual facing by moving forward one block and comparing GPS positions.
-- Without this, position tracking is wrong from the very first move.
-- Returns true only when the facing was actually measured (_self.facingKnown).
-- 2026-10-06: node_182 rebooted mid-air, logged "GPS lost during facing
-- detection. Assuming north.", and every move after that went the wrong way --
-- it flew ~1,000 blocks off before it was stopped. A guessed facing is now
-- recorded as unknown, and base.waitForPositionFix will not let a turtle move
-- on it. Also false when all four sides are blocked: no step, no measurement,
-- where the old code logged the assumed facing as if it had been found.
local function detectFacing()
    local x1, y1, z1 = gps.locate(CFG.GPS_TIMEOUT)
    if not x1 then
        logWarn("Cannot detect facing — no GPS. Facing UNKNOWN; not moving on a guess.")
        _self.facingKnown = false
        return false
    end

    -- While it turns about to measure, the facing IS unknown -- and the journal
    -- must say so if the power goes mid-way (GPS 3).
    _self.facingKnown = false

    -- In the base the measuring step is a step into a section like any other,
    -- and which one is not known (that is what is being measured): every
    -- neighbouring section is asked for first, and given back afterwards.
    _self.facingWhy = nil
    local claimed = base.atc.claimAround and base.atc.claimAround(x1, y1, z1)
    if claimed == false then
        _self.facingWhy = "atc"           -- held by the ATC, not boxed in (base.waitForPositionFix)
        -- From a dock this is waiting in a safe place, as for a booking: not a
        -- stall. Only a turtle refused while standing IN a section counts.
        if base.atc.here() then base.atc.stalled("cannot measure facing: the ATC has not let it step") end
        logWarn("Cannot detect facing yet -- the ATC has not granted the sections around it. Facing UNKNOWN.")
        return false
    end

    -- Try to move forward one step to detect direction
    _measureTurns = 0
    local moved = jMove("forward")
    if not moved then
        -- Blocked — try turning until we find a free direction
        for _ = 1, 4 do
            jTurn("turnRight")
            if jMove("forward") then moved = true; break end
        end
    end
    if not moved and not claimed then
        -- Defined after digGuarded, so reached through base at call time.
        -- Never in the base: what boxes a turtle in there is other turtles.
        moved = base.digOutForFacing(x1, y1, z1)
    end
    if not moved then
        _measureTurns = nil
        if claimed then base.atc.releaseAround(claimed) end
        base.atc.stalled("boxed in on all four sides")
        logWarn("Cannot detect facing — boxed in on all four sides. Facing UNKNOWN.")
        _self.facingKnown = false
        return false
    end

    local x2, y2, z2 = gps.locate(CFG.GPS_TIMEOUT)
    local turnsMade = _measureTurns or 0
    _measureTurns = nil
    local backOk = jMove("back")  -- return to original position
    if claimed then base.atc.releaseAround(claimed) end
    -- IT MEASURED WHERE IT STANDS: IT KEEPS THAT (2026-11-16, sim w3_depart_off_dock).
    -- The step and the step back were counted from the facing it believed, which
    -- is what this is measuring, so the position they leave is only as good as
    -- that guess: a support back in the building by the way it came believed it
    -- stood one block from where GPS had just put it, drove home one cell off and
    -- stood blocked at the next turtle's dock until STUCK. Back where it started
    -- it is at the first fix; if the step back failed, at the second.
    if backOk and x1 then
        _self.pos = { x = math.floor(x1), y = math.floor(y1), z = math.floor(z1) }
    elseif x2 then
        _self.pos = { x = math.floor(x2), y = math.floor(y2), z = math.floor(z2) }
    end

    if not x2 then
        logWarn("GPS lost during facing detection. Facing UNKNOWN; not moving on a guess.")
        _self.facingKnown = false
        return false
    end

    local dx = math.floor(x2) - math.floor(x1)
    local dz = math.floor(z2) - math.floor(z1)

    if     dz < 0 then _self.facing = 0  -- north (-Z)
    elseif dx > 0 then _self.facing = 1  -- east  (+X)
    elseif dz > 0 then _self.facing = 2  -- south (+Z)
    elseif dx < 0 then _self.facing = 3  -- west  (-X)
    else
        _self.facingKnown = false
        return false
    end

    local names = { [0]="north", [1]="east", [2]="south", [3]="west" }
    logInfo("Facing: " .. names[_self.facing])
    -- The facing it booted with: before the measuring turns (checkJournal).
    _self.bootFacing = (_self.facing - turnsMade) % 4
    _self.facingKnown = true
    writeJournal(nil)
    return true
end

local function initPosition()
    local claim, why = journalClaim()    -- before detectFacing moves or burns fuel
    if gpsSync() then
        logInfo(string.format("GPS fix: %d,%d,%d", _self.pos.x, _self.pos.y, _self.pos.z))
        detectFacing()
        checkJournal(claim, why)
        base.restoreTrail()      -- defined with the trail, below
    else
        logWarn("No GPS fix. Tracking from (0,0,0). Facing assumed north.")
    end
end

-- NEVER FLY ON A GUESSED POSITION. 2026-10-05: the world restarted at 02:29 with
-- the GPS hosts not yet up; every turtle booted with "No GPS fix. Tracking from
-- (0,0,0)", and the four miners mid-job ran boot recovery from that guess --
-- flying toward loaders 1,700 and 2,800 blocks off in the wrong place. None came
-- back; all four were lost. A position is trustworthy only once GPS has given it
-- (posFixed, set by gpsSync). Anything that is about to travel on its own after
-- a reboot calls this first: it retries GPS until a fix arrives, standing still,
-- then re-detects facing -- a late fix without it still points every move
-- the wrong way.
function base.detectFacingForTest() return detectFacing() end
function base.setFacingUnknownForTest() _self.facingKnown = false end   -- test seam
function base.setPosForTest(p) _self.pos = { x = p.x, y = p.y, z = p.z } end     -- test seam
function base.setRunningForTest(v) _self.running = v and true or nil end                  -- test seam
function base.setIdForTest(id) _self.id = id end                                   -- test seam
function base.setServerDownForTest(v) _self.serverDown = v and true or false end    -- test seam
function base.initPositionForTest() return initPosition() end

-- Position AND facing: either one wrong sends every move astray (2026-10-05,
-- position; 2026-10-06, facing).
function base.setBootGuardForTest(on) _self.bootGuard = on end
function base.setRoleForTest(r) _self.role = r end
function base.setDockForTest(d) _self.dock = d end
function base.setHomingForTest(on) _self.homing = on end

function base.hasPositionFix() return _self.posFixed == true and _self.facingKnown == true end

-- positionOnly: a caller that never moves sideways (recovering an item placed
-- up or down) needs a measured position but no facing (review #5, release 2).
function base.waitForPositionFix(why, positionOnly)
    if _self.posFixed and (positionOnly or _self.facingKnown) then return true end
    logWarn(string.format("No GPS fix or facing -- NOT moving until both are measured (%s)",
        tostring(why)))
    local tries = 0
    while not ((_self.posFixed or gpsSync()) and (positionOnly or _self.facingKnown or detectFacing())) do
        tries = tries + 1
        -- A STUCK TURTLE SAYS SO (2026-10-08). node_184 and node_182 registered
        -- at 12:07:56 and were never heard from again: this wait runs before
        -- base.run starts heartbeats and the log outbox, so the server pruned
        -- them as offline and only a screenshot showed why. Once a minute (the
        -- first try, then every sixth) it reports where it is and ships its log
        -- lines; the server raises NEEDS HANDS on the report.
        -- HELD BY THE ATC IS NOT STUCK (T2 shakeout-payload-g, 01:44: 9 docked turtles
        -- raised NEEDS HANDS on the first refusal after a restart, granted 3-4 s later;
        -- Head Engineer, 2026-11-24). A player's hands do not help a turtle the ATC holds.
        -- A refusal still standing a minute on says so with its own code, atc_wait.
        if tries % 6 == 1 and _self.posFixed and _self.facingWhy == "atc" then
            if tries > 1 then
                local line = string.format("atc_wait: facing unknown at %d,%d,%d (waiting for the ATC to grant the cells around it: %s)",
                    _self.pos.x, _self.pos.y, _self.pos.z, tostring(base.atc.lastRefusal))
                logWarn(line)
                pcall(base.sendProgress, line)
                pcall(flushLogQueue)
                _self.saidAtcWait = true
            end
        elseif tries % 6 == 1 then
            local where = _self.posFixed
                and string.format("facing unknown at %d,%d,%d", _self.pos.x, _self.pos.y, _self.pos.z)
                or "no GPS fix, position unknown"
            pcall(base.sendProgress, string.format("stuck_no_fix: %s (%s)", where, tostring(why)))
            pcall(flushLogQueue)
            _self.saidStuckNoFix = true    -- the server now holds it until it reports docked
        end
        -- Standing in the base, it tells the ATC so (atc.keepAlive): silent 180 s
        -- it is taken for dead and its section given away under it.
        if base.atc then pcall(base.atc.keepAlive) end
        sleep(10)
    end
    logInfo(string.format("Position and facing measured after %d retries: %d,%d,%d -- %s can go ahead",
        tries, _self.pos.x, _self.pos.y, _self.pos.z, tostring(why)))
    -- IT SAID IT WAS STUCK, SO IT SAYS IT MEASURED. Only "docked" cleared the
    -- server's flag, and a turtle that measured and went straight to work never
    -- said that: node_227 kept NEEDS HANDS 75 minutes (T2 shakeout-side-a).
    -- saidStuckNoFix stays set: a turtle that is on its dock still says "docked",
    -- which also ends the server's recovery hold.
    if tries > 0 and (_self.saidStuckNoFix or _self.saidAtcWait) then
        pcall(base.sendProgress, string.format("measured: %d,%d,%d -- %s",
            _self.pos.x, _self.pos.y, _self.pos.z, tostring(why)))
    end
    return true
end

-- ─── The way it came ─────────────────────────────────────────────────────────
-- Every cell it has stood in since it last left the building's floor, a simple
-- path (a step back onto an earlier cell cuts the loop off). For a turtle that
-- cannot dig, it is the one way home it knows is open: a support follows its
-- delivery's tunnel out, and the holding line's columns home were dug only if
-- its delivery went home the same way. Alone -- its delivery's job failed, or
-- a lost answer told it its delivery was offline -- 6 of 8 supports met rock
-- (sim w3_side_atc) and node_141 did on the real game (T2 w3-depart-off-dock-b,
-- 2026-11-14). home.retrace walks it back. In memory only: a reboot forgets it.
local trail = { MAX = 20000, cells = {}, at = {} }
local function trailKey(p) return p.x .. "," .. p.y .. "," .. p.z end
function trail.note(prev)
    local p = _self.pos
    -- An empty trail starts where the turtle stood before this step: the floor
    -- cell it left, normally, or where it booted.
    if #trail.cells == 0 and prev then
        trail.cells[1] = { x = prev.x, y = prev.y, z = prev.z }
        trail.at[trailKey(prev)] = 1
    end
    if p.y == CFG.FLOOR_Y and base.isInsideBuilding(p) then
        trail.cells = { { x = p.x, y = p.y, z = p.z } }
        trail.at = { [trailKey(p)] = 1 }
        trail.forget()
        return
    end
    local k = trailKey(p)
    local i = trail.at[k]
    if i then
        for j = #trail.cells, i + 1, -1 do
            trail.at[trailKey(trail.cells[j])] = nil
            trail.cells[j] = nil
        end
        trail.save()
        return
    end
    if #trail.cells >= trail.MAX then return end
    trail.cells[#trail.cells + 1] = { x = p.x, y = p.y, z = p.z }
    trail.at[k] = #trail.cells
    -- Written at a corner only: a straight step goes the way the last one went,
    -- and trail.restore walks that line on to where the turtle stands.
    local n, c = #trail.cells, trail.cells
    if n == 2 or (n > 2 and (c[n].x - c[n-1].x ~= c[n-1].x - c[n-2].x or c[n].y - c[n-1].y ~= c[n-1].y - c[n-2].y
            or c[n].z - c[n-1].z ~= c[n-1].z - c[n-2].z)) then
        trail.save()
    end
end

-- KEPT ON DISK BY A TURTLE THAT CANNOT DIG (T2 shakeout-payload-e, 2026-11-23).
-- node_239 and node_235, rebooted out in the tunnel by the restart burst, were
-- given holding slots behind rock, logged "no way back is known (trail empty)"
-- and stood in the lane to the end of the run; 10 supports following their
-- deliveries out bumped into them for 120 s and gave up. Its corners only --
-- the cells between are a straight line -- so a support's way out is a few
-- hundred bytes, written a few times a trip. A turtle that can dig needs none.
trail.FILE, trail.MAX_CORNERS = "trail.dat", 2000
function trail.forget()
    if not trail.onDisk then return end
    trail.onDisk = false
    pcall(fs.delete, trail.FILE)
end
function trail.save()
    if _self.canDig then return end
    local cells, out = trail.cells, {}
    for i, c in ipairs(cells) do
        local a, b = cells[i - 1], cells[i + 1]
        if not a or not b or c.x - a.x ~= b.x - c.x or c.y - a.y ~= b.y - c.y or c.z - a.z ~= b.z - c.z then
            out[#out + 1] = c.x .. "," .. c.y .. "," .. c.z
        end
    end
    if #out > trail.MAX_CORNERS then trail.onDisk = true; trail.forget(); return end
    local ok = pcall(function()
        local tmp = trail.FILE .. ".tmp"
        local h = fs.open(tmp, "w")
        h.write(table.concat(out, ";"))
        h.close()
        if fs.exists(trail.FILE) then fs.delete(trail.FILE) end
        fs.move(tmp, trail.FILE)
    end)
    trail.onDisk = ok or trail.onDisk
end
-- At boot, once GPS has put it somewhere: the way it came, if what is on disk
-- leads to where it stands -- along its last line (the steps no corner wrote),
-- or one step off it (a corner the power cut before it wrote). Anything else
-- (carried off by hand, a broken file) is no way back at all.
function trail.restore()
    if not fs.exists(trail.FILE) then return end
    trail.onDisk = true
    local p = _self.pos
    local cells = {}
    local ok = pcall(function()
        local h = fs.open(trail.FILE, "r")
        local s = h.readAll()
        h.close()
        for x, y, z in s:gmatch("(-?%d+),(-?%d+),(-?%d+)") do
            local c = { x = tonumber(x), y = tonumber(y), z = tonumber(z) }
            local a = cells[#cells]
            if a then
                local d = math.abs(c.x - a.x) + math.abs(c.y - a.y) + math.abs(c.z - a.z)
                local sx, sy, sz = math.floor((c.x - a.x) / d), math.floor((c.y - a.y) / d), math.floor((c.z - a.z) / d)
                if math.abs(sx) + math.abs(sy) + math.abs(sz) ~= 1 then error("not a straight line", 0) end
                for k = 1, d do cells[#cells + 1] = { x = a.x + sx * k, y = a.y + sy * k, z = a.z + sz * k } end
            else
                cells[1] = c
            end
        end
    end)
    local n = #cells
    if not ok or n == 0 or (p.y == CFG.FLOOR_Y and base.isInsideBuilding(p)) then trail.forget(); return end
    local at
    for i = n, 1, -1 do
        if cells[i].x == p.x and cells[i].y == p.y and cells[i].z == p.z then at = i; break end
    end
    if at then
        for j = n, at + 1, -1 do cells[j] = nil end
    else
        local l, m = cells[n], cells[n - 1]
        local dx, dy, dz = p.x - l.x, p.y - l.y, p.z - l.z
        local d = math.abs(dx) + math.abs(dy) + math.abs(dz)
        local onLine = m and d > 0 and dx == (l.x - m.x) * d and dy == (l.y - m.y) * d and dz == (l.z - m.z) * d
        if onLine then
            for k = 1, d do cells[#cells + 1] = { x = l.x + (l.x - m.x) * k, y = l.y + (l.y - m.y) * k, z = l.z + (l.z - m.z) * k } end
        elseif d == 1 then
            cells[#cells + 1] = { x = p.x, y = p.y, z = p.z }
        else
            logWarn(string.format("The way I came, kept from before the reboot, does not lead to %d,%d,%d -- not trusted",
                p.x, p.y, p.z))
            trail.forget()
            return
        end
    end
    trail.cells, trail.at = cells, {}
    for i, c in ipairs(cells) do trail.at[trailKey(c)] = i end
    logInfo(string.format("The way I came: %d cell(s), kept from before the reboot", #cells))
end
base.restoreTrail = trail.restore
function base.trailForTest() return trail.cells end

-- R3, THE RETURN AS A PAIR (docs/superpowers/specs/2026-11-17-delivery-pair-and-
-- hole-design.md). A support that lagged behind its delivery was told to hold
-- where it stood; told then to come home, it planned its own way to the holding
-- slot -- through rock it cannot dig ("way home is shut", then a retrace): 9 times
-- a side-test run, and under R2 they met in one tunnel and stayed. Its delivery's
-- own cells are dug. So at the holding line the delivery sends the last
-- base.TRAIL_TAIL_N cells of its path, and its support walks them up to the cell
-- behind it -- every step onto a cell its delivery stood in.
base.TRAIL_TAIL_N = 60
function base.trailTail(n)
    local out = {}
    for i = math.max(1, #trail.cells - n + 1), #trail.cells do
        local c = trail.cells[i]
        out[#out + 1] = { x = c.x, y = c.y, z = c.z }
    end
    return out
end
function base.walkPartnerTrail(quiet)
    local t = _self.partnerTrail
    _self.partnerTrail = nil
    if type(t) ~= "table" or #t < 2 then return 0 end
    local p, at = _self.pos, nil
    for i = #t - 1, 1, -1 do
        local c = t[i]
        if c.x == p.x and c.y == p.y and c.z == p.z then at = i; break end
    end
    if not at then
        for i = #t - 1, 1, -1 do      -- or the cell beside it, one step onto the path
            local c = t[i]
            if math.abs(c.x - p.x) + math.abs(c.y - p.y) + math.abs(c.z - p.z) == 1 then
                if not base.move.to(c.x, c.y, c.z) then return 0 end
                at = i; break
            end
        end
    end
    if not at then return 0 end
    local walked = 0
    for k = at + 1, #t - 1 do        -- up to the cell behind its delivery, never into it
        local c = t[k]
        if not base.move.to(c.x, c.y, c.z) then break end
        walked = walked + 1
    end
    if walked > 0 and not quiet then
        logInfo(string.format("Walked %d cell(s) of my delivery's path, to the cell behind it at %d,%d,%d",
            walked, _self.pos.x, _self.pos.y, _self.pos.z))
    end
    return walked
end

-- FOLLOWING, IT STEPS ONTO ITS DELIVERY'S OWN CELLS (T2 shakeout-payload-e,
-- 2026-11-23). node_217 went up and over node_235, parked in the tunnel at
-- 196,60,-2794; its support node_237 missed the steps between -- it was still
-- moving when they came -- and planned a straight line to where its delivery
-- had got to, into node_235: 120 s blocked, and it gave up. Every step its
-- delivery sends carries the last FOLLOW_TAIL_N cells it stood in; the support
-- walks them to the cell behind it, and only with none to walk goes straight
-- for where its delivery was, as before.
-- As corners (base.trailCornersTail), so a support far behind -- node_52, eight
-- seconds behind node_33 in sim w3_pair_server_crash -- is still on them.
base.FOLLOW_TAIL_N = 200
function base.trailCornersTail(n)
    local t, out = base.trailTail(n), {}
    for i, c in ipairs(t) do
        local a, b = t[i - 1], t[i + 1]
        if not a or not b or c.x - a.x ~= b.x - c.x or c.y - a.y ~= b.y - c.y or c.z - a.z ~= b.z - c.z then
            out[#out + 1] = c
        end
    end
    return out
end
function base.followPartner(pl)
    if type(pl) ~= "table" then return false end
    local prev, tail, p = pl.prev, nil, _self.pos
    -- The corners back into cells; anything that is not a straight line between them is no path.
    if type(pl.tail) == "table" then
        tail = {}
        for _, c in ipairs(pl.tail) do
            local a = tail[#tail]
            if type(c) ~= "table" or type(c.x) ~= "number" or type(c.y) ~= "number" or type(c.z) ~= "number" then tail = nil; break end
            if a then
                local d = math.abs(c.x - a.x) + math.abs(c.y - a.y) + math.abs(c.z - a.z)
                local sx, sy, sz = math.floor((c.x - a.x) / math.max(d, 1)), math.floor((c.y - a.y) / math.max(d, 1)), math.floor((c.z - a.z) / math.max(d, 1))
                if d == 0 or math.abs(sx) + math.abs(sy) + math.abs(sz) ~= 1 or #tail + d > 4000 then tail = nil; break end
                for k = 1, d do tail[#tail + 1] = { x = a.x + sx * k, y = a.y + sy * k, z = a.z + sz * k } end
            else
                tail[1] = { x = c.x, y = c.y, z = c.z }
            end
        end
    end
    -- Only cells that end where it just was: going back down a shaft it climbed, its
    -- path cuts the loop off, and the cell "behind" it there is the one below it,
    -- where it goes next (sim w3_job_failed_lost: the support stood in it, "a turtle
    -- is blocking down" at 196,63,-2761).
    local b = type(tail) == "table" and #tail >= 2 and tail[#tail - 1]
    if b and type(prev) == "table" and (b.x ~= prev.x or b.y ~= prev.y or b.z ~= prev.z) then tail = nil end
    if type(tail) == "table" and #tail >= 2 then
        _self.partnerTrail = tail
        if base.walkPartnerTrail(true) > 0 then return true end
        if p.x == b.x and p.y == b.y and p.z == b.z then return true end
    end
    if type(prev) == "table" and type(prev.x) == "number" and type(prev.y) == "number" and type(prev.z) == "number" then
        return base.move.to(prev.x, prev.y, prev.z) and true or false
    end
    return false
end

local function applyMove(dir)
    -- Save previous position before updating
    local prevX, prevY, prevZ = _self.pos.x, _self.pos.y, _self.pos.z

    if dir == "forward" then
        if     _self.facing == 0 then _self.pos.z = _self.pos.z - 1
        elseif _self.facing == 1 then _self.pos.x = _self.pos.x + 1
        elseif _self.facing == 2 then _self.pos.z = _self.pos.z + 1
        elseif _self.facing == 3 then _self.pos.x = _self.pos.x - 1
        end
    elseif dir == "back" then
        if     _self.facing == 0 then _self.pos.z = _self.pos.z + 1
        elseif _self.facing == 1 then _self.pos.x = _self.pos.x - 1
        elseif _self.facing == 2 then _self.pos.z = _self.pos.z - 1
        elseif _self.facing == 3 then _self.pos.x = _self.pos.x + 1
        end
    elseif dir == "up"   then _self.pos.y = _self.pos.y + 1
    elseif dir == "down" then _self.pos.y = _self.pos.y - 1
    end

    -- Periodic GPS re-sync to correct drift on long journeys
    _self.moveCount = _self.moveCount + 1
    if _self.moveCount % CFG.GPS_RESYNC_INTERVAL == 0 then
        gpsSync()
    end

    trail.note({ x = prevX, y = prevY, z = prevZ })
    if base.atc and base.atc.pathStep then base.atc.pathStep() end
    -- Delivery and miner turtles broadcast their previous position so support can follow 1 block behind,
    -- and the last cells they stood in (base.followPartner): a support that missed a step walks those.
    if _self.partnerId and (_self.role == proto.ROLE.DELIVERY or _self.role == proto.ROLE.MINER) and _self.modem then
        local sig = proto.encode(proto.MSG.POSITION_UPDATE, _self.id, _self.partnerId, {
            prev = { x=prevX, y=prevY, z=prevZ }, tail = base.trailCornersTail(base.FOLLOW_TAIL_N),
        })
        proto.send(_self.modem, proto.CH_LOCAL, sig)
    end
    writeJournal(nil)
end

-- ─── Geofence helpers ───────────────────────────────────────────────────────
-- Shared by tryMove's own dir-based guard AND bypassForward's raw turtle.
-- forward() calls below -- bypassForward turns and moves the turtle directly,
-- bypassing tryMove entirely, so it needs the identical check applied at
-- every individual step or the fence stops meaning anything once a turtle
-- (e.g. a placed chunk loader sitting right in front of the miner, which the
-- solo-miner design does on purpose) blocks the forward path.

-- Position after a single forward/back step from the CURRENT facing, without
-- mutating any state.
local function projectStep(dir)
    local nx, nz = _self.pos.x, _self.pos.z
    local sign = (dir == "forward") and 1 or -1
    if     _self.facing == 0 then nz = nz - sign
    elseif _self.facing == 1 then nx = nx + sign
    elseif _self.facing == 2 then nz = nz + sign
    else                          nx = nx - sign end
    return nx, nz
end

-- True when the fence is active and stepping `dir` from the current facing
-- would leave it. Always false when the fence is absent/inactive, so callers
-- never need to separately check isActive().
local function fenceBlocksStep(dir)
    if not (_geofence and _geofence.isActive()) then return false end

    -- A ceiling is a ONE-WAY barrier: it may refuse a move that would carry the
    -- turtle up through it, and nothing else. Anything stricter strands.
    --
    -- The first version passed y on every direction, which W1 hit twice while
    -- integrating. A miner at travel altitude (175/200) under a 160 ceiling had
    -- forward, up AND down all refused at once -- every direction, with the
    -- loader already placed and the record already written. Descending toward
    -- the lease was refused for being above it, which is precisely backwards,
    -- and horizontal moves were judged against a ceiling they cannot change.
    --
    -- So: `up` tests y, `down` and the horizontals do not. That also restores
    -- the contract geofence.lua documents and its own tests assert -- "a
    -- horizontal move passes no y and must not be judged against the ceiling"
    -- -- which this caller was quietly contradicting.
    if dir == "up" then
        return not _geofence.contains(_self.pos.x, _self.pos.z, _self.pos.y + 1)
    end
    if dir == "down" then
        return not _geofence.contains(_self.pos.x, _self.pos.z)
    end

    local nx, nz = projectStep(dir)
    return not _geofence.contains(nx, nz)
end

-- ─── Movement ────────────────────────────────────────────────────────────────

local move = {}

-- Inspect function for each direction (nil for back — no inspectBack in CC)
local INSPECT = {
    forward = turtle.inspect,
    up      = turtle.inspectUp,
    down    = turtle.inspectDown,
    back    = nil,
}

local DIG = {
    forward = turtle.dig,
    up      = turtle.digUp,
    down    = turtle.digDown,
    back    = nil,
}

local function isTurtleBlock(dir)
    local fn = INSPECT[dir]
    if not fn then return false end
    local ok, data = fn()
    return ok and type(data) == "table"
           and type(data.name) == "string"
           and data.name:find("turtle")
end

-- Never dig a turtle. Not in the bypass, not when surrounded, not anywhere.
--
-- tryMove already refuses to dig a blocker and waits instead -- but the bypass it
-- falls through to dug blind, so the sequence was: notice a turtle, decline to
-- dig it, try to route around it, and dig a DIFFERENT turtle on the way past.
--
-- Hardware loss is not recoverable the way terrain loss is. A mined turtle takes
-- its computer ID, its files and its loader_state with it, and its placed loader
-- is orphaned permanently with nothing left that knows to reclaim it. It is also
-- silent: the registry simply stops hearing from the victim and prunes it as
-- offline. Observed 2026-08-22 -- node_139 docked carrying node_119, a MINER, as
-- an item, and it was diagnosed as a missing turtle for a whole session before
-- someone looked in a slot.
--
-- Refusal is reported distinctly from failure so callers can tell "I must not"
-- from "I could not". A turtle in the way is a reason to WAIT: any column of
-- turtles is transient by definition, because everyone in it is trying to leave.
local function digGuarded(dir)
    local fn = DIG[dir]
    if not fn then return false, "no_dig_for_dir" end
    if isTurtleBlock(dir) then return false, "would_dig_turtle" end
    return fn()
end

-- BOXED IN BY ROCK AFTER A REBOOT (2026-10-08). The 12:05 restart caught node_184
-- and node_182 mining at depth with stone on all four sides. detectFacing must
-- step to measure, 1.9.134 rightly will not move on a guessed facing, and the
-- two retried every 10 s until a player dug them a hole. A miner carries a
-- pickaxe for exactly this: dig one block, so the caller can step and measure.
--
-- Nothing tells it which way it faces, so it may dig in ANY of the four
-- directions -- and so it digs only where all four are safe:
--   * not near the depot, whose walls and one-block shafts are not rock;
--   * not when any neighbour lies outside an armed fence, since the one it digs
--     could be that one;
--   * never a turtle (digGuarded) -- a placed loader is one.
-- Returns true having stepped forward one block; the caller steps back.
function base.digOutForFacing(x, y, z)
    if not _self.canDig then return false end
    local pos = { x = math.floor(x), y = math.floor(y), z = math.floor(z) }
    if base.nearDepot(pos) then return false end
    if _geofence and _geofence.isActive() then
        for _, d in ipairs({ { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } }) do
            if not _geofence.contains(pos.x + d[1], pos.z + d[2]) then return false end
        end
    end
    local function digAndStep()
        for _ = 1, 4 do
            if turtle.detect() then
                base.makeRoomBeforeDig()
                if digGuarded("forward") and jMove("forward") then
                    logWarn("Boxed in on all four sides -- dug one block out to measure facing")
                    return true
                end
            end
            jTurn("turnRight")
        end
        return false
    end
    -- In travel mode a miner's pickaxe is stowed (2026-10-08 22:57: node_178,
    -- caught by a second reboot climbing its own shaft with chunky and modem
    -- on). The installed wrapper borrows it for the dig, as every travel-mode
    -- dig does, and never from chunky's side. Roles without one dig as they are.
    if not _digToolWrapper then return digAndStep() end
    local stepped = false
    local ok, err = pcall(_digToolWrapper, "digging out to measure facing",
        function() stepped = digAndStep() end)
    if not ok then logWarn("Dig-out to measure facing failed: " .. tostring(err)) end
    return ok and stepped
end

-- Attempt to route around a turtle blocking the forward path.
-- Tries (in order): left strafe, right strafe, dig UP over it, dig DOWN under it.
-- Vertical bypasses work even in 1-block-wide tunnels where lateral strafes fail.
-- All position tracking is done internally; caller must NOT call applyMove again.
-- Returns true if the turtle successfully moved past the obstacle.
local function bypassForward()

    -- ── Lateral bypass (left or right) ───────────────────────────────────────
    local function tryStrafe(isLeft)
        local turnOut = isLeft and move.turnLeft  or move.turnRight
        local turnRtn = isLeft and move.turnRight or move.turnLeft

        turnOut()
        if fenceBlocksStep("forward") then turnRtn(); return false end
        if not jMove("forward") then turnRtn(); return false end
        applyMove("forward")
        turnRtn()

        local advanced = 0
        for _ = 1, 3 do
            if fenceBlocksStep("forward") then break end
            if jMove("forward") then
                applyMove("forward")
                advanced = advanced + 1
                if not isTurtleBlock("forward") then break end
            else
                break
            end
        end

        if advanced == 0 then
            turnRtn()
            -- Undoing the sideways step. Original code called turtle.forward()
            -- + applyMove unconditionally here (not even checking forward()'s
            -- return) -- preserved exactly when the fence isn't blocking; only
            -- skip the real move when it would breach the fence.
            if fenceBlocksStep("forward") then
                turnOut()
                return false
            end
            jMove("forward"); applyMove("forward")
            turnOut()
            return false
        end

        turnRtn()
        if not fenceBlocksStep("forward") then
            if jMove("forward") then applyMove("forward") end
        end
        turnOut()
        return true
    end

    -- ── Vertical bypass (up over obstacle, then back down) ───────────────────
    -- Needs canDig (delivery has a pickaxe, support does not).
    -- Advances 2 blocks at the upper level so delivery is fully past support
    -- before descending (support is 1 block wide so 2 steps = safely clear).
    local function tryVertical(isUp)
        if not _self.canDig then return false end

        local digLayer  = isUp and turtle.digUp   or turtle.digDown
        local moveLayer = function() return jMove(isUp and "up" or "down") end
        local applyDir  = isUp and "up"           or "down"
        local returnDig = isUp and turtle.digDown or turtle.digUp
        local returnMov = function() return jMove(isUp and "down" or "up") end
        local returnDir = isUp and "down"         or "up"
        local detectLayer = isUp and turtle.detectUp or turtle.detectDown

        -- 1. Dig and move to upper/lower level.
        -- Refusing here is the whole point: this is the step that was digging a
        -- second turtle while routing around the first. Bail so the caller tries
        -- the other direction and then waits.
        if detectLayer() then
            base.makeRoomBeforeDig()
            local dug, why = digGuarded(applyDir)
            if not dug then
                if why == "would_dig_turtle" then
                    logWarn("Vertical bypass: a turtle is " .. applyDir
                        .. " — refusing to dig it, will wait instead")
                end
                return false
            end
        end
        if not moveLayer() then return false end
        applyMove(applyDir)

        -- 2. Advance 2 blocks past the obstacle at this level (dig terrain if needed)
        -- This is horizontal (x/z) movement despite living inside the "vertical"
        -- bypass -- the up/down step itself never touches x/z and needs no
        -- check, but this forward advance does, same as tryStrafe above.
        local advanced = 0
        for _ = 1, 2 do
            if fenceBlocksStep("forward") then break end
            if not jMove("forward") then
                if isTurtleBlock("forward") then break end  -- another turtle, stop
                base.makeRoomBeforeDig()
                turtle.dig()                                -- terrain — dig it
                sleep(0.2)
                if fenceBlocksStep("forward") then break end
                if not jMove("forward") then break end
            end
            applyMove("forward")
            advanced = advanced + 1
        end

        if advanced < 2 then
            -- Couldn't clear obstacle at this level — go back.
            -- If something has moved into the level we came from and it is a
            -- turtle, we stay put rather than dig it. Being at the wrong Y is
            -- survivable; move.to corrects it.
            local returnDetectA = isUp and turtle.detectDown or turtle.detectUp
            if returnDetectA() then digGuarded(returnDir) end
            -- applyMove ONLY on a move that actually happened. This was
            -- unconditional -- `returnMov(); applyMove(returnDir)` -- so a failed
            -- return silently desynced the tracked position from the real one,
            -- which is the worst kind of bug this file can have: every later
            -- fence check and GPS-free move would be computed from a lie. The
            -- guard above makes a failed return far more likely, so this had to
            -- be corrected in the same change rather than left as latent.
            if returnMov() then applyMove(returnDir) end
            return false
        end

        -- 3. Return to original Y level (dig if terrain moved in)
        local returnDetect = isUp and turtle.detectDown or turtle.detectUp
        if returnDetect() then digGuarded(returnDir) end
        if not returnMov() then
            -- Stuck at the new level — still report success (move.to will fix Y)
            logWarn("Vertical bypass: could not return to original Y — move.to will correct")
            return true
        end
        applyMove(returnDir)
        return true
    end

    logInfo("Turtle blocking forward — attempting intelligent bypass...")
    if tryStrafe(true)  then logInfo("Bypass: left lane");  return true end
    if tryStrafe(false) then logInfo("Bypass: right lane"); return true end
    -- Vertical bypass (dig up/down) is only safe underground in tight tunnels.
    -- Inside the surface depot (y >= FLOOR_Y) never dig — just wait or strafe.
    if _self.pos.y < CFG.FLOOR_Y then
        if tryVertical(true)  then logInfo("Bypass: dug UP over blocker");    return true end
        if tryVertical(false) then logInfo("Bypass: dug DOWN under blocker"); return true end
    end
    logInfo("All bypass routes failed — waiting for path to clear")
    return false
end

-- Invariant J: nothing may block silently for more than 10 seconds.
--
-- tryMove has two waits that could, and both are the shape the invariant exists
-- to stop: from the outside a turtle holding position is indistinguishable from
-- a crashed one, and the whole fleet's diagnosis cost this month has been made
-- of that ambiguity. The server-down hold announces itself once when serverDown
-- trips and then says nothing for as long as it lasts, which is unbounded; the
-- turtle-blocked wait says nothing at all for its full two minutes.
--
-- Reports the first time a wait crosses the threshold and then at a slower
-- cadence, because a line per retry is how a log stops being readable -- these
-- computers have already needed two rounds of log-volume fixes (1.9.61/1.9.67).
local WAIT_REPORT_AFTER  = 10
local WAIT_REPORT_REPEAT = 30

-- `what` is a function, not a string, so the detail is read at the moment it is
-- reported rather than when the wait began -- position changes under a bypass.
--
-- BOTH the constructor and the reporter take `now` from the caller rather than
-- reading os.clock themselves. That is not a micro-optimisation: the loops below
-- already read the clock once per iteration for their own deadline, and reading
-- it a second time changes the NUMBER of os.clock calls per retry. A test
-- harness that advances a fake clock per call -- test_bypass_geofence does
-- exactly that, ten seconds a call, to reach the 120 s deadline without spinning
-- for two real minutes -- then burns its budget faster and the code under test
-- gives up before reaching the branch it was written for. Caught as an
-- intermittent failure in an unrelated suite.
local function waitReporter(what, now)
    local started = now
    local nextAt  = started + WAIT_REPORT_AFTER
    return function(now)
        -- BEFORE THE CONTROL LOOP RUNS, A WAIT TELLS THE SERVER (T2 shakeout-payload-i, 2026-11-24).
        -- Three copies of node_215 waited 46 min in boot recovery's ATC booking loop and sent the
        -- server nothing: heartbeats and the log outbox start with base.run. The server pruned
        -- node_215 as offline and its duplicate check (seq streams) never heard the copies. A
        -- STATUS_UPDATE, not a heartbeat: the first heartbeat releases the job re-send the server
        -- holds for a rebooted turtle. Every 20 s of wall clock, with the log lines.
        if not _self.running then
            local wall = os.epoch("utc")
            if not _self.waitToldAt or wall - _self.waitToldAt >= 20000 then
                _self.waitToldAt = wall
                pcall(base.sendProgress, string.format("recovery_wait: Still waiting %ds — %s",
                    math.floor(now - started), what()))
                pcall(flushLogQueue)
            end
        end
        if now < nextAt then return end
        nextAt = now + WAIT_REPORT_REPEAT
        logWarn(string.format("Still waiting %ds — %s",
            math.floor(now - started), what()))
    end
end

-- One block sideways, whichever of the four sides is free: not fenced, not a
-- turtle, and diggable if it is rock. Makes room before digging like any move.
-- Returns true having moved; false having turned back to where it started.
function base.sidestepOutOfColumn()
    for _ = 1, 4 do
        if not fenceBlocksStep("forward") and not isTurtleBlock("forward") then
            if turtle.detect() and _self.canDig then
                base.makeRoomBeforeDig()
                digGuarded("forward")
            end
            if jMove("forward") then
                applyMove("forward")
                return true
            end
        end
        move.turnRight()
    end
    return false
end

-- Refused targets recently logged, for the geofence refusal below: key -> {loggedAt,
-- lastAt, held}. Cleared when it passes 32 keys -- a miner meets a handful per
-- sector, and a clear only means one extra line.
local _fenceRefusals, _fenceRefusalKeys = {}, 0
local function fenceRefusalSlot(key)
    if _fenceRefusals[key] == nil then
        _fenceRefusalKeys = _fenceRefusalKeys + 1
        if _fenceRefusalKeys > 32 then _fenceRefusals, _fenceRefusalKeys = {}, 1 end
    end
end

-- ─── Base air-traffic control: the turtle's half (2026-11-03, atc.lua) ──────
-- One turtle per section of the base (waypoints.lua, W.atcSection). A step into
-- a new section waits here until the ATC computer says it may enter; leaving a
-- section gives it back. A whole route is booked first (atc.book), so a turtle
-- waits in its dock or the holding line, not in the corridor. NO ANSWER MEANS NO
-- ENTRY: with the ATC down a turtle stops at the edge of the section it holds,
-- and the base pauses instead of jamming.
-- docs/superpowers/specs/2026-11-03-base-atc-design.md
--
-- One table, not a dozen locals: CC refuses this file past 200 locals alive at
-- once counted with the functions around them (tests/test_cc_local_limit.lua).
-- ON ONCE THIS TURTLE HAS HEARD AN ATC, AND FROM THEN ON FOR GOOD. A base with no
-- ATC computer moves exactly as before; a base that has one keeps gating while it
-- is down, after a reboot, after a world restart -- the file says it exists.
local atc = {
    SEEN_FILE = "atc.seen",
    ENABLED  = W.atcSection ~= nil and fs.exists("atc.seen"),
    REPLY_S  = 2,          -- one round trip
    STUCK_S  = 160,        -- no progress this long: the job goes back to the queue
    route    = nil,        -- the booked sections, in order
    nonce    = 0,
    stallAt  = nil,        -- os.clock() when progress stopped
    stuckSent = false,
}

function atc.heard()
    if atc.ENABLED or not W.atcSection then return end
    atc.ENABLED = true
    pcall(function()
        local f = fs.open(atc.SEEN_FILE, "w")
        if f then f.write(tostring(os.epoch("utc"))); f.close() end
    end)
    logInfo("ATC heard: this turtle now asks it before every step into the base")
end

function atc.section(x, y, z) return W.atcSection and W.atcSection(x, y, z) or nil end

-- Is there an ATC? Asks it (at most once a minute) when this turtle has never
-- heard one. EVERY use of the base asks first -- the step gate, a booking, facing
-- detection. A booking used to be skipped before the first gated step had
-- switched the gate on, so the boot rush homed with no bookings, the ATC took
-- each turtle in as "standing where it is", and opposite movers met head-on on
-- the red lane in every bay (w3_atc_base150, boot rush, 2026-11-03).
function atc.ensure()
    if atc.ENABLED then return true end
    if not W.atcSection then return false end
    if atc.probedAt and os.clock() - atc.probedAt < 60 then return false end
    atc.probedAt = os.clock()
    local okAsk, answer = pcall(atc.ask, proto.MSG.ATC_REQUEST, { route = {} })
    if okAsk and answer then atc.heard() end   -- an error is no answer: never cost the move
    return atc.ENABLED
end
function atc.here() return atc.section(_self.pos.x, _self.pos.y, _self.pos.z) end

-- The booked sections from `from` on (from included), or {from, nextSec}.
function atc.remaining(from, nextSec)
    local r, out, on = atc.route, {}, false
    if r then
        for _, s in ipairs(r) do
            if s == from or s == nextSec then on = true end
            if on then out[#out + 1] = s end
        end
    end
    if #out == 0 then
        if from then out[#out + 1] = from end
        if nextSec and nextSec ~= from then out[#out + 1] = nextSec end
    end
    return out
end

function atc.send(msgType, payload)
    payload.ch = OWN_CHANNEL or proto.CH_PRIVATE
    if not _self.modem then return false end
    return pcall(proto.send, _self.modem, proto.CH_ATC, proto.encode(msgType, _self.id, "atc", payload))
end

-- One round trip: the reply payload, or nil when the ATC did not answer.
function atc.ask(msgType, payload)
    atc.nonce = atc.nonce + 1
    payload.nonce = atc.nonce
    if not atc.send(msgType, payload) then return nil end
    local deadline = os.clock() + atc.REPLY_S
    while true do
        local left = deadline - os.clock()
        if left <= 0 then return nil end
        local msg = pumpFor(_jobInbox, proto.MSG.ATC_REPLY, left)
        if not msg then return nil end
        if type(msg.payload) == "table" and msg.payload.nonce == payload.nonce then return msg.payload end
    end
end

-- No progress for STUCK_S: hand the job back once and stop counting as idle.
-- Called from every wait that is a refusal; a silent ATC is a pause, not a stall.
function atc.stalled(why)
    local now = os.clock()
    atc.stallAt = atc.stallAt or now
    if atc.stuckSent or now - atc.stallAt < atc.STUCK_S then return end
    atc.stuckSent = true
    atc.statusBefore = _self.status
    logWarn(string.format("STUCK %ds at %d,%d,%d (%s) -- handing job %s back, status ERROR",
        math.floor(now - atc.stallAt), _self.pos.x, _self.pos.y, _self.pos.z, why, tostring(_self.jobId)))
    if _self.jobId then
        base.reportFailed(_self.jobId, "stuck: " .. why, true)
        _self.jobId = nil
        atc.handedBack = true      -- the blocked move in the base gives way (tryMove)
    end
    _self.status = proto.STATUS.ERROR
    comms.toServer(proto.MSG.STATUS_UPDATE, proto.payloadStatusUpdate(nil, proto.STATUS.ERROR,
        "stuck: " .. why, base.getPos()))
end
-- Moving again ends a stall. A turtle that had reported STUCK goes back to the
-- status it had: left at ERROR it would never be given work again (15 docked
-- turtles in the boot rush, 2026-11-03). Its job, if it had one, is already back
-- in the queue and stays there.
function atc.progressed()
    atc.stallAt = nil
    atc.handedBack = nil
    if not atc.stuckSent then return end
    atc.stuckSent = false
    _self.status = (atc.statusBefore and atc.statusBefore ~= proto.STATUS.ERROR) and atc.statusBefore or proto.STATUS.IDLE
    atc.statusBefore = nil
    logInfo("Moving again after STUCK -- status " .. tostring(_self.status))
    comms.toServer(proto.MSG.STATUS_UPDATE, proto.payloadStatusUpdate(nil, _self.status, "moving again", base.getPos()))
end

-- Before a step from section `cur` into section `sec`: wait for the grant.
function atc.waitEnter(sec, cur)
    local report, last
    while true do
        local r = atc.ask(proto.MSG.ATC_ENTER, { sec = sec, cur = cur, route = atc.remaining(cur, sec) })
        last = r
        if r and r.ok then return true end
        local now = os.clock()
        if r and r.why ~= "settling" then atc.stalled("ATC: " .. tostring(r.why) .. " for " .. sec) end
        report = report or waitReporter(function()
            return string.format("ATC: waiting to enter %s at %d,%d,%d (%s)", sec,
                _self.pos.x, _self.pos.y, _self.pos.z, last and tostring(last.why) or "no answer from the ATC")
        end, now)
        report(now)
        sleep(r and 1 or 2)
    end
end

-- Book a route (waypoints, in move.to's order) from where the turtle stands.
-- Returns once admitted: the turtle waits HERE -- its dock, the holding line, the
-- sky -- until the route's first section is free.
-- giveUp (optional): called before every ask; a reason string ends the wait --
-- the booking is cancelled and book returns false, reason. A support whose
-- delivery went down without it stops waiting (PARTNER_LEFT, base.depart).
function atc.book(waypoints, label, giveUp, path)
    -- THE PAIR TAG IS FOR ONE ADMISSION (2026-11-17, T2 w3-pair-dropout-b). Left
    -- set, it made node_96's way home from the hole -- its support gone -- a pair's
    -- request: the ATC waited for the partner's ask, and node_96 held DH for good.
    local pair = atc.pair
    atc.pair = nil
    atc.owesUntil = nil        -- asking anew: no more "I am out" (atc.keepInBase)
    if not atc.ensure() then return true end
    local list = W.routeSections(base.getPos(), waypoints)
    atc.route = list
    -- Its path from the first ask: a pair is let in on its partner's ask, and a report
    -- of this one's that came before its own answer said nothing of a path -- which let
    -- the path go (sim w3_retrace_head_on: "node_34 reports without its path", 14 s in).
    if path then atc.takePath(path) else atc.path = nil end
    if #list == 0 and not path then return true end
    local report, last
    local place, after = nil, nil
    while true do
        local stop = giveUp and giveUp()
        if stop then
            atc.send(proto.MSG.ATC_CANCEL, { cur = atc.here() })
            atc.route = nil
            logWarn(string.format("ATC: %s no longer wanted (%s) -- not waiting to be let in", label or "route", tostring(stop)))
            return false, stop
        end
        local r = atc.ask(proto.MSG.ATC_REQUEST, { route = list, cur = atc.here(), group = atc.group, pair = pair, path = path, pathKind = path and path.kind,
            pathStanding = path and path.standing or nil })
        last = r
        if r and r.ok then
            atc.progressed()
            return true
        end
        -- ITS PLACE IN LINE (R3), said when it changes: "Departure: 3rd in line, after node_212".
        if r and r.place and (r.place ~= place or r.after ~= after) then
            place, after = r.place, r.after
            local n = tonumber(place) or 0
            local suffix = (n % 100 >= 11 and n % 100 <= 13) and "th" or ({ "st", "nd", "rd" })[n % 10] or "th"
            logInfo(string.format("%s: %d%s in line%s", r.line == "return" and "Return" or "Departure", n, suffix,
                after and (", after " .. tostring(after)) or ", next out"))
        end
        local now = os.clock()
        -- The reason of the LATEST answer, not the first: the shakeout review read
        -- a turtle still quoting a refusal from hours before.
        report = report or waitReporter(function()
            return string.format("ATC: %s waiting to be let in (%s) at %d,%d,%d", label or "route",
                last and tostring(last.why) or "no answer from the ATC", _self.pos.x, _self.pos.y, _self.pos.z)
        end, now)
        report(now)
        sleep(r and 2 or 3)
    end
end

-- STILL HERE (2026-11-16, sim w3_side_atc on 17d6b30; T2 shakeout-side-d). The
-- ATC takes a turtle silent STALE_MS (180 s) for dead and gives back every
-- section it holds, the one it stands in too. A turtle that waits in the base
-- without asking -- for a GPS fix to measure its facing, or behind a turtle that
-- does not move -- said nothing: its section was let go under it, another turtle
-- was let into the next one, and the two met head-on, each in the section the
-- other needed. Waiting there, it reports where it stands (ATC_REPORT: it keeps
-- its booking alive, or takes back the section it stands in) once a KEEPALIVE_S.
-- Rebooted with no GPS it does not know where it stands: an empty report still
-- keeps alive whatever it holds (every message does), and claims nothing.
-- 10 s, not 30: in a 50% radio loss a 30 s report lost every time for 180 s is
-- one in twenty, and side test sim w3_side_atc on 9ca58c9 drew it -- node_53
-- swept 2 s after it measured its facing, then a circle with node_55 at DH.
-- 18 reports in 180 s, all lost at 50%: one in 260,000.
atc.KEEPALIVE_S = 10
function atc.keepAlive()
    if not atc.ENABLED then return end
    local now = os.epoch("utc")
    if atc.aliveAt and now - atc.aliveAt < atc.KEEPALIVE_S * 1000 then return end
    atc.aliveAt = now
    if _self.posFixed and atc.here() then atc.report()
    else atc.send(proto.MSG.ATC_REPORT, { route = {}, onPath = atc.path and true or nil }) end
end

-- STANDING IN THE BASE, IT SAYS SO, WHATEVER IT WAITS FOR (2026-11-17, sim
-- w3_side_atc). node_31 waited at the dispatch hole for SUPPORT_STAGED and said
-- nothing to the ATC; at 180 s it was taken for dead, DH was dropped under it and
-- the next pair let into the hole it stood in -- a head-on that held the base 4 h.
-- Called from the control loop: while it stands in a section or holds a booking.
-- A docked turtle with nothing booked has nothing to say.
function atc.keepInBase()
    if not atc.ENABLED then return end
    -- On its path out of every section: it says it is out -- which heals a lost leave -- and
    -- on its path, so the path stays (sim w3_atc_leave_lost on (D)).
    if atc.route == nil and atc.here() == nil and atc.path then
        local now = os.epoch("utc")
        if atc.owesUntil and now < atc.owesUntil and _self.posFixed
           and not (atc.aliveAt and now - atc.aliveAt < atc.KEEPALIVE_S * 1000) then
            atc.aliveAt = now
            atc.send(proto.MSG.ATC_REPORT, { out = true, route = {}, onPath = true })
            return
        end
        atc.keepAlive()
        return
    end
    if atc.route == nil and atc.here() == nil then
        -- OUT OF THE BASE, IT SAYS SO A WHILE (2026-11-17, T2 shakeout-side-h s002):
        -- node_215's ATC_LEAVE for DH, sent once as it stepped into the tunnel, was
        -- lost, and DH stayed booked, empty, until the 180 s sweep. The first of these
        -- the ATC hears lets its booking go. Only from a measured position.
        local now = os.epoch("utc")
        if atc.owesUntil and now < atc.owesUntil and _self.posFixed and not atc.claiming
           and not (atc.aliveAt and now - atc.aliveAt < atc.KEEPALIVE_S * 1000) then
            atc.aliveAt = now
            atc.send(proto.MSG.ATC_REPORT, { out = true, route = {} })
        end
        return
    end
    atc.keepAlive()
end
atc.OWE_MS = 300000
function atc.steppedOut()
    atc.owesUntil = os.epoch("utc") + atc.OWE_MS
    atc.aliveAt = nil
end

-- GIVING WAY BEFORE ITS FIRST STEP IN, IT GIVES BACK WHAT IT WAS LET INTO (T2
-- shakeout-payload-d, 2026-11-23). node_218, on its dock after the world restart,
-- was let out (S1 J1 W1 DH), found a turtle in front of it, said STUCK and gave
-- way -- and held S1, the section beside its dock, 45 min to the end of the run:
-- it never stepped into the base, so it never stepped out of it, nothing cancelled
-- the booking, and its keep-alives held it. Its neighbours could not measure their
-- facing. The cancel goes once; the "out" reports after it heal a lost one.
function atc.giveBackUnentered()
    if not atc.ENABLED then return end
    atc.finish()
    atc.steppedOut()
end

-- Done with the base: give back everything but the section it stands in.
-- keepPath: a departure done with its sections at the foot of the dispatch shaft keeps
-- the path it is about to walk ((D), atc.takePath).
function atc.finish(keepPath)
    if not atc.ENABLED then return end
    keepPath = keepPath and atc.path ~= nil
    atc.send(proto.MSG.ATC_CANCEL, { cur = atc.here(), keepPath = keepPath or nil })
    atc.route = nil
    if not keepPath then atc.path = nil end
end

-- The sections of the four blocks beside (x, y, z), asked for one at a time;
-- nil when none is in the base, false when one was refused (the rest given
-- back), else the list granted. For facing detection, which cannot know which
-- of the four it is about to step into.
function atc.claimAround(x, y, z)
    if not W.atcSection then return nil end
    local cur, want, seen = atc.section(x, y, z), {}, {}
    for _, d in ipairs({ { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } }) do
        local s = atc.section(x + d[1], y, z + d[2])
        if s and s ~= cur and not seen[s] then seen[s] = true; want[#want + 1] = s end
    end
    if #want == 0 or not atc.ensure() then return nil end
    atc.claiming = true          -- held to measure: no "out" report meanwhile (atc.keepInBase)
    local got = {}
    for _, s in ipairs(want) do
        local r = atc.ask(proto.MSG.ATC_ENTER, { sec = s, cur = cur, route = { cur, s } })
        if not (r and r.ok) then
            atc.lastRefusal = r and tostring(r.why) or "no answer from the ATC"
            atc.releaseAround(got)
            return false
        end
        got[#got + 1] = s
    end
    return got
end

function atc.releaseAround(list)
    for _, s in ipairs(list or {}) do atc.send(proto.MSG.ATC_LEAVE, { sec = s }) end
    -- Its ATC_LEAVEs go once (T2 shakeout-payload-c, node_453: one lost, the claim
    -- beside its dock stood for good and 8 bay-4 miners could never measure their
    -- facing). Let go, it says it is out a while, as after stepping out of the base.
    atc.claiming = nil
    if atc.here() == nil then atc.steppedOut() end
end

-- Where it is and what it still needs, for an ATC that just booted.
function atc.report()
    local cur = atc.here()
    atc.send(proto.MSG.ATC_REPORT, { cur = cur, route = atc.remaining(cur), group = atc.group, onPath = atc.path and true or nil })
end
base.atc = atc

-- A DELIVERY NEVER LEAVES ITS SUPPORT'S CHUNK (T2 shakeout-payload-e, 2026-11-23;
-- Head Engineer ruling 2026-11-24). The support is the pair's chunk loader, and at
-- Advanced Peripherals' default chunkyTurtleRadius = 0 it loads only the chunk it
-- stands in. node_221 reached its destination 160,67,-2752, chunk 10,-172, with
-- node_234 21 blocks back in chunk z -174, and stopped dead there: nothing else
-- loads ground south of the base. So before a step into a new chunk -- and before
-- ASCENDING -- the delivery asks its support where it is (SUPPORT_WHERE, carrying
-- its own cells, so a support that lagged walks up behind it) and goes on the
-- answer that puts its support in the chunk it is leaving. The ask is repeated
-- for a lost message; the wait ends on the answer, or on the support giving up
-- (JOB_ABORT), or -- the last line, as for a support whose delivery died (R4) --
-- on SUPPORT_SILENT_S without a word from it. On only from base.setFollowGate:
-- while its support is actually following it out in the world.
base.SUPPORT_SILENT_S = 300
function base.setFollowGate(on) _self.followGate = on and true or nil end
function base.awaitSupportInChunk(why)
    local partner = _self.partnerId
    if not partner or not _self.modem then return true end
    local cx, cz = math.floor(_self.pos.x / 16), math.floor(_self.pos.z / 16)
    local nextAsk, heard, report = 0, os.epoch("utc"), nil
    while _self.partnerId == partner do
        if base.isRecalled() then return true end
        local now = os.epoch("utc")
        if now >= nextAsk then
            nextAsk = now + 3000
            local last2 = base.trailTail(2)
            proto.send(_self.modem, proto.CH_LOCAL, proto.encode(proto.MSG.SUPPORT_WHERE, _self.id, partner,
                { prev = #last2 == 2 and last2[1] or nil, tail = base.trailCornersTail(base.FOLLOW_TAIL_N) }))
        end
        local msg = base.receive(1)
        if msg and msg.from == partner then
            heard = os.epoch("utc")
            local pl = type(msg.payload) == "table" and msg.payload or {}
            if msg.type == proto.MSG.SUPPORT_HERE and type(pl.x) == "number" and type(pl.z) == "number" then
                if math.floor(pl.x / 16) == cx and math.floor(pl.z / 16) == cz then return true end
                -- Or in the cell right behind: as close as a one-block tunnel lets it come.
                -- node_221's destination 160,67,-2752 is a chunk's first block; the cell
                -- behind it is in the chunk before, and waiting for its support in its own
                -- chunk there waited for good.
                local b = base.trailTail(2)[1]
                if b and #base.trailTail(2) == 2 and pl.x == b.x and pl.y == b.y and pl.z == b.z then return true end
                nextAsk = os.epoch("utc") + 1000   -- not here yet: asked again as it walks up behind
            elseif msg.type == proto.MSG.JOB_ABORT and (tonumber(msg.ts) or 0) >= (_self.jobSince or 0) then
                logWarn(string.format("Support %s gave up (%s) at the edge of chunk %d,%d -- not going on without it",
                    tostring(partner), tostring(pl.reason), cx, cz))
                _self.partnerId = nil
                return false
            end
        end
        if os.epoch("utc") - heard > base.SUPPORT_SILENT_S * 1000 then
            logWarn(string.format("Support %s silent %ds at the edge of chunk %d,%d -- taken for gone; calling it home",
                tostring(partner), base.SUPPORT_SILENT_S, cx, cz))
            -- CALLED HOME, NOT JUST DROPPED (sim w3_side_atc on 8cc17b2, 2026-11-24). node_35 took node_54 for
            -- gone 5 s before a 300 s blackout ended and went home saying nothing; node_54, alive at the hole's
            -- foot, waited 315 s for a partner that had stopped talking to it, in node_35's way home. The
            -- come-home repeats (atc.keepPair), so one sent into the blackout is heard once the radio is back.
            atc.callSupportHome(partner, nil)
            _self.partnerId = nil
            return false
        end
        report = report or waitReporter(function()
            return string.format("waiting for my support %s to reach chunk %d,%d (%s)", tostring(partner), cx, cz, tostring(why))
        end, os.clock())
        report(os.clock())
    end
    return _self.partnerId ~= nil
end

-- The step that crosses into a new chunk waits for the support (above).
function base.chunkGate(dir)
    if not (_self.followGate and _self.partnerId and _self.role == proto.ROLE.DELIVERY) then return true end
    if dir ~= "forward" and dir ~= "back" then return true end
    local nx, nz = projectStep(dir)
    if math.floor(nx / 16) == math.floor(_self.pos.x / 16) and math.floor(nz / 16) == math.floor(_self.pos.z / 16) then
        return true
    end
    return base.awaitSupportInChunk(string.format("stepping into chunk %d,%d", math.floor(nx / 16), math.floor(nz / 16)))
end

-- (D), PATH-SCOPED BOOKINGS (Head Engineer ruling, 2026-11-24; sim w3_pair_server_crash, T2
-- shakeout-payload-g node_234/node_231 at 190/191,60,-2813). A turtle that cannot dig walking back the
-- departures' tunnel met a pair coming out along it, head-on. Inside the zone near the base (below the
-- floor, within base.nearDepot) a departure books the cells it will walk -- its X-then-Z leg from the
-- shaft's foot towards its destination -- and a turtle walking back books its way back; the ATC holds a
-- request whose cells cross another party's until those are walked past. Cells are let go by moves:
-- a turtle walking back as it passes them; a delivery with its support following PATH_MARGIN behind
-- itself (its support is within a chunk of it, base.awaitSupportInChunk), and the rest once it has
-- gone PATH_MARGIN cells beyond its path. A step into a zone cell off its path asks for it first.
atc.PATH_MARGIN = 32
local function cellKeyOf(c) return string.format("%d,%d,%d", c.x, c.y, c.z) end
function atc.inZone(c) return c.y < CFG.FLOOR_Y and base.nearDepot(c) end
function atc.corners(cells)
    local out = {}
    for i, c in ipairs(cells) do
        local a, b = cells[i - 1], cells[i + 1]
        if not a or not b or c.x - a.x ~= b.x - c.x or c.y - a.y ~= b.y - c.y or c.z - a.z ~= b.z - c.z then
            out[#out + 1] = { x = c.x, y = c.y, z = c.z }
        end
    end
    return out
end
-- The cells of a walk inside the zone: from its first cell in the zone to the next one out of it,
-- less any section cells at either end -- the shaft's foot is DH's, which the ATC already lets one
-- party at a time into: held as a path cell too, it held a pair going west for a whole walk back
-- coming from the east (sim w3_retrace_long_walk). Section cells in the middle stay: a path is a line.
function atc.zoneLeg(cells)
    local out = {}
    for _, c in ipairs(cells) do
        if atc.inZone(c) then out[#out + 1] = c elseif #out > 0 then break end
    end
    while #out > 0 and atc.section(out[1].x, out[1].y, out[1].z) do table.remove(out, 1) end
    while #out > 0 and atc.section(out[#out].x, out[#out].y, out[#out].z) do out[#out] = nil end
    return out
end
-- move.to's way at one y: X first, then Z.
function atc.lCells(a, b)
    local out, x, z = { { x = a.x, y = a.y, z = a.z } }, a.x, a.z
    while x ~= b.x do x = x + (b.x > x and 1 or -1); out[#out + 1] = { x = x, y = a.y, z = z } end
    while z ~= b.z do z = z + (b.z > z and 1 or -1); out[#out + 1] = { x = x, y = a.y, z = z } end
    return out
end
function base.setDepartDest(d) _self.departDest = d end
function atc.departurePath()
    local d = _self.departDest
    if not (d and type(d.x) == "number" and type(d.z) == "number") then return nil end
    local a = { x = W.WORLD_EXIT.x, y = W.WORLD_EXIT.y, z = W.WORLD_EXIT.z }
    local leg = atc.zoneLeg(atc.lCells(a, { x = d.x, y = a.y, z = d.z }))
    if #leg == 0 then return nil end
    local corners = atc.corners(leg)
    corners.kind = "out"
    return corners
end
function atc.retracePath()
    local rev = {}
    for i = #trail.cells, 1, -1 do rev[#rev + 1] = trail.cells[i] end
    local leg = atc.zoneLeg(rev)
    if #leg == 0 then return nil end
    local corners = atc.corners(leg)
    corners.kind = "back"
    -- standing in the zone already (rebooted out there), its first cell is the one it stands in
    local c1 = corners[1]
    corners.standing = c1.x == _self.pos.x and c1.y == _self.pos.y and c1.z == _self.pos.z or nil
    return corners
end
function atc.takePath(corners)
    local p = { list = {}, set = {}, idx = {}, walked = 0, at = 0, beyond = 0 }
    for i, c in ipairs(corners) do
        local a = corners[i - 1]
        local seg = { c }
        if a then         -- a straight line from a to c, along whichever one axis they differ on
            seg = {}
            local d = math.abs(c.x - a.x) + math.abs(c.y - a.y) + math.abs(c.z - a.z)
            for k = 0, d do
                local f = d > 0 and k / d or 0
                seg[#seg + 1] = { x = math.floor(a.x + (c.x - a.x) * f + 0.5), y = math.floor(a.y + (c.y - a.y) * f + 0.5),
                                  z = math.floor(a.z + (c.z - a.z) * f + 0.5) }
            end
        end
        for j = a and 2 or 1, #seg do
            local k = cellKeyOf(seg[j])
            if not p.set[k] then p.list[#p.list + 1] = k; p.set[k] = true; p.idx[k] = #p.list end
        end
    end
    atc.path = p
end
function atc.pathStep()
    local p = atc.path
    if not p then return end
    local i = p.idx[cellKeyOf(_self.pos)]
    -- Off it counts only once it has been on it: the way from its dock to the shaft is not "beyond".
    if i then p.at, p.beyond = math.max(p.at, i), 0 elseif p.at > 0 then p.beyond = p.beyond + 1 end
    local margin = (_self.partnerId and _self.followGate) and atc.PATH_MARGIN or 0
    -- the cell it stands in stays its own: at the shaft's foot it still holds it until its climb is booked
    local walked = math.max(0, p.at - math.max(margin, 1))
    if p.beyond >= atc.PATH_MARGIN then walked = #p.list end
    if walked > p.walked and (walked >= #p.list or walked - p.walked >= 8) then
        p.walked = walked
        atc.send(proto.MSG.ATC_PATH, { walked = walked })
    end
    if p.walked >= #p.list then
        atc.path = nil
        atc.steppedOut()        -- it says it is out a while, which heals a lost leave
    end
end
-- Before a raw step: a zone cell off its path is asked for first (a dig-round's detour).
function atc.pathAllow(dir)
    local p = atc.path
    if not p then return true end
    local c = { x = _self.pos.x, y = _self.pos.y, z = _self.pos.z }
    if dir == "up" then c.y = c.y + 1 elseif dir == "down" then c.y = c.y - 1 else c.x, c.z = projectStep(dir) end
    local k = cellKeyOf(c)
    -- A cell of a section (the dispatch shaft, DH) is the section's to grant: a delivery coming
    -- down the shaft asked for 143,66,-2813 as a detour (sim w3_retrace_head_on).
    if p.set[k] or not atc.inZone(c) or atc.section(c.x, c.y, c.z) then return true end
    local r = atc.ask(proto.MSG.ATC_PATHADD, { cells = { c } })
    if r and r.ok then
        p.list[#p.list + 1] = k; p.set[k] = true; p.idx[k] = p.at
        return true
    end
    -- The ATC holds no path of its (it restarted, or a report let it go): there is nothing of
    -- its to keep, and waiting for a cell nobody will grant waited for good (sim w3_side_atc).
    if r and r.why == "no path" then
        atc.path = nil
        return true
    end
    logInfo(string.format("Detour into %d,%d,%d not booked (%s) -- waiting", c.x, c.y, c.z,
        tostring(r and r.why or "no answer from the ATC")))
    return false
end

local function tryMove(digFn, dir)
    -- Parked (duplicate_id): no step, whatever asks for one, until a person sees to it.
    while _self.parked do sleep(10) end
    -- NO TURTLE MOVES AFTER BOOT ON A GUESS (recovery layer release 2). Only
    -- miners ever called waitForPositionFix; delivery and support moved on
    -- whatever initPosition guessed ("Facing assumed north") -- the failure that
    -- lost four miners on 2026-10-05. Here, so it holds however a role first
    -- moves. Armed by base.init; a no-op once position and facing are measured.
    if _self.bootGuard and not (_self.posFixed and _self.facingKnown) then
        base.waitForPositionFix("first move after boot")
    end
    -- Hold position while the server is unreachable so it does not lose track of
    -- us — except during a fixed-path sky return, or an autonomous return, where
    -- the whole point is to get home WITHOUT the server. Blocking there would
    -- strand the miner in the field for as long as the server stays down, and
    -- leave its placed loader force-loading a chunk indefinitely.
    local downReport = nil
    -- Not while homing, and never inside the base: there the ATC is the
    -- authority, and a turtle must be able to park with the server down (ATC
    -- card, requirement 7).
    -- Nor a support following its delivery (R4): its delivery decides where it
    -- goes, and a delivery on its way home does not pause; paused, the support
    -- was left behind and the pair split (sim w3_pair_server_crash).
    while _self.serverDown
          and not _self.inSkyReturn
          and not _self.autonomousReturn
          and not _self.homing
          and not (_self.role == proto.ROLE.SUPPORT and _self.partnerId)
          and not (atc.ENABLED and atc.here())
          -- Nor a turtle holding an admitted booking or a path: what it holds, every turtle
          -- behind it waits for. node_221, admitted with node_225, paused on its dock -- in no
          -- section -- and held DH J1 N1 W1 10 minutes (T2 shakeout-payload-g, 02:53).
          and not (atc.ENABLED and (atc.route ~= nil or atc.path ~= nil)) do
        -- Escape hatch for a solo miner holding a placed loader (see
        -- base.setServerDownEscape). nil for every other role, so their loop
        -- body stays exactly `sleep(2)`. pcall'd so a faulty predicate can
        -- never break movement for the whole fleet.
        if _serverDownEscape then
            local pok, escape = pcall(_serverDownEscape)
            if pok and escape then break end
        end
        -- Built lazily: a turtle that is not blocked never pays for this, and
        -- the overwhelmingly common case is that this loop is not entered.
        local now = os.clock()
        downReport = downReport or waitReporter(function()
            return string.format("server unreachable, holding at %d,%d,%d before moving %s",
                _self.pos.x, _self.pos.y, _self.pos.z, dir)
        end, now)
        downReport(now)
        sleep(2)
    end

    -- Geofence: refuse any move that would leave the placed loader's footprint,
    -- or rise above a lease ceiling. Enforced here, at the single choke point
    -- every move passes through, so a new call site cannot bypass it.
    --
    -- EVERY direction, including up and down. That used to read "only
    -- forward/back change chunk, so vertical moves are never fenced" -- correct
    -- for a chunk anchor and wrong for a lease, whose ceiling is expressed
    -- purely in y. (bypassForward below has its own raw turtle.forward() calls
    -- that bypass this function entirely -- see fenceBlocksStep.)
    if fenceBlocksStep(dir) then
        -- anchor() is nil when only a lease is armed, so this must not
        -- dereference it unconditionally -- doing so would turn a refused move
        -- into a crash on the very path the lease exists to exercise.
        local a  = _geofence.anchor()
        local ls = _geofence.lease and _geofence.lease()
        local where
        if dir == "up" or dir == "down" then
            where = string.format("y=%d", _self.pos.y + ((dir == "up") and 1 or -1))
        else
            local nx, nz = projectStep(dir)
            where = string.format("%d,%d", nx, nz)
        end
        local fence = a and string.format("anchor chunk %d,%d r%d", a.cx, a.cz, a.chunkRadius)
              or (ls and string.format("lease %d,%d..%d,%d ceil %s",
                    ls.x1, ls.z1, ls.x2, ls.z2, tostring(ls.ceilingY))
                  or "fence")
        -- ONE LINE PER REFUSED TARGET IN TEN SECONDS (2026-11-02). node_118
        -- logged ~294 of these in three seconds across three targets and
        -- burned 237 log slots in under a minute -- the window in which any
        -- other line from it would have been lost. The refusal returned at once,
        -- so the caller retrying it spun. Now the same target refused again
        -- within a second waits half a second, and is logged once per ten
        -- seconds; the next line says how many were held back.
        local key, nowMs = where .. "|" .. fence, os.epoch("utc")
        fenceRefusalSlot(key)
        local seen = _fenceRefusals[key]
        if seen and nowMs - seen.lastAt < 1000 then sleep(0.5) end
        if not seen or nowMs - seen.loggedAt >= 10000 then
            local held = (seen and seen.held > 0)
                and string.format(" -- %d identical refusal(s) held back", seen.held) or ""
            logWarn(string.format("Geofence: refusing move to %s (%s)%s", where, fence, held))
            seen = { loggedAt = nowMs, held = 0 }
            _fenceRefusals[key] = seen
        else
            seen.held = seen.held + 1
        end
        seen.lastAt = nowMs
        return false, "geofence_breach"
    end

    -- THE ATC GATE. A step into a section this turtle is not in waits for the
    -- grant; nothing else in this function changes for a step that stays in the
    -- world. inBase also turns off the sidesteps below: in a one-block lane a
    -- step sideways is a step into somebody else's section.
    local atcFrom, atcInto = nil, nil
    if not atc.ENABLED and W.atcSection then
        -- BEFORE THE FIRST STEP INTO THE BASE, LOOK FOR AN ATC. Waiting to hear its
        -- hello is not enough: at boot 147 turtles started homing within 2 s and
        -- heard it only at its 60 s repeat, so the boot rush ran ungated and jammed
        -- (w3_atc_base150, 2026-11-03). A base with no ATC loses 2 s a minute.
        local nx, ny, nz = _self.pos.x, _self.pos.y, _self.pos.z
        if dir == "up" then ny = ny + 1 elseif dir == "down" then ny = ny - 1 else nx, nz = projectStep(dir) end
        if atc.section(nx, ny, nz) or atc.here() then atc.ensure() end
    end
    if atc.ENABLED then
        local nx, ny, nz = _self.pos.x, _self.pos.y, _self.pos.z
        if dir == "up" then ny = ny + 1 elseif dir == "down" then ny = ny - 1 else nx, nz = projectStep(dir) end
        atcFrom, atcInto = atc.here(), atc.section(nx, ny, nz)
        if atcInto and atcInto ~= atcFrom then atc.waitEnter(atcInto, atcFrom) end
    end
    if not base.chunkGate(dir) then return false, "support not with me at a chunk's edge" end
    local inBase = atcFrom ~= nil or atcInto ~= nil

    local maxDig      = (digFn and _self.canDig) and 12 or CFG.MOVE_RETRIES
    local digAttempts = 0

    -- Separate deadline for turtle-blocked waiting (2 minutes max)
    local turtleDeadline  = os.clock() + 120
    local turtleWaits     = 0
    local bypassAttempted = false
    local blockReport     = nil

    while true do
        if jMove(dir) then
            applyMove(dir)
            atc.progressed()
            if atcFrom and atcFrom ~= atcInto then
                atc.send(proto.MSG.ATC_LEAVE, { sec = atcFrom })
                if atcInto == nil then atc.steppedOut() end      -- out of the base: it says so a while
            end
            return true
        end

        if isTurtleBlock(dir) then
            -- Another turtle is in the way — wait, then try to route around it.
            -- Read the clock ONCE and pass it down; see waitReporter for why a
            -- second read is not free.
            local now = os.clock()
            -- In the base the ATC granted this section, so what blocks it is a turtle
            -- that cannot move: not a reason to give up and go IDLE in the lane (the
            -- server would offer it work; it would never say STUCK -- boxed-in test,
            -- sim, 2026-11-03). It waits, the stuck rule hands its job back and marks
            -- it ERROR at STUCK_S, and it carries on if the way clears.
            if now > turtleDeadline and not inBase then
                -- Logged as well as returned. Callers do report this, but not
                -- all of them reach the server, and two minutes of standing
                -- still ending in silence is the case Invariant J is about.
                logWarn(string.format(
                    "Gave up after 120s blocked by a turtle moving %s at %d,%d,%d",
                    dir, _self.pos.x, _self.pos.y, _self.pos.z))
                return false, "blocked by turtle (" .. dir .. ")"
            end
            turtleWaits = turtleWaits + 1
            -- A TURTLE THAT IS OFF IS TURNED BACK ON (2026-11-17, T2 shakeout-side-f).
            -- CC's timeout terminates a computer where it stands, and a terminated
            -- one stays off: dead #210 plugged the departure lane and node_211 bumped
            -- it 323 times. A turtle next to another computer can turn it on (it is a
            -- peripheral), and then it boots and recovers like any rebooted turtle.
            -- Once per blocked step: a turtle that is on is simply waited for.
            -- In the base the one turned on must get home through a one-block lane
            -- this turtle stands in: it gives way -- its trip ends here (a departure
            -- fails and is paired again; any other trip goes home first) -- rather
            -- than meet it head-on (sim w3_dead_turtle_lane).
            if turtleWaits == 1 then
                local okR, revived = pcall(base.reviveIfOff, dir)
                if okR and revived and inBase then
                    if atcFrom == nil then atc.giveBackUnentered() end
                    return false, "turned on a stopped turtle in my way -- giving way"
                end
            end
            if inBase then atc.stalled("blocked by a turtle moving " .. dir); atc.keepAlive() end
            -- ITS JOB HANDED BACK, IT GIVES WAY (the card "a turtle that handed its job
            -- back on STUCK carries on with the job"; sim w3_side_atc 2026-11-17). node_36
            -- handed job_0035 back and waited on to move forward, for a job no longer its
            -- own, telling its support "still coming" for 4 h. The trip ends here: a
            -- departure fails (its support is told), any other trip goes home.
            if inBase and atc.handedBack then
                atc.handedBack = nil
                logWarn(string.format("My job is handed back and a turtle blocks me %s at %d,%d,%d -- giving way",
                    dir, _self.pos.x, _self.pos.y, _self.pos.z))
                if atcFrom == nil then atc.giveBackUnentered() end
                return false, "stuck: my job is handed back -- giving way"
            end
            blockReport = blockReport or waitReporter(function()
                return string.format("a turtle is blocking %s at %d,%d,%d (%d attempts)",
                    dir, _self.pos.x, _self.pos.y, _self.pos.z, turtleWaits)
            end, now)
            blockReport(now)
            -- After ~3 s of waiting, attempt a one-block lateral bypass (forward only)
            if dir == "forward" and turtleWaits >= 6 and not bypassAttempted and not inBase then
                bypassAttempted = true
                if bypassForward() then
                    return true   -- position already updated inside bypassForward
                end
            end
            -- A HEAD-ON MEETING IN A ONE-BLOCK SHAFT. job_0058, 2026-09-16:
            -- node_139 climbing and node_138 descending met in one column, each
            -- waited 120 s for the other, and the climber's job failed for good.
            -- Forward meetings had a bypass; vertical ones had nothing.
            --
            -- One of them must yield, and they cannot talk, so the rule is by
            -- direction: the DESCENDING turtle steps sideways after ~3 s. The
            -- climber waits longer (~35 s) before doing the same, so a head-on
            -- pair always resolves with the descender moving, and a climber under
            -- something that will never move (a standing loader) still gets out.
            --
            -- Returns true having moved sideways, not vertically: move.to's
            -- vertical loop simply asks again from the new column, and its X/Z
            -- loops bring the turtle back afterwards. Never near the depot, whose
            -- holes are one-block shafts turtles queue in on purpose.
            if (dir == "down" or dir == "up") and not bypassAttempted
                    and turtleWaits >= (dir == "down" and 6 or 20)
                    and not base.nearDepot(_self.pos) and not inBase then
                bypassAttempted = true
                if base.sidestepOutOfColumn() then
                    logInfo(string.format(
                        "Stepped out of a shared shaft to let a turtle pass (was moving %s), now at %d,%d,%d",
                        dir, _self.pos.x, _self.pos.y, _self.pos.z))
                    return true
                end
            end
            -- Back off progressively: 0.5s → 1s → 1.5s → 2s (cap)
            sleep(math.min(2.0, 0.5 * turtleWaits))
        else
            -- Static block (terrain, gravel, etc.) — dig it
            digAttempts = digAttempts + 1
            if digAttempts > maxDig then
                return false, "blocked (" .. dir .. ")"
            end
            if digFn and _self.canDig then
                base.makeRoomBeforeDig()
                digFn()
                sleep(digAttempts <= 4 and 0.2 or 0.4)
            else
                sleep(0.3)
            end
        end
    end
end

function move.forward() return tryMove(turtle.dig,     "forward") end
function move.back()    return tryMove(nil,             "back")    end
function move.up()      return tryMove(turtle.digUp,   "up")      end
function move.down()    return tryMove(turtle.digDown, "down")    end

function move.turnLeft()
    jTurn("turnLeft")
    _self.facing = (_self.facing - 1) % 4
    writeJournal(nil)
end

function move.turnRight()
    jTurn("turnRight")
    _self.facing = (_self.facing + 1) % 4
    writeJournal(nil)
end

function move.face(dir)
    dir = dir % 4
    local diff = (dir - _self.facing) % 4
    if     diff == 1 then move.turnRight()
    elseif diff == 2 then move.turnRight(); move.turnRight()
    elseif diff == 3 then move.turnLeft()
    end
end

-- Navigate to absolute world coordinate.
-- A LEG THAT MAY BE ABANDONED. A role sets a predicate around a move it would
-- rather give up than finish -- the miner's outbound flight, while a recall may
-- arrive -- and move.to checks it before every block. 2026-09-22: node_119 was
-- recalled at 08:59 and flew 1,700 blocks on regardless, nine minutes, because
-- nothing in the flight asked. Never set around a trip home: a recall must not
-- stop a turtle that is already coming back. nil (the default) costs nothing.
function base.setMoveAbort(fn) _self.moveAbort = fn end

function move.to(tx, ty, tz)
    -- A flight to the point above the arrivals hole goes by the sky holding line
    -- when there is an ATC (ATC card, addition A): the miner's own program flies
    -- straight there, and the ATC decides who comes down the column next.
    if atc.ENABLED and not atc.skyBound and tx == W.ARRIVALS_HOLE.x and tz == W.ARRIVALS_HOLE.z
            and ty >= W.ATC.SKY_MIN_Y and atc.here() ~= "ARR" and _self.dock then
        return atc.skyArrive(ty)
    end
    -- Vertical first
    while _self.pos.y < ty do
        if _self.moveAbort and _self.moveAbort() then return false, "aborted" end
        local ok, err = move.up()
        if not ok then return false, "stuck up: " .. (err or "?") end
    end
    while _self.pos.y > ty do
        if _self.moveAbort and _self.moveAbort() then return false, "aborted" end
        local ok, err = move.down()
        if not ok then return false, "stuck down: " .. (err or "?") end
    end
    -- X axis: recalculate facing each step so a bypass overshoot auto-corrects
    -- (without this, a 2-block bypass past the target leaves facing wrong and
    --  the turtle drives away from the target forever)
    while _self.pos.x ~= tx do
        if _self.moveAbort and _self.moveAbort() then return false, "aborted" end
        if _self.pos.x < tx then move.face(1) else move.face(3) end
        local ok, err = move.forward()
        if not ok then return false, "stuck X: " .. (err or "?") end
    end
    -- Z axis: same per-step facing recalc
    while _self.pos.z ~= tz do
        if _self.moveAbort and _self.moveAbort() then return false, "aborted" end
        if _self.pos.z < tz then move.face(2) else move.face(0) end
        local ok, err = move.forward()
        if not ok then return false, "stuck Z: " .. (err or "?") end
    end
    return true
end

-- Follow an ordered list of {x,y,z} waypoints.
function move.followRoute(waypoints)
    for _, wp in ipairs(waypoints) do
        local ok, err = move.to(wp.x, wp.y, wp.z)
        if not ok then return false, err end
    end
    return true
end

-- A holding slot from the ATC; waits (outside the base) until it gives one.
-- maxS: give up after this long (nil: wait for ever), returning nil. A turtle that
-- cannot dig takes only the slot it stands under (strict); kept from it, it goes
-- back the way it came instead (home.retrace).
function atc.holdSlot(line, prefer, maxS)
    local report, last
    local since = os.clock()
    -- A turtle that cannot dig (support) takes the slot it stands under or none.
    local strict = prefer ~= nil and not _self.canDig
    -- ONLY REFUSALS COUNT (2026-11-17, T2 shakeout-side-h, node_217). Behind its
    -- delivery's slot, it asked while the ATC computer was down -- "no answer" for
    -- 120 s -- and its bound took silence for a refusal: a 192-step retrace the long
    -- way round. A silent ATC is a pause, not a refusal.
    local refusedFor, lastT = 0, since
    while true do
        local r = atc.ask(proto.MSG.ATC_REQUEST, { kind = "hold", line = line, prefer = prefer, strict = strict,
            pair = (_self.role == proto.ROLE.SUPPORT) and _self.partnerId or nil })
        last = r
        if r and r.ok and r.slot then return r.slot end
        local now = os.clock()
        if r then refusedFor = refusedFor + (now - lastT) end
        lastT = now
        if maxS and refusedFor >= maxS then return nil end
        report = report or waitReporter(function()
            return string.format("ATC: no %s holding slot yet (%s) at %d,%d,%d", line,
                last and tostring(last.why) or "no answer from the ATC", _self.pos.x, _self.pos.y, _self.pos.z)
        end, now)
        report(now)
        sleep(r and 2 or 3)
    end
end

-- The tunnel slot to ask for, from `pos`, or nil for the next one in turn.
--   * the slot whose column it stands in, anywhere SOUTH of the slot: a support
--     (which cannot dig) is in its delivery's, dug all the way up -- however far
--     it had fallen behind when the delivery stopped (five came home six blocks
--     short and met rock one column over, sim 2026-11-03);
--   * otherwise the slot its delivery named in ASCENDING / RETURN_TO_DOCK
--     (_self.partnerSlot): a support that lagged further back is somewhere on the
--     delivery's own path, and holdingApproach from there walks that path. Given
--     the next slot in turn instead, one was sent through rock and stranded in
--     the departure tunnel, and every later departure piled up behind it (sim
--     20261104-183352: 105 deliveries waiting by hour 105).
function atc.preferSlot(pos)
    local dx = pos.x - W.ARRIVALS_HOLE.x
    if dx > 0 and dx % W.ATC.HOLD_STEP == 0 and dx / W.ATC.HOLD_STEP <= W.ATC.HOLD_SLOTS
            and pos.z <= W.ATC.HOLD_Z then
        return dx / W.ATC.HOLD_STEP
    end
    return _self.partnerSlot
end

-- How long a delivery or miner at the hole waits for its support to stage: 60 s
-- without an ATC (as before), STAGE_WAIT_S under one (see base.depart).
atc.STAGE_WAIT_S = 600
function atc.stageWaitS()
    return atc.ENABLED and atc.STAGE_WAIT_S or 60
end

-- The delivery's word to its support (ASCENDING: hold; RETURN_TO_DOCK: come
-- home), naming its holding slot when it has one.
function atc.signalSupport(msgType, partnerId, slot, trailTail)
    local sig = proto.encode(msgType, _self.id, partnerId, { slot = slot, trail = trailTail })
    proto.send(_self.modem, proto.CH_LOCAL, sig)
end

-- Concatenate waypoint lists.
function atc.join(...)
    local out = {}
    for _, list in ipairs({ ... }) do for _, wp in ipairs(list) do out[#out + 1] = wp end end
    return out
end

-- Sky slot, wait there for the whole way home, then fly to the column: ends
-- standing at the top of the arrivals column, holding ARR, the route booked.
function atc.skyArrive(ty)
    atc.skyBound = true
    local k = atc.holdSlot("sky")
    logInfo(string.format("Sky arrival: to holding slot %d at y=%d", k, ty))
    local ok, err = move.followRoute(W.holdingApproach(_self.pos, k, ty))
    if ok then
        local exit = W.holdingExitRoute(k, ty)
        atc.book(atc.join(exit, { { x = W.ARRIVALS_HOLE.x, y = CFG.FLOOR_Y, z = W.ARRIVALS_HOLE.z } },
            W.returnRoute(_self.dock)), "sky arrival from slot " .. k)
        logInfo("Called down from sky slot " .. k)
        ok, err = move.followRoute(exit)
    end
    atc.skyBound = false
    return ok, err
end

base.move = move

-- ─── Depot Routing ───────────────────────────────────────────────────────────

-- Navigate from current position (dock) to the world via the dispatch hole.
-- Call this at the start of every job before heading to destination.
local departImpl
-- However a departure ends -- out of the hole, or a route that failed half way --
-- the booking is given back (all but the section it stands in). A failed one kept
-- the whole outbound route booked for good (node_3069, sim, 2026-11-03).
-- HOLE_PENDING, the delivery's "still coming" to its support (2026-11-16, T2
-- shakeout-side-c). The support waits 180 s for HOLE_READY and then gives up; under
-- the ATC a delivery can be held at its dock longer than that, so the support went
-- home and the delivery went out alone -- without the chunk loading its support
-- carries -- and froze in unloaded ground at 160,-2752 (11 times in one run). From
-- the start of a departure until HOLE_READY the control loop says "still coming"
-- every HOLE_PENDING_MS; each one restarts the support's 180 s. A delivery that has
-- died says nothing, and its support gives up as before.
local HOLE_PENDING_MS = 20000
-- R4 (docs/superpowers/specs/2026-11-17-delivery-pair-and-hole-design.md): A
-- PAIR KEEPS TOGETHER ON ITS OWN WORD. A following support that heard nothing for
-- 15 s asked the server whether its delivery was online; back from a crash, the
-- server had not heard the delivery again yet, said "offline", and the support --
-- which cannot dig -- went home alone (T2 shakeout-side-e, node_218, 02:13:29:
-- the start of jam 2 and of every stranded support). So for the whole of its job
-- the delivery tells its support it is there, every PAIR_ALIVE_MS, over the
-- turtles' own radio -- no server in it. _self.pairMate is its support for the
-- job; _self.partnerId is cleared while it delivers and is not this.
local PAIR_ALIVE_MS = 20000
local HOME_REPEAT_MS = 10000
-- THE HOLD NOTICE IS REPEATED TOO (2026-11-17, T2 shakeout-side-h). At its holding
-- slot a delivery told its support "hold; I am in slot N, by this path" ONCE; lost
-- in the server outage, node_219 stood 8.5 min in another pair's path (it held
-- node_221 120 s), and told to come home it planned its own way, from 6 cells off,
-- into rock. So the notice goes every HOME_REPEAT_MS while the delivery holds, and
-- the come-home -- which carries the path as well -- replaces it.
function atc.startHoldNotice(to, slot, trail)
    local now = os.epoch("utc")
    _self.holdNotice = { to = to, slot = slot, trail = trail, at = now, untilMs = now + 600000 }
    atc.signalSupport(proto.MSG.ASCENDING, to, slot, trail)
end
function atc.callSupportHome(to, slot)
    local trail = _self.holdNotice and _self.holdNotice.trail
    _self.holdNotice = nil
    atc.signalSupport(proto.MSG.RETURN_TO_DOCK, to, slot, trail)
    _self.callHome = { to = to, slot = slot, trail = trail, at = os.epoch("utc"), untilMs = os.epoch("utc") + 600000 }
end

function atc.keepPair(now)
    local ch = _self.callHome
    if ch then
        if now >= ch.untilMs then _self.callHome = nil
        elseif now - (ch.at or 0) >= HOME_REPEAT_MS then
            ch.at = now
            atc.signalSupport(proto.MSG.RETURN_TO_DOCK, ch.to, ch.slot, ch.trail)
        end
    end
    local hn = _self.holdNotice
    if hn then
        if now >= hn.untilMs then _self.holdNotice = nil
        elseif now - (hn.at or 0) >= HOME_REPEAT_MS then
            hn.at = now
            atc.signalSupport(proto.MSG.ASCENDING, hn.to, hn.slot, hn.trail)
        end
    end
    if _self.role ~= proto.ROLE.DELIVERY or not _self.pairMate or not _self.jobId then return end
    if now - (_self.pairAliveAt or 0) < PAIR_ALIVE_MS then return end
    _self.pairAliveAt = now
    atc.signalSupport(proto.MSG.PAIR_ALIVE, _self.pairMate)
end

-- IS MY PAIR STILL ON? (2026-11-17, sim w3_side_atc). A delivery waiting on its
-- dock to be let out with its support stops when the server calls the pair off
-- (PAIR_CANCEL) -- told once, and a blackout lost it: node_36 waited 39 min for a
-- support that had a new job, then 600 s at the hole. So while it waits it asks
-- (PAIR_ASK, every PAIR_ASK_MS); the server answers PAIR_CANCEL when the job is no
-- longer its pair's. The giveUp of its departure booking: "pair_cancelled" or nil.
local PAIR_ASK_MS = 10000
function atc.pairStillOn()
    if _self.pairCancelled then return "pair_cancelled" end
    if not (_self.partnerId and _self.jobId) or _self.serverDown then return nil end
    local now = os.epoch("utc")
    if now - (_self.pairAskedAt or 0) >= PAIR_ASK_MS then
        _self.pairAskedAt = now
        comms.toServer(proto.MSG.PAIR_ASK, { jobId = _self.jobId })
    end
    return nil
end

function atc.keepSupport(now)
    if not _self.holePendingTo or now - (_self.holePendingAt or 0) < HOLE_PENDING_MS then return end
    _self.holePendingAt = now
    atc.signalSupport(proto.MSG.HOLE_PENDING, _self.holePendingTo)
end

-- THE SUPPORT DOES NOT STEP INTO THE HOLE CELL WHILE ITS DELIVERY STANDS IN IT
-- (2026-11-16, T2 shakeout-side-d). SUPPORT_STAGED was sent once; a radio loss
-- lost it, the delivery waited on at the hole, and the support stepped forward
-- into it -- and inside the base a move blocked by a turtle waits for ever,
-- deaf to its delivery standing it down. At 600 s the delivery turned for home
-- through the support: each blocked the other's only way out, and no departure
-- was let in again. So, standing at staging and facing the hole, it says
-- SUPPORT_STAGED again every STAGED_REPEAT_S until the hole cell is empty (its
-- delivery has gone down), and gives up -- home, the job goes back -- if its
-- delivery stands it down (PARTNER_LEFT) or has not gone in STAGE_WAIT_S.
-- Returns true when the cell is clear, else false and why.
local STAGED_REPEAT_S = 5
-- EMPTY FOR CLEAR_S IN A ROW, NOT ONCE (2026-11-16, T2 w3-atc-staged-lost-c): a
-- delivery rebooted in the hole cell measures its facing by stepping out and back;
-- seen empty that moment, the support stepped in behind it as it came back, and
-- each stood in the other's only way out. A delivery that has gone down leaves
-- the cell empty; a facing check is gone in a second.
local CLEAR_S = 3
function atc.awaitHoleClear(partnerGone)
    local hole = W.DISPATCH_HOLE
    local dx, dz = hole.x - _self.pos.x, hole.z - _self.pos.z
    local adjacent = _self.pos.y == hole.y and math.abs(dx) + math.abs(dz) == 1
    if adjacent then move.face(dz < 0 and 0 or dx > 0 and 1 or dz > 0 and 2 or 3) end
    local deadline = os.epoch("utc") / 1000 + atc.stageWaitS()
    local nextSay, report, emptySince = 0, nil, nil
    while true do
        local now = os.epoch("utc") / 1000
        if now >= nextSay then
            nextSay = now + STAGED_REPEAT_S
            proto.send(_self.modem, proto.CH_LOCAL, proto.encode(proto.MSG.SUPPORT_STAGED, _self.id, _self.partnerId, {}))
        end
        sleep(1)
        if partnerGone() then return false, "partner_left" end
        if base.isRecalled() then return false, "recalled" end
        if not adjacent then return true end
        if isTurtleBlock("forward") then
            emptySince = nil
        else
            emptySince = emptySince or now
            if now - emptySince >= CLEAR_S then return true end
        end
        if now >= deadline then
            logWarn(string.format("Delivery %s still in the hole cell after %ds -- not stepping into it; home, the job goes back",
                tostring(_self.partnerId), atc.stageWaitS()))
            return false, "delivery_never_descended"
        end
        report = report or waitReporter(function()
            return string.format("delivery %s still in the hole cell -- SUPPORT_STAGED repeated", tostring(_self.partnerId))
        end, os.clock())
        report(os.clock())
    end
end

-- R1 (docs/superpowers/specs/2026-11-17-delivery-pair-and-hole-design.md): A
-- DELIVERY MOVES ONLY ONCE ITS SUPPORT HAS ACCEPTED TOO. side-e jam 1: the
-- support it was given refused, and the delivery went out regardless and held
-- the dispatch hole 600 s for nobody. Accepted, it waits on its dock -- a known
-- place, in no section -- for the server's PAIR_GO, asking (PAIR_ASK) every 5 s
-- so a lost answer is asked again. PAIR_CANCEL: the pair is off, the job goes
-- back to be paired again; it stays docked. Not a timer for traffic: PAIR_LAST_S
-- is only for a server that never answers, and freezes while it is down.
local PAIR_LAST_S = 300
function base.awaitPairGo(jobId)
    local want = { [proto.MSG.PAIR_GO] = true, [proto.MSG.PAIR_CANCEL] = true }
    local waited, nextAsk = 0, 0
    logInfo("Waiting for my support to accept too (PAIR_GO)...")
    while true do
        if base.isRecalled() then return false, "recalled" end
        if not _self.serverDown and waited >= nextAsk then
            comms.toServer(proto.MSG.PAIR_ASK, { jobId = jobId })
            nextAsk = waited + 5
        end
        local msg = base.receive(1, want)
        if msg and type(msg.payload) == "table" and msg.payload.jobId == jobId then
            if msg.type == proto.MSG.PAIR_GO then
                logInfo("Pair on: my support has accepted too -- going")
                return true
            end
            logWarn("Pair off (" .. tostring(msg.payload.reason) .. ") -- staying docked; the job goes back to be paired again")
            return false, "pair_cancelled"
        end
        if not _self.serverDown then waited = waited + 1 end
        if waited >= PAIR_LAST_S then return false, "no_pair_go" end
    end
end

-- R2: A SUPPORT ASKS FOR ITS WAY OUT FROM ITS DOCK, WITH ITS DELIVERY, as soon as
-- it has its job: the ATC lets the pair in as one unit, so once its delivery is
-- at the hole its own way is already its, and nothing in between can hold it
-- back. It asks every 2 s until let in (atc.book), so a half that reboots and
-- asks again is the same request. It stops only on its delivery's word, a
-- recall, the pair being called off, or -- the last line, for a delivery that
-- died -- PREBOOK_SILENT_S with no word from its delivery at all.
local PREBOOK_SILENT_S = 180
function base.prebookDeparture()
    if not _self.dock or not _self.partnerId then return true end
    local route = W.supportDepartureRoute(_self.dock)
    atc.group, atc.pair = _self.partnerId, _self.partnerId
    local function giveUp()
        if base.partnerLeft() then return "partner_left" end
        if base.isRecalled() then return "recalled" end
        if _self.pairCancelled then return "pair_cancelled" end
        if (os.epoch("utc") - base.partnerHeardAt()) / 1000 > PREBOOK_SILENT_S then return "no_word_from_delivery" end
        return nil
    end
    local booked, why = atc.book(atc.join(route, { { x = W.DISPATCH_HOLE.x, y = W.DISPATCH_HOLE.y, z = W.DISPATCH_HOLE.z } }),
        "departure (with my delivery)", giveUp)
    atc.pair = nil
    return booked, why
end

local REVIVE_SIDE = { forward = "front", up = "top", down = "bottom" }
function base.reviveIfOff(dir)
    local side = REVIVE_SIDE[dir]
    if not side or peripheral.getType(side) ~= "turtle" then return false end
    if peripheral.call(side, "isOn") ~= false then return false end
    local who = peripheral.call(side, "getID")
    peripheral.call(side, "turnOn")
    logWarn(string.format("A turtle (#%s) in my way %s at %d,%d,%d was OFF -- turned it back on",
        tostring(who), dir, _self.pos.x, _self.pos.y, _self.pos.z))
    return true
end

function base.depart(noDescend)
    if _self.role == proto.ROLE.DELIVERY and _self.partnerId then
        _self.holePendingTo, _self.holePendingAt = _self.partnerId, 0
        atc.keepSupport(os.epoch("utc"))
    end
    local ok, a, b = pcall(departImpl, noDescend)
    _self.holePendingTo = nil
    atc.finish(ok and a == true and not noDescend)
    atc.group = nil
    atc.pair = nil
    if not ok then error(a, 0) end
    return a, b
end

function departImpl(noDescend)
    if not _self.dock then logWarn("No dock assigned, departing from current pos.") return true end

    -- AWAY FROM ITS DOCK, GO HOME FIRST (2026-11-14, T2 shakeout-side-a). Every
    -- departure route below starts at the dock. A job given back to a turtle that
    -- was somewhere else began this departure where it stood: node_208 timed out
    -- waiting for the warehouse at its destination (196,67,-2761), got the job
    -- again, drove straight north through the support rows into node_216 parked on
    -- its dock, and held the whole outbound route for 50 minutes with every
    -- departure in the base behind it. node_210, given its job back inside the
    -- dispatch shaft, drove up the shaft into its own support coming down.
    -- So home first, the way any returning turtle comes (the inside way from the
    -- floor, else down, the holding line and the arrivals hole), then out as usual.
    -- Its partner is waiting on its own dock for HOLE_READY: the trip home must not
    -- signal it (home.dock tells a partner it is ascending), so it is set aside.
    gpsSync()
    if _self.pos.x ~= _self.dock.x or _self.pos.z ~= _self.dock.z or _self.pos.y ~= CFG.FLOOR_Y then
        logWarn(string.format("Asked to depart at %d,%d,%d, away from my dock %d,%d -- going home first",
            _self.pos.x, _self.pos.y, _self.pos.z, _self.dock.x, _self.dock.z))
        local partner = _self.partnerId
        _self.partnerId = nil
        local okHome, homeErr = base.returnToDock()
        _self.partnerId = partner
        atc.finish()
        if not okHome then return false, "could not get home to depart: " .. tostring(homeErr) end
    end

    -- Pre-departure fuel reserve check. A flat critical threshold isn't enough for a
    -- full warehouse run, so require a conservative reserve before leaving the dock.
    if turtle.getFuelLevel() < CFG.FUEL_RESERVE then
        logWarn(string.format("Pre-departure fuel check: %d < %d, attempting refuel",
            turtle.getFuelLevel(), CFG.FUEL_RESERVE))
        base.fuel.dockRefuel()
        if turtle.getFuelLevel() < CFG.FUEL_RESERVE then
            base.setStatus(proto.STATUS.ERROR)
            comms.toServer(proto.MSG.STATUS_UPDATE, proto.payloadStatusUpdate(
                _self.jobId, proto.STATUS.ERROR, "insufficient fuel for departure", base.getPos()))
            return false, "insufficient fuel for departure (have " .. turtle.getFuelLevel()
                .. ", need " .. CFG.FUEL_RESERVE .. ")"
        end
    end

    logInfo("Departing via dispatch lane...")
    base.setStatus(proto.STATUS.TRAVELLING)

    -- GPS resync from dock position before precision bay navigation.
    -- Corrects any position drift from previous trips so the aisle routes are exact.
    gpsSync()
    -- Face toward taxiway before departing — consistent starting orientation.
    move.face(W.dockFacing(_self.dock))

    if _self.role == proto.ROLE.DELIVERY or _self.role == proto.ROLE.MINER then
        -- ── Delivery / Miner departure ────────────────────────────────────────
        -- Navigate to hole entrance, signal support, wait for support to stage
        -- behind us, THEN descend so they go down together.

        local route = W.departureRoute(_self.dock)
        atc.group = _self.id
        -- R2: let out only with its support, as one unit (atc.lua); it waits here, on
        -- its dock. A pair the server called off (its support dropped out) ends it.
        atc.pair = _self.partnerId
        local bookedOut, whyNot = atc.book(route, "departure", atc.pairStillOn, atc.departurePath())
        if not bookedOut then return false, whyNot end
        local ok, err = move.followRoute(route)
        if not ok then return false, "departure route failed: " .. (err or "?") end

        if _self.partnerId then
            -- Signal support to start its departure route
            logInfo("At hole — signalling support to stage...")
            _self.holePendingTo = nil
            local sig = proto.encode(proto.MSG.HOLE_READY, _self.id, _self.partnerId, {})
            proto.send(_self.modem, proto.CH_LOCAL, sig)

            -- Wait for support to reach staging position (1 block behind us)
            -- Loop so we don't consume unrelated messages (heartbeat ACKs etc.)
            -- Under the ATC the support's way to the hole is granted like any other,
            -- and other traffic can hold it back minutes (a silent turtle keeps its
            -- sections STALE_MS, 3 min). A delivery that went down alone after 60 s
            -- left its support to come out late and chase it in a straight line --
            -- through rock it cannot dig -- stranded in the departure tunnel, and
            -- every later departure piled up behind it (sim, 105 deliveries waiting;
            -- sandbox/scenarios/w3_atc_pair_split.lua). So it waits STAGE_WAIT_S.
            logInfo("Waiting for SUPPORT_STAGED...")
            local deadline = os.epoch("utc") / 1000 + atc.stageWaitS()
            local staged, gaveUp = false, nil
            while os.epoch("utc") / 1000 < deadline do
                if base.isRecalled() then break end
                local msg = base.receive(5)
                if not msg then
                    -- timeout tick — keep waiting
                elseif msg.type == proto.MSG.SUPPORT_STAGED and msg.from == _self.partnerId
                       and (tonumber(msg.ts) or 0) >= (_self.jobSince or 0) then
                    -- From THIS job only: its support repeats SUPPORT_STAGED until the
                    -- hole is clear (atc.awaitHoleClear), so copies are left over.
                    logInfo("Support staged — descending together.")
                    staged = true
                    break
                elseif msg.type == proto.MSG.JOB_ABORT and msg.from == _self.partnerId
                       and (tonumber(msg.ts) or 0) >= (_self.jobSince or 0) then
                    -- From THIS job only: a JOB_ABORT left in the inbox from the pair's
                    -- last job sent node_32 down alone the moment it reached the hole
                    -- (sim w3_side_atc, "Support node_55 gave up (recalled)").
                    -- The support has given up on this job (it waits only 180 s for
                    -- HOLE_READY, and under the ATC a departure can take longer to be
                    -- let in). Waiting out STAGE_WAIT_S for it held the dispatch hole
                    -- 10 minutes per pair, and every pair behind timed out the same
                    -- way (w3_bay_types150, 2026-11-12: 12 supports, a 16,140 s wait).
                    gaveUp = msg.payload and msg.payload.reason or "its job was aborted"
                    break
                end
                -- Any other message (HEARTBEAT_ACK etc.) is silently ignored here;
                -- controlLoop also receives it via parallel and handles it there.
            end
            if base.isRecalled() then return true end
            -- NEVER OUT WITHOUT ITS SUPPORT (2026-11-16, T2 shakeout-side-c). The
            -- support is the delivery's chunk loader: a delivery that went down
            -- alone travelled into ground nobody loaded and froze there (160,-2752,
            -- 11 times in one run). So it does not go: it tells a support still
            -- coming to stand down, goes home, and the job goes back to be sent
            -- again with a support (departure_failed, recoverable). It does not
            -- hold the dispatch hole meanwhile: the ATC booking is given back here.
            if gaveUp or not staged then
                local partner = _self.partnerId
                if gaveUp then
                    logWarn(string.format("Support %s gave up (%s) -- not going out without it; home, and the job goes back",
                        tostring(partner), tostring(gaveUp)))
                else
                    logWarn(string.format("Support %s never staged in %ds -- not going out without it; told it to stand down",
                        tostring(partner), atc.stageWaitS()))
                    base.atc.signalSupport(proto.MSG.PARTNER_LEFT, partner)
                end
                -- Told already (or it told us): no JOB_ABORT from sendFailed, which
                -- a support given a new job with this delivery would take as its own.
                _self.partnerId = nil
                atc.finish()
                base.returnToDock()
                return false, "support " .. tostring(partner) .. " not with me (" .. tostring(gaveUp or "never staged") .. ")"
            end
        end

        if not noDescend then
            logInfo("Descending dispatch hole...")
            for _ = 1, 10 do
                move.down()
                if _self.pos.y <= W.WORLD_EXIT.y then break end
            end
        end

    else
        -- ── Support departure ─────────────────────────────────────────────────
        -- Navigate to 1 block before the hole (staging), signal delivery,
        -- then move to hole and descend.

        local route = W.supportDepartureRoute(_self.dock)
        -- One party with the delivery it follows: it may share the dispatch
        -- corner its partner is holding for it.
        atc.group = _self.partnerId
        atc.pair = _self.partnerId
        local function partnerGone() return base.partnerLeft() and "partner_left" end
        local booked, why = atc.book(atc.join(route, { { x = W.DISPATCH_HOLE.x, y = W.DISPATCH_HOLE.y, z = W.DISPATCH_HOLE.z } }),
            "departure", partnerGone)
        if not booked then
            logWarn("Delivery " .. tostring(_self.partnerId) .. " stood me down (not going out without me) -- staying docked")
            return false, why
        end
        local ok, err = move.followRoute(route)
        if not ok then return false, "departure route failed: " .. (err or "?") end

        -- At staging position — tell delivery it can descend, and wait for it to
        -- go before stepping into the hole cell it stands in.
        if _self.partnerId then
            logInfo("Staged behind hole — signalling delivery to descend.")
            local clear, why = atc.awaitHoleClear(partnerGone)
            if not clear then
                if why == "partner_left" then
                    logWarn("Delivery " .. tostring(_self.partnerId) .. " stood me down (not going out without me) -- back to my dock, not down the hole")
                end
                atc.finish()
                base.returnToDock()
                return false, why
            end
        else
            -- Brief pause so delivery starts descending first (clears the hole entrance)
            sleep(1)
        end

        -- Its delivery may have gone down without it while it came: do not follow
        -- a turtle that has left -- back to the dock, and the job goes back.
        if _self.partnerId and partnerGone() then
            logWarn("Delivery " .. tostring(_self.partnerId) .. " stood me down (not going out without me) -- back to my dock, not down the hole")
            atc.finish()
            base.returnToDock()
            return false, "partner_left"
        end

        -- Move to hole and descend
        move.to(W.DISPATCH_HOLE.x, W.DISPATCH_HOLE.y, W.DISPATCH_HOLE.z)
        if not noDescend then
            logInfo("Descending dispatch hole...")
            for _ = 1, 10 do
                move.down()
                if _self.pos.y <= W.WORLD_EXIT.y then break end
            end
        end
    end

    logInfo(string.format("Exited depot at %d,%d,%d", _self.pos.x, _self.pos.y, _self.pos.z))
    return true
end

-- Navigate from the world back to dock via arrivals hole.
-- Call this when turtle is outside/underground after completing a job.
-- Always goes underground first then up through the arrivals hole.
-- Confirm we are actually standing on the dock before anything claims we are.
-- Returns true, or false plus a reason.
--
-- The block this replaces corrected and then DISCARDED the result: the turtle
-- knew it was in the wrong place, logged it, attempted a fix, and reported
-- success regardless. Observed 2026-08-25 -- node_119 was found at
-- 228,210,-2782, which is exactly ARRIVALS_HOLE's x/z at its sky travel
-- altitude, 143 blocks above its own dock, reporting phase DOCKED and status
-- IDLE. IDLE is dispatchable, so the next mine job would have started from
-- there. Its fuel had jumped +87,737, which is dockRefuel falling back to
-- deploying its own ender chest because the dock station was 143 blocks below --
-- a chest left somewhere nobody would look.
--
-- Two properties this must keep:
--   * re-sync AFTER the correction, not only before it. The correction moves the
--     turtle, so the belief that justified it is stale by the time it returns.
--   * never let the caller refuel on this path. That refuel is what abandoned
--     the chest.
local function verifyAtDock()
    local FLOOR_Y = CFG.FLOOR_Y
    gpsSync()
    if _self.pos.x == _self.dock.x and _self.pos.z == _self.dock.z then return true end

    logWarn(string.format("Post-dock GPS mismatch: at %d,%d want %d,%d — correcting",
        _self.pos.x, _self.pos.z, _self.dock.x, _self.dock.z))
    local ok2, err2 = move.to(_self.dock.x, FLOOR_Y, _self.dock.z)
    gpsSync()
    if ok2 and _self.pos.x == _self.dock.x and _self.pos.z == _self.dock.z then
        return true
    end
    return false, string.format("dock not reached: at %d,%d,%d want %d,%d (%s)",
        _self.pos.x, _self.pos.y, _self.pos.z,
        _self.dock.x, _self.dock.z, tostring(err2))
end

local home = {}
function home.dock()
    if not _self.dock then logWarn("No dock assigned, staying put.") return true end

    -- Already inside the building, on its floor: the way home is the inside one.
    -- Down through the floor to the tunnel was tried by supports whose delivery
    -- never called them (they cannot dig, so it failed in the dock; sim, 2026-11-03).
    if _self.pos.y == CFG.FLOOR_Y and base.isInsideBuilding(_self.pos) then
        return home.internal()
    end

    base.setStatus(proto.STATUS.RETURNING)

    local FLOOR_Y       = CFG.FLOOR_Y
    local UNDERGROUND_Y = W.WORLD_ENTRY.y  -- 60

    -- If turtle is at surface level outside, descend to underground travel Y first
    if _self.pos.y >= FLOOR_Y then
        logInfo("Descending to underground travel level...")
        local ok, err = move.to(_self.pos.x, UNDERGROUND_Y, _self.pos.z)
        if not ok then
            logWarn("Could not descend fully: " .. (err or "?"))
        end
    end

    -- Stop position broadcasts and tell support to hold BEFORE ascending.
    -- Clearing partnerId immediately is critical: if support misses the ASCENDING
    -- signal (it can happen if support is mid-move.to()), it would otherwise keep
    -- following POSITION_UPDATEs all the way to the surface and block delivery.
    local savedPartnerId, savedSlot = nil, nil
    local function holdSupport(slot)
        if _self.partnerId and _self.role == proto.ROLE.DELIVERY then
            savedPartnerId  = _self.partnerId
            savedSlot       = slot
            _self.partnerId = nil   -- kills all further POSITION_UPDATE broadcasts NOW
            -- Send ASCENDING so support knows to hold (best-effort; if missed it's OK
            -- because broadcasts have already stopped so support gets no more updates).
            -- It names the holding slot: a support that lagged comes to the same one,
            -- along the path this turtle just dug (base.atc.preferSlot).
            -- And the tail of its own path (R3): a support that lagged walks these
            -- dug cells up behind it rather than planning a way through rock.
            base.atc.startHoldNotice(savedPartnerId, slot, base.trailTail(base.TRAIL_TAIL_N))
            sleep(0.5)
        end
    end

    local ok, err
    if base.atc.ENABLED then
        -- THE HOLDING LINE (ATC card, 2026-11-03). Not straight for the hole --
        -- every returning turtle aiming at one cell is what piled twenty of them
        -- into the tunnel. A slot from the ATC, reached from the far side so it
        -- never crosses the taxi row; the support stops one block behind, in the
        -- slot's own column; then up the shaft only once the whole way home is
        -- free.
        -- Which slot to ask for: base.atc.preferSlot (the column it stands in, or
        -- its delivery's slot for a support that lagged behind on the way).
        -- A turtle that cannot dig, in the dispatch shaft or at its foot, goes back up
        -- it: the way in is overhead, and it stands in DH. Asking for a holding slot
        -- from there held DH while it waited for its delivery's slot, which its
        -- delivery sat in waiting for sections held by departures waiting for DH
        -- (sim w3_side_atc, node_55 at 143,60,-2813 to the end of the run).
        if not _self.canDig and atc.here() == "DH" then
            return home.retrace("in the dispatch shaft")
        end
        local k = base.atc.holdSlot("tunnel", base.atc.preferSlot(_self.pos), (not _self.canDig) and 120 or nil)
        if not k then return home.retrace("no holding slot of mine in 120 s") end
        _self.partnerSlot = nil
        logInfo("Navigating underground to holding slot " .. k .. "...")
        ok, err = move.followRoute(W.holdingApproach(_self.pos, k, UNDERGROUND_Y))
        if not ok and not _self.canDig then
            return home.retrace("could not reach holding slot " .. k .. ": " .. (err or "?"))
        end
        if not ok then return false, "could not reach holding slot " .. k .. ": " .. (err or "?") end
        holdSupport(k)
        local exit, home = W.holdingExitRoute(k), W.returnRoute(_self.dock)
        local whole = {}
        for _, wp in ipairs(exit) do whole[#whole + 1] = wp end
        for _, wp in ipairs(home) do whole[#whole + 1] = wp end
        base.atc.book(whole, "return from holding slot " .. k)
        logInfo("Called up from holding slot " .. k .. " -- ascending arrivals hole...")
        ok, err = move.followRoute(exit)
        if not ok then return false, "could not leave holding slot " .. k .. ": " .. (err or "?") end
    else
        -- Navigate underground to arrivals hole X,Z
        -- Support is following via position broadcasts so it arrives right behind us
        logInfo("Navigating underground to arrivals hole...")
        ok, err = move.to(W.ARRIVALS_HOLE.x, UNDERGROUND_Y, W.ARRIVALS_HOLE.z)
        if not ok and not _self.canDig then
            return home.retrace("could not reach arrivals hole: " .. (err or "?"))
        end
        if not ok then return false, "could not reach arrivals hole: " .. (err or "?") end
        holdSupport()

        -- Ascend through arrivals hole into building (no POSITION_UPDATEs, partnerId is nil)
        logInfo("Ascending arrivals hole...")
        for _ = 1, 10 do
            move.up()
            if _self.pos.y >= FLOOR_Y then break end
        end
    end

    -- GPS resync now that we're on the surface — corrects any drift from underground
    -- travel before precision bay navigation (tight corridors, 1-block clearance).
    gpsSync()

    -- Navigate to red taxiway to fully clear the arrivals hole exit, THEN signal
    -- support so it has room to ascend without colliding with us.
    if savedPartnerId then
        move.to(W.ARRIVALS_HOLE.x, FLOOR_Y, W.RED_Z)
        logInfo("Clear of arrivals hole — signalling support to return.")
        -- REPEATED UNTIL HEARD (R3): sent once, it was lost in a radio blackout and
        -- its support held in the holding line until the 300 s silence rule sent it
        -- home (sim w3_side_atc, node_55). atc.keepPair repeats it every
        -- HOME_REPEAT_MS, after this job too, until the support answers HOME_HEARD.
        -- It carries the path, for a support that missed the hold notice.
        base.atc.callSupportHome(savedPartnerId, savedSlot)
        -- partnerId already nil, nothing more to clear
    end

    -- Follow red taxiway back to dock
    local route = W.returnRoute(_self.dock)
    ok, err = move.followRoute(route)
    if not ok then
        base.setStatus(proto.STATUS.ERROR)
        comms.toServer(proto.MSG.STATUS_UPDATE, proto.payloadStatusUpdate(
            _self.jobId, proto.STATUS.ERROR, "return route failed: " .. (err or "?"), base.getPos()))
        return false, "return route failed: " .. (err or "?")
    end

    -- GPS verify final dock position; correct if off by 1 from route rounding.
    -- A turtle that is NOT at its dock must not report that it is: IDLE plus
    -- DOCKED is dispatchable, and the next job would start from wherever it
    -- actually is. ERROR keeps it out of registry.getIdle until someone looks.
    local atDock, dockErr = verifyAtDock()
    if not atDock then
        base.setStatus(proto.STATUS.ERROR)
        return false, dockErr
    end

    -- Face toward the taxiway so departure always starts from the same orientation.
    -- This makes the first move (toward the back aisle) consistent and predictable.
    move.face(W.dockFacing(_self.dock))

    logInfo("Docked at bay " .. _self.dock.bay .. " row " .. _self.dock.row)
    pcall(base.sendProgress, "docked")   -- ends a recovery hold, any role (release 3)

    -- All roles top up fuel at dock (dockRefuel skips at ≥80% so miners at full are unaffected).
    base.fuel.dockRefuel()

    return true
end

-- Sky-path variant of returnToDock: ascend to Y=200, fly to arrivals hole at
-- altitude, then descend through the hole and follow the normal return route.
-- Use for mining recall where both turtles come back via the sky rather than
-- navigating underground (which risks terrain collisions from deep scan depths).
function home.fromSky()
    if not _self.dock then logWarn("No dock assigned, staying put.") return true end

    base.setStatus(proto.STATUS.RETURNING)

    local FLOOR_Y     = CFG.FLOOR_Y
    local SKY_RETURN_Y = 200

    -- 1. Ascend straight up to sky altitude from current position
    logInfo("Ascending to sky Y=" .. SKY_RETURN_Y .. " for sky return...")
    move.to(_self.pos.x, SKY_RETURN_Y, _self.pos.z)

    -- 2. Fly at sky altitude to directly above arrivals hole (move.to is vertical-first,
    --    so targeting the same Y means only X then Z movement happens here)
    logInfo("Flying to arrivals hole at Y=" .. SKY_RETURN_Y .. "...")
    move.to(W.ARRIVALS_HOLE.x, SKY_RETURN_Y, W.ARRIVALS_HOLE.z)

    -- 3. Descend straight down through the arrivals hole to floor level -- once
    --    the whole way home is free (a no-op without an ATC, and when the sky
    --    holding line already booked it).
    atc.book(atc.join({ { x = W.ARRIVALS_HOLE.x, y = FLOOR_Y, z = W.ARRIVALS_HOLE.z } }, W.returnRoute(_self.dock)),
        "sky return")
    logInfo("Descending through arrivals hole...")
    local ok, err = move.to(W.ARRIVALS_HOLE.x, FLOOR_Y, W.ARRIVALS_HOLE.z)
    if not ok then
        base.setStatus(proto.STATUS.ERROR)
        return false, "sky descent failed: " .. (err or "?")
    end

    gpsSync()

    -- 4. Follow standard return route from arrivals hole to dock
    local route = W.returnRoute(_self.dock)
    ok, err = move.followRoute(route)
    if not ok then
        base.setStatus(proto.STATUS.ERROR)
        return false, "sky return route failed: " .. (err or "?")
    end

    local atDock, dockErr = verifyAtDock()
    if not atDock then
        base.setStatus(proto.STATUS.ERROR)
        return false, dockErr
    end

    move.face(W.dockFacing(_self.dock))
    logInfo("Docked at bay " .. _self.dock.bay .. " row " .. _self.dock.row)
    pcall(base.sendProgress, "docked")   -- ends a recovery hold, any role (release 3)

    -- All roles top up fuel at dock (dockRefuel skips at ≥80% so miners at full are unaffected).
    base.fuel.dockRefuel()

    return true
end

-- Navigate from anywhere inside the building back to dock.
-- Uses an aisle route that moves Z first so the turtle never cuts
-- through occupied dock rows.  Safe to call from any floor position.
-- BACK THE WAY IT CAME, for a turtle that cannot dig and whose way home is shut
-- (see trail above). Each step is onto the cell it stood in before this one, so
-- it needs no digging; the move layer asks the ATC before the dispatch shaft (DH),
-- as for any step into a section, so it climbs only when no departure holds it.
-- On the building's floor -- the top of the dispatch hole, where the trail began --
-- it goes home the inside way. Every role that cannot dig, not supports only.
function home.retrace(why)
    local cells = trail.cells
    if #cells < 2 then return false, tostring(why) .. "; and no way back is known (trail empty)" end
    logWarn(string.format("Cannot dig and the way home is shut (%s) -- retracing the %d step(s) I came by",
        tostring(why), #cells - 1))
    atc.finish()
    -- THE CLIMB IS BOOKED BEFORE THE NO-SIDESTEP ZONE (base.nearDepot). It went
    -- back along the departures' own tunnel; waiting for the dispatch shaft at the
    -- foot of it, it stood in the one cell a delivery coming down needed, and near
    -- the depot neither may step aside: node_53 and node_37 at 142/143,60,-2813 to
    -- the end of the run (sim w3_side_atc). So the shaft and the way home inside
    -- are asked for out in the open tunnel, where a delivery coming the other way
    -- digs round a turtle in its path; once they are its, nobody comes down.
    -- (D): ITS WAY BACK IS BOOKED AT THE ZONE'S EDGE, THE CLIMB AT THE SHAFT. Booked at the
    -- edge, the shaft and the way home inside held every departure, whichever way it went,
    -- for the whole walk back (sim w3_retrace_head_on). Its path keeps a departure the other
    -- way off its cells; at the shaft's foot -- still holding the cell it stands in -- it asks
    -- for the shaft and the way home, and that ends its path.
    local booked, climbed = not atc.ENABLED, not atc.ENABLED
    local path = atc.ENABLED and atc.retracePath() or nil
    if not path then booked = climbed end
    while #trail.cells > 1 and not (_self.pos.y == CFG.FLOOR_Y and base.isInsideBuilding(_self.pos)) do
        local n = #trail.cells
        local p = trail.cells[n - 1]
        local atShaft = atc.section(p.x, p.y, p.z) == "DH"      -- the dispatch shaft, not a section on the way
        if not booked and path and (base.nearDepot(p) or base.nearDepot(_self.pos)) then
            booked = true
            atc.book({}, "back the way I came (its path)", nil, path)
        end
        if not climbed and (atShaft or (not path and (base.nearDepot(p) or base.nearDepot(_self.pos)))) then
            climbed, booked = true, true
            atc.book(atc.join({ { x = W.WORLD_EXIT.x, y = W.WORLD_EXIT.y, z = W.WORLD_EXIT.z },
                                { x = W.DISPATCH_HOLE.x, y = CFG.FLOOR_Y, z = W.DISPATCH_HOLE.z } },
                W.internalReturnRouteFrom(_self.dock, W.DISPATCH_HOLE.x, W.DISPATCH_HOLE.z)), "back the way I came", nil,
                -- the cell it stands in goes with it: asking anew ends its path, and waiting
                -- for the shaft it would stand in a cell a departure could be let out into
                path and { { x = _self.pos.x, y = _self.pos.y, z = _self.pos.z }, kind = "back", standing = true } or nil)
        end
        local ok, err = move.to(p.x, p.y, p.z)
        if not ok then
            return false, string.format("%s; retracing stopped at %d,%d,%d: %s", tostring(why),
                _self.pos.x, _self.pos.y, _self.pos.z, tostring(err))
        end
        if #trail.cells >= n then
            return false, string.format("%s; retracing lost its way at %d,%d,%d", tostring(why),
                _self.pos.x, _self.pos.y, _self.pos.z)
        end
    end
    if not (_self.pos.y == CFG.FLOOR_Y and base.isInsideBuilding(_self.pos)) then
        return false, tostring(why) .. "; the way back ran out before the building"
    end
    logInfo(string.format("Back in the building at %d,%d,%d by the way I came -- homing inside",
        _self.pos.x, _self.pos.y, _self.pos.z))
    return home.internal()
end

function home.internal()
    if not _self.dock then return true end
    -- GPS sync first so current position is accurate
    gpsSync()
    -- Re-derive heading from GPS before following the route. A physical bump or
    -- chunk reload can desync _self.facing; a wrong heading here causes the most
    -- damage (cutting across occupied dock rows), so correct it up front.
    detectFacing()
    -- Already at dock? Just orient and done.
    if _self.pos.x == _self.dock.x and _self.pos.z == _self.dock.z then
        move.face(W.dockFacing(_self.dock))
        logInfo("Already at dock bay " .. _self.dock.bay .. " row " .. _self.dock.row)
        return true
    end
    base.setStatus(proto.STATUS.RETURNING)
    logInfo(string.format("Homing to dock from %d,%d,%d...",
        _self.pos.x, _self.pos.y, _self.pos.z))
    -- Position-aware route: moves Z to the red taxiway FIRST at the current X
    -- column so the turtle never traverses another dock row sideways.
    local route = W.internalReturnRouteFrom(_self.dock, _self.pos.x, _self.pos.z)
    atc.book(route, "homing inside the base")
    local ok, err = move.followRoute(route)
    if not ok then
        base.setStatus(proto.STATUS.ERROR)
        comms.toServer(proto.MSG.STATUS_UPDATE, proto.payloadStatusUpdate(
            _self.jobId, proto.STATUS.ERROR, "internal return route failed: " .. (err or "?"), base.getPos()))
        return false, "internal return failed: " .. (err or "?")
    end
    -- GPS verify — correct any sub-block drift before accepting future jobs.
    gpsSync()
    if _self.pos.x ~= _self.dock.x or _self.pos.z ~= _self.dock.z then
        logWarn(string.format("Post-dock mismatch: at %d,%d want %d,%d — correcting",
            _self.pos.x, _self.pos.z, _self.dock.x, _self.dock.z))
        move.to(_self.dock.x, CFG.FLOOR_Y, _self.dock.z)
    end
    move.face(W.dockFacing(_self.dock))
    logInfo("Docked at bay " .. _self.dock.bay .. " row " .. _self.dock.row)
    pcall(base.sendProgress, "docked")   -- ends a recovery hold, any role (release 3)
    if not _self.canDig then base.fuel.dockRefuel() end
    return true
end

-- A trip home moves with the server down (ATC card, requirement 7) and gives
-- back whatever it booked when it ends, docked or not.
local function homing(fn)
    return function()
        _self.homing = true
        local ok, a, b = pcall(fn)
        _self.homing = false
        atc.finish()
        if not ok then error(a, 0) end
        -- Said here, for every role: support_turtle ignores what returnToDock
        -- returns, and node_81 was left in the tunnel with no word of why (sim,
        -- 2026-11-03).
        if a == false then
            logWarn(string.format("Return home failed at %d,%d,%d: %s", _self.pos.x, _self.pos.y, _self.pos.z, tostring(b)))
        end
        return a, b
    end
end
base.returnToDock         = homing(home.dock)
base.returnToDockFromSky  = homing(home.fromSky)
base.returnToDockInternal = homing(home.internal)

-- ─── Fuel ────────────────────────────────────────────────────────────────────
-- Turtles carry an entangled chest in a reserved slot.
-- Delivery turtles use slot 15 (slot 16 is reserved for the delivery ender chest).
-- Support/chunk-loader turtles use slot 16.
-- Set by base.init() based on role.

local CHEST_SLOT = 16  -- overridden to 15 for DELIVERY role in base.init()
-- !! Set this to the exact item ID of your entangled chest mod !!
-- Common: "entangled:entangled_tile"  "enderstorage:ender_chest"
local CHEST_ITEM = "enderstorage:ender_chest"

local fuel = {}

function fuel.level()      return turtle.getFuelLevel() end
function fuel.max()        return turtle.getFuelLimit()  end
function fuel.isCritical() return fuel.level() < CFG.FUEL_CRITICAL end

-- Find or make a free adjacent side for placing the chest.
-- Preference: down → up → front.
-- If all blocked, digs a hole rather than giving up.
-- Returns placeFn, digFn, suckFn, cleanupFn
-- cleanupFn fills the dug hole back in after (nil if nothing was dug)
local function findFreeSpace()
    -- Check existing free spaces first (no digging needed)
    if not turtle.detectDown() then
        return turtle.placeDown, turtle.digDown, turtle.suckDown, nil
    elseif not turtle.detectUp() then
        return turtle.placeUp, turtle.digUp, turtle.suckUp, nil
    elseif not turtle.detect() then
        return turtle.place, turtle.dig, turtle.suck, nil
    end

    -- All sides blocked
    if not _self.canDig then
        -- No pickaxe (support turtle) — can't dig, report and give up
        logWarn("Surrounded and no pickaxe — cannot deploy chest. Waiting for clear space...")
        return nil
    end

    -- Has pickaxe — dig a temporary hole.
    -- Guarded: a turtle that finds itself surrounded AT A DOCK is surrounded by
    -- other docked turtles, by construction. This is the most crowded part of the
    -- map and these were three raw digs with no inspection at all.
    logWarn("Surrounded — digging temporary refuel hole...")
    if digGuarded("down") then
        return turtle.placeDown, turtle.digDown, turtle.suckDown, nil
    end
    if digGuarded("up") then
        return turtle.placeUp, turtle.digUp, turtle.suckUp, nil
    end
    if digGuarded("forward") then
        return turtle.place, turtle.dig, turtle.suck, nil
    end

    -- Completely surrounded by unbreakable blocks
    return nil
end

-- Slots we never burn fuel from or suck coal into.
-- Delivery: slot 15 = fuel EC, slot 16 = delivery EC.
-- Support:  slot 16 = fuel EC, slot 15 kept free as safety margin.
-- Both roles: only use slots 1-BURN_MAX for fuel operations.
local BURN_MAX = 14   -- updated to CHEST_SLOT-1 (min 14) in base.init()

-- Slots and item names the debris sweep in refuelFromChest must never drop.
--
-- That sweep was written for support turtles, which accumulate road debris in
-- slots 1..BURN_MAX and keep nothing else there. A miner keeps its entire kit in
-- that range -- scanner, carried loader, stowed tool, and the modem during the
-- retrieval window -- so the sweep was throwing the turtle's own hardware on the
-- ground. Losing the modem is the one that bricks it: equipment.reconcile looks
-- for the modem in the inventory it was just dropped from, so Invariant B cannot
-- hold, comms.init errors, and base.init takes ore_turtle's module load down
-- with it -- skipping recoverPlacedLoader() and abandoning the placed loader.
--
-- Empty by default, so delivery and support keep exactly the behaviour they had.
local _protectedSlots = {}
local _protectedNames = {}

-- Slots are each protected item's declared home; names cover the same item after
-- it has been physically displaced into a mining slot -- dug up during movement,
-- or a retrieved loader turtle landing in the first free slot. ore_turtle
-- already learned it needs both (see its rescueProtectedItems), so the sweep
-- honours both rather than trusting slot position alone.
function base.setProtectedSlots(slots, names)
    _protectedSlots, _protectedNames = {}, {}
    for _, s in ipairs(slots or {}) do _protectedSlots[s] = true end
    for _, n in ipairs(names or {}) do _protectedNames[n] = true end
end

-- Role-installed hook that makes room for coal WITHOUT throwing anything away.
--
-- The debris sweep below is a last resort: it drops on the ground, where items
-- despawn. A role that has somewhere better to put its cargo installs it here,
-- and when the hook frees enough slots the sweep never runs at all.
--
-- This is deliberately a callback rather than a chest slot for turtle_base to
-- deploy itself. Banking cargo means placing an ender chest and digging it back
-- up, and this file already carries hard-won evidence of how badly that goes:
-- see the recovery comment further down, where both of a turtle's ender chests
-- share ONE registry name (EnderStorage separates them by colour frequency, not
-- item id), so nothing here can tell the fuel chest from the payload chest.
-- Deploying a second, name-identical chest inside this same function -- while a
-- loose one may already be in flight -- walks straight into the failure that
-- comment records: slot 15 ending with two chests and slot 16 with none.
--
-- The miner already solves all of this in ore_turtle's dumpToEC, which banks to
-- the ore chest, preserves coal, rescues displaced hardware, and guards the dock
-- station chest. The hook reaches that code from the one refuel path that does
-- not otherwise pass through it: fuel.ensureFuel() firing asynchronously from
-- the control loop.
--
-- The installed function must be safe to call with the pickaxe already held,
-- since refuelFromChest normally runs inside the dig-tool wrapper.
--
-- nil by default: delivery and support keep exactly the behaviour they have.
local _makeRoomFn = nil
function base.setMakeRoomFn(fn) _makeRoomFn = fn end

-- ROOM AT THE INSTANT OF EVERY DIG ON THE WAY SOMEWHERE (1.9.125).
--
-- A move digs whatever is in its path, and turtle.dig() with no room for the
-- drop does not refuse: it breaks the block and throws the item on the ground.
-- The miner checked its pack only before setting off for each ore, never on the
-- way, so one long dig through stone filled the pack and every block after that
-- landed on the floor of the mining zone -- where it never despawns, because
-- the chunk unloads when the miner leaves. The user reported the lag on
-- 2026-10-01; the same gap is how node_139 lost a loader climbing to it.
--
-- A role sets a function that makes room if room is short (the miner banks to
-- its ore chest). It runs before every dig in a move. nil by default: delivery
-- and support keep exactly the behaviour they have.
--
-- Guarded against re-entry: making room may itself dig (to place the chest),
-- and must not recurse into another round of making room.
function base.setDigRoomFn(fn) _self.digRoomFn = fn end

function base.makeRoomBeforeDig()
    if not _self.digRoomFn or _self.makingRoom then return end
    _self.makingRoom = true
    local ok, err = pcall(_self.digRoomFn)
    _self.makingRoom = false
    if not ok then
        logWarn("Dig make-room hook failed (" .. tostring(err) .. ")")
    end
    -- Measured, not assumed: a dig with no empty slot anywhere may throw its
    -- drop on the ground. Counted on every one, logged at most once a minute
    -- with the count since the last line, so the gate can see whether any spill
    -- is left after this fix.
    for s = 1, 16 do
        if turtle.getItemCount(s) == 0 then return end
    end
    _self.fullDigs = (_self.fullDigs or 0) + 1
    local now = os.clock()
    if now - (_self.fullDigLogAt or -math.huge) >= 60 then
        _self.fullDigLogAt = now
        logWarn(string.format(
            "Digging with no empty slot at %d,%d,%d -- the drop may land on the ground "
            .. "(%d such dig(s) since the last report)",
            _self.pos.x, _self.pos.y, _self.pos.z, _self.fullDigs))
        _self.fullDigs = 0
    end
end

-- Quick scan of inventory slots 1-BURN_MAX for any loose burnable items (used on boot).
-- Skips if already at max fuel to avoid wasting coal from previous runs.
function fuel.refuel()
    if fuel.level() >= fuel.max() then return end
    local before = fuel.level()
    for slot = 1, BURN_MAX do
        if turtle.getItemCount(slot) > 0 then
            turtle.select(slot)
            turtle.refuel()
        end
        if fuel.level() >= fuel.max() then break end
    end
    turtle.select(1)
    local gained = fuel.level() - before
    if gained > 0 then
        logInfo(string.format("Refuelled +%d (now %d)", gained, fuel.level()))
    end
end

-- LEFTOVER COAL GOES BACK (2026-10-08, the user). Both refuels suck coal into
-- every empty working slot and burn it, but a turtle burns only what its tank
-- has room for and keeps the rest -- so it came away from every refuel with its
-- inventory full of coal it could not use. After burning, every fuel item left
-- in the working slots goes back into the chest it came from. The one exception
-- is a miner's coal reserve slot, which it keeps stocked on purpose.
fuel.ITEMS = { ["minecraft:coal"] = true, ["minecraft:charcoal"] = true,
               ["minecraft:coal_block"] = true }

-- The drop that puts items back where `suckFn` took them from; nil if unknown,
-- because a drop toward no inventory throws the items on the ground.
function fuel.dropFor(suckFn)
    if suckFn == turtle.suckDown then return turtle.dropDown end
    if suckFn == turtle.suckUp   then return turtle.dropUp   end
    if suckFn == turtle.suck     then return turtle.drop     end
    return nil
end

-- Which face a place function puts its block on, and that block's absolute
-- position: what the ledger records. Forward uses the facing as it stands.
function fuel.blockFor(placeFn)
    local p = _self.pos
    if placeFn == turtle.placeDown then return "down", p.x, p.y - 1, p.z end
    if placeFn == turtle.placeUp   then return "up",   p.x, p.y + 1, p.z end
    local nx, nz = projectStep("forward")
    return "forward", nx, p.y, nz
end

-- Takes from the chest `suckFn` reaches only the fuel the tank can burn, and
-- burns it as it goes: one item first, to learn what one gives, then just
-- enough to fill the tank. The return below never once worked live (325
-- refuels, no "Returned" line, 1.9.138-1.9.151): the coal chests are kept
-- topped up by the base, so they are full again before the turtle can hand
-- anything back. Not taking it is the only return that cannot fail.
-- A miner's empty coal reserve slot is stocked afterwards, as it always was.
-- True if the chest gave anything.
function fuel.drawFrom(suckFn)
    local gave = false
    local slot
    for s = 1, BURN_MAX do
        if s ~= _self.fuelReserveSlot and turtle.getItemCount(s) == 0 then slot = s; break end
    end
    if slot then
        local per   -- fuel one item gives; learned from the first burn
        turtle.select(slot)
        while fuel.level() < fuel.max() do
            local want = per and math.min(64, math.ceil((fuel.max() - fuel.level()) / per)) or 1
            if not suckFn(want) then break end
            gave = true
            local had, before = turtle.getItemCount(slot), fuel.level()
            turtle.refuel()
            local burned = had - turtle.getItemCount(slot)
            if burned == 0 or turtle.getItemCount(slot) > 0 then break end   -- not fuel, or full
            per = math.max(1, math.floor((fuel.level() - before) / burned))
        end
    end
    local r = _self.fuelReserveSlot
    if r and r <= BURN_MAX and turtle.getItemCount(r) == 0 then
        turtle.select(r)
        if suckFn(64) then gave = true end
    end
    turtle.select(1)
    return gave
end

function fuel.returnLeftover(dropFn, where)
    if not dropFn then return 0 end
    local back = 0
    for s = 1, BURN_MAX do
        local i = turtle.getItemDetail(s)
        if s ~= _self.fuelReserveSlot and i and fuel.ITEMS[i.name] then
            turtle.select(s)
            if dropFn() then back = back + i.count - turtle.getItemCount(s) end
        end
    end
    turtle.select(1)
    if back > 0 then
        logInfo(string.format("Returned %d leftover fuel item(s) to %s", back, where))
    end
    return back
end

-- PLACED-ITEM LEDGER (recovery layer release 2; ruled 2026-10-08, contract
-- 2026-10-12). Whatever a turtle places in the world and means to take back is
-- recorded here BEFORE the place and cleared only once it is back in its home
-- slot, so a reboot at any instant errs toward "we may have one out there" --
-- the recoverable direction. One file per kind, because two can be out at once:
-- a dump can start while the fuel chest is down. W1's chest_state (2026-10-08,
-- since deleted -- the ore chest is a kind here now) is the storage contract
-- this generalises; node_181 lost its ore chest to a reboot mid-dump that day
-- because nothing on disk said it was out there.
--
-- A field of base rather than a module: a new module and its first require
-- cannot ship in one OTA (the updater running it is the previous version).
base.ledger = { _cache = {}, _loaded = {} }

function base.ledger.path(kind) return "ledger_" .. kind .. ".dat" end

-- `entry` = { x, y, z (the BLOCK), face = "down"|"up"|"forward", facing,
-- turtleAt = { x, y, z } }. Returns true once on disk, or false, reason. The
-- caller MUST NOT place on false: a crash after an unrecorded place strands the
-- item with nothing recording why.
function base.ledger.record(kind, entry)
    local rec = {}
    for k, v in pairs(entry) do rec[k] = v end
    rec.placedAt = os.epoch("utc")
    local f = fs.open(base.ledger.path(kind), "w")
    if not f then
        -- Leave the cache alone: claiming a placement we could not persist
        -- would be a lie in memory as well as on disk.
        return false, "ledger_write_failed"
    end
    -- A write can throw (a full disk) as well as fs.open returning nil. Escaping
    -- here would kill base.run on roles that refuel unwrapped, and the refuel
    -- would retry on the next boot: a crash loop (review #9). Caught, the
    -- partial file removed, and reported like any other failed write.
    local wrote = pcall(function()
        f.write(textutils.serialise(rec))
        f.close()
    end)
    if not wrote then
        pcall(f.close)
        if fs.exists(base.ledger.path(kind)) then pcall(fs.delete, base.ledger.path(kind)) end
        return false, "ledger_write_failed"
    end
    base.ledger._cache[kind], base.ledger._loaded[kind] = rec, true
    return true
end

-- After a clean place() failure: nothing went down, and a false record would
-- send a turtle digging at a block it never used.
function base.ledger.rollback(kind)
    base.ledger.clear(kind)
    logInfo("Ledger: " .. kind .. " placement failed cleanly -- record rolled back")
end

-- Only once the item is confirmed back in its home slot. Clearing early would
-- erase the only record of something still standing in the world.
function base.ledger.clear(kind)
    base.ledger._cache[kind], base.ledger._loaded[kind] = nil, true
    local p = base.ledger.path(kind)
    if fs.exists(p) then fs.delete(p) end
end

function base.ledger.get(kind)
    local L = base.ledger
    if L._loaded[kind] then return L._cache[kind] end
    L._loaded[kind] = true
    local p = L.path(kind)
    if not fs.exists(p) then return nil end
    local f = fs.open(p, "r")
    if not f then return nil end
    local raw = f.readAll()
    f.close()
    -- A truncated write must not brick the boot: an unreadable record is no
    -- record, said out loud.
    local ok, data = pcall(textutils.unserialise, raw or "")
    if ok and type(data) == "table" and data.x ~= nil then
        L._cache[kind] = data
    else
        logWarn("Ledger file for " .. kind .. " is unreadable -- treated as no record")
    end
    return L._cache[kind]
end

-- Every kind with a record, from disk, so a reboot sees what the last life left.
function base.ledger.all()
    local out = {}
    for _, name in ipairs(fs.list("")) do
        local kind = name:match("^ledger_(.+)%.dat$")
        if kind then
            local e = base.ledger.get(kind)
            if e then out[kind] = e end
        end
    end
    return out
end

-- A kind is two fields (W1's point, 2026-10-08): the block name that proves
-- identity before digging, and the slot it must end up in. homeSlot may be a
-- function, for slots a role only fixes in base.init (the fuel chest's).
base.ledger._kinds = {}
function base.ledger.registerKind(kind, spec)
    base.ledger._kinds[kind] = spec
end

base.ledger.RECOVER_REACH = 4      -- cells: how far from where it placed an item a rebooted turtle walks back
-- Any recovery that cannot finish keeps the record -- it is the only evidence
-- -- and says where, so a person can go and get it.
function base.ledger.needsHands(kind, e, reason)
    local detail = string.format("needs_hands: %s at %s,%s,%s -- %s",
        kind, tostring(e.x), tostring(e.y), tostring(e.z), tostring(reason))
    logWarn("Ledger: " .. detail)
    pcall(base.sendProgress, detail)
    return false, reason
end

-- Take one recorded item back, in the contract's order (2026-10-12): position
-- and facing measured; standing where it was placed (a reboot does not move a
-- turtle, so anything else means the record cannot be trusted); aimed at the
-- recorded face; the block IS the item; room made without dropping anything;
-- dug through digGuarded, with the pickaxe borrowed when it is stowed; home
-- slot confirmed; only then cleared. Every failure keeps the record.
function base.ledger.recover(kind)
    local L = base.ledger
    local e = L.get(kind)
    if not e then return true end
    local spec = L._kinds[kind]
    if not spec then return L.needsHands(kind, e, "unknown_kind") end
    local home = type(spec.homeSlot) == "function" and spec.homeSlot() or spec.homeSlot
    -- The name recorded at placement wins: a role may carry a chest whose
    -- exact item it only knows when it places it (release 4, delivery).
    local blockName = e.blockName or spec.blockName

    -- ALREADY HOME (review #3): a reboot between the dig and the clear, or a
    -- person fetching it by hand. The record is stale; going to dig would send
    -- someone to an empty block on every boot.
    local inHome = turtle.getItemDetail(home)
    if inHome and inHome.name == blockName then
        L.clear(kind)
        logInfo("Ledger: the " .. kind .. " is already home -- stale record cleared")
        pcall(base.sendProgress, "ledger_ok: " .. kind)
        return true
    end

    local dir = (e.face == "down" and "down") or (e.face == "up" and "up") or "forward"
    base.waitForPositionFix("recovering the " .. kind, dir ~= "forward")
    local at = e.turtleAt or {}
    -- A FEW CELLS OFF, IT GOES BACK (sim w3_delivery_ec_reboot W3_AFTER_CHEST; T2 shakeout-
    -- payload-d). A delivery steps off its ender chest to put its regular chests down; rebooted
    -- there -- one cell away -- it left the chest in the world for hands, and the order failed.
    -- With GPS on it, within RECOVER_REACH of where it stood, it walks back without digging --
    -- a chest it just placed may be on the way -- and the checks below still decide: aimed at
    -- the recorded face, the block must be the item. Further, or blocked: hands, as before.
    if _self.posFixed and type(at.x) == "number" and type(at.y) == "number" and type(at.z) == "number"
       and (_self.pos.x ~= at.x or _self.pos.y ~= at.y or _self.pos.z ~= at.z)
       and math.abs(_self.pos.x - at.x) + math.abs(_self.pos.y - at.y) + math.abs(_self.pos.z - at.z) <= L.RECOVER_REACH then
        logInfo(string.format("Ledger: the %s was placed from %d,%d,%d -- going back there from %d,%d,%d",
            kind, at.x, at.y, at.z, _self.pos.x, _self.pos.y, _self.pos.z))
        local couldDig = _self.canDig
        _self.canDig = false
        pcall(move.to, at.x, at.y, at.z)
        _self.canDig = couldDig
    end
    if _self.pos.x ~= at.x or _self.pos.y ~= at.y or _self.pos.z ~= at.z then
        return L.needsHands(kind, e, "not_where_it_was_placed")
    end
    if dir == "forward" then
        if e.facing == nil then return L.needsHands(kind, e, "facing_not_recorded") end
        for _ = 1, 4 do
            if _self.facing == e.facing then break end
            move.turnRight()
        end
        if _self.facing ~= e.facing then return L.needsHands(kind, e, "could_not_turn") end
    end

    local seen, data = INSPECT[dir]()
    if not (seen and type(data) == "table" and data.name == blockName) then
        -- Dug before the reboot landed, and still in a working slot (review #3).
        if L.bringHome(blockName, home) then
            L.clear(kind)
            logInfo("Ledger: the " .. kind .. " was already aboard -- moved home, record cleared")
            pcall(base.sendProgress, "ledger_ok: " .. kind)
            return true
        end
        return L.needsHands(kind, e, "not_the_item")
    end

    local function hasRoom()
        for s = 1, 16 do if turtle.getItemCount(s) == 0 then return true end end
        return false
    end
    if not hasRoom() then base.makeRoomBeforeDig() end
    if not hasRoom() then return L.needsHands(kind, e, "no_room") end

    local dug = false
    local function dig() dug = digGuarded(dir) and true or false end
    if _digToolWrapper then
        if not pcall(_digToolWrapper, "recovering the " .. kind, dig) then dug = false end
    else
        dig()
    end
    if not dug then return L.needsHands(kind, e, "dig_failed") end

    if not L.bringHome(blockName, home) then
        -- It IS aboard, so the record no longer describes the world: clear it,
        -- and say plainly what is wrong instead (review #2).
        L.clear(kind)
        return L.needsHands(kind, e, "aboard_but_not_in_slot_" .. tostring(home))
    end

    L.clear(kind)
    logInfo(string.format("Ledger: recovered the %s from %d,%d,%d", kind, e.x, e.y, e.z))
    pcall(base.sendProgress, "ledger_ok: " .. kind)
    return true
end

-- Put one `name` into `home`: true once it is there. Clears the home slot
-- first by moving whatever else holds it to a free slot -- never dropping it
-- (refuel guards against coal landing in CHEST_SLOT; review #2). Takes the item
-- from a working slot below `home`, or from a reserved slot above it only when
-- that holds 2+ -- refuelFromChest's own rule, because every ender chest shares
-- one item name and a lone chest above is another chest's home.
function base.ledger.bringHome(name, home)
    local d = turtle.getItemDetail(home)
    if d and d.name == name then return true end
    if d then
        for s = 1, 16 do
            if s ~= home and turtle.getItemCount(s) == 0 then
                turtle.select(home)
                turtle.transferTo(s)
                break
            end
        end
        if turtle.getItemCount(home) > 0 then turtle.select(1); return false end
    end
    local from
    for s = 1, home - 1 do
        local i = turtle.getItemDetail(s)
        if i and i.name == name then from = s; break end
    end
    if not from then
        for s = home + 1, 16 do
            local i = turtle.getItemDetail(s)
            if i and i.name == name and i.count >= 2 then from = s; break end
        end
    end
    if from then
        turtle.select(from)
        turtle.transferTo(home, 1)
    end
    turtle.select(1)
    local h = turtle.getItemDetail(home)
    return h ~= nil and h.name == name
end

-- Record, then place below; a placement that fails leaves no record (the
-- contract's order). The entry names the item actually in `slot`, so a role
-- need not know its chest's exact item in advance. placeFn defaults to
-- turtle.placeDown; a role passes its own (delivery digs first).
function base.ledger.placeDown(kind, slot, placeFn)
    local item = turtle.getItemDetail(slot)
    local ok, why = base.ledger.record(kind, {
        x = _self.pos.x, y = _self.pos.y - 1, z = _self.pos.z, face = "down",
        facing = _self.facing, blockName = item and item.name,
        turtleAt = { x = _self.pos.x, y = _self.pos.y, z = _self.pos.z } })
    if not ok then return false, why end
    turtle.select(slot)
    local placed, reason = (placeFn or turtle.placeDown)()
    if not placed then base.ledger.rollback(kind) end
    return placed, reason
end

-- Clear the record once its item is back in `slot`; true if there is no
-- record left. Still out there: the record stays, for boot to recover.
function base.ledger.clearIfHome(kind, slot)
    local e = base.ledger.get(kind)
    if not e then return true end
    local spec = base.ledger._kinds[kind] or {}
    local d = turtle.getItemDetail(slot)
    if d and d.name == (e.blockName or spec.blockName) then
        base.ledger.clear(kind)
        return true
    end
    return false
end

-- WHICH ENDER CHESTS ARE NOT THE PAYLOAD CHEST (2026-10-16). Both chests share
-- one item name, and with no NBT the delivery turtle locked EVERY chest in
-- slots 1-15 as "other" -- so node_109, its delivery chest in slot 1, could
-- never move it home and every dispatch aborted. With the payload chest home in
-- ecSlot, every other chest is locked, as before. With ecSlot empty, only the
-- fuel slot is: a lone other chest is the payload chest. Two loose chests and
-- no fuel chest in its slot cannot be told apart, so all are locked and the
-- caller aborts as it always did.
function base.otherChestSlots(ecSlot, fuelSlot)
    local function isChest(s)
        local it = turtle.getItemDetail(s)
        local n = it and it.name:lower() or ""
        return n:find("ender") ~= nil or n:find("entangled") ~= nil
    end
    local others, loose = {}, {}
    for s = 1, 16 do
        if s ~= ecSlot and isChest(s) then
            others[s] = true
            if s ~= fuelSlot then loose[#loose + 1] = s end
        end
    end
    if isChest(ecSlot) then return others end
    if isChest(fuelSlot) and #loose == 1 then others[loose[1]] = nil end
    return others
end

-- Every recorded item, at boot. Returns how many came back.
function base.ledger.recoverAll()
    local n = 0
    for kind in pairs(base.ledger.all()) do
        if base.ledger.recover(kind) then n = n + 1 end
    end
    return n
end

-- The fuel chest is the ledger's first entry (ruled 2026-10-08): every role
-- uses one. Its home slot is read when recovering, because base.init moves it
-- to 15 for delivery turtles after this file has loaded.
base.ledger.registerKind("fuel_chest", { blockName = CHEST_ITEM,
                                         homeSlot = function() return CHEST_SLOT end })

-- Deploy the entangled chest, drain coal into slots 1-BURN_MAX, burn it, recover chest.
-- Before deploying, clears non-fuel debris from slots 1-BURN_MAX to ensure there is
-- room for coal (support turtles accumulate road debris while following delivery).
function fuel.refuelFromChest()
    local chestData = turtle.getItemDetail(CHEST_SLOT)
    if not chestData then
        logWarn("Slot " .. CHEST_SLOT .. " has no entangled chest!")
        return false
    end
    if chestData.name ~= CHEST_ITEM then
        logWarn(string.format("Slot %d has wrong item (%s) — expected %s, cannot refuel",
            CHEST_SLOT, chestData.name, CHEST_ITEM))
        return false
    end

    -- ── Clear debris to make room ────────────────────────────────────────────
    local function freeCount()
        local n = 0
        for s = 1, BURN_MAX do
            if turtle.getItemCount(s) == 0 then n = n + 1 end
        end
        return n
    end

    -- Bank the cargo first if the role knows how, so the sweep has nothing left
    -- to throw away. Guarded by pcall: a hook that fails must not take the
    -- refuel down with it, because a turtle that cannot refuel is a worse
    -- outcome than a stack of cobblestone on the floor.
    if freeCount() < 4 and _makeRoomFn then
        local ok, err = pcall(_makeRoomFn)
        if not ok then
            logWarn("Make-room hook failed (" .. tostring(err)
                .. ") — falling back to the debris sweep")
        end
    end

    if freeCount() < 4 then
        logInfo("Clearing debris from inventory to make room for coal...")
        for s = 1, BURN_MAX do
            if freeCount() >= 4 then break end
            local item = turtle.getItemDetail(s)
            if item then
                local n = item.name
                local isFuel = (n == "minecraft:coal" or n == "minecraft:charcoal"
                                or n == "minecraft:coal_block" or n == CHEST_ITEM)
                if not isFuel and not _protectedSlots[s] and not _protectedNames[n] then
                    turtle.select(s)
                    -- Prefer dropping down; fall back to forward
                    if not turtle.dropDown() then turtle.drop() end
                end
            end
        end
        -- Protected hardware can hold the count below the target. That is the
        -- correct outcome -- less coal this trip beats a miner that has thrown
        -- away its scanner -- but it must not pass silently, because a miner
        -- that never frees a slot draws no coal and will be back here shortly.
        local free = freeCount()
        if free < 4 then
            logWarn(string.format(
                "Debris sweep freed only %d slot(s) — protected items left in place; "
                .. "this refuel will draw less coal than usual", free))
        else
            logInfo(string.format("Debris cleared — %d free slot(s) now available", free))
        end
    end

    local placeFn, digFn, suckFn = findFreeSpace()
    if not placeFn then
        logError("Completely surrounded by unbreakable blocks — cannot deploy chest!")
        return false
    end

    -- RECORDED BEFORE IT GOES DOWN (recovery layer release 2). A reboot between
    -- this place and the dig below strands the fuel chest in the world, for
    -- every role; the record is what lets the next boot go back for it.
    local face, bx, by, bz = fuel.blockFor(placeFn)
    local recorded, why = base.ledger.record("fuel_chest", {
        x = bx, y = by, z = bz, face = face, facing = _self.facing,
        turtleAt = { x = _self.pos.x, y = _self.pos.y, z = _self.pos.z } })
    if not recorded then
        logWarn("Fuel chest NOT placed: its record could not be written (" .. tostring(why) .. ")")
        return false
    end

    -- Place chest
    turtle.select(CHEST_SLOT)
    if not placeFn() then
        logWarn("Failed to place entangled chest.")
        base.ledger.rollback("fuel_chest")
        return false
    end
    sleep(0.5)  -- wait for peripheral/block to register

    -- Draw into slots 1-BURN_MAX only, so CC never auto-fills slots 15 or 16
    -- (reserved for ender chests), and only what the tank burns.
    local before = fuel.level()
    if not fuel.drawFrom(suckFn) and before < fuel.max() then
        logWarn("Entangled chest is empty — no coal available!")
    end

    -- Then whatever loose fuel is aboard, if the chest could not fill the tank.
    -- Slots 1-BURN_MAX only (never touch slots 15 or 16)
    for slot = 1, BURN_MAX do
        if turtle.getItemCount(slot) > 0 then
            turtle.select(slot)
            turtle.refuel()
        end
    end
    local gained = fuel.level() - before
    logInfo(string.format("Refuelled +%d (now %d/%d)", gained, fuel.level(), fuel.max()))
    fuel.returnLeftover(fuel.dropFor(suckFn), "the fuel ender chest")

    -- Break chest — drops as item, turtle auto-collects
    digFn()
    sleep(0.3)

    -- If coal accidentally landed in CHEST_SLOT, burn it before recovering the chest
    local cs = turtle.getItemDetail(CHEST_SLOT)
    if cs and cs.name ~= CHEST_ITEM then
        turtle.select(CHEST_SLOT)
        turtle.refuel()   -- burns coal; EC is not burnable so this is safe
    end

    -- Recover the deployed chest into CHEST_SLOT, taking exactly ONE item.
    --
    -- Both of this turtle's ender chests share a single item name (EnderStorage
    -- separates them by colour frequency, not registry id), so neither this
    -- search nor getItemDetail can tell the fuel chest from the ore/delivery
    -- chest in the slot above. Two consequences, both observed:
    --
    --   * Scanning all 16 slots could "recover" the chest out of slot 16, which
    --     leaves a miner with nowhere to dump ore for the rest of the job.
    --   * The dug chest can merge into that slot's existing chest stack, and
    --     transferTo with no count then moves BOTH, emptying slot 16. Probing
    --     the field refuel showed exactly that: slot 15 ended with 2 chests and
    --     slot 16 with none.
    --
    -- So: prefer the working slots, and only ever draw from a reserved slot when
    -- it holds 2+ chests (proof ours merged in), never a lone one.
    local function chestAt(s)
        local i = turtle.getItemDetail(s)
        if i and i.name == CHEST_ITEM then return i end
        return nil
    end
    if not chestAt(CHEST_SLOT) then
        local from
        for slot = 1, CHEST_SLOT - 1 do
            if chestAt(slot) then from = slot; break end
        end
        if not from then
            for slot = CHEST_SLOT + 1, 16 do
                local i = chestAt(slot)
                if i and i.count >= 2 then from = slot; break end
            end
        end
        if from then
            turtle.select(from)
            turtle.transferTo(CHEST_SLOT, 1)
        else
            logWarn(string.format(
                "Entangled chest not recovered into slot %d — check inventory", CHEST_SLOT))
        end
    end
    turtle.select(1)
    -- Cleared only once the chest is home. Anything else keeps the record, and
    -- the next boot goes back for it.
    if chestAt(CHEST_SLOT) then
        base.ledger.clear("fuel_chest")
    else
        logWarn("Fuel chest not confirmed home -- its ledger record is kept for the next boot")
    end

    return gained > 0
end

-- Refuel from a chest placed below/above/front at the dock station.
-- Called on boot and after returning to dock.
-- Fills up as much as possible then stops.
-- Skips entirely if fuel is already above 80% to avoid burning existing coal.
function fuel.dockRefuel()
    local pct = fuel.level() / math.max(fuel.max(), 1)
    if pct >= 0.8 then
        logInfo(string.format("Fuel already at %d%% — skipping dock refuel.", math.floor(pct*100)))
        return true
    end
    logInfo("Refuelling at dock station...")

    -- Draw from the dock chest into slots 1-BURN_MAX only, and only what the
    -- tank burns
    local before  = fuel.level()
    local suckFns = { turtle.suckDown, turtle.suckUp, turtle.suck }
    local source  = nil   -- the side that actually gave coal, for the return
    for _, suckFn in ipairs(suckFns) do
        if fuel.drawFrom(suckFn) then source = source or suckFn end
    end

    -- Then whatever loose fuel is aboard. Slots 1-BURN_MAX only
    for slot = 1, BURN_MAX do
        if turtle.getItemCount(slot) > 0 then
            turtle.select(slot)
            turtle.refuel()
        end
    end
    turtle.select(1)
    local gained = fuel.level() - before
    fuel.returnLeftover(fuel.dropFor(source), "the dock chest")

    if gained > 0 then
        logInfo(string.format("Dock refuel +%d (now %d/%d)", gained, fuel.level(), fuel.max()))
        return true
    end

    logWarn("Dock refuel: no coal found in station — check chest below dock!")

    -- Fall back to the turtle's own fuel ender chest.
    --
    -- dockRefuel only ever sucked from the dock station chest, so a miner
    -- carrying a full coal ender chest could not top itself up at the dock. It
    -- then cleared the flat 500-fuel pre-departure gate and flew out on fuel
    -- that could not bring it home. On 1.9.7 that stranded one miner mid-air at
    -- 0 fuel and brought a second home nearly empty.
    --
    -- MINER only, deliberately: delivery and support must stay behaviourally
    -- identical, and they are not the roles that strand thousands of blocks out.
    if _self.role ~= proto.ROLE.MINER then return false end

    -- Never dig here. refuelFromChest falls back to digging when down, up and
    -- front are all blocked, and at a dock the blocked space below is the
    -- station chest itself. Bailing out is better than breaking it.
    if turtle.detectDown() and turtle.detectUp() and turtle.detect() then
        logWarn("Fuel EC fallback skipped — no free space to deploy without digging")
        return false
    end

    logInfo("Dock chest dry — falling back to the fuel ender chest")
    local ecBefore = fuel.level()
    local target   = fuel.max() * 0.8   -- same 80% mark dockRefuel considers "full"
    for _ = 1, 8 do
        if fuel.level() >= target then break end
        if not fuel.protectedRefuelFromChest() then break end
    end
    local ecGained = fuel.level() - ecBefore
    if ecGained > 0 then
        logInfo(string.format("Fuel EC refuel +%d (now %d/%d)",
            ecGained, fuel.level(), fuel.max()))
        return true
    end
    logWarn("Fuel EC refuel yielded nothing — is the coal ender chest stocked?")
    return false
end

-- refuelFromChest, run through the installed dig-tool wrapper when there is one.
-- With no wrapper installed (delivery / support / warehouse) this is literally
-- `return fuel.refuelFromChest()`.
--
-- pcall'd because withDigTool re-raises anything the body threw after putting
-- the modem back; ensureFuel runs inside controlLoop, and an error escaping here
-- kills the whole parallel.waitForAny runner (i.e. the running job).
function fuel.protectedRefuelFromChest()
    if not _digToolWrapper then return fuel.refuelFromChest() end
    local result = false
    local ok, ran = pcall(_digToolWrapper, "critical refuel", function()
        result = fuel.refuelFromChest()
    end)
    if not ok then
        logWarn("Guarded refuel failed: " .. tostring(ran))
        return false
    end
    -- `result` is initialised to false and only ever set inside the injected
    -- body, so it already carries the right answer for both of withDigTool's
    -- paths: false if the body never ran (no pickaxe available, nothing
    -- placed), or whatever fuel.refuelFromChest() actually returned if it did.
    return result
end

local MAX_FUEL_RETRIES = 5

function fuel.ensureFuel()
    local fuelRetries = 0
    while fuel.isCritical() do
        fuelRetries = fuelRetries + 1
        if fuelRetries > MAX_FUEL_RETRIES then
            logWarn("Cannot refuel after " .. MAX_FUEL_RETRIES .. " attempts — setting ERROR status")
            base.setStatus(proto.STATUS.ERROR)
            return false  -- caller must handle
        end
        logWarn(string.format("Fuel critical (%d) — deploying entangled chest...", fuel.level()))
        -- Send heartbeat so server doesn't mark us offline during refuel
        if _self.id then
            comms.toServer(proto.MSG.HEARTBEAT, proto.payloadHeartbeat(
                proto.STATUS.ERROR, fuel.level(), base.getPos(), _self.jobId))
        end
        local ok = fuel.protectedRefuelFromChest()
        if not ok or fuel.isCritical() then
            -- GPS resync before reporting ERROR position — corrects position if turtle
            -- was physically relocated (e.g. player moved it to dock while stuck).
            gpsSync()
            comms.toServer(proto.MSG.STATUS_UPDATE, proto.payloadStatusUpdate(
                _self.jobId, proto.STATUS.ERROR, "fuel_critical_no_coal", base.getPos()))
            -- Wait but keep sending heartbeats every 5 seconds
            for _ = 1, 6 do
                if _self.id then
                    comms.toServer(proto.MSG.HEARTBEAT, proto.payloadHeartbeat(
                        proto.STATUS.ERROR, fuel.level(), base.getPos(), _self.jobId))
                end
                sleep(5)
                gpsSync()  -- keep position current in case turtle is moved during wait
                if not fuel.isCritical() then break end
            end
        end
    end
    return true
end

base.fuel = fuel

-- ─── Registration ────────────────────────────────────────────────────────────

-- Attempts the MINER role's BOOT registration is allowed before base.init gives
-- up and returns. ~6 * (REGISTER_TIMEOUT + 5s) = about a minute of trying.
--
-- Why only the miner, and only at boot: this loop blocking forever is correct
-- for a turtle that cannot do anything useful without the server. A solo miner
-- that reboots in the field with a chunk loader PLACED is the one exception --
-- ore_turtle's recoverPlacedLoader runs after base.init returns, so an
-- unbounded wait here means the loader is never retrieved and the miner never
-- comes home, which is exactly the no-server-contact invariant. Every other
-- role passes maxAttempts = nil and gets the original unbounded loop, so
-- delivery/support/warehouse boot behaviour is byte-for-byte unchanged.
local BOOT_REGISTER_ATTEMPTS = 6

-- Registration retry backoff: 5s, 10s, 20s, 40s, then capped at 60s. Flat 5s
-- retries let a lost ACK become a fleet-wide storm — see the comment in
-- register()'s retry branch.
local REGISTER_BACKOFF_BASE = 5
local REGISTER_BACKOFF_MAX  = 60

-- Returns true once the server ACKs. Returns false only when maxAttempts is set
-- and exhausted; with maxAttempts nil it never returns false.
--
-- Deliberately does NOT set _self.serverDown on giving up. serverDown is only
-- ever cleared inside this function's success branch, and sendHeartbeat only
-- calls register() once _missedHeartbeats trips -- which never happens while
-- the server is ACKing. Setting it here could therefore latch a turtle into a
-- permanent serverDown that nothing clears if the server was in fact up.
local function register(maxAttempts)
    -- Small delay so ender modem has time to connect after boot
    sleep(2)

    local attempt = 0
    while true do
        attempt = attempt + 1
        logInfo(string.format("Registering (attempt %d)...", attempt))
        -- midJob=true tells server this is a reconnect, not a fresh boot:
        -- the turtle's job coroutine is still alive and will resume automatically.
        -- Server re-links the job instead of re-queuing it for a new pair.
        comms.toServer(proto.MSG.REGISTER, {
            role     = _self.role,
            fuel     = fuel.level(),
            fuelMax  = fuel.max(),
            position = base.getPos(),
            midJob   = _self.busy,
            -- Whether the job is waiting for its next sector order. The server
            -- used to replay the last SECTOR_ASSIGN to every reconnecting
            -- miner; one that was mid-sector already had it, so the replay sat
            -- in its inbox and walked it straight back into the sector it had
            -- just finished (W6, node_139: 6 replays, 4 repeated sectors in
            -- jobs 0039-0042). Now the server replays only when this is true.
            awaitingSector = base.isAwaiting(proto.MSG.SECTOR_ASSIGN),
            -- The channel this turtle ALSO listens on. nil means it could not
            -- have one and is staying on the shared channel; the server must
            -- then keep sending there. Placed after awaitingSector so existing
            -- payload anchors keep their positions.
            privateChannel = OWN_CHANNEL,
            hardware = base.hardwareVerdict(),
            -- The updater's own failure record, if its last run failed. The
            -- updater runs inside this turtle and its printed reasons never
            -- reached the fleet log; this is how a failed update gets said.
            updateFailed = base.readUpdateFailed(),
        })

        -- Waits for a REGISTER_ACK SPECIFICALLY, and routes anything else into
        -- the inboxes rather than discarding it.
        --
        -- This line was the fleet outage. proto.receive returns the first message
        -- addressed to this turtle of ANY type, so a HEARTBEAT_ACK arriving first
        -- -- and fifteen turtles produce a steady stream of them -- came back
        -- here, failed the type test below, and was thrown away along with the
        -- attempt. The real ACK then landed with nothing waiting for it and went
        -- the same way. Every retry added traffic and made the next collision
        -- likelier, until the whole fleet did nothing but re-introduce itself.
        local reply = base.receiveCtrl(CFG.REGISTER_TIMEOUT, proto.MSG.REGISTER_ACK)
        if reply and reply.payload.ok then
            -- Server sends assigned dock in the ACK
            if reply.payload.dock then
                _self.dock = reply.payload.dock
                base.saveDock(_self.dock)
                logInfo(string.format("Assigned dock: bay %d row %s (%d,%d,%d)",
                    _self.dock.bay, _self.dock.row,
                    _self.dock.x, _self.dock.y, _self.dock.z))
            end
            if _self.serverDown then
                local p = _self.pos
                logInfo(string.format(
                    "Server reconnected — resuming from %d,%d,%d", p.x, p.y, p.z))
                _self.serverDown = false
            end
            logInfo("Registered successfully.")
            return true
        end

        if maxAttempts and attempt >= maxAttempts then
            logWarn(string.format(
                "No response from server after %d attempts — continuing unregistered. "
                .. "Heartbeats will keep retrying.", attempt))
            return false
        end

        -- Not connected yet — wait and retry, backing off.
        --
        -- A flat 5s retry turned a lost ACK into a fleet-wide storm. Captured
        -- 2026-09-02: all 15 turtles re-registering together every 32s, then
        -- every 7s, with identical fuel values each round -- nobody working,
        -- everyone shouting. The server logged every registration, so it was
        -- receiving and answering them; the ACKs were being consumed by the
        -- other coroutine before register() could see them (Invariant G, the
        -- inbox that does not exist).
        --
        -- That is a runaway: retries add traffic, traffic drops more ACKs, more
        -- turtles retry. It ended with the server unable to push at all and the
        -- dashboard frozen for 11.8 hours.
        --
        -- Backing off does not fix the race -- only the inbox does -- but it
        -- stops the race from feeding itself. Fewer attempts per second means
        -- less traffic, which means a given attempt is more likely to survive,
        -- so the fleet converges instead of diverging.
        -- Two attempts with no ACK: if this turtle dropped the shared channel
        -- (step 3) and the server is older than 1.9.111, its reply went to a
        -- channel nobody is listening on. Reopen it and keep retrying.
        if attempt >= 2 then base.reopenSharedChannel() end

        local wait = math.min(REGISTER_BACKOFF_BASE * (2 ^ (attempt - 1)),
                              REGISTER_BACKOFF_MAX)
        logWarn(string.format(
            "No response from server. Retrying in %ds (attempt %d)...", wait, attempt))
        sleep(wait)
    end
end

-- ─── Heartbeat ───────────────────────────────────────────────────────────────

-- THE FLEET MUST NOT HEARTBEAT IN UNISON.
--
-- Measured from the fleet log on 2026-09-08: fourteen episodes in an hour where
-- 8-14 turtles declared the server unreachable within 6-12 MILLISECONDS of each
-- other, while the server was awake and logged every subsequent re-registration
-- as a success. Independent per-message loss cannot do that. Whole heartbeat
-- ROUNDS were being destroyed.
--
-- The mechanism is a phase lock, and it is the same shape as the bridge push
-- timeout that used to equal STORAGE_INTERVAL:
--
--   1. A fleet-wide re-registration resets every turtle's heartbeat clock at
--      once -- they land within 60ms of each other -- so the fleet becomes one
--      synchronised round arriving every 5 seconds.
--   2. The server's RS poll also runs every 5 seconds and yields for 45-150ms.
--      Any event arriving during a yield is destroyed; CC does not queue it.
--   3. Equal periods mean the phase between the round and the poll window
--      drifts slowly. When it drifts into alignment the ENTIRE round is lost,
--      not a fraction of it.
--   4. Three aligned rounds is 15s, which is MAX_MISSED. The whole fleet
--      declares the server down together, re-registers together, and is
--      re-synchronised -- which is why it recurs every one to three minutes.
--
-- Jitter breaks step 1. A spread round can only ever lose the fraction that
-- lands in the window, and no turtle can lose three in a row to one cause.
--
-- RANDOM PER INTERVAL, not a fixed per-node offset. A fixed offset would spread
-- the fleet but freeze each turtle's phase relative to the poll -- so a turtle
-- unlucky in its offset would lose EVERY heartbeat, for ever. That is worse
-- than the fault being fixed.
local HEARTBEAT_JITTER = 0.4   -- +/-40%: a 5s interval becomes 3-7s

-- SEED PER NODE OR THIS DOES NOTHING.
--
-- Lua's generator is deterministic from its seed, and nothing in this codebase
-- seeded it. Every turtle would draw the identical "random" sequence, stay
-- exactly as synchronised as before, and the fix would look applied while
-- changing nothing at all. The computer ID is unique per machine by definition.
do
    local id = 0
    pcall(function() id = os.getComputerID() or 0 end)
    math.randomseed(id * 7919 + (os.epoch("utc") % 100000))
end

local function heartbeatGap()
    local spread = (math.random() * 2 - 1) * HEARTBEAT_JITTER
    return CFG.HEARTBEAT_INTERVAL * 1000 * (1 + spread)
end
base._heartbeatGap = heartbeatGap   -- test seam

local _missedHeartbeats = 0
local MAX_MISSED = 3  -- re-register after this many missed ACKs
local _heartbeatCount = 0

-- ────────────────────────────────────────────────────────────────── Stall witness
--
-- Why a turtle now says HOW it lost the server, not just that it did.
--
-- Measured 2026-09-10 across a full day of fleet log: 291 disconnect events in
-- 68 clusters, five of them hitting 12-15 nodes at once. Two server-side
-- explanations were tested against that log and both are dead. Bridge pushes
-- are NEGATIVELY correlated with the clusters -- 5 near-hits where chance alone
-- predicts 9. And the server never stopped: its 60-second loop rollup arrives
-- on cadence straight through every fleet-wide dropout, reporting ~100ms worst
-- busy time, while the bridge (a separate process, outside the game) keeps its
-- own 60s cadence unbroken.
--
-- So the server was running and every turtle stopped hearing it anyway. Two
-- explanations remain, and they are indistinguishable from the server side:
--
--   A. The messages are genuinely being lost. The turtle kept running, sent its
--      three heartbeats, and no ACK came back.
--   B. The turtle itself stopped running -- the game paused -- and fifteen
--      seconds of wall clock passed in what the turtle experienced as one
--      moment.
--
-- Only the turtle can separate those, and only by reporting what its OWN loop
-- did during the window. That is all this section is.
--
-- It prints the raw numbers next to the verdict deliberately. A verdict whose
-- inputs are invisible is one nobody can overrule, and the threshold below is a
-- judgement call that deserves to be second-guessed from the log.
local _lastAckWall   = 0   -- epoch of the last message from the server
local _beatsSinceAck = 0   -- heartbeats ATTEMPTED since then
local _beatsUnsent   = 0   -- ... of which this many had no modem to go out on
local _commsGapSeen  = false -- a deliberate modem-off window was flagged
local _loopTurns     = 0   -- control-loop iterations since then
local _loopGapMax    = 0   -- longest pause between two consecutive iterations
local _lastLoopWall  = 0

-- ── The healthy baseline ─────────────────────────────────────────────────────
--
-- Every counter above is reset by witnessAck, which fires on any message from
-- the server. That is right for the verdict -- it describes the window the
-- turtle lost -- but it means the loop rate is only ever REPORTED from windows
-- where ACKs were already going missing.
--
-- Measured 2026-09-14: median 1.77 loop turns/second across 666 witness
-- samples, against a floor of 3.0 inbound messages/second per turtle. Every
-- private reply from the server rides ONE shared channel, so each turtle
-- receives all fifteen turtles' traffic and discards fourteen fifteenths of it.
-- That looks like a receiver that cannot keep up -- but with no healthy sample
-- to compare against it is equally consistent with a loop that normally runs
-- fast and merely sags during the bad windows. Those two readings point at
-- different faults and nothing in the log could tell them apart.
--
-- So: counters that are NOT reset by an ACK, reported on a slow cadence. Their
-- only job is to give that 1.77 something to be measured against.
local _baseTurns   = 0   -- loop iterations since the last baseline report
local _baseGapMax  = 0   -- longest pause between two of them, ms
local _baseSince   = 0   -- epoch this baseline window opened

-- THE DRAIN, which is the number that actually settles it.
--
-- Loop rate alone cannot: a slow loop that still keeps pace with its mailbox is
-- not a bottleneck. The spec owner's ruling asks for messages arriving against
-- messages handled, and would drop the per-turtle-channel proposal on this alone
-- if handled keeps pace.
--
-- Queue depth is not readable -- CC exposes no API -- so "arriving" cannot be
-- counted directly. But the server ACKs every heartbeat from a known turtle,
-- unconditionally and exactly once. So over a healthy window, acks seen against
-- beats sent counts how much of what was DEFINITELY sent to this turtle reached
-- its control loop. No fleet-size assumption, no inference, and a shortfall is
-- loss rather than evidence of it.
local _baseMsgs    = 0   -- every modem_message the control loop handled
local _baseAcks    = 0   -- ... of which came from the server, to us
local _baseBeats   = 0   -- heartbeats this turtle sent in the window

-- The control loop blocks on os.pullEvent, and when nothing else is happening
-- the only thing that wakes it is the wakeup timer at CFG.HEARTBEAT_INTERVAL.
-- So a five-second pause on an idle turtle is not a stall, it is the design.
--
-- Set at TWICE that, because a threshold drawn from the busy case is how the
-- phase-stuck detector cried wolf fourteen times on 2026-09-09: its bar came
-- from the fast early phases, and DUMPING legitimately lasts most of a sector.
-- Nothing schedules a ten-second gap, so at or above it the turtle was not
-- running.
local WITNESS_FREEZE_MS = CFG.HEARTBEAT_INTERVAL * 1000 * 2

local function witnessTurn(now)
    if _lastLoopWall > 0 then
        local gap = now - _lastLoopWall
        if gap > _loopGapMax then _loopGapMax = gap end
        if gap > _baseGapMax then _baseGapMax = gap end
    end
    _lastLoopWall = now
    _loopTurns    = _loopTurns + 1
    _baseTurns    = _baseTurns + 1
    if _baseSince == 0 then _baseSince = now end
    -- Sampled per iteration rather than read at report time: the flag is
    -- cleared again when the swap finishes, so by the time the turtle notices
    -- it has lost the server the window that caused it has usually closed.
    if _self.commsGap then _commsGapSeen = true end
end

local function witnessAck(now)
    _lastAckWall   = now
    _beatsSinceAck = 0
    _beatsUnsent   = 0
    _commsGapSeen  = false
    _loopTurns     = 0
    _loopGapMax    = 0
end

-- The line that separates the explanations.
--
-- THERE WERE THREE, not two, and the first real capture found the one neither
-- half of this comment predicted. node_138, 2026-09-10 10:08:06, mid-job:
--
--   18.7s since last ACK, 3 beats sent, loop turned 102x, worst pause 0.9s
--
-- 102 turns and a 0.9s worst pause: emphatically running. So the first version
-- of this function said "the ACKs did not arrive", which reads as a lost-message
-- bug. It was not. The turtle was in the loader-retrieval ascent, where
-- equipment.retrievalSwapIn takes the MODEM off to fit the chunk loader --
-- chunk loading outranks comms. It had no radio. Nothing was lost, because
-- nothing was ever transmitted.
--
-- "3 beats sent" was the giveaway and the instrument said it anyway: sendHeartbeat
-- had been CALLED three times, and comms.toServer had pcall'd its way past a nil
-- peripheral each time. Attempted is not sent, and a witness that cannot tell
-- those apart hands back a confident wrong answer -- which is worse than the
-- silence it replaced, because someone will act on it.
--
-- The fleet already knows about these windows: _self.commsGap is set for exactly
-- this reason and the server prints "(comms gap expected)" beside the phase. The
-- turtle just was not consulting its own flag.
--
-- Clauses are ADDED, not chosen between. A turtle can freeze during a swap, and
-- an either/or verdict would hide whichever it checked second.
local function witnessVerdict(now)
    -- A turtle that has never heard from the server has no baseline, and
    -- "0.0s since last ACK" would read as a server that answered a moment ago.
    -- Saying so is the difference between a measurement and a plausible lie.
    if _lastAckWall == 0 then
        return string.format(
            "no ACK since boot, %d beats attempted, loop turned %dx, worst pause %.1fs "
            .. "[never connected — nothing to compare against]",
            _beatsSinceAck, _loopTurns, _loopGapMax / 1000)
    end

    local why = {}
    if _beatsUnsent > 0 then
        why[#why + 1] = string.format(
            "no radio for %d of them — %s", _beatsUnsent,
            _commsGapSeen and "a declared comms gap, nothing was lost"
                           or "and NO comms gap was declared")
    end
    if _loopGapMax >= WITNESS_FREEZE_MS then
        why[#why + 1] = "this turtle stopped running"
    end
    -- Only reachable with a radio attached and a loop that kept turning, which
    -- is the ONLY combination that means a message went missing.
    if #why == 0 then
        why[1] = "radio on and loop turning — the ACKs did not arrive"
    end

    return string.format(
        "%.1fs since last ACK, %d beats attempted, loop turned %dx, worst pause %.1fs [%s]",
        (now - _lastAckWall) / 1000, _beatsSinceAck, _loopTurns,
        _loopGapMax / 1000, table.concat(why, "; "))
end

-- Test seams. The production callers are the control loop, the server-message
-- gate in dispatchControl and sendHeartbeat, none of which can be reached
-- without standing up a registration, a modem and three heartbeat boundaries.
function base._witnessTurn(now)    witnessTurn(now)    end
function base._witnessAck(now)     witnessAck(now)     end
function base._witnessVerdict(now) return witnessVerdict(now) end
function base._witnessBeat(noRadio)
    _beatsSinceAck = _beatsSinceAck + 1
    if noRadio then _beatsUnsent = _beatsUnsent + 1 end
end
function base._witnessCommsGap()   _commsGapSeen = true end

-- One line every BASELINE_EVERY beats. Deliberately INFO, not WARN: it is not a
-- fault, it is the control group. Reported only when the turtle is NOT in
-- trouble -- a baseline taken during a disconnect would be the very sample we
-- already have too much of.
--
-- WAS 20 (~100 s), AND THAT WAS TOO OFTEN. Measured 2026-09-15 on 1.9.106:
-- 438 of the fleet's 1,143 log lines per hour were this one line -- 38% of all
-- traffic -- and log loss rose to 2.50% against 0.1-0.7% on every earlier
-- reading. An instrument that is more than a third of the traffic is not
-- observing the system, it is loading it, and this one was loading the very
-- channel whose losses it exists to measure.
--
-- 60 (~5 min) cuts it to ~13% of traffic. The numbers it was built for are
-- already banked -- 480 healthy samples inside three hours, far more than the
-- comparison needed -- so the cadence can drop by two thirds and still deliver
-- a usable sample over any run long enough to matter.
local BASELINE_EVERY = 60

-- Returns the line as well as logging it. A test that had to scrape print()
-- output would be asserting on the logger, not on the arithmetic, and the
-- arithmetic is the whole point of this instrument.
local function reportBaseline(now)
    if _baseSince == 0 or _baseTurns == 0 then return nil end
    local span = now - _baseSince
    if span <= 0 then return nil end
    local line = string.format(
        "loop baseline: %.2f turns/s, %.2f msgs/s handled, %d acks for %d beats "
        .. "over %.0fs (%d turns, worst pause %.1fs) [healthy]",
        _baseTurns / (span / 1000), _baseMsgs / (span / 1000),
        _baseAcks, _baseBeats, span / 1000, _baseTurns, _baseGapMax / 1000)
    logInfo(line)
    -- Reset, so each line describes its OWN window. Without this the rate
    -- converges on a lifetime average and stops being able to show a change.
    _baseTurns, _baseGapMax, _baseSince = 0, 0, now
    _baseMsgs, _baseAcks, _baseBeats = 0, 0, 0
    return line
end
base._reportBaseline = reportBaseline   -- test seam

-- Test seam for the drain counters. They are bumped from three production
-- places the tests cannot reach -- the control loop's modem_message branch, the
-- server-message gate, and sendHeartbeat -- so the ARITHMETIC is exercised
-- through here and the WIRING is pinned by source assertions. Neither alone is
-- enough: a seam-only test passes against production that never counts, and a
-- source-only test passes against arithmetic that is wrong.
function base._baselineBump(msgs, acks, beats)
    _baseMsgs  = _baseMsgs  + (msgs  or 0)
    _baseAcks  = _baseAcks  + (acks  or 0)
    _baseBeats = _baseBeats + (beats or 0)
end

local function sendHeartbeat()
    _heartbeatCount = _heartbeatCount + 1
    _beatsSinceAck  = _beatsSinceAck + 1
    _baseBeats      = _baseBeats + 1
    -- Skipped while the turtle believes the server is gone: this is the healthy
    -- control group, so a sample taken mid-disconnect would defeat its purpose.
    if _heartbeatCount % BASELINE_EVERY == 0 and not _self.serverDown then
        reportBaseline(os.epoch("utc"))
    end
    -- Periodic GPS resync so idle or error-state turtles self-correct position drift.
    -- GPS locate needs no movement — just radio signal from beacons. Silent on failure.
    if _heartbeatCount % 12 == 0 then
        gpsSync()
    end
    -- Counted from the send's RESULT, not from the modem handle.
    --
    -- 1.9.96 checked `not _self.modem`, and that is never true during the very
    -- window it was written for: equipment.retrievalSwapIn takes the modem off
    -- and nothing clears the turtle's handle to it. The wrapper stays, detached,
    -- and every call on it raises. So a radio-less turtle was reported as
    -- "radio on and loop turning -- the ACKs did not arrive": the first
    -- version's wrong answer, shipped again one release later as the fix for it.
    local sent = comms.toServer(proto.MSG.HEARTBEAT, proto.payloadHeartbeat(
        _self.status, fuel.level(), base.getPos(), _self.jobId,
        { phase = _self.phase, chunk = _self.chunk, commsGap = _self.commsGap,
          hardware = base.hardwareVerdict() }))
    if not sent then _beatsUnsent = _beatsUnsent + 1 end
    _missedHeartbeats = _missedHeartbeats + 1

    -- If too many heartbeats go unacknowledged, server is unreachable.
    -- Pause movement and wait — re-register until server responds.
    if _missedHeartbeats >= MAX_MISSED then
        if not _self.serverDown then
            logWarn(string.format(
                "Server unreachable — pausing at %d,%d,%d — %s",
                _self.pos.x, _self.pos.y, _self.pos.z,
                witnessVerdict(os.epoch("utc"))))
            _self.serverDown = true
        end
        -- Whatever the next flush carries was written across a window where the
        -- server was not listening, so it does not get thrown at the void once
        -- and forgotten. See the note on markSuspect in logship.lua.
        _log:markSuspect()
        _missedHeartbeats = 0
        local ok = pcall(register)
        if not ok then
            logWarn("Re-registration failed, will retry next heartbeat.")
        end
    end
end

-- Test seam. The only way to show the witness counts a beat that could not go
-- out is to send a real one into a detached modem; everything else reaches the
-- counter through base._witnessBeat, which is exactly how 1.9.96's wrong test
-- for "no radio" passed while the production check could never fire.
base._sendHeartbeat = sendHeartbeat

-- Called when server responds to confirm it's alive (on any valid message back)
local function resetMissedHeartbeats()
    _missedHeartbeats = 0
end

-- ─── Job Helpers ─────────────────────────────────────────────────────────────

function base.setStatus(status, jobId)
    _self.status = status
    if jobId ~= nil then _self.jobId = jobId end
end
function base.statusForTest() return _self.status end   -- test seam

function base.sendProgress(detail)
    comms.toServer(proto.MSG.STATUS_UPDATE, proto.payloadStatusUpdate(
        _self.jobId, _self.status, detail, base.getPos()))
end

function base.sendComplete(result)
    -- Logged because it is fire-and-forget: job_0052 and job_0061 docked with
    -- no "Job complete" on the server, and without this line "never sent" and
    -- "sent and lost" look identical. It rides the log outbox, so it can arrive
    -- after the fact even when the message itself did not.
    -- REPEATED UNTIL THE SERVER HAS IT, as a JOB_FAILED is (sim w3_side_atc: working through a
    -- server outage, node_35 finished job_0050 with the server down; the one JOB_COMPLETE was
    -- lost, the job stayed open for good, and two later orders to its destination were never sent).
    local cp = proto.payloadJobComplete(_self.jobId, result)
    if _self.jobId then
        local now = os.epoch("utc")
        _self.completesOut = _self.completesOut or {}
        _self.completesOut[_self.jobId] = { p = cp, at = now, untilMs = now + 600000 }
    end
    local sent = comms.toServer(proto.MSG.JOB_COMPLETE, cp)
    logInfo(string.format("JOB_COMPLETE sent for %s%s", tostring(_self.jobId),
        sent and "" or " -- the send FAILED (no modem)"))
    _self.status    = proto.STATUS.IDLE
    _self.jobId     = nil
    _self.partnerId = nil
    _self.busy      = false
end

-- A JOB_FAILED IS REPEATED UNTIL THE SERVER HAS IT (2026-11-18, SPEC-OWNER's ruling;
-- sim w3_depart_off_dock: one sent once was thrown away in the server's RS-poll
-- wait, and the job never came back). Each one carries its own failId; the control
-- loop sends it again every FAIL_REPEAT_MS (base.keepFails) until JOB_FAILED_ACK for
-- that failId arrives, for up to 10 minutes. The server takes each failId once.
local FAIL_REPEAT_MS = 10000
function base.reportFailed(jobId, reason, recoverable)
    local p = proto.payloadJobFailed(jobId, reason, recoverable)
    _self.failSeq = (_self.failSeq or 0) + 1
    local now = os.epoch("utc")
    p.failId = tostring(_self.id) .. ":" .. tostring(math.floor(now)) .. ":" .. tostring(_self.failSeq)
    _self.failsOut = _self.failsOut or {}
    _self.failsOut[p.failId] = { p = p, at = now, untilMs = now + 600000 }
    comms.toServer(proto.MSG.JOB_FAILED, p)
    return p.failId
end
function base.keepFails(now)
    for id, c in pairs(_self.completesOut or {}) do
        if now >= c.untilMs then
            _self.completesOut[id] = nil
        elseif now - c.at >= FAIL_REPEAT_MS then
            c.at = now
            comms.toServer(proto.MSG.JOB_COMPLETE, c.p)
        end
    end
    if not _self.failsOut then return end
    for id, f in pairs(_self.failsOut) do
        if now >= f.untilMs then
            _self.failsOut[id] = nil
        elseif now - f.at >= FAIL_REPEAT_MS then
            f.at = now
            comms.toServer(proto.MSG.JOB_FAILED, f.p)
        end
    end
end

function base.sendFailed(reason, recoverable)
    -- A DELIVERY OUT IN THE WORLD BRINGS ITS SUPPORT HOME FIRST (2026-11-14). Its
    -- support follows it one block behind through the tunnel it digs, and gets
    -- home only that way: it cannot dig. A JOB_ABORT here sent the support home
    -- alone, through rock -- 6 of 8 stranded in the side-test sim (w3_side_atc).
    -- So the failure waits: the job runner takes it home exactly as after a
    -- delivery (DESCENDED, then the support follows, ASCENDING and RETURN_TO_DOCK
    -- name the holding slot), and says the job failed once it is docked.
    -- A RECALL TOO (R4, 2026-11-17): recalled out in the world -- the warehouse's
    -- timeout recalled one already on its way home -- it sent its support JOB_ABORT
    -- and dropped it, and the support went home alone and stayed in the tunnel (sim
    -- w3_pair_recalled_home). The job code brings it home with its partner kept.
    if _self.role == proto.ROLE.DELIVERY and _self.partnerId and _self.jobId and not _self.failLater
       and not (_self.pos.y == CFG.FLOOR_Y and base.isInsideBuilding(_self.pos)) then
        _self.failLater = { reason = reason, recoverable = recoverable, partner = _self.partnerId }
        logWarn(string.format("Job %s failed (%s) at %d,%d,%d -- bringing support %s home first, then reporting it",
            tostring(_self.jobId), tostring(reason), _self.pos.x, _self.pos.y, _self.pos.z, tostring(_self.partnerId)))
        return
    end
    -- Tell support to abort immediately so it doesn't wait 180s for HOLE_READY.
    -- Not when this turtle is a support standing down because its delivery went
    -- on without it: the delivery is out working, and this JOB_ABORT ended its job
    -- at the destination (sandbox/scenarios/w3_atc_partner_left.lua, 2026-11-12).
    if _self.partnerId and not tostring(reason):find("partner_left", 1, true) then
        base.signalPartnerDirect(proto.MSG.JOB_ABORT, _self.partnerId, { reason = reason, jobId = _self.pairJobId })
    end
    base.reportFailed(_self.jobId, reason, recoverable)
    _self.status    = proto.STATUS.IDLE
    _self.jobId     = nil
    _self.partnerId = nil
    _self.busy      = false
end

-- Generic send to server — used by delivery turtle for warehouse handshake messages
function base.sendToServer(msgType, payload)
    comms.toServer(msgType, payload)
end

-- Send a direct CH_LOCAL signal to the paired partner turtle
function base.signalPartner(msgType, payload)
    if not _self.partnerId or not _self.modem then return end
    local sig = proto.encode(msgType, _self.id, _self.partnerId, payload or {})
    proto.send(_self.modem, proto.CH_LOCAL, sig)
end

-- Like signalPartner but uses an explicit target ID.
-- Use this when partnerId has been temporarily cleared to stop broadcasts
-- but you still need to send one final signal (e.g. ASCENDING, RETURN_TO_DOCK).
function base.signalPartnerDirect(msgType, targetId, payload)
    if not targetId or not _self.modem then return end
    local sig = proto.encode(msgType, _self.id, targetId, payload or {})
    proto.send(_self.modem, proto.CH_LOCAL, sig)
end

function base.queryTurtle(targetId, timeout)
    comms.toServer(proto.MSG.TURTLE_QUERY, proto.payloadTurtleQuery(targetId))
    -- Waits for TURTLE_INFO specifically. Previously took whatever arrived
    -- first and discarded it if the type did not match -- the same loss the
    -- registration storm was made of.
    local reply = base.receive(timeout or 5, proto.MSG.TURTLE_INFO)
    if reply then
        return reply.payload
    end
    return nil
end

-- Wait for one of several message types, returning the message or nil on
-- timeout / recall. Freezes the deadline while the server is unreachable.
function base.waitForAny(types, seconds)
    local set = {}
    for _, t in ipairs(types) do set[t] = true end
    local deadline = os.epoch("utc") / 1000 + seconds
    while os.epoch("utc") / 1000 < deadline do
        if base.isRecalled() then return nil end
        if base.isServerDown() then
            deadline = os.epoch("utc") / 1000 + seconds
            sleep(2)
        else
            -- The set is passed down rather than filtered here, so a message
            -- outside it stays queued instead of being dropped.
            local msg = base.receive(math.max(1, deadline - os.epoch("utc") / 1000), set)
            if msg then return msg end
        end
    end
    return nil
end

-- ─── Init ────────────────────────────────────────────────────────────────────

-- Boot homing, out of base.init so it can be tested (review #1, release 2).
-- MAY THIS TURTLE RESUME WHERE IT STANDS? (W1, resume-after-restart card.)
--
-- A role installs a predicate BEFORE base.init; nil means "no", which is every
-- role's behaviour until it says otherwise. It exists because the decision has
-- to be made in base.init and the facts live in the role: only ore_turtle knows
-- whether it wrote down a sector order before its loader went into the ground.
--
-- WHY IT CANNOT WAIT FOR THE ROLE'S OWN RECOVERY. homeAfterBoot runs inside
-- base.init, and for a field reboot it sends "recovering: at x,y,z". The server
-- reads that one string as "this turtle is flying home", requeues the miner's
-- job and drops the re-send it was holding for the first heartbeat -- measured
-- in the simulator:
--     Queuing re-send of job_0001 to rebooted turtle node_11
--     Re-send of job_0001 to node_11 held for its first heartbeat
--     node_11 is recovering from a reboot and flying home -- job_0001 requeued
--     Held re-send of job_0001 to node_11 dropped: no longer its job
-- All of that happens before ore_turtle's own recovery gets a say, so a miner
-- that fully intended to resume found its job already given away and stood in
-- the field with nothing to do. The announcement is the thing that has to be
-- withheld, and this is the only place it is made.
--
-- W1 CHANGING A W3 FILE, said out loud: the card names turtle_base as where
-- this belongs, the baton ruling of 2026-10-27 is that the holder writes and
-- runs its own tests rather than relaying, and the alternative was to leave the
-- last shakeout prerequisite blocked on a one-line hand-off. Mailed to
-- SPEC-OWNER and W3 with this reasoning.
local _mayResumeHere = nil
function base.setResumeIntent(fn) _mayResumeHere = fn end

-- WHAT TO DO IF NO JOB EVER COMES. A role installs fn and a wall-clock gap in
-- seconds; the job runner calls it while it has nothing to run.
--
-- It exists because of a hole the resume-after-restart card opened and could
-- not close from the role side. A miner that holds position instead of flying
-- home is waiting for the job the server re-sends on its first heartbeat -- and
-- if that job was cancelled meanwhile, nothing arrives and nothing ever will.
-- Measured in the simulator: "Recall-all cancelled 1 unfinished job(s)" then
-- "Held re-send of job_0001 to node_11 dropped: no longer its job", and the
-- miner stood in the field indefinitely. It could not even hear the recall,
-- because boot recovery has its modem swapped out for the chunk loader.
--
-- WALL CLOCK, NOT A TIMER, deliberately: parallel.waitForAny consumes os timer
-- events, so a timer started here would fight the control loop for them and
-- whole rounds would vanish. Every event the runner already wakes on moves this
-- forward instead, and heartbeats alone guarantee it runs.
local _idleFn, _idleMs = nil, 0
function base.setIdleAction(fn, seconds)
    _idleFn = fn
    _idleMs = (tonumber(seconds) or 0) * 1000
end
function base.mayResumeHere()
    if type(_mayResumeHere) ~= "function" then return false end
    local ok, v = pcall(_mayResumeHere)
    -- A predicate that raises means the role cannot answer, and "cannot answer"
    -- must read as no: the old flight home is the safe direction.
    return ok and v == true
end

function base.homeAfterBoot()
    -- If not physically at assigned dock, home there now before accepting any jobs.
    -- This corrects position mismatches caused by crashes, reassignments, or reboots.
    -- Only runs when inside the building at floor level (safe to use internal taxiway).
    if _self.dock then
        -- THE ROUTE IS CHOSEN FROM A MEASURED POSITION (review #1, release 2).
        -- A single gpsSync that failed left (0,0,0), which is never "inside", so
        -- a turtle sitting at its own dock took the outside route -- and once
        -- GPS returned, delivery dug down through its station chest and the
        -- floor. Miners keep their behaviour: ore_turtle measures before it
        -- decides anything outside the base.
        if _self.role == proto.ROLE.MINER then
            gpsSync()
        else
            base.waitForPositionFix("boot: choosing a route home")
        end
        local p = _self.pos
        local insideBuilding = base.isInsideBuilding(p)
        local atDock = (p.x == _self.dock.x and p.z == _self.dock.z)
        if insideBuilding and not atDock then
            logInfo(string.format("Not at dock (%d,%d) — homing from (%d,%d)...",
                _self.dock.x, _self.dock.z, p.x, p.z))
            base.returnToDockInternal()
        elseif atDock and _self.saidStuckNoFix then
            -- IT SAID IT WAS STUCK, SO IT MUST SAY IT IS DOCKED. The server holds a
            -- stuck_no_fix turtle until it reports docked, and a turtle already on
            -- its own dock never went home, so it never said so: 144 of 150 sat
            -- held for five hours after the boot rush for the aisle (sim, 2026-11-03).
            _self.saidStuckNoFix = nil
            pcall(base.sendProgress, "docked")
        elseif not insideBuilding then
            -- A FIELD REBOOT, ANY ROLE (recovery layer release 3). Say so -- the
            -- server requeues the job this turtle held and holds it until it
            -- docks -- and take back what the ledger says it left out, BEFORE
            -- the first step toward home: the item is beside it now, and every
            -- later step takes it further away.
            -- THE LEDGER FIRST EITHER WAY. Whatever happens next, anything this
            -- turtle left on the ground is beside it NOW and every later step
            -- takes it further away.
            local rok, rerr = pcall(base.recoverLedger)
            if not rok then logWarn("Ledger recovery before flying home failed: " .. tostring(rerr)) end
            -- A ROLE THAT MAY RESUME SAYS NOTHING YET. "recovering:" is read by
            -- the server as "flying home" and costs this turtle its job before
            -- its own recovery has even run. The role decides and announces.
            if base.mayResumeHere() then
                logInfo(string.format(
                    "Rebooted outside building at %d,%d,%d with an order to resume"
                    .. " — deferring to the role, not announcing a recovery",
                    p.x, p.y, p.z))
                return
            end
            pcall(base.sendProgress, string.format("recovering: at %d,%d,%d", p.x, p.y, p.z))
            if _self.role == proto.ROLE.MINER then
                logInfo(string.format(
                    "Miner rebooted outside building at %d,%d,%d — deferring return to job handler",
                    p.x, p.y, p.z))
            elseif _self.role == proto.ROLE.SUPPORT and p.y > CFG.FLOOR_Y + 20 then
                logInfo(string.format(
                    "Mining support rebooted at altitude %d,%d,%d — deferring return to job handler",
                    p.x, p.y, p.z))
            else
                logInfo(string.format(
                    "Rebooted outside building at %d,%d,%d — returning via arrivals hole",
                    p.x, p.y, p.z))
                base.returnToDock()
            end
        end
    end
end

function base.init(role)
    _self.id   = proto.selfId()
    _self.role = role
    -- Delivery and miner turtles reserve slot 16 for their own ender chest
    -- (delivery EC / ore EC), so the fuel ender chest lives in slot 15.
    if role == proto.ROLE.DELIVERY or role == proto.ROLE.MINER then
        CHEST_SLOT = 15
        logInfo("Fuel ender chest slot set to 15 (" .. role .. " role)")
    end
    -- BURN_MAX = highest slot we'll ever suck coal into or burn from.
    -- Always cap at 14 so slots 15 and 16 are never touched by fuel ops.
    BURN_MAX = math.min(CHEST_SLOT - 1, 14)
    logInfo("Fuel burn range: slots 1-" .. BURN_MAX)
    -- A miner's kit lives in slots 1-4, inside the debris sweep's range, so it
    -- must be protected before anything can refuel. Registered here rather than
    -- left to ore_turtle for two reasons: it has to hold on every boot including
    -- one where comms.init below fails and ore_turtle's module load never gets
    -- past base.init, and turtle_base owns the sweep so it owns the guard.
    --
    -- equipment.lua does not ship to delivery or support (see install.lua
    -- PROFILES), so this is deliberately optional -- those roles keep the
    -- unprotected sweep, which is correct for them.
    if role == proto.ROLE.MINER then
        local okEq, eq = pcall(require, "equipment")
        if okEq and eq then
            base.setProtectedSlots(
                { eq.SLOTS.SCANNER, eq.SLOTS.LOADER, eq.SLOTS.TOOL, eq.SLOTS.MODEM },
                { eq.ITEMS.SCANNER, eq.ITEMS.LOADER_TURTLE,
                  eq.ITEMS.PICKAXE, eq.ITEMS.CHUNKY, eq.ITEMS.MODEM })
            logInfo("Protected slots 1-4 — the debris sweep will not drop miner hardware")
            -- The coal reserve the miner keeps stocked; a refuel never returns it.
            _self.fuelReserveSlot = eq.SLOTS.COAL
        else
            logWarn("equipment.lua unavailable — debris sweep is UNPROTECTED on this miner")
        end
    end
    print(string.format("=== %s [%s] v%s booting ===", _self.id, role, proto.VERSION))
    comms.init()
    _self.bootGuard = true   -- tryMove waits for a measured position and facing
    initPosition()
    fuel.refuel()
    -- Miner only: bounded so a field reboot with a placed loader can get to
    -- ore_turtle's recoverPlacedLoader without the server. nil (unbounded, the
    -- original behaviour) for every other role.
    -- Its dock from before the reboot, so a boot with no server still knows where
    -- home is (node_481, 24h-b); registering replaces it with the server's.
    if not _self.dock and base.loadSavedDock() then
        logInfo(string.format("Dock from before the reboot: bay %s row %s (%d,%d)",
            tostring(_self.dock.bay), tostring(_self.dock.row), _self.dock.x, _self.dock.z))
    end
    register(role == proto.ROLE.MINER and BOOT_REGISTER_ATTEMPTS or nil)
    base.homeAfterBoot()
    -- Startup homing may have set status to RETURNING — reset to IDLE now we're docked.
    _self.status = proto.STATUS.IDLE
    _self.jobId  = nil
    -- Face toward taxiway so the turtle is oriented consistently at its dock on boot.
    if _self.dock then move.face(W.dockFacing(_self.dock)) end
    logInfo(string.format("Ready. Fuel:%d/%d  Pos:%d,%d,%d  Dock:%s",
        fuel.level(), fuel.max(),
        _self.pos.x, _self.pos.y, _self.pos.z,
        _self.dock and ("bay ".. _self.dock.bay .." row ".. _self.dock.row) or "none"))
end

-- ─── Main Event Loop ─────────────────────────────────────────────────────────
-- Uses parallel to run the job handler and the control loop concurrently.
-- This ensures the job coroutine receives warehouse events (e.g. CHESTS_READY)
-- while the control loop still handles heartbeats and RECALL.

-- Recover everything the ledger says this turtle left in the world. Called at
-- the top of base.run, so every role does it at boot; exported so a role with
-- its own pre-run recovery (ore_turtle's loader) can call it first -- the chest
-- is adjacent and cheap, the loader recovery flies away. A no-op when empty.
-- Take back only what this turtle placed where it stands now: a job that ends
-- away from its dock ends where it failed, beside what it placed there. A
-- delivery whose job failed at its destination left its ender chest standing, and
-- every job given it after failed at once (ec_not_in_slot_16_at_dispatch, three
-- times over, sim w3_side_atc). Anything placed elsewhere is left to boot recovery:
-- asked for away from it, recover() would call for hands that are not needed.
function base.ledger.recoverHere()
    local n = 0
    for kind in pairs(base.ledger._kinds or {}) do
        local e = base.ledger.get(kind)
        local at = e and e.turtleAt
        if at and at.x == _self.pos.x and at.y == _self.pos.y and at.z == _self.pos.z then
            local ok, got = pcall(base.ledger.recover, kind)
            if ok and got then n = n + 1 end
        end
    end
    if n > 0 then logInfo(string.format("Ledger: took back %d item(s) placed here before going home", n)) end
    return n
end

function base.recoverLedger()
    local n = base.ledger.recoverAll()
    if n > 0 then logInfo(string.format("Ledger: recovered %d item(s) at boot", n)) end
    return n
end

function base.run(jobHandler)
    _self.running = true    -- heartbeats and the log outbox from here on (waitReporter)
    -- Before the loop, so before any job can reach this turtle. pcall'd: a
    -- recovery that throws must not stop the turtle running at all.
    local lok, lerr = pcall(base.recoverLedger)
    if not lok then logWarn("Ledger recovery at boot failed: " .. tostring(lerr)) end
    -- Wall-clock heartbeat: immune to timer events being consumed by sleep() inside ensureFuel()
    local lastHeartbeatWall = os.epoch("utc")
    local heartbeatTarget   = heartbeatGap()
    -- The outbox was created at module load, which on a real turtle is a second
    -- or so ago and on a fake clock is a different clock entirely. Realign it
    -- with the one this loop actually reads.
    _log:resetInterval(os.epoch("utc"))
    local wakeupTimer       = os.startTimer(CFG.HEARTBEAT_INTERVAL)
    local pendingJob        = nil   -- job table waiting to be started
    local jobCo             = nil   -- running job coroutine

    -- Action one control-plane message.
    --
    -- The SAME function serves both arrival paths -- pulled straight off the
    -- wire, and drained out of _ctrlInbox -- because the defect this replaces
    -- was precisely that the two paths did different things. A message that took
    -- the queue must behave exactly as one that did not.
    local function dispatchControl(msg)
        -- ONLY the server's own traffic is evidence the server is alive. Every
        -- server->turtle message carries from = "server" (central_server.lua's
        -- sendTo/sendBroadcast are the only two senders), so this gate is exact.
        --
        -- Resetting on *any* addressed message was a fleet-wide fault, not a
        -- miner-only one: a placed chunk loader broadcasts LOADER_BEACON to
        -- "broadcast" on CH_LOCAL every 5s (loader_turtle.lua), every turtle
        -- opens CH_LOCAL, and the modems are ender modems with effectively
        -- unlimited range. MAX_MISSED=3 at a 5s heartbeat needs 15s to trip, so
        -- one loader standing anywhere in the world held _missedHeartbeats at 0
        -- for EVERY turtle. That suppressed the missed-ACK re-registration path
        -- in sendHeartbeat -- the only way a running turtle rejoins the server's
        -- in-memory registry after a restart -- for delivery and support too, and
        -- made base.isServerDown() permanently false exactly when a loader was
        -- out.
        --
        -- Partner traffic (POSITION_UPDATE, SUPPORT_STAGED, ...) and warehouse
        -- traffic (from = "warehouse") are not evidence about the server either,
        -- so this gate is strictly more correct than resetting on all of them.
        --
        -- This line is ALSO half of the 1.9.74 storm fix: it used to sit on the
        -- direct-pull path only, so an ACK that arrived while this coroutine was
        -- inside pumpFor was filed and never acted on.
        if msg.from == "server" then
            _baseAcks = _baseAcks + 1
            resetMissedHeartbeats()
            -- Same gate, same reason: only the server's own traffic is
            -- evidence that the server is alive, so only it may clear the
            -- window this turtle would otherwise have to report on.
            witnessAck(os.epoch("utc"))
        end

        if msg.type == proto.MSG.JOB_ASSIGN and not _self.busy then
            local job = msg.payload
            comms.toServer(proto.MSG.JOB_ACK,
                proto.payloadJobAck(job.jobId, true, nil))
            _self.busy   = true
            _self.jobId  = job.jobId
            _self.status = proto.STATUS.TRAVELLING
            pendingJob   = { id=job.jobId, type=job.jobType, params=job.params }
            _self.jobSince = os.epoch("utc")

        elseif msg.type == proto.MSG.JOB_ASSIGN and _self.busy then
            comms.toServer(proto.MSG.JOB_ACK,
                proto.payloadJobAck(msg.payload.jobId, false, "busy"))

        elseif msg.type == proto.MSG.RECALL then
            logWarn("RECALL: " .. (msg.payload.reason or "?"))
            if _self.busy then
                -- Signal the job runner to exit its current wait loop.
                -- The job runner will clean up (pick up EC etc.) then
                -- call returnToDock itself. Control loop must NOT also
                -- navigate or the two coroutines fight over movement.
                _self.recalled = true
                pendingJob = nil
                -- A miner's recallReturn() has to retrieve its placed
                -- chunk loader before it can come home, and it reports
                -- the failure itself once that is done. sendFailed here
                -- would end the job while the loader is still standing.
                if _self.role ~= proto.ROLE.MINER then
                    base.sendFailed("recalled", true)
                end
            elseif _self.homing then
                -- ALREADY GOING HOME (2026-11-15). The job runner takes a turtle home
                -- when a job ends away from its dock; a RECALL then -- the job given
                -- to another, a stale support -- found it not busy and started a SECOND
                -- trip home from this loop, both coroutines moving it, and this loop
                -- stopped beating: the server called it offline while it wandered
                -- (sim w3_atc_lost_release, node_56). One trip home at a time.
                logInfo("RECALL while already on my way home -- carrying on")
            else
                -- Idle turtle: navigate directly.
                local insideBuilding = base.isInsideBuilding(_self.pos)
                if insideBuilding then
                    base.returnToDockInternal()
                elseif _self.pos.y >= 100 then
                    -- Turtle is at sky altitude (mine recall position) —
                    -- fly home at Y=200 via arrivals hole, not underground.
                    base.returnToDockFromSky()
                else
                    base.returnToDock()
                end
                _self.busy   = false
                _self.status = proto.STATUS.IDLE
                _self.jobId  = nil
            end

        elseif msg.type == proto.MSG.FORCE_REFUEL then
            if not _self.busy and not _self.recalled
                    and base.isInsideBuilding(_self.pos) then
                logInfo("FORCE_REFUEL received — refuelling at dock")
                if _customRefuelFn then
                    _customRefuelFn()
                else
                    fuel.dockRefuel()
                end
                -- Push fresh fuel level so fleet panel updates immediately
                comms.toServer(proto.MSG.HEARTBEAT, proto.payloadHeartbeat(
                    _self.status, fuel.level(), base.getPos(), _self.jobId))
            elseif not base.isInsideBuilding(_self.pos) then
                logWarn("FORCE_REFUEL ignored — turtle not at dock")
            end

        elseif msg.type == proto.MSG.RE_REGISTER then
            -- _self.busy is deliberately left ALONE. It is what becomes
            -- midJob in the register payload, and clearing it would send
            -- the server down the rebooted-turtle branch -- the very path
            -- that makes a reboot useless for testing the sector gate.
            logWarn("RE_REGISTER received — reintroducing without rebooting")
            local ok, err = pcall(register)
            if not ok then
                logWarn("RE_REGISTER failed: " .. tostring(err))
            end

        elseif msg.type == proto.MSG.ATC_HELLO then
            -- The ATC booted with nothing: tell it where we are and what we
            -- still need. Only a turtle standing in a section has anything to say.
            base.atc.heard()
            if base.atc.here() then pcall(base.atc.report) end

        elseif msg.type == proto.MSG.REBOOT then
            -- Deliberately does NOT call sendFailed. The job is meant to
            -- survive as far as the server is concerned: what is under test
            -- is whether the server replays a sector order to a turtle that
            -- comes back mid-job. Failing the job first would remove the
            -- very condition being tested.
            logWarn("REBOOT received — rebooting now (requested)")
            _log:urgent()
            sleep(1)
            os.reboot()

        elseif msg.type == proto.MSG.UPDATE_ALL then
            local pin = msg.payload and proto.isCommitRef(msg.payload.ref) and msg.payload.ref
            logWarn("UPDATE_ALL received — running updater then rebooting"
                .. (pin and (" (pinned to " .. pin:sub(1, 10) .. ")") or " (from master)"))
            if _self.busy and _self.jobId then
                base.sendFailed("update_all", false)
            end
            -- Fetch the commit the deploy named, not whatever master's cache holds.
            proto.stageUpdateRef(msg.payload and msg.payload.ref)
            sleep(1)
            if fs.exists("updater.lua") then
                shell.run("updater")
            else
                logWarn("updater.lua not found — rebooting anyway")
                os.reboot()
            end

        elseif CTRL_TYPES[msg.type] then
            -- HEARTBEAT_ACK and REGISTER_ACK. Their entire meaning is the
            -- reset above, so they are CONSUMED here, not routed.
            --
            -- Routing them was the 1.9.74 bug: a control type handed back to
            -- routeMessage goes straight into the queue this dispatcher is
            -- draining, so the queue could never empty. It filled at one ACK
            -- per turtle per 5s, hit INBOX_MAX in about five minutes, and then
            -- evicted its oldest entry on every push -- taking a REGISTER_ACK
            -- with it. A late REGISTER_ACK reaching here is stale by
            -- construction: register() runs inside this coroutine and holds the
            -- inbox itself while it waits, so nothing is waiting for this one.
        else
            -- Anything the control loop does not itself act on
            -- belongs to a job handler or to worker coordination.
            -- ROUTED, not dropped: the handler may not be waiting
            -- at this instant, and a message that arrives before
            -- its reader does must still be there when it asks.
            -- Dropping it here is the same class of fault as the
            -- registration storm, one layer down.
            routeMessage(msg)
        end
    end

    -- Control loop: handles heartbeat, RECALL, and JOB_ASSIGN
    local function controlLoop()
        while true do
            -- Everything the control plane was handed while this coroutine was
            -- busy elsewhere, actioned before anything else this iteration.
            --
            -- WHY THIS EXISTS. Until 1.9.75 nothing popped _ctrlInbox at all.
            -- register()'s filtered receiveCtrl was its only reader, and it only
            -- ever takes a REGISTER_ACK. Every routed HEARTBEAT_ACK therefore
            -- accumulated -- one per turtle every 5 seconds -- and every routed
            -- RECALL was a turtle that never came home.
            --
            -- It drains BEFORE the heartbeat check below, so a queued ACK clears
            -- _missedHeartbeats before sendHeartbeat can increment it into
            -- MAX_MISSED. In the other order the fleet still storms, just one
            -- iteration later.
            local queued = base.drainCtrl()
            for i = 1, #queued do dispatchControl(queued[i]) end

            if fuel.isCritical() then
                fuel.ensureFuel()
                -- The re-arm that used to live here is now unconditional at the
                -- bottom of the loop, which covers this case and every other one.
            end

            -- Wall-clock heartbeat check (survives timer events being swallowed by sleep())
            local now = os.epoch("utc")
            -- One reading per iteration, so the gap between two of them
            -- spans the os.pullEvent at the bottom of this loop. That is
            -- where a paused game hides: the turtle is not slow, it is
            -- absent, and the only trace is that its clock moved while it
            -- did not.
            witnessTurn(now)
            atc.keepSupport(now)
            atc.keepPair(now)
            base.keepFails(now)
            atc.keepInBase()
            if now - lastHeartbeatWall >= heartbeatTarget then
                sendHeartbeat()
                lastHeartbeatWall = now
                -- Re-drawn every beat: a single draw would just move this
                -- turtle's fixed slot, not stop it having one.
                heartbeatTarget = heartbeatGap()
            end
            -- Batch-forward accumulated print() lines to the server every 15
            -- seconds. tick() short-circuits that interval when the outbox has
            -- filled: a burst is exactly the case where waiting 15 seconds
            -- loses the lines worth having.
            _log:tick(now)

            local event, p1, p2, p3, p4 = os.pullEvent()

            if event == "modem_message" then
                _baseMsgs = _baseMsgs + 1
                _self.heardAnyAt = os.epoch("utc")     -- R4: a support's partner silence counts only while it hears others
                local parsed = type(p4) == "table" and p4 or textutils.unserialise(p4)
                if parsed then
                    local valid, msg = proto.decode(parsed)
                    if valid and (msg.to == _self.id or msg.to == "broadcast")
                       and firstSight(msg) then
                        dispatchControl(msg)
                    end
                end

            elseif event == "timer" and p1 == wakeupTimer then
                -- Wakeup timer fired — wall-clock check above handles actual heartbeat.
            end

            -- GUARANTEED WAKEUP. Re-armed unconditionally, whatever woke us.
            --
            -- Every check above -- heartbeat, log flush, the ctrl drain -- sits
            -- BEFORE os.pullEvent, which blocks until an event arrives. So they
            -- are not a safety net: they are behind the thing that gets stuck.
            -- Losing a single wakeup timer event left this loop with no pending
            -- timer, and an idle docked turtle generates nothing else -- it stops
            -- heartbeating, so no HEARTBEAT_ACK comes back, and a loader placed
            -- by turtle.place() is powered off and beacons nothing. The turtle
            -- then sits alive and completely deaf, screen reading "Ready.",
            -- until someone reboots it by hand.
            --
            -- Observed 2026-09-04: all 15 turtles silent for over two hours,
            -- server healthy throughout, player standing in the depot. Every
            -- turtle was running and none of them could ever speak again.
            --
            -- This is the identical fault the spec owner fixed in the SERVER's
            -- loop in 6f7d1c6, whose comment ends "it is also, finally, why
            -- rebooting a single turtle revived the whole fleet three separate
            -- times." The turtle side had the same shape and never got the fix.
            --
            -- Timer events are lost routinely: any call that yields on a filter
            -- destroys what arrives during it. That is not an edge case here, it
            -- is the normal cost of a turtle doing anything at all.
            os.cancelTimer(wakeupTimer)
            wakeupTimer = os.startTimer(CFG.HEARTBEAT_INTERVAL)
        end
    end

    -- Job runner: waits for a pending job then executes it
    local function jobRunner()
        while true do
            -- Wait until a job is assigned, and while waiting give the role a
            -- chance to decide it has waited long enough (base.setIdleAction).
            local idleSince = os.epoch("utc")
            while not pendingJob do
                os.pullEvent()
                if _idleFn and _idleMs > 0
                   and (os.epoch("utc") - idleSince) >= _idleMs then
                    idleSince = os.epoch("utc")
                    -- pcall'd: an idle action that raises must not take the job
                    -- runner down with it, or the turtle stops accepting work.
                    local iok, ierr = pcall(_idleFn)
                    if not iok then logWarn("Idle action failed: " .. tostring(ierr)) end
                end
            end

            local job = pendingJob
            pendingJob = nil

            local ok, err = pcall(jobHandler, job)
            _self.recalled = false   -- clear after job exits regardless of reason
            if not ok then
                logError("Job handler crashed: " .. tostring(err))
                base.sendFailed(tostring(err), true)
            end

            -- A failure held back in the world (base.sendFailed): home first, the
            -- support with it, then the report. Down to the tunnel it came along and
            -- DESCENDED, as after a delivery, so the support follows again; the trip
            -- home signals it the rest of the way. failLater stays set over the
            -- report so it is sent now, not held back again.
            if _self.failLater then
                local f = _self.failLater
                pcall(gpsSync)
                pcall(base.ledger.recoverHere)
                if _self.pos.y > W.WORLD_ENTRY.y then pcall(move.to, _self.pos.x, W.WORLD_ENTRY.y, _self.pos.z) end
                _self.partnerId = f.partner
                base.signalPartnerDirect(proto.MSG.DESCENDED, f.partner, {})
                _self.busy = true
                local hok, herr = pcall(base.returnToDock)
                _self.busy = false
                if not hok then logWarn("Bringing the support home: " .. tostring(herr)) end
                base.sendFailed(f.reason, f.recoverable)
                _self.failLater = nil
            end

            -- A JOB THAT ENDS AWAY FROM THE DOCK GOES HOME (2026-11-14). A failed
            -- job ends where it failed, and nothing brought the turtle back: the
            -- server sends no recall on JOB_FAILED, and refuses one from a turtle
            -- whose job went to another. In the side-test sim (w3_side_atc) 6 of 14
            -- turtles ended IDLE at destinations and in the tunnel -- deliveries
            -- whose warehouse wait timed out after a blackout, supports that stood
            -- down -- and a turtle given work from there drove through the base
            -- (see departImpl). Busy while it goes, so a RECALL meanwhile does not
            -- start a second trip home from the control loop, nor a job.
            if _self.dock and not pendingJob then
                -- Busy BEFORE the GPS read: gpsSync waits for replies, and a RECALL
                -- read meanwhile by the control loop would start its own trip home.
                local wasBusy = _self.busy
                _self.busy = true
                pcall(gpsSync)
                _self.busy = wasBusy
                local p = _self.pos
                if p.x ~= _self.dock.x or p.z ~= _self.dock.z or p.y ~= CFG.FLOOR_Y then
                    logWarn(string.format("Job over at %d,%d,%d, away from my dock %d,%d -- going home",
                        p.x, p.y, p.z, _self.dock.x, _self.dock.z))
                    pcall(base.ledger.recoverHere)
                    _self.busy = true
                    local hok, herr = pcall(base.returnToDock)
                    _self.busy = false
                    _self.recalled = false
                    _self.status = proto.STATUS.IDLE
                    if not hok then logWarn("Going home after the job: " .. tostring(herr)) end
                end
            end
        end
    end

    -- Run both loops in parallel so events are shared between them
    parallel.waitForAny(controlLoop, jobRunner)
end

return base
