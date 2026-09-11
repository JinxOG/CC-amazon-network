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
    peripheral.find    = function(n)
        if n == "rsBridge" then return rs end
        if n == "modem" then return { open = function() end, transmit = function() end } end
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
    _G.__LOGSHIP_RAW_PRINT = nil
    sleep = function() end
    os.reboot = function() error("__rebooted__", 0) end
    if opts.noLogship then
        package.preload["logship"] = function() error("module 'logship' not found", 0) end
    end

    local sent = {}
    local modem = {
        open     = function() end,
        transmit = function(_, _, payload) sent[#sent + 1] = payload end,
    }
    local rs, chest = fakeRS(nil), fakeChest({})
    peripheral.find = function(n)
        if n == "rsBridge" then return rs end
        if n == "modem" then return modem end
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
    return {
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
}
