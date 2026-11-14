-- The server's GPS check must keep running when its timer event is lost (W3, 2026-11-14). It gates every dispatch,
-- and it ran only when its own 5 s timer fired: after the total radio blackout in the side-test sim (w3_side_atc) its
-- last judgement, "0 of 4 GPS hosts answered", stood for the rest of the run and no job went out again.
package.path = "./?.lua;" .. package.path

local stub = require("tests.stub_cc")

local function freshServer()
    stub.install({})
    local clock = 1794540000000
    local savedEpoch, savedPeripheral = os.epoch, peripheral
    os.epoch = function() return clock end
    peripheral = { find = function() return nil end }
    package.loaded["cloudstore"] = nil
    _G.__CC_SERVER_TEST = true
    package.loaded["central_server"] = nil
    package.loaded["waypoints"] = nil
    local server = require("central_server")
    return server, server._test, function()
        os.epoch, peripheral = savedEpoch, savedPeripheral
        _G.__CC_SERVER_TEST = nil
        package.loaded["central_server"] = nil
        package.loaded["cloudstore"] = nil
    end, function(ms) clock = clock + ms end
end

local function src()
    local f = assert(io.open("central_server.lua", "rb")); local s = f:read("*a"); f:close(); return s
end

return {
    ["the wall-clock block runs the GPS check when its timer has not, as every other periodic task"] = function(assert_eq)
        local s = src()
        local a = s:find("local wc = os.epoch(\"utc\")", 1, true)
        local block = a and s:sub(a, a + 6000) or ""
        assert_eq(a ~= nil, true, "found the wall-clock block (the case under test)")
        assert_eq(block:find("isDue(wc, state.lastGpsWC or 0", 1, true) ~= nil and block:find("gpsTickSafe", 1, true) ~= nil,
            true, "it runs dispatcher.gpsTickSafe when state.lastGpsWC is old")
    end,

    ["a GPS tick notes when it ran, and a failing one says so once"] = function(assert_eq)
        local server, T, restore = freshServer()
        local D = T.dispatcher
        D.gpsTickSafe()
        local noted = T.state.lastGpsWC
        local real = D.gpsTick
        D.gpsTick = function() error("boom") end
        local before = #T.state.log
        D.gpsTickSafe(); D.gpsTickSafe(); D.gpsTickSafe()
        local said = 0
        for i = before + 1, #T.state.log do
            if tostring(T.state.log[i].msg):find("GPS check tick failed", 1, true) then said = said + 1 end
        end
        D.gpsTick = real
        restore()
        assert_eq(noted, 1794540000000, "the run's time is noted, for the wall-clock fallback")
        assert_eq(said, 1, "three failing ticks, one line")
    end,
}
