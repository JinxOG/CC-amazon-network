-- warehouse.lua's Refined Storage call path.
--
-- Every rsBridge call was unprotected until 2026-08-28. AdvancedPeripherals
-- 0.7.44r threw NoClassDefFoundError from ItemFilter.parse on every importItem
-- between 26 June and 28 August; that error left clearEnderChest, left main, and
-- ended the program, so the warehouse stayed dead until a human noticed
-- deliveries had stopped. The mod bug is fixed upstream. These cover the
-- exposure it revealed, which is not specific to importItem -- an unloaded RS
-- network or the next mod regression arrives exactly the same way.
--
-- The property under test throughout: a throwing peripheral must degrade the
-- call, never the program.

package.path = "./?.lua;" .. package.path

local stub = require("tests.stub_cc")

-- rsBridge stand-in. `throwOn` names a method that raises, reproducing the mod
-- bug; everything else answers normally.
local function fakeRS(throwOn)
    local calls = {}
    local function guard(name, ret)
        return function(...)
            calls[#calls + 1] = name
            if throwOn == name then error("java.lang.NoClassDefFoundError: TableHelper", 0) end
            return ret
        end
    end
    return {
        _calls     = calls,
        importItem = guard("importItem", 3),
        exportItem = guard("exportItem", 5),
        getItem    = guard("getItem", { amount = 64 }),
        -- Without these the probe reads nothing, the poster never fires, and a
        -- test asserting it posts would be asserting against a dead branch.
        listItems  = guard("listItems", {
            { name = "minecraft:iron_ore", displayName = "[Iron Ore]", amount = 1204 },
            { name = "minecraft:coal",     displayName = "[Coal]",     amount = 64 },
        }),
        listCraftableItems = guard("listCraftableItems", {
            { name = "minecraft:iron_ingot" },
        }),
    }
end

-- A chest that keeps whatever it holds. When an import fails the items really do
-- stay put, so a chest that empties itself anyway would hide the failure this
-- test exists to reproduce -- clearEnderChest would return early instead of
-- exhausting its retries and warning.
local function fakeChest(contents)
    return { list = function() return contents end }
end

local function fresh(rs, chest)
    stub.install({})
    -- The harness has no global sleep; only test_control_loop installs one.
    -- clearEnderChest's retry pacing needs it, and a no-op is right here: the
    -- point is the retry behaviour, not the delay.
    sleep = function() end
    peripheral = peripheral or {}
    -- Honours the filter argument. The real peripheral.find does, and
    -- warehouse.lua now passes one to reject a WIRED modem -- a harness that
    -- ignored it would let that filter be deleted with every test still green.
    peripheral.find    = function(n, filter)
        if n == "rsBridge" then return rs end
        if n == "modem" then
            local m = { open = function() end, transmit = function() end,
                        isWireless = function() return true end }
            if filter and not filter("back", m) then return nil end
            return m
        end
        return nil
    end
    peripheral.wrap    = function() return chest end
    peripheral.getType = function() return "minecraft:chest" end
    peripheral.getName = function() return "rsBridge_0" end
    _G.__CC_WAREHOUSE_TEST = true
    package.loaded["warehouse"] = nil
    package.loaded["protocol"]  = nil
    local W = require("warehouse")
    _G.__CC_WAREHOUSE_TEST = nil
    package.loaded["warehouse"] = nil
    return W
end

-- ─── The event loop, driven for real ─────────────────────────────────────────
--
-- Runs main() -- or the whole file, crash wrapper included -- against a scripted
-- event queue and a fake clock. The stub's os.pullEvent raises once its queue is
-- empty, which is how every run here ends; `ranOut` says the loop really
-- consumed the whole script, rather than dying earlier for some other reason
-- and passing a count check by accident.
--
-- Every event is a modem message the router discards ("nil" unserialises to
-- nil). No timer event is ever delivered, so a loop that re-arms only inside its
-- timer branch is left exactly where the 2026-09-04 fleet freeze left it.
local NO_MSG = { "modem_message", "top", 0, 0, "nil", 0 }

local function driveWarehouse(opts)
    opts = opts or {}
    local c = stub.install({})
    c.events = {}
    for i = 1, (opts.events or 5) do c.events[i] = NO_MSG end

    local saved = {
        http    = _G.http,
        epoch   = os.epoch,
        print   = print,
        raw     = _G.__LOGSHIP_RAW_PRINT,
        reboot  = os.reboot,
        preload = package.preload["logship"],
    }
    local clock = 1700000000000
    os.epoch = function() return clock end
    local stubPull = os.pullEvent
    os.pullEvent = function(f)
        clock = clock + (opts.stepMs or 0)
        return stubPull(f)
    end
    -- Recorded rather than swallowed: the missing-module test asserts on what
    -- the warehouse says on its own console.
    local printed = {}
    print = function(...)
        local parts = {}
        for i = 1, select("#", ...) do parts[i] = tostring((select(i, ...))) end
        printed[#printed + 1] = table.concat(parts, " ")
    end
    -- The stub has no http at all, so the poster would silently do nothing and
    -- every test would still pass. Record what it tries to send.
    local posts = {}
    _G.http = opts.noHttp and nil or {
        request = function(url, body) posts[#posts + 1] = { url = url, body = body } end,
    }
    _G.__LOGSHIP_RAW_PRINT = nil
    sleep = function() end
    os.reboot = function() error("__rebooted__", 0) end
    if opts.noLogship then
        package.preload["logship"] = function() error("module 'logship' not found", 0) end
    end

    local sent = {}
    local modem = {
        isWireless = function() return not opts.wiredOnly end,
        open     = function() end,
        transmit = function(_, _, payload) sent[#sent + 1] = payload end,
    }
    local rs, chest = fakeRS(nil), fakeChest({})
    -- Make time pass BETWEEN the storage read and the post, so "stamped with
    -- the read time" and "stamped with send time" stop being the same number.
    -- Without this the clock never moves in between and a mutant that swaps
    -- one for the other is invisible.
    local afterCraft = nil
    if opts.craftDelayMs then
        local inner = rs.listCraftableItems
        rs.listCraftableItems = function(...)
            clock = clock + opts.craftDelayMs
            afterCraft = clock
            return inner(...)
        end
    end
    peripheral.find = function(n, filter)
        if n == "rsBridge" then return rs end
        if n == "modem" then
            if filter and not filter("back", modem) then return nil end
            return modem
        end
        return nil
    end
    peripheral.wrap    = function() return chest end
    peripheral.getType = function() return "minecraft:chest" end
    peripheral.getName = function() return "rsBridge_0" end

    package.loaded["warehouse"] = nil
    package.loaded["protocol"]  = nil
    package.loaded["logship"]   = nil
    local ok, err
    if opts.wholeFile then
        ok, err = pcall(require, "warehouse")
    else
        _G.__CC_WAREHOUSE_TEST = true
        local W = require("warehouse")
        _G.__CC_WAREHOUSE_TEST = nil
        ok, err = pcall(W.main)
    end
    _G.__CC_WAREHOUSE_TEST = nil
    package.loaded["warehouse"] = nil
    package.loaded["logship"]   = nil

    os.epoch, print, os.reboot  = saved.epoch, saved.print, saved.reboot
    _G.http                     = saved.http
    _G.__LOGSHIP_RAW_PRINT      = saved.raw
    package.preload["logship"]  = saved.preload
    os.pullEvent                = stubPull

    -- What the radio carried, as fleet-log lines from this source.
    local logLines = {}
    for _, payload in ipairs(sent) do
        local msg = textutils.unserialise(payload)
        if type(msg) == "table" and msg.type == "TURTLE_LOG" and msg.from == "warehouse"
           and type(msg.payload) == "table" and type(msg.payload.lines) == "table" then
            for _, l in ipairs(msg.payload.lines) do logLines[#logLines + 1] = l end
        end
    end
    -- Every decoded message, not only the log batches: the digest has to be
    -- visible here or a sender that never sends looks exactly like one that
    -- works.
    local msgs = {}
    for _, payload in ipairs(sent) do
        local m = textutils.unserialise(payload)
        if type(m) == "table" then msgs[#msgs + 1] = m end
    end
    return {
        afterCraft = afterCraft,
        posts    = posts,
        msgs     = msgs,
        ok       = ok,
        err      = tostring(err),
        ranOut   = tostring(err):find("no more queued events", 1, true) ~= nil,
        armed    = c.timersStarted,
        printed  = printed,
        logLines = logLines,
    }
end

local function anyLine(lines, needle, level)
    for _, l in ipairs(lines) do
        if tostring(l.msg):find(needle, 1, true) and (level == nil or l.level == level) then
            return true
        end
    end
    return false
end

return {
    ["a throwing rsBridge call returns nil and an error, and does not raise"] = function(assert_eq)
        local W = fresh(fakeRS("importItem"), fakeChest({}))
        local ok, res, err = pcall(W.rsCall, "importItem", { name = "x", count = 1 }, "top")
        assert_eq(ok, true,
            "rsCall must absorb the throw -- unprotected, this ended the whole program")
        assert_eq(res, nil)
        assert_eq(type(err), "string")
    end,

    ["a healthy call passes its result through"] = function(assert_eq)
        local W = fresh(fakeRS(nil), fakeChest({}))
        assert_eq(W.rsCall("exportItem", { name = "x", count = 5 }, "top"), 5)
        assert_eq(W.rsCall("getItem", { name = "x" }).amount, 64)
    end,

    -- pcall would catch a nil method on its own, so the guard's only value is the
    -- message: "rsBridge has no method 'x'" instead of "attempt to call a nil
    -- value". That distinction is the whole point, so it is what gets asserted --
    -- checking only for "some string" passes with the guard deleted.
    ["an unknown method names itself rather than reporting a nil call"] = function(assert_eq)
        local W = fresh(fakeRS(nil), fakeChest({}))
        local res, err = W.rsCall("noSuchMethod", {})
        assert_eq(res, nil)
        assert_eq(type(err) == "string" and err:find("noSuchMethod", 1, true) ~= nil, true,
            "the error must name the method that was missing")
    end,

    -- The exact shape of the live bug: a chest with items, an import that throws.
    ["clearEnderChest survives an import that throws every time"] = function(assert_eq)
        local rs = fakeRS("importItem")
        local W  = fresh(rs, fakeChest({ [1] = { name = "minecraft:stone", count = 8 } }))
        local ok, total = pcall(W.clearEnderChest)
        assert_eq(ok, true,
            "a failing import must not take the warehouse down with it")
        assert_eq(total, 0, "and nothing may be counted as moved when nothing moved")
    end,

    ["checkStock reports empty rather than crashing when getItem throws"] = function(assert_eq)
        local W = fresh(fakeRS("getItem"), fakeChest({}))
        local ok, inStock, have = pcall(W.checkStock, "minecraft:iron_ingot", 10)
        assert_eq(ok, true)
        assert_eq(inStock, false, "an unreadable stock level is a shortfall, not a pass")
        assert_eq(have, 0)
    end,

    ["loadChests reports zero when the export throws"] = function(assert_eq)
        local W = fresh(fakeRS("exportItem"), fakeChest({}))
        local ok, moved = pcall(W.loadChests, 4)
        assert_eq(ok, true)
        assert_eq(moved, 0,
            "zero loaded is what makes the caller abort the job -- a raise would "
            .. "have skipped that decision entirely")
    end,
    -- The tick timer was re-armed ONLY inside its own `p1 == tickTimer` branch.
    -- Lose one such event -- any yield destroys what arrives during it, timer
    -- events included, and clearEnderChest sleeps -- and the loop has no pending
    -- timer. It then advances only when a message happens to arrive: timeouts
    -- stop firing and an idle warehouse freezes while looking healthy.
    -- Byte-for-byte the fault that left all 15 turtles alive and deaf on
    -- 2026-09-04; W3 found it here on 2026-09-10.
    ["the tick timer is re-armed whatever woke the loop"] = function(assert_eq)
        local r = driveWarehouse({ events = 5 })
        assert_eq(r.ranOut, true,
            "the loop must consume the whole script; it died early: " .. r.err)
        -- Pre-fix this is EXACTLY 1: the arm before the loop and nothing else.
        assert_eq(r.armed > 1, true,
            "the loop must re-arm its tick on every iteration; with only the "
            .. "timer-branch re-arm this is 1 and one lost timer event leaves the "
            .. "warehouse blocked in os.pullEvent — got " .. tostring(r.armed))
    end,

    -- The warehouse forwarded nothing to the fleet log. A frozen state machine,
    -- a destroyed handshake step or a slow poll there was found out only from a
    -- delivery that never arrived.
    ["the warehouse's own log reaches the fleet log"] = function(assert_eq)
        local r = driveWarehouse({ events = 4, stepMs = 16000 })
        assert_eq(r.ranOut, true, "the loop must run the whole script: " .. r.err)
        assert_eq(#r.logLines > 0, true,
            "no TURTLE_LOG batch from 'warehouse' crossed the radio in 64 simulated "
            .. "seconds — the flush interval is 15")
        assert_eq(anyLine(r.logLines, "Warehouse online"), true,
            "the startup banner must be among the forwarded lines")
    end,

    -- The crash line is the single most valuable line this computer prints, and
    -- the loop's interval flush never runs again once main has died. It has to
    -- leave on the way down, and as a real ERROR so ?level=ERROR finds it.
    ["a warehouse crash reaches the fleet log, at ERROR"] = function(assert_eq)
        local r = driveWarehouse({ events = 2, wholeFile = true })
        assert_eq(r.err, "__rebooted__",
            "the crash wrapper must run through to its reboot; got " .. r.err)
        assert_eq(anyLine(r.logLines, "[FATAL]"), true,
            "the crash must be forwarded before the reboot, not left in an outbox "
            .. "that dies with it")
        assert_eq(anyLine(r.logLines, "[FATAL]", "ERROR"), true,
            "and at level ERROR, as a field rather than something parsed from text")
    end,

    -- A plain require failing at startup would stop the warehouse before its own
    -- crash handler runs -- and before it can receive the UPDATE_ALL that would
    -- deliver the missing file. That is the 2026-09-10 fleet outage ("module
    -- 'logship' not found", fifteen turtles at a shell prompt) on the one machine
    -- nobody can see. Losing the log is survivable; losing the warehouse is not.
    ["a missing logship degrades the log, not the warehouse"] = function(assert_eq)
        local r = driveWarehouse({ events = 3, noLogship = true })
        assert_eq(r.ranOut, true,
            "the warehouse must still reach its event loop without logship; got " .. r.err)
        local warned = false
        for _, line in ipairs(r.printed) do
            if line:find("logship", 1, true) then warned = true end
        end
        assert_eq(warned, true,
            "and it must say on its own console that it is not forwarding")
    end,

    -- ─── The storage timing probe ────────────────────────────────────────────
    --
    -- The probe exists to time listItems on THIS computer, so it can be compared
    -- against the dispatch server's 8-29 s stalls for the same minute. Every
    -- number in that investigation was taken on the dispatch computer, which
    -- measures how long that computer waited rather than how long the storage
    -- network took.
    --
    -- Both tests below cover the same risk: the probe is itself an enumeration,
    -- and an enumeration is exactly the yield that destroys a delivery step.
    -- W3 warned about this on 2026-09-10 and W6 committed to the guard on
    -- 2026-09-22. These are that promise, kept in code rather than in a memo.
    ["the probe never runs while a delivery is in flight"] = function(assert_eq)
        local W = fresh(fakeRS(nil), fakeChest({}))
        assert_eq(W.probeDue(9e12, false), false,
            "overdue by any measure, but the warehouse is mid-handshake: an "
            .. "enumeration here destroys the step it lands on")
        assert_eq(W.probeDue(9e12, true), true,
            "and it must still run when idle, or the probe measures nothing at all")
    end,

    -- If the storage network turns out to be the slow party, a probe on a fixed
    -- interval would keep buying seconds of deafness to re-learn that. It has to
    -- notice and step back on its own.
    ["a slow reading backs the probe off instead of paying again"] = function(assert_eq)
        local W = fresh(fakeRS(nil), fakeChest({}))
        local now = 1700000000000
        assert_eq(W.probeRecord(now, W.PROBE_SLOW_MS), W.PROBE_BACKOFF_MS,
            "a slow call must widen the interval")
        assert_eq(W.probeDue(now + W.PROBE_EVERY_MS, true), false,
            "and the normal interval must not make it due again after a back-off")
        assert_eq(W.probeRecord(now, 5), W.PROBE_EVERY_MS,
            "a fast call returns it to the normal interval")
    end,


    -- The two tests above exercise the guard directly. NEITHER of them proves
    -- the probe is wired into the loop at all: delete the call site and both
    -- still pass, because a pure function does not care whether anyone calls
    -- it. That is the shape this project keeps getting caught by -- a check
    -- whose pass state is indistinguishable from the thing never running.
    --
    -- This one drives the real loop and requires the reading to reach the
    -- fleet log, which is the only place the measurement is of any use.
    ["the probe actually runs in the loop and its reading reaches the fleet log"] = function(assert_eq)
        local r = driveWarehouse({ events = 4, stepMs = 16000 })
        assert_eq(r.ranOut, true, "the loop must run the whole script: " .. r.err)
        assert_eq(anyLine(r.logLines, "RS probe: listItems"), true,
            "no probe reading crossed the radio -- the probe is not called from "
            .. "the loop, or its line is not forwarded, and either way the "
            .. "measurement does not exist where anyone can read it")
    end,


    -- ─── The storage digest ─────────────────────────────────────────────────
    --
    -- The dispatch computer never receives the item list: 469 items is 65 KB
    -- serialised, against ~8 KB for the largest thing on the wire, and payload
    -- deafness is on record from a 96 KB push. It gets counts, plus stock for
    -- the names it asked about.
    ["the watchlist is capped, so the digest cannot grow into a 65 KB message again"] = function(assert_eq)
        local W = fresh(fakeRS(nil), fakeChest({}))
        local many = {}
        for i = 1, 500 do many[i] = "minecraft:ore_" .. i end
        assert_eq(#W.acceptWatchlist(many), W.DIGEST_MAX_NAMES,
            "an uncapped watchlist is how a 4 KB contract becomes 65 KB in six "
            .. "months, by accident, with nobody left who remembers the reason")
        assert_eq(W.acceptWatchlist("not a table"), nil)
    end,

    -- Degrade the watchdog, never the heartbeat: the counts are what carry
    -- liveness and the same-network check.
    ["an oversized digest drops the ore stock and still reports the counts"] = function(assert_eq)
        local W = fresh(fakeRS(nil), fakeChest({}))
        local big = {}
        for i = 1, 400 do big["minecraft:a_very_long_ore_name_number_" .. i] = 123456 end
        local payload, oversize = W.digestPayload(469, 24531758, big)
        assert_eq(oversize ~= nil, true, "a payload past the cap must report its size")
        assert_eq(payload.ores, nil, "the ore stock is what gets dropped")
        assert_eq(payload.itemCount, 469, "and the counts must survive")
        assert_eq(payload.grandTotal, 24531758)
        local small = W.digestPayload(469, 24531758, { ["minecraft:iron_ore"] = 12 })
        assert_eq(small.ores["minecraft:iron_ore"], 12, "a small one keeps its stock")
    end,

    -- Wiring, not logic. Both tests above pass with nothing ever sent.
    ["the digest actually reaches the radio"] = function(assert_eq)
        local r = driveWarehouse({ events = 4, stepMs = 16000 })
        assert_eq(r.ranOut, true, "the loop must run the whole script: " .. r.err)
        local found = false
        for _, m in ipairs(r.msgs) do
            if m.type == "STORAGE_DIGEST" and type(m.payload) == "table"
               and m.payload.itemCount ~= nil and m.payload.grandTotal ~= nil then
                found = true
            end
        end
        assert_eq(found, true,
            "no STORAGE_DIGEST carrying itemCount and grandTotal crossed the "
            .. "radio -- the digest is built but never sent, which looks "
            .. "identical to a warehouse with nothing to say")
    end,


    -- W3 renamed this type while writing the contract and told nobody. The
    -- message would have been well-formed, delivered, and matched no handler:
    -- the digest simply never appears, and nothing reports a fault. A silent
    -- fallback is what turns a rename into that.
    ["a missing message constant falls back AND says it fell back"] = function(assert_eq)
        local W = fresh(fakeRS(nil), fakeChest({}))
        local name, fellBack = W.msgName({ STORAGE_DIGEST = "STORAGE_DIGEST" }, "STORAGE_DIGEST")
        assert_eq(name, "STORAGE_DIGEST")
        assert_eq(fellBack, false, "a constant that exists is not a fallback")
        local n2, fb2 = W.msgName({}, "STORAGE_DIGEST")
        assert_eq(n2, "STORAGE_DIGEST", "it must still send something usable")
        assert_eq(fb2, true,
            "and it must report the fallback -- otherwise a renamed type looks "
            .. "exactly like a working one")
    end,


    -- An RS Bridge is normally attached over a WIRED modem, and
    -- peripheral.find("modem") answers with it just as happily as an ender one.
    -- Wrapping the wired one looks entirely healthy -- open succeeds, RS works,
    -- the screen prints -- while every transmit goes onto the cable and the air
    -- is never heard. This computer ran that way for nine days: no logs, no
    -- digests, and UPDATE_ALL never arrived.
    --
    -- The filter matters, but failing LOUDLY matters more: a silent wrong modem
    -- is what cost the nine days.
    ["a wired-only machine refuses to start, and says why"] = function(assert_eq)
        local r = driveWarehouse({ wiredOnly = true, wholeFile = true, events = 2 })
        assert_eq(r.ok, false,
            "a warehouse with no wireless modem must not run: it looks healthy "
            .. "from the inside and is deaf to the entire fleet")
        assert_eq(r.err:find("WIRELESS", 1, true) ~= nil, true,
            "and the error has to name the problem -- got: " .. r.err)
    end,


    -- ─── The bridge poster ──────────────────────────────────────────────────
    --
    -- storageTs is the moment RS was last read SUCCESSFULLY, never send time.
    -- W5 arbitrates the dispatch copy against this one on newest read-time, so
    -- a stale reading stamped with a fresh clock would win and show old stock
    -- as live -- the exact failure this project keeps paying for.
    ["the post body carries the read time, the source, and the craftable flag"] = function(assert_eq)
        local W = fresh(fakeRS(nil), fakeChest({}))
        local items = { { name = "minecraft:iron_ore", amount = 7 },
                        { name = "minecraft:coal", displayName = "[Coal]", count = 3 } }
        local body = W.buildPostBody(items, 1700000000123, { ["minecraft:iron_ore"] = true })
        assert_eq(body:find("1700000000123", 1, true) ~= nil, true, "read time must be sent")
        assert_eq(body:find('"source"', 1, true) ~= nil, true)
        assert_eq(body:find("warehouse", 1, true) ~= nil, true)
        assert_eq(body:find("iron_ore", 1, true) ~= nil, true)
        assert_eq(body:find("[Coal]", 1, true) ~= nil, true, "displayName is kept for the panel")
        assert_eq(body:find("true", 1, true) ~= nil, true, "the craftable flag is stamped")
    end,

    -- W5 asks that the reply be read rather than discarded. A post refused every
    -- cycle otherwise looks exactly like one that is working.
    ["a refusal is read back and reported, not discarded"] = function(assert_eq)
        local W = fresh(fakeRS(nil), fakeChest({}))
        assert_eq(W.readPostReply('{"ok":true}'), true)
        local ok, why = W.readPostReply('{"ok":false,"error":"storage must be an array"}')
        assert_eq(ok, false)
        assert_eq(why, "storage must be an array", "the stated reason must survive")
        assert_eq(W.readPostReply(nil), false, "no reply at all is not success")
        assert_eq(W.readPostReply(""), false)
    end,

    -- Wiring, not logic: both tests above pass with nothing ever posted.
    ["the full list is actually posted to the bridge"] = function(assert_eq)
        local r = driveWarehouse({ events = 4, stepMs = 16000 })
        assert_eq(r.ranOut, true, "the loop must run the whole script: " .. r.err)
        assert_eq(#r.posts > 0, true,
            "nothing was posted -- the dashboard would show the dispatch copy, "
            .. "which stands its poll down during mining and goes stale")
        assert_eq(r.posts[1].url:find("/storage", 1, true) ~= nil, true)
        assert_eq(r.posts[1].body:find("iron_ore", 1, true) ~= nil, true)
    end,

    -- The stamp has to be the READ time, and the only way to tell is to make
    -- time pass between the read and the send.
    ["the post is stamped when RS was read, not when it was sent"] = function(assert_eq)
        local r = driveWarehouse({ events = 4, stepMs = 16000, craftDelayMs = 5000 })
        assert_eq(r.ranOut, true, "the loop must run the whole script: " .. r.err)
        assert_eq(#r.posts > 0, true, "nothing was posted")
        assert_eq(r.afterCraft ~= nil, true, "the craft delay must have been applied")
        local ts = tonumber(r.posts[1].body:match('"storageTs"%s*:%s*(%d+)'))
        assert_eq(ts ~= nil, true, "the body must carry a storageTs")
        assert_eq(ts < r.afterCraft, true,
            "storageTs must predate the work done after the read. W5 arbitrates "
            .. "on newest read-time, so a send-time stamp would let a stale "
            .. "reading win and show old stock as live")
    end,


    -- W5: "older than the snapshot already held" is not an error during the
    -- cutover -- it is what newest-wins looks like while the dispatch server is
    -- still pushing. Warning on it every cycle is how a real warning stops
    -- being read.
    ["the one expected refusal is not reported as a fault"] = function(assert_eq)
        local W = fresh(fakeRS(nil), fakeChest({}))
        assert_eq(W.refusalIsExpected("older than the snapshot already held"), true)
        assert_eq(W.refusalIsExpected("storage is not an array"), false,
            "a real refusal must still be a warning")
        assert_eq(W.refusalIsExpected("missing or unusable storageTs"), false)
        assert_eq(W.refusalIsExpected(nil), false)
    end,


    -- The reply never arrives in this harness, so the first post stays in
    -- flight. Every later cycle must therefore skip -- both the send AND the
    -- 45 KB body build, which is the whole point of checking before building.
    -- At 30s this was cheap; at the 10s cadence the user asked for, a bridge
    -- slower than one cycle would have this computer serialise every item over
    -- and over and throw the result away.
    ["a post already in flight stops the next cycle rebuilding the body"] = function(assert_eq)
        -- Deliberately inside the 30s stuck-clear window. Past it the poster is
        -- SUPPOSED to try again -- a lost reply event must not wedge it forever
        -- -- so a longer run would be testing against the escape hatch rather
        -- than against the guard. 8 steps of 3s is 24s: three cycles, one post.
        local r = driveWarehouse({ events = 8, stepMs = 3000 })
        assert_eq(r.ranOut, true, "the loop must run the whole script: " .. r.err)
        assert_eq(#r.posts, 1,
            "three cycles with no reply, inside the stuck window, must post "
            .. "exactly once -- got " .. #r.posts
            .. "; without the guard each cycle rebuilds 45 KB and retries")
    end,

}
