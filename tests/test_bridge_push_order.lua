-- Why the server lost both the push completion AND its timeout, once a minute.
--
-- Measured 2026-09-03 by the spec owner: twelve force-clears in 13.7 minutes,
-- every stall running the FULL force-clear window (33.2, 31.6, 31.3, 29.4, 29.6,
-- 25.9 s) rather than ending at the 5 s timeout. Inbound traffic ~5 messages/sec
-- against a 256-slot event queue, which is why counting queue capacity never
-- explained it: nothing was overflowing.
--
-- Two separate causes, both structural, both in the ordering rather than in any
-- one function:
--
-- 1. THE COMPLETION. The bridge answers in ~1 ms. The push used to be issued
--    from the wall-clock block roughly forty lines above refreshStorage, so on
--    any iteration where both were due -- every 15 s, lcm(BRIDGE_INTERVAL 3,
--    STORAGE_INTERVAL 5) -- rsBridge.listItems() began yielding a few statements
--    after http.request returned, with the response already in flight. A
--    peripheral call parks the coroutine on a filtered wait and CC discards
--    every event that does not match it. The yield does not have to be long
--    (159 ms worst, measured); it has to be ADJACENT, and it was adjacent by
--    construction.
--
-- 2. THE TIMEOUT. BRIDGE_PUSH_TIMEOUT was 5, equal to STORAGE_INTERVAL. The
--    timeout timer is started in the same iteration as the push, and that
--    iteration stamps lastStorageWC, so the next poll was scheduled for exactly
--    push + 5 s -- the instant the timeout fired. The two "independently
--    dropped" events were the same peripheral call eating the same push twice.
--
-- SOURCE-ORDERING, and weaker than the tests it sits beside. server.run's loop
-- is not reachable under this harness: requiring central_server.lua with the
-- test seam set returns before the loop, and the loop never terminates. What
-- can be pinned is the ordering that caused it, which is the thing at risk of
-- being tidied back.

package.path = "./?.lua;" .. package.path

-- The push witness, from a freshly loaded server (module-level, via the seam).
local function witness()
    _G.__CC_SERVER_TEST = true
    package.loaded["central_server"] = nil
    package.loaded["waypoints"]      = nil
    local stub = require("tests.stub_cc")
    stub.install({})
    local W = require("central_server")._test.pushWitness
    _G.__CC_SERVER_TEST = nil
    package.loaded["central_server"] = nil
    return W
end

local function serverSource()
    local f = assert(io.open("central_server.lua", "r"))
    local src = f:read("*a")
    f:close()
    return src
end

