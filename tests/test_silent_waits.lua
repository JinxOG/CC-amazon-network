-- Invariant J: nothing may block silently for more than 10 seconds.
--
-- tryMove had two waits that did. The turtle-blocked wait stood still for a full
-- two minutes and said nothing at all, then returned an error string and left it
-- to the caller. The server-down hold announces itself once when serverDown
-- trips and is then silent for as long as it lasts, which is unbounded.
--
-- Both are the ambiguity the invariant exists to remove: from the outside, a
-- turtle holding position is indistinguishable from a crashed one. Most of this
-- month's diagnosis cost has been made of exactly that.

package.path = "./?.lua;" .. package.path

local stub = require("tests.stub_cc")

local TURTLE = "computercraft:turtle_advanced"

-- A turtle boxed in on every side a bypass could take: ahead, both lanes, and
-- up/down. Without all five the bypass succeeds and the wait never happens, so
-- the test would pass while exercising nothing.
local function boxedIn()
    return {
        pos   = { x = 0, y = 60, z = 0, facing = 0 },   -- facing north (-z)
        world = {
            ["0,60,-1"] = TURTLE,   -- forward
            ["-1,60,0"] = TURTLE,   -- left lane
            ["1,60,0"]  = TURTLE,   -- right lane
            ["0,61,0"]  = TURTLE,   -- up   (vertical bypass)
            ["0,59,0"]  = TURTLE,   -- down (vertical bypass)
        },
    }
end

-- Time advances ONLY inside sleep, by the amount slept. That is faithful to what
-- the loop actually does -- it sleeps between retries -- and it makes the number
-- of report lines a function of elapsed time rather than of iteration count,
-- which is the property under test.
local function withClock(body)
    local savedClock, savedSleep, savedPrint = os.clock, sleep, print
    local t = 1000
    local lines = {}
    os.clock = function() return t end
    sleep    = function(n) t = t + (n or 0) end
    local restore = function()
        os.clock, sleep, print = savedClock, savedSleep, savedPrint
    end
    local ok, err = pcall(function()
        local c = stub.install(boxedIn())
        gps = { locate = function() return c.pos.x, c.pos.y, c.pos.z end }
        package.loaded["turtle_base"] = nil
        package.loaded["geofence"]    = nil
        local base = require("turtle_base")
        base.gpsSync()
        -- Captured AFTER load, so turtle_base's own print wrapper is already
        -- installed and this sees what it forwards.
        print = function(...) lines[#lines + 1] = table.concat({ ... }, "\t") end
        body(base, c, lines, function() return t end)
    end)
    restore()
    if not ok then error(err, 0) end
    return lines
end

local function countMatching(lines, needle)
    local n = 0
    for _, l in ipairs(lines) do
        if l:find(needle, 1, true) then n = n + 1 end
    end
    return n
end

return {
    ["a turtle blocked for two minutes says so, repeatedly but not constantly"] =
    function(assert_eq)
        local lines = withClock(function(base)
            local ok, err = base.move.forward()
            assert_eq(ok, false, "precondition: the move must actually be blocked")
            assert_eq(tostring(err):find("blocked by turtle", 1, true) ~= nil, true,
                "precondition: it must give up on the turtle-blocked path, "
                .. "not the static-block one — got: " .. tostring(err))
        end)

        local waits = countMatching(lines, "Still waiting")
        assert_eq(waits >= 1, true,
            "two minutes of standing still must not be silent (Invariant J)")
        -- Rate limiting is half the point. The loop retries roughly sixty times
        -- over 120 s; a line per retry is how a log stops being readable, and
        -- these computers have already needed two rounds of log-volume fixes.
        assert_eq(waits <= 8, true,
            "the wait report must be rate-limited, not one line per retry — got "
            .. waits)

        assert_eq(countMatching(lines, "Gave up after 120s") >= 1, true,
            "giving up must be logged, not only returned to the caller")
    end,

    ["a block that clears inside ten seconds is not reported at all"] =
    function(assert_eq)
        local lines = withClock(function(base, c)
            -- Clears after ~5 s of sleeping: 0.5 + 1.0 + 1.5 + 2.0. Under the
            -- threshold, so a correct implementation stays quiet. This is the
            -- guard against over-fixing by logging on every wait, which would
            -- put a line in the log for every routine step around a passing
            -- turtle at the depot.
            local slept, savedSleep = 0, sleep
            sleep = function(n)
                slept = slept + 1
                savedSleep(n)
                if slept == 4 then
                    c.world["0,60,-1"] = nil
                    c.world["-1,60,0"] = nil
                    c.world["1,60,0"]  = nil
                end
            end
            base.move.forward()
            sleep = savedSleep
        end)

        assert_eq(countMatching(lines, "Still waiting"), 0,
            "a short, ordinary wait must stay out of the log")
    end,

    -- SOURCE-ONLY, and weaker than the two above, deliberately.
    --
    -- The server-down hold needs _self.serverDown true, and nothing exposes a
    -- setter -- it is only set from inside sendHeartbeat once MAX_MISSED
    -- heartbeats go unacknowledged. Reaching it from here means standing up the
    -- control loop and then re-entering movement, i.e. two harnesses to pin two
    -- lines of wiring whose reporter is already covered by the tests above.
    --
    -- What this does pin is that the wiring exists at all, which is the thing
    -- that could be quietly dropped.
    ["the server-down hold reports itself too (SOURCE-ONLY, weaker)"] =
    function(assert_eq)
        local f = assert(io.open("turtle_base.lua", "r"))
        local src = f:read("*a")
        f:close()

        local loopAt = src:find("while _self%.serverDown")
        assert_eq(loopAt ~= nil, true, "the server-down hold moved or vanished")
        local endAt = src:find("local maxDig", loopAt)
        assert_eq(endAt ~= nil and endAt > loopAt, true,
            "could not bound the hold loop")
        local body = src:sub(loopAt, endAt)

        -- The call, not the construction: building a reporter and never calling
        -- it is silence with extra steps.
        assert_eq(body:find("downReport()", 1, true) ~= nil, true,
            "the unbounded server-down hold must report itself (Invariant J)")
        assert_eq(body:find("waitReporter(", 1, true) ~= nil, true,
            "and must use the shared, rate-limited reporter rather than its own")
    end,
}
