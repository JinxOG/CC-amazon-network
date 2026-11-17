-- atc.lua
-- The base air-traffic control computer (2026-11-03; board card "TOP PRIORITY -
-- Base air-traffic control computer: no gridlock at 150 turtles").
-- Installed as startup.lua on its own computer: install atc
--
-- One turtle per section of the base (waypoints.lua, W.atcSection). A turtle
-- books its route as an ordered list of sections; a booking is ADMITTED only
-- when its first section is free, and admission appends it to the queue of every
-- section on the route at once. A turtle enters a section only at the head of
-- that section's queue. Every booking waits only for bookings admitted before
-- it, so no cycle can form: no deadlock, head-on meetings included.
--
-- NOTHING ON DISK. At boot it broadcasts ATC_HELLO and, for SETTLE_MS, only
-- collects where every turtle says it is; then it rebuilds, turtles already in
-- a section first (they hold it physically), and bookings nearest the open end
-- first, so a base left full unjams from the open end inward.
-- docs/superpowers/specs/2026-11-03-base-atc-design.md

local proto = require("protocol")
local okW, W = pcall(require, "waypoints")   -- the holding line's length is the layout's

local CFG = {
    SETTLE_MS   = 15000,     -- after boot: collect reports, admit nothing
    STALE_MS    = 180000,    -- a booking whose turtle says nothing this long is dropped where not entered
    SWEEP_MS    = 5000,
    HELLO_EVERY = 60000,     -- re-announce, for a turtle that missed the boot hello
    FAIR_MS     = 60000,     -- a request waiting this long keeps later overlapping ones out
    HOLD_SLOTS  = (okW and type(W) == "table" and W.ATC and W.ATC.HOLD_SLOTS) or 14,   -- per holding line, from waypoints.lua
    SLOT_KEEP_MS = 60000,    -- a slot just left is not handed to a stranger for this long
    DEAF_GAP_MS = 10000,     -- hearing nobody at all this long: the ATC is deaf, and that time is no one's silence
    PAIR_FRESH_MS = 15000,   -- a pair's half that asked this recently is waiting with it (each asks every 2 s)
}

-- ─── The rules, with no radio (tests drive these) ───────────────────────────

local core = {}

-- SILENCE IS ONLY SILENCE WHILE OTHERS ARE HEARD (2026-11-14). A booking and a
-- holding slot are dropped after STALE_MS of silence from their turtle: a dead
-- turtle must not hold the base for good. In a total radio blackout the ATC hears
-- nobody, every turtle in the base is "silent", and after 3 minutes the sweep took
-- from each the sections it stood in; when the radio came back it had granted
-- them to others, and two turtles each held what the other needed -- node_35 in
-- R5 waiting for J5, node_36 holding J5 waiting for R5, to the end of the run
-- (sim w3_side_atc, a 5-minute blackout). So time in which the ATC heard no one at
-- all (a gap over DEAF_GAP_MS) is counted apart, st.deaf, and does not count as
-- anyone's silence. A dead turtle is still swept: the others keep talking.
local function noteHeard(st, now)
    if st.lastHeard and now - st.lastHeard > CFG.DEAF_GAP_MS then st.deaf = (st.deaf or 0) + (now - st.lastHeard) end
    st.lastHeard = now
end
local function deafNow(st, now)
    local d = st.deaf or 0
    if st.lastHeard and now - st.lastHeard > CFG.DEAF_GAP_MS then d = d + (now - st.lastHeard) end
    return d
end
local function silentFor(st, x, now)
    return (now - x.at) - (deafNow(st, now) - (x.deafAt or 0))
end

function core.new(now)
    return { epoch = now, settleUntil = now + CFG.SETTLE_MS, q = {}, res = {}, byTurtle = {},
             reports = {}, nextRid = 0, log = {}, waiting = {}, slots = {} }
end

local function note(st, line) st.log[#st.log + 1] = line end

local function queue(st, s)
    local q = st.q[s]
    if not q then q = {}; st.q[s] = q end
    return q
end

local function removeFrom(q, rid)
    for i = #q, 1, -1 do if q[i] == rid then table.remove(q, i) end end
end

local function newRid(st)
    st.nextRid = st.nextRid + 1
    return st.nextRid
end

local function drop(st, rid, keep)
    local r = st.res[rid]
    if not r then return end
    for _, s in ipairs(r.list) do
        if s ~= keep then removeFrom(queue(st, s), rid) end
    end
    if keep and r.entered[keep] then
        r.list = { keep }
    else
        st.res[rid] = nil
        if st.byTurtle[r.id] == rid then st.byTurtle[r.id] = nil end
    end
end

-- Admit `list` for turtle `id`; `cur` is the section it physically stands in (or nil).
local function admit(st, id, list, cur, now, physical)
    local old = st.byTurtle[id]
    if old then drop(st, old) end
    local rid = newRid(st)
    local r = { id = id, list = {}, entered = {}, at = now, deafAt = deafNow(st, now) }
    for _, s in ipairs(list) do r.list[#r.list + 1] = s end
    st.res[rid], st.byTurtle[id] = r, rid
    for _, s in ipairs(r.list) do
        local q = queue(st, s)
        if physical and s == cur then
            table.insert(q, 1, rid)      -- it is in there: it owns it, whatever the queue said
            r.entered[s] = true
        else
            q[#q + 1] = rid
        end
    end
    return rid
end

-- A party is a delivery and its support: group is the delivery's id. Its own
-- bookings are the party's whatever group they carry (2026-11-16, T2
-- w3-atc-staged-lost-c): rebooted in the dispatch hole cell, a delivery booked
-- its way home with no group -- a reboot forgets it -- and its support, behind
-- it at staging and asking in the delivery's party, was held "busy at W1" by
-- that booking while the delivery waited for the support to move: each waited
-- for the other. And the other way: the support's bookings are its delivery's.
local function sameParty(st, rid, id, group)
    local x = st.res[rid]
    if x == nil then return false end
    if x.id == id then return true end
    if group ~= nil and (x.group == group or x.id == group) then return true end
    return x.group ~= nil and x.group == id
end

local function headIsTurtle(st, s, id, group)
    local head = queue(st, s)[1]
    return head ~= nil and sameParty(st, head, id, group)
end

-- A route is let in only when EVERY section on it is free (or held by this
-- turtle or its partner): nobody is ever admitted to wait at a section edge, and
-- the dispatch hole cannot hold a queue (ATC card, addition C). A request older
-- than FAIR_MS that overlaps keeps later ones out, so a long route is not starved.
local function routeFree(st, list, id, group, cur)
    for _, s in ipairs(list) do
        if s ~= cur then
            for _, rid in ipairs(queue(st, s)) do
                if not sameParty(st, rid, id, group) then return false, s end
            end
        end
    end
    return true
end

-- Its partner (same group, another turtle) already holds a booking: the pair is
-- part-way through the base together. An older waiter that overlaps can only be
-- waiting for what the pair holds -- it cannot move until the pair has gone --
-- so holding the second half of the pair back for it is a circle: the shakeout's
-- 150-turtle sim froze the dispatch hole that way (w3_bay_types150, 2026-11-11).
-- The partner's own booking counts whatever group it carries (2026-11-17): rebuilt
-- after an ATC restart from its report, a delivery in DH had none, and its support
-- was held "after an older request" for the DH its delivery held for it.
local function partnerIn(st, id, group)
    if group == nil then return false end
    for _, x in pairs(st.res) do
        if x.id ~= id and (x.group == group or x.id == group) then return true end
    end
    return false
end

-- The same circle for any turtle (2026-11-14): an older waiter whose route needs
-- a section this one already stands in cannot move until this one has gone, so it
-- is not waited for. A support that cannot dig came back up the dispatch shaft by
-- the way it went and stood in DH asking for its way home; the departures queued
-- for DH were older, so it was held "after an older request", in DH, to the end
-- of the run (sim w3_side_atc).
-- The departures go through DH, the returns through ARR (R3).
local function lineOf(list)
    for _, s in ipairs(list or {}) do
        if s == "DH" then return "departure" elseif s == "ARR" then return "return" end
    end
    return nil
end

-- R3: NO CLOCK IN THE ORDER (SPEC-OWNER's ruling, 2026-11-17: "alternate; if only one
-- line is waiting it goes straight away, and the order never depends on a clock").
-- FAIR_MS let a newer request overtake an older one for its first 60 s. Now an older
-- waiter whose route overlaps always goes first -- unless it is in the other line
-- and that line had the last turn (st.lastLine): the departure and the return lines
-- take turns where they share sections. A pair never waits for itself.
local function olderWaiterOverlaps(st, list, id, now, cur)
    local mine = st.waiting[id]
    local myLine = lineOf(list)
    local myGroup = mine and mine.group
    local since = mine and mine.since or now
    local holds = {}
    if cur then holds[cur] = true end
    for k, x in pairs(st.res) do
        if x.id == id then
            for s in pairs(x.entered) do holds[s] = true end
            -- booked and first in the queue counts too: a waiter behind it waits for it
            for _, s in ipairs(x.list) do if queue(st, s)[1] == k then holds[s] = true end end
        end
    end
    for other, w in pairs(st.waiting) do
        local theirLine = lineOf(w.list)
        local myTurn = myLine ~= nil and theirLine ~= nil and myLine ~= theirLine and st.lastLine == theirLine
        local sameParty = myGroup ~= nil and w.group == myGroup
        if other ~= id and w.since < since and now - w.at < 10000 and not myTurn and not sameParty then
            local waitsForMe = false
            for _, a in ipairs(w.list) do if holds[a] then waitsForMe = true end end
            if not waitsForMe then
                for _, a in ipairs(w.list) do
                    for _, b in ipairs(list) do if a == b then return true end end
                end
            end
        end
    end
    return false
end

-- One message from a turtle. Returns the reply payload.
--   p.op     "request" | "enter" | "leave" | "cancel" | "report"
--   p.sec    the section (enter, leave)
--   p.cur    the section it stands in now, or nil
--   p.route  the sections still ahead of it, in order, from p.cur
-- EVERY TURTLE KNOWS ITS PLACE IN LINE (R3; the user, 2026-11-17: "I'm number 5,
-- and I'm going number 6"). A request waiting to be let in is in a line: the
-- departures (its route goes through DH) or the returns (through ARR). Its place
-- is one more than the waiting requests of that line that asked before it -- a
-- pair counted once, by its group -- and "after" is the one just ahead. Only
-- requests still asking count (each asks every 2 s): one that stopped is gone.
local function placeInLine(st, id, now)
    local me = st.waiting[id]
    local line = me and lineOf(me.list)
    if not line then return nil end
    local mine = me.group or id
    local ahead, afterSince, after = {}, -1, nil
    for oid, w in pairs(st.waiting) do
        local key = w.group or oid
        if oid ~= id and key ~= mine and lineOf(w.list) == line and now - (w.at or 0) <= CFG.PAIR_FRESH_MS
           and (w.since < me.since or (w.since == me.since and tostring(oid) < tostring(id))) then
            if not ahead[key] or w.since < ahead[key] then ahead[key] = w.since end
        end
    end
    local n = 0
    for key, since in pairs(ahead) do
        n = n + 1
        if since > afterSince then afterSince, after = since, key end
    end
    return line, n + 1, after
end
local function withPlace(st, id, now, reply)
    reply.line, reply.place, reply.after = placeInLine(st, id, now)
    return reply
end

function core.handle(st, id, p, now)
    p = p or {}
    local rid = st.byTurtle[id]
    noteHeard(st, now)
    -- every entry this turtle holds is alive while it talks, its one-step ones too
    -- -- and its party's (R2, 2026-11-17): a pair admitted as one unit, the support
    -- waits silently on its dock for HOLE_READY while its delivery talks its way to
    -- the hole; the pair's group is the delivery's id.
    for _, x in pairs(st.res) do
        if x.id == id or (x.group ~= nil and (x.group == id or x.group == p.group)) then
            x.at, x.deafAt = now, deafNow(st, now)
        end
    end
    for _, line in pairs(st.slots) do
        for k, sl in pairs(line) do
            if sl.id == id then
                -- a turtle stepping into the arrivals section has left its slot
                -- a turtle stepping into the arrivals section has left its slot; the slot
                -- is kept back a minute for the support that followed it in (below)
                if p.op == "enter" and p.sec == "ARR" then line[k] = { freedAt = now, at = 0 } elseif sl.id then sl.at, sl.deafAt = now, deafNow(st, now) end
            end
        end
    end

    if now < st.settleUntil then
        st.reports[id] = { cur = p.cur, route = p.route or {}, at = now, group = p.group }
        if p.op == "leave" or p.op == "cancel" or p.op == "report" then return { ok = true } end
        return { ok = false, why = "settling" }
    end

    if p.op == "report" then
        if p.cur and not rid then
            local nrid = admit(st, id, (p.route and #p.route > 0) and p.route or { p.cur }, p.cur, now, true)
            st.res[nrid].group = p.group      -- its party, so a pair is rebuilt as one (R2)
        end
        return { ok = true }
    end

    if p.op == "request" then
        local list = p.route or {}
        if #list == 0 then return { ok = true } end
        local r = rid and st.res[rid]
        if r and r.list[1] == list[1] and #r.list == #list then return { ok = true, rid = rid } end
        -- A NEW ROUTE IS THE END OF THE OLD ONE (2026-11-15). A turtle can be in one
        -- place, and asks from there (p.cur): whatever else it still holds is what a
        -- lost ATC_LEAVE / ATC_CANCEL left behind. node_208 docked in a radio loss
        -- with R2-R5 still its own; asking for a departure every two seconds kept
        -- that booking alive (every message does), and the returns waiting for R2-R5
        -- held its departure back as the older requests -- 12 of 20 jammed 45 min
        -- (T2 shakeout-side-c). Asking anew lets the old go, as the cancel would have.
        for k, x in pairs(st.res) do if x.id == id then drop(st, k, p.cur) end end
        -- A PAIR'S DEPARTURE IS ADMITTED AS ONE UNIT (R2, docs/superpowers/specs/
        -- 2026-11-17-delivery-pair-and-hole-design.md). The delivery was let out
        -- alone and its support asked only once the delivery stood at the hole;
        -- traffic let in between held the support back while the delivery held the
        -- hole -- every STAGE_WAIT_S expiry sat in that gap. Each half now asks from
        -- its dock naming its partner (p.pair). Neither is let in until both have
        -- asked (the partner's ask is fresh: it asks every 2 s) and both ways are
        -- free; then both at once, and nothing is let between them.
        if p.pair and not (st.byTurtle[p.pair] and st.res[st.byTurtle[p.pair]]) then
            local pw = st.waiting[p.pair]
            local w0 = st.waiting[id]
            if not w0 then st.waiting[id] = { since = now, at = now, list = list, group = p.group, cur = p.cur, pair = p.pair }
            else w0.at, w0.list, w0.group, w0.cur, w0.pair = now, list, p.group, p.cur, p.pair end
            if not (pw and pw.pair == id and pw.list and now - (pw.at or 0) <= CFG.PAIR_FRESH_MS) then
                return withPlace(st, id, now, { ok = false, why = "waiting for partner" })
            end
            local free1, b1 = routeFree(st, list, id, p.group, p.cur)
            local free2, b2 = routeFree(st, pw.list, p.pair, pw.group, pw.cur)
            if free1 and free2 then
                local nrid = admit(st, id, list, p.cur, now, p.cur ~= nil)
                st.res[nrid].group = p.group
                local prid = admit(st, p.pair, pw.list, pw.cur, now, pw.cur ~= nil)
                st.res[prid].group = pw.group
                st.waiting[id], st.waiting[p.pair] = nil, nil
                st.lastLine = lineOf(list) or st.lastLine
                note(st, string.format("admitted pair %s + %s: %s / %s", id, p.pair,
                    table.concat(list, " "), table.concat(pw.list, " ")))
                return { ok = true, rid = nrid }
            end
            return withPlace(st, id, now, { ok = false, why = "busy at " .. tostring(free1 and b2 or b1) })
        end
        local free, busyAt = routeFree(st, list, id, p.group, p.cur)
        -- A turtle standing in a section (p.cur) is in the way of others whatever it
        -- waits for: fairness never holds it back, only occupancy (routeFree) does.
        -- Held back, it closed circles through chains of waiters -- one in DH behind
        -- returns that were behind a request waiting for that DH (sim w3_side_atc).
        if free and (p.cur ~= nil or partnerIn(st, id, p.group) or not olderWaiterOverlaps(st, list, id, now, p.cur)) then
            local nrid = admit(st, id, list, p.cur, now, p.cur ~= nil)
            st.res[nrid].group = p.group
            st.waiting[id] = nil
            st.lastLine = lineOf(list) or st.lastLine
            note(st, string.format("admitted %s: %s", id, table.concat(list, " ")))
            return { ok = true, rid = nrid }
        end
        local w = st.waiting[id]
        if not w then st.waiting[id] = { since = now, at = now, list = list, group = p.group }
        else w.at, w.list, w.group = now, list, p.group end
        return withPlace(st, id, now, { ok = false, why = free and "after an older request" or ("busy at " .. tostring(busyAt)) })
    end

    -- A holding slot (the tunnel line, or the sky line: p.line = "sky").
    if p.op == "hold" then
        local line = (p.line == "sky") and "sky" or "tunnel"
        st.slots[line] = st.slots[line] or {}
        local slots = st.slots[line]
        local want = tonumber(p.prefer)
        for k = 1, CFG.HOLD_SLOTS do
            if slots[k] and slots[k].id == id then
                -- Its slot from before -- unless it asks for the one it now stands
                -- under: then the old one goes. node_81 kept slot 1 from a trip seven
                -- minutes earlier and was sent back to it, through rock (2026-11-03).
                if not want or want == k then slots[k].at, slots[k].deafAt = now, deafNow(st, now); return { ok = true, slot = k } end
                slots[k] = { freedAt = now, at = 0 }
            end
        end
        local function free(sl, mine)
            if not sl then return true end
            if sl.id then return silentFor(st, sl, now) > CFG.STALE_MS end
            return mine or now - (sl.freedAt or 0) > CFG.SLOT_KEEP_MS
        end
        -- THE SLOT IT STANDS IN FIRST (p.prefer). A support cannot dig: it can
        -- only use the tunnel its delivery dug, and the one dug all the way to the
        -- arrivals column is its partner's slot, which it is standing in. Given
        -- the first free slot instead, node_81 met solid rock one block on and
        -- stayed in the tunnel (sim, 2026-11-03).
        if want and want >= 1 and want <= CFG.HOLD_SLOTS and free(slots[want], true) then
            slots[want] = { id = id, at = now, deafAt = deafNow(st, now) }
            note(st, string.format("%s slot %d (%s, the one it stands under)", id, want, line))
            return { ok = true, slot = want }
        end
        -- STRICT: a turtle that cannot dig takes the slot it stands under or none --
        -- any other is through rock. node_81 was given slot 1 while 3 was still held
        -- (the ATC had restarted) and stayed in the tunnel (sim, 2026-11-03).
        -- A PAIR SHARES ITS SLOT (2026-11-17): the support stands in its own delivery's
        -- column, behind it; refused ("slot 14 is node_33's"), it waited until its
        -- delivery had left. p.pair is its delivery.
        if want and p.pair and slots[want] and slots[want].id == p.pair then
            note(st, string.format("%s shares slot %d with its delivery %s (%s)", id, want, p.pair, line))
            return { ok = true, slot = want }
        end
        if p.strict and want then
            local sl = slots[want]
            return { ok = false, why = string.format("slot %d is %s's", want, tostring(sl and sl.id or "kept back")) }
        end
        -- IN TURN AROUND THE LINE, not the first free one: handing out slot 1 again
        -- and again sent every arrival up the same column, into the support of the
        -- pair before, still waiting there -- 8 turtles piled up under slot 1 (sim,
        -- 2026-11-03). In turn, a column comes round again only every HOLD_SLOTS
        -- arrivals.
        st.nextSlot = st.nextSlot or {}
        local start = st.nextSlot[line] or 1
        for i = 0, CFG.HOLD_SLOTS - 1 do
            local k = (start - 1 + i) % CFG.HOLD_SLOTS + 1
            if free(slots[k], false) then
                slots[k] = { id = id, at = now, deafAt = deafNow(st, now) }
                st.nextSlot[line] = k % CFG.HOLD_SLOTS + 1
                note(st, string.format("%s slot %d (%s)", id, k, line))
                return { ok = true, slot = k }
            end
        end
        return { ok = false, why = "holding line full" }
    end

    if p.op == "enter" then
        local s = p.sec
        if not s then return { ok = false, why = "no section" } end
        -- A turtle the ATC does not know, mid-route (the ATC restarted, or the
        -- turtle missed the hello): what it says it holds and needs is the booking.
        -- Only the section it STANDS in is taken on trust; the one it wants next
        -- must be free like any other step. Taking its whole route on trust let
        -- opposite movers in the boot rush into each other's paths (2026-11-03).
        if not (rid and st.res[rid]) and p.cur then
            rid = admit(st, id, { p.cur }, p.cur, now, true)
        end
        local r = rid and st.res[rid]
        local inList = false
        if r then for _, x in ipairs(r.list) do if x == s then inList = true end end end
        if not inList then
            -- a one-section step outside any booking: only into a free section
            local q = queue(st, s)
            if #q == 0 or headIsTurtle(st, s, id) then
                local arid = newRid(st)
                st.res[arid] = { id = id, list = { s }, entered = { [s] = true }, at = now, adhoc = true }
                table.insert(q, 1, arid)
                return { ok = true }
            end
            return { ok = false, why = "busy", ahead = #q }
        end
        if headIsTurtle(st, s, id, r.group) then
            r.entered[s] = true
            return { ok = true }
        end
        -- BACK INTO A SECTION OF ITS OWN ROUTE THAT IT HAS ALREADY LEFT (a homing
        -- route goes up a bay's centre column to the red lane and back down it).
        -- Leaving took it out of that section's queue, so "ahead" was a wait for
        -- nobody, for good: node_3069 sat at J5 after a world restart (sim,
        -- 2026-11-03). Re-entering is a one-step entry: only into a free section.
        local q = queue(st, s)
        local queued = false
        for _, x in ipairs(q) do if x == rid then queued = true end end
        if not queued then
            if #q == 0 then
                table.insert(q, 1, rid)
                r.entered[s] = true
                return { ok = true }
            end
            return { ok = false, why = "busy", ahead = #q }
        end
        return { ok = false, why = "ahead", ahead = #q }
    end

    if p.op == "leave" then
        local s = p.sec
        if s then
            local q = queue(st, s)
            for i = #q, 1, -1 do
                local x = st.res[q[i]]
                if x and x.id == id then
                    x.entered[s] = nil
                    table.remove(q, i)
                end
            end
            -- a booking with nothing queued any more is finished
            for k, x in pairs(st.res) do
                if x.id == id then
                    local any = false
                    for _, y in ipairs(x.list) do
                        for _, z in ipairs(queue(st, y)) do if z == k then any = true end end
                    end
                    if not any then
                        st.res[k] = nil
                        if st.byTurtle[id] == k then st.byTurtle[id] = nil end
                    end
                end
            end
        end
        return { ok = true }
    end

    if p.op == "cancel" then
        for k, x in pairs(st.res) do if x.id == id then drop(st, k, p.cur) end end
        -- done with the base (home, or out of the hole): no slot of its own any more
        for _, line in pairs(st.slots) do
            for k, sl in pairs(line) do if sl.id == id then line[k] = { freedAt = now, at = 0 } end end
        end
        return { ok = true }
    end

    return { ok = false, why = "unknown op" }
end

-- End of the settle window: rebuild from what the turtles said. Turtles standing
-- in a section first, nearest the open end (fewest sections left) first.
function core.settle(st, now)
    local list = {}
    for id, r in pairs(st.reports) do list[#list + 1] = { id = id, cur = r.cur, route = r.route, group = r.group } end
    table.sort(list, function(a, b)
        if (a.cur ~= nil) ~= (b.cur ~= nil) then return a.cur ~= nil end
        if #a.route ~= #b.route then return #a.route < #b.route end
        return tostring(a.id) < tostring(b.id)
    end)
    local n = 0
    for _, e in ipairs(list) do
        if e.cur then
            local nrid = admit(st, e.id, (#e.route > 0) and e.route or { e.cur }, e.cur, now, true)
            st.res[nrid].group = e.group          -- a pair rebuilt as one (R2)
            n = n + 1
        end
    end
    st.reports = {}
    note(st, string.format("rebuilt from reports: %d turtle(s) in a section", n))
    return n
end

-- A turtle silent STALE_MS gives back EVERYTHING, the sections it entered too.
-- Keeping those "because it stands there" leaked: a lost leave, or a one-step
-- entry (facing detection) that was never refreshed, held a bay column for good
-- and kept 35 departures in their docks (w3_atc_base150, 2026-11-03). A live
-- turtle waiting at a gate asks every second, so it is never silent; a dead one
-- left in a lane is still in the way, and the next turtle's stuck rule hands its
-- job back.
function core.sweep(st, now)
    local dropped = 0
    for rid, r in pairs(st.res) do
        if silentFor(st, r, now) > CFG.STALE_MS then
            for _, s in ipairs(r.list) do removeFrom(queue(st, s), rid) end
            st.res[rid] = nil
            if st.byTurtle[r.id] == rid then st.byTurtle[r.id] = nil end
            dropped = dropped + 1
            local held = {}
            for s in pairs(r.entered) do held[#held + 1] = s end
            note(st, string.format("%s silent %ds: booking dropped%s", r.id, math.floor(silentFor(st, r, now) / 1000),
                #held > 0 and (", including " .. table.concat(held, " ") .. " it had entered") or ""))
        end
    end
    return dropped
end

-- Who holds what, for the screen and the log.
function core.summary(st)
    local held, who = 0, {}
    for s, q in pairs(st.q) do
        if #q > 0 then
            held = held + 1
            local r = st.res[q[1]]
            who[#who + 1] = s .. "=" .. (r and tostring(r.id) or "?") .. (#q > 1 and ("+" .. (#q - 1)) or "")
        end
    end
    table.sort(who)
    local n = 0
    for _ in pairs(st.res) do n = n + 1 end
    return held, n, table.concat(who, " ")
end

core.CFG = CFG
if _G.__ATC_TEST then return core end

-- ─── The computer ───────────────────────────────────────────────────────────

local modem = peripheral.find("modem")
if not modem then error("atc: no modem. Attach a wireless or ender modem.") end
modem.open(proto.CH_ATC)
modem.open(proto.CH_BROADCAST)

local _log
local okLS, logship = pcall(require, "logship")
if okLS then
    _log = logship.new({
        source = "atc",
        send = function(lines, bootId)
            proto.send(modem, proto.CH_SERVER, proto.encode(proto.MSG.TURTLE_LOG, "atc", "server",
                { lines = lines, bootId = bootId }))
        end,
    })
end

local function log(line) print("[ATC] " .. line) end

local function reply(to, ch, payload)
    proto.send(modem, tonumber(ch) or proto.CH_PRIVATE, proto.encode(proto.MSG.ATC_REPLY, "atc", to, payload))
end

local OPS = {
    [proto.MSG.ATC_REQUEST] = "request", [proto.MSG.ATC_ENTER] = "enter", [proto.MSG.ATC_LEAVE] = "leave",
    [proto.MSG.ATC_CANCEL] = "cancel", [proto.MSG.ATC_REPORT] = "report",
}

local function main()
    local now = os.epoch("utc")
    local st = core.new(now)
    local settled = false
    -- %s for the epoch, not %d: a 13-digit ms epoch is out of %d's range on CC (and in the sim).
    log(string.format("ATC online v%s -- epoch %s; settling %ds before granting anything",
        proto.VERSION, tostring(st.epoch), math.floor(CFG.SETTLE_MS / 1000)))
    local function hello()
        proto.send(modem, proto.CH_BROADCAST, proto.encode(proto.MSG.ATC_HELLO, "atc", "broadcast", { epoch = st.epoch }))
    end
    hello()
    local lastHello, lastSweep, lastSummary = now, now, now
    local tick = os.startTimer(1)
    while true do
        local ev, p1, p2, p3, p4 = os.pullEvent()
        now = os.epoch("utc")
        if ev == "modem_message" then
            local raw = type(p4) == "table" and p4 or textutils.unserialise(p4)
            local valid, msg = proto.decode(raw)
            if valid then
                local op = OPS[msg.type]
                if op and (msg.to == "atc" or msg.to == "broadcast") then
                    local pl = msg.payload or {}
                    pl.op = (op == "request" and pl.kind == "hold") and "hold" or op
                    local ok, out = pcall(core.handle, st, msg.from, pl, now)
                    if not ok then
                        log("handle failed for " .. tostring(msg.from) .. ": " .. tostring(out))
                        out = { ok = false, why = "atc error" }
                    end
                    out.nonce, out.epoch = pl.nonce, st.epoch
                    if op ~= "leave" and op ~= "report" then reply(msg.from, pl.ch, out) end
                elseif msg.type == proto.MSG.UPDATE_ALL then
                    log("UPDATE_ALL -- updating")
                    proto.stageUpdateRef(msg.payload and msg.payload.ref)
                    if fs.exists("updater.lua") then shell.run("updater") else os.reboot() end
                    return
                end
            end
        elseif ev == "timer" and p1 == tick then
            tick = os.startTimer(1)
        end
        if not settled and now >= st.settleUntil then
            settled = true
            local n = core.settle(st, now)
            log(string.format("settled: rebuilt %d turtle(s) standing in a section; granting", n))
        end
        if now - lastSweep >= CFG.SWEEP_MS then
            lastSweep = now
            core.sweep(st, now)
        end
        -- Said again 3, 8 and 14 s after boot: the first one goes out while the
        -- fleet is still opening its radios.
        local since = now - st.epoch
        if (since >= 3000 and lastHello < st.epoch + 3000) or (since >= 8000 and lastHello < st.epoch + 8000)
                or (since >= 14000 and lastHello < st.epoch + 14000) then
            lastHello = now
            hello()
        end
        if now - lastHello >= CFG.HELLO_EVERY then
            lastHello = now
            hello()
        end
        if now - lastSummary >= 60000 then
            lastSummary = now
            local held, n, who = core.summary(st)
            log(string.format("%d section(s) held, %d booking(s)%s", held, n, held > 0 and (": " .. who) or ""))
        end
        for _, line in ipairs(st.log) do log(line) end
        st.log = {}
        if _log then _log:tick() end
    end
end

local ok, err = pcall(main)
if not ok then
    print("[ATC] crashed: " .. tostring(err))
    if _log then pcall(function() _log:flush() end) end
    sleep(5)
    os.reboot()
end