-- The loop body only. Anchored on the pullEventRaw that opens it, so a match in
-- the startup code above (server.run calls refreshStorage once before the loop)
-- cannot satisfy an ordering assertion about the loop.
local function loopBody(src)
    local from = src:find("local event, p1, p2, p3, p4 = os%.pullEventRaw%(%)")
    assert(from, "the event loop's pullEventRaw moved or vanished")
    local to = src:find("\n%-%- ─── Test seam", from)
    return src:sub(from, to or #src), from
end

return {
    ["the bridge push is issued after every call that can yield (SOURCE-ORDERING, weaker)"] =
    function(assert_eq)
        local body = loopBody(serverSource())

        -- Anchored on the ARGUMENT, not the wrapper: these calls were bare pcall
        -- until the stall instrumentation wrapped them in timed(), and an
        -- assertion pinned to the wrapper name goes red on a change that did
        -- not touch the property it guards.
        local pushAt = body:find(", startBridgePush%)")
        assert_eq(pushAt ~= nil, true, "the loop no longer pushes at all")

        -- refreshStorage is the yield that eats the response. Both its triggers
        -- -- the storageTimer handler and the wall-clock fallback -- must come
        -- before the push, or the adjacency is back.
        local lastPollAt = nil
        local at = body:find(", refreshStorage%)")
        assert_eq(at ~= nil, true, "the RS poll moved or vanished from the loop")
        while at do
            lastPollAt = at
            at = body:find(", refreshStorage%)", at + 1)
        end
        assert_eq(lastPollAt < pushAt, true,
            "every refreshStorage call must precede the push: the bridge answers "
            .. "in ~1 ms, so a peripheral call yielding after http.request "
            .. "destroys the http_success it is waiting for")

        -- Same argument for the craftable poll, which is the same peripheral.
        local craftAt = body:find(", refreshCraftable%)")
        assert_eq(craftAt ~= nil and craftAt < pushAt, true,
            "the craftable poll must precede the push for the same reason")
    end,

    ["exactly one place starts a bridge push (SOURCE-ONLY, weaker)"] =
    function(assert_eq)
        local body = loopBody(serverSource())

        -- Matched on the argument position, NOT `startBridgePush()`: the loop
        -- never uses the bare-call form, so that pattern matched nothing but
        -- the prose mentioning it -- a count that was 1 whatever the code did.
        local n, at = 0, body:find(", startBridgePush%)")
        while at do
            n = n + 1
            at = body:find(", startBridgePush%)", at + 1)
        end
        -- Two triggers were the original defect on this line: the bridgeTimer
        -- branch pushed WITHOUT stamping lastBridgePushWC, so it and the
        -- wall-clock check ran as independent triggers -- the same double-run
        -- the storageTimer handler carries a comment about having already fixed
        -- for the RS poll. A second site also reintroduces the adjacency this
        -- file exists to prevent, because it would not be at the bottom.
        assert_eq(n, 1,
            "the loop must start a push from exactly one place, or the stamp "
            .. "that paces it is bypassed and the ordering is not guaranteed")
    end,

    ["the push timeout is not phase-locked to the RS poll"] =
    function(assert_eq)
        local src = serverSource()

        -- Read the real value out of the source; the constant is a local inside
        -- server.run and is not reachable through the test seam.
        local timeout = tonumber(src:match("local BRIDGE_PUSH_TIMEOUT = (%d+)"))
        assert_eq(timeout ~= nil, true, "BRIDGE_PUSH_TIMEOUT moved or vanished")

        -- CFG is reachable, so this half is a genuine value comparison rather
        -- than a second source scan.
        _G.__CC_SERVER_TEST = true
        package.loaded["central_server"] = nil
        package.loaded["waypoints"]      = nil
        local stub = require("tests.stub_cc")
        stub.install({})
        local storage = require("central_server")._test.CFG.STORAGE_INTERVAL
        _G.__CC_SERVER_TEST = nil
        package.loaded["central_server"] = nil

        -- Equal was the bug. A multiple in either direction locks the same way:
        -- the timeout is armed in the iteration that stamps lastStorageWC, so
        -- any common period puts it inside a poll's yield window every time.
        assert_eq(timeout ~= storage, true,
            "BRIDGE_PUSH_TIMEOUT must not equal STORAGE_INTERVAL — at 5 and 5 "
            .. "the timeout fired at exactly the next RS poll, every time, "
            .. "which is why no stall ever ended at 5 s")
        assert_eq(timeout % storage ~= 0 and storage % timeout ~= 0, true,
            "nor a multiple of it, which locks the phase the same way")

        -- And it must still beat the fleet's patience: MAX_MISSED (3) x
        -- HEARTBEAT_INTERVAL (5) = 15 s. At or above that, one dropped event
        -- makes the server unresponsive for exactly as long as it takes the
        -- fleet to give up on it, which is the feedback loop from 2026-08-30.
        assert_eq(timeout < 15, true,
            "the timeout must recover well before a turtle re-registers")
    end,

    -- ── The push witness (cleanup phase, Wave 2 card 7) ─────────────────────
    -- What the loop did between a push leaving and its timeout. Driven directly:
    -- server.run's loop is not reachable here, and the witness is module-level
    -- so that its judgement can be tested rather than read.
    ["a timeout after a storage scan says the scan ran in the window"] =
    function(assert_eq)
        local W = witness()
        W.start()
        W.step("bridgePush", 15); W.turn("timer")          -- the push's own turn
        W.step("refreshStorage", 546); W.turn("timer")     -- the next turn
        W.step("handler:HEARTBEAT", 1); W.turn("modem_message")
        local line = W.summary() or ""
        assert_eq(line:find("2 event(s)", 1, true) ~= nil, true,
            "the push's own turn is not part of the window -- got: " .. line)
        assert_eq(line:find("refreshStorage 546ms", 1, true) ~= nil, true,
            "and the step that ran must be named with its time -- got: " .. line)
        assert_eq(line:find("a storage peripheral call ran", 1, true) ~= nil, true,
            "and the verdict must say a storage call ran -- got: " .. line)
    end,

    -- The finding that would sink the hypothesis. A witness that could not
    -- report "nothing ran" would read every timeout as proof of the storage
    -- scan -- a pass state that looks like its no-data state.
    ["a timeout with nothing after the push says so"] = function(assert_eq)
        local W = witness()
        W.start()
        W.step("bridgePush", 15); W.turn("timer")
        local line = W.summary() or ""
        assert_eq(line:find("no events", 1, true) ~= nil, true,
            "zero events after the push must be reported as zero -- got: " .. line)
        assert_eq(line:find("storage peripheral call ran", 1, true), nil,
            "and must not blame the storage scan for a window it was not in")
    end,

    ["a window with no storage call says it was not the scan"] = function(assert_eq)
        local W = witness()
        W.start()
        W.turn("timer")
        W.step("handler:HEARTBEAT", 2); W.turn("modem_message")
        local line = W.summary() or ""
        assert_eq(line:find("not the storage scan", 1, true) ~= nil, true,
            "a timeout with no storage call in its window is a different fault, "
            .. "and must be labelled as one -- got: " .. line)
    end,

    -- A storage call that was not the slowest step in its turn must still count.
    ["a storage call behind a slower step still counts"] = function(assert_eq)
        local W = witness()
        W.start(); W.turn("timer")
        W.step("dispatch", 900); W.step("refreshCraftable", 40); W.turn("timer")
        local line = W.summary() or ""
        assert_eq(line:find("refreshCraftable 40ms", 1, true) ~= nil, true,
            "every step is recorded, not just the slowest -- got: " .. line)
        assert_eq(line:find("a storage peripheral call ran", 1, true) ~= nil, true,
            "so the verdict sees it -- got: " .. line)
    end,

    ["a long window is capped and says how much it left out"] = function(assert_eq)
        local W = witness()
        W.start(); W.turn("timer")
        for _ = 1, 20 do W.turn("modem_message") end
        local line = W.summary() or ""
        assert_eq(line:find("20 event(s)", 1, true) ~= nil, true,
            "the count must be the real count -- got: " .. line)
        assert_eq(line:find("(+12 more)", 1, true) ~= nil, true,
            "and a capped trail must say what it dropped -- got: " .. line)
    end,

    ["a reply that arrived ends the window"] = function(assert_eq)
        local W = witness()
        W.start(); W.turn("timer"); W.turn("modem_message")
        W.stop()
        assert_eq(W.summary(), nil,
            "after the reply there is no window to report")
    end,

    -- SOURCE-ONLY, weaker: the loop is not reachable. Comments stripped, since an
    -- anchor matching prose has passed against broken code five times.
    ["the push, the reply, the timeout and the loop all feed the witness (SOURCE-ONLY, weaker)"] =
    function(assert_eq)
        local f = assert(io.open("central_server.lua", "r"))
        local src = f:read("*a")
        f:close()
        local NL = string.char(10)
        local code = (src:gsub("%-%-[^" .. NL .. "]*", ""))
        local function near(anchor, want, span)
            local at = code:find(anchor, 1, true)
            return at ~= nil and code:sub(at, at + (span or 400)):find(want, 1, true) ~= nil
        end
        assert_eq(near("bridgeTimeoutId   = os.startTimer(BRIDGE_PUSH_TIMEOUT)", "pushWitness.start()", 120), true,
            "starting a push must open the window")
        assert_eq(near("if p1 == CFG.BRIDGE_URL and bridgePending then", "pushWitness.stop()", 120), true,
            "the reply must close it")
        assert_eq(near("elseif p1 == bridgeTimeoutId then", "pushWitness.summary()", 300), true,
            "the timeout line must carry the evidence")
        assert_eq(near("local ms = os.epoch(\"utc\") - t0", "pushWitness.step(name, ms)", 200), true,
            "every timed step must be recorded")
        -- Anchored on the loop's own busy-window line and searched BACKWARDS
        -- from it. The first version searched the whole file for
        -- "pushWitness.turn(event)" -- which also matches the function's
        -- DEFINITION, so deleting the call left it green. Caught by mutation.
        local busyAt = code:find('local busy = os.epoch("utc") - busyStart', 1, true)
        assert_eq(busyAt ~= nil and code:sub(math.max(1, busyAt - 80), busyAt)
                      :find("pushWitness.turn(event)", 1, true) ~= nil, true,
            "and every loop turn must be counted, at the loop itself")
    end,

}
