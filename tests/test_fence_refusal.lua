-- A refused move must not flood the log (W3 card "A refused move retries
-- hundreds of times a second and floods the log", found 2026-09-29).
--
-- node_118 logged ~294 "Geofence: refusing move to ..." lines in three seconds,
-- across three targets, and burned 237 of its log slots in under a minute -- the
-- window in which any other line from it would have been lost. The geofence was
-- right to refuse; the refusal returned at once, so a caller retrying it spun.
-- Now each refused target is logged at most once in ten seconds (the next line
-- says how many were held back), and the same target refused again within a
-- second waits half a second, so a retry loop cannot spin.
local stub = require("tests.stub_cc")

local slept = {}
sleep = function(s) slept[#slept + 1] = s end
local clock = 1000000
os.epoch = function() return clock end

local function fresh(opts)
    local c = stub.install(opts)
    gps = { locate = function() return c.pos.x, c.pos.y, c.pos.z end }
    package.loaded["turtle_base"] = nil
    package.loaded["geofence"]    = nil
    local base = require("turtle_base")
    base.gpsSync()
    return base, c
end

-- Loaded BEFORE print is captured: logship owns print once turtle_base loads.
local function capture()
    local lines, saved = {}, print
    print = function(...) lines[#lines + 1] = table.concat({ ... }, " ") end
    return lines, function() print = saved end
end

local function count(lines, text)
    local n = 0
    for _, l in ipairs(lines) do if l:find(text, 1, true) then n = n + 1 end end
    return n
end

-- At y=160 under a lease ceiling of 160: every move up is refused.
local function underCeiling()
    local base = fresh({ equipped = { left = "minecraft:diamond_pickaxe" },
                         pos = { x = 0, y = 160, z = -16, facing = 0 } })   -- north edge, facing north
    base.geofence.setLease(-16, -16, 15, 15, 160)
    return base
end

return {
    ["one refused move retried 300 times is logged once in ten seconds"] = function(assert_eq)
        local base = underCeiling()
        local lines, restore = capture()
        local refused = 0
        for _ = 1, 300 do
            local ok, why = base.move.up()
            if not ok and why == "geofence_breach" then refused = refused + 1 end
        end
        restore()
        assert_eq(refused, 300, "every one is still refused")
        assert_eq(count(lines, "refusing move"), 1, "but logged once")
    end,

    ["after the quiet ten seconds the line says how many were held back"] = function(assert_eq)
        local base = underCeiling()
        local lines, restore = capture()
        for _ = 1, 300 do base.move.up() end
        clock = clock + 11000
        base.move.up()
        restore()
        assert_eq(count(lines, "refusing move"), 2)
        assert_eq(count(lines, "299 identical refusal"), 1, "the held-back count is said")
    end,

    ["two refused targets taken in turn are each logged once"] = function(assert_eq)
        local base = underCeiling()                          -- on the north edge: forward leaves the lease too
        local lines, restore = capture()
        for _ = 1, 150 do base.move.up(); base.move.forward() end
        restore()
        assert_eq(count(lines, "refusing move to y=161"), 1)
        assert_eq(count(lines, "refusing move to 0,-17"), 1)
    end,

    ["the same refusal again within a second waits half a second; the first does not"] = function(assert_eq)
        local base = underCeiling()
        local lines, restore = capture()
        slept = {}
        base.move.up()
        local afterFirst = #slept
        base.move.up()
        restore()
        local waited = false
        for i = afterFirst + 1, #slept do if (slept[i] or 0) >= 0.5 then waited = true end end
        assert_eq(afterFirst, 0, "the first refusal returns at once")
        assert_eq(waited, true, "a repeat within a second waits")
    end,
}
