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
}

-- ─── The rules, with no radio (tests drive these) ───────────────────────────

local core = {}

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
    local r = { id = id, list = {}, entered = {}, at = now }
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

local function sameParty(st, rid, id, group)
    local x = st.res[rid]
    return x ~= nil and (x.id == id or (group ~= nil and x.group == group))
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

local function olderWaiterOverlaps(st, list, id, now)
    local mine = st.waiting[id]
    local since = mine and mine.since or now
    for other, w in pairs(st.waiting) do
        if other ~= id and w.since < since and now - w.since > CFG.FAIR_MS and now - w.at < 10000 then
            for _, a in ipairs(w.list) do
                for _, b in ipairs(list) do if a == b then return true end end
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
function core.handle(st, id, p, now)
    p = p or {}
    local rid = st.byTurtle[id]
    -- every entry this turtle holds is alive while it talks, its one-step ones too
    for _, x in pairs(st.res) do if x.id == id then x.at = now end end
    for _, line in pairs(st.slots) do
        for k, sl in pairs(line) do
            if sl.id == id then
                -- a turtle stepping into the arrivals section has left its slot
                -- a turtle stepping into the arrivals section has left its slot; the slot
                -- is kept back a minute for the support that followed it in (below)
                if p.op == "enter" and p.sec == "ARR" then line[k] = { freedAt = now, at = 0 } elseif sl.id then sl.at = now end
            end
        end
    end

    if now < st.settleUntil then
        st.reports[id] = { cur = p.cur, route = p.route or {}, at = now }
        if p.op == "leave" or p.op == "cancel" or p.op == "report" then return { ok = true } end
        return { ok = false, why = "settling" }
    end

    if p.op == "report" then
        if p.cur and not rid then admit(st, id, (p.route and #p.route > 0) and p.route or { p.cur }, p.cur, now, true) end
        return { ok = true }
    end

    if p.op == "request" then
        local list = p.route or {}
        if #list == 0 then return { ok = true } end
        local r = rid and st.res[rid]
        if r and r.list[1] == list[1] and #r.list == #list then return { ok = true, rid = rid } end
        local free, busyAt = routeFree(st, list, id, p.group, p.cur)
        if free and not olderWaiterOverlaps(st, list, id, now) then
            local nrid = admit(st, id, list, p.cur, now, p.cur ~= nil)
            st.res[nrid].group = p.group
            st.waiting[id] = nil
            note(st, string.format("admitted %s: %s", id, table.concat(list, " ")))
            return { ok = true, rid = nrid }
        end
        local w = st.waiting[id]
        if not w then st.waiting[id] = { since = now, at = now, list = list } else w.at, w.list = now, list end
        return { ok = false, why = free and "after an older request" or ("busy at " .. tostring(busyAt)) }
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
                if not want or want == k then slots[k].at = now; return { ok = true, slot = k } end
                slots[k] = { freedAt = now, at = 0 }
            end
        end
        local function free(sl, mine)
            if not sl then return true end
            if sl.id then return now - sl.at > CFG.STALE_MS end
            return mine or now - (sl.freedAt or 0) > CFG.SLOT_KEEP_MS
        end
        -- THE SLOT IT STANDS IN FIRST (p.prefer). A support cannot dig: it can
        -- only use the tunnel its delivery dug, and the one dug all the way to the
        -- arrivals column is its partner's slot, which it is standing in. Given
        -- the first free slot instead, node_81 met solid rock one block on and
        -- stayed in the tunnel (sim, 2026-11-03).
        if want and want >= 1 and want <= CFG.HOLD_SLOTS and free(slots[want], true) then
            slots[want] = { id = id, at = now }
            note(st, string.format("%s slot %d (%s, the one it stands under)", id, want, line))
            return { ok = true, slot = want }
        end
        -- STRICT: a turtle that cannot dig takes the slot it stands under or none --
        -- any other is through rock. node_81 was given slot 1 while 3 was still held
        -- (the ATC had restarted) and stayed in the tunnel (sim, 2026-11-03).
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
                slots[k] = { id = id, at = now }
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
    for id, r in pairs(st.reports) do list[#list + 1] = { id = id, cur = r.cur, route = r.route } end
    table.sort(list, function(a, b)
        if (a.cur ~= nil) ~= (b.cur ~= nil) then return a.cur ~= nil end
        if #a.route ~= #b.route then return #a.route < #b.route end
        return tostring(a.id) < tostring(b.id)
    end)
    local n = 0
    for _, e in ipairs(list) do
        if e.cur then
            admit(st, e.id, (#e.route > 0) and e.route or { e.cur }, e.cur, now, true)
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
        if now - r.at > CFG.STALE_MS then
            for _, s in ipairs(r.list) do removeFrom(queue(st, s), rid) end
            st.res[rid] = nil
            if st.byTurtle[r.id] == rid then st.byTurtle[r.id] = nil end
            dropped = dropped + 1
            local held = {}
            for s in pairs(r.entered) do held[#held + 1] = s end
            note(st, string.format("%s silent %ds: booking dropped%s", r.id, math.floor((now - r.at) / 1000),
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
