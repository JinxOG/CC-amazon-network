-- What a delivery or support turtle does when its control loop dies.
--
-- Cleanup phase card 5, signed off by the spec owner on 2026-09-11 under the
-- §5.3 exception to Invariant H
-- (2026-09-11-spec-owner-to-W3-release-order-and-crash-sign-off.md).
--
-- Two different repairs, found by reading the files:
--
--   * support_turtle.lua has a crash handler -- print, sleep(20), reboot -- but
--     never flushed the log. logship's print capture queues the fatal line, and
--     the control loop that would have sent it is the thing that just died. So
--     the one line that explains the crash was the one guaranteed not to arrive.
--   * delivery_turtle.lua had NO crash handler. base.run was called bare, so a
--     control-loop crash escaped startup.lua and left the turtle at the shell
--     prompt -- no reboot, no re-registration -- until someone walked over.
--
-- These run each startup script for real, against a fake turtle_base whose run
-- loop raises. The scripts cannot be require()'d (they run on load and never
-- return), which is why the existing coverage of them is a loadfile and a text
-- search; this is the first test that executes their crash path.

package.path = "./?.lua;" .. package.path

local BOOM   = "boom: the control loop died"
local REBOOT = { "reboot" }        -- os.reboot never returns; a sentinel models that

-- Runs `path` as startup.lua. runBehaviour is what base.run does: "crash" raises,
-- "return" returns normally. Returns the ordered calls, the printed lines, and
-- whether the script ended in a reboot.
local function runScript(path, runBehaviour)
    local calls, printed = {}, {}
    local noop = function() end
    local anything = { __index = function() return noop end }
    local fakeBase = setmetatable({
        fuel      = setmetatable({}, anything),
        run       = function()
            calls[#calls + 1] = "run"
            if runBehaviour == "crash" then error(BOOM, 0) end
        end,
        flushLogs = function() calls[#calls + 1] = "flushLogs" end,
    }, anything)

    local saved = { base = package.loaded["turtle_base"], reboot = os.reboot,
                    sleep = sleep, print = print }
    package.loaded["turtle_base"] = fakeBase
    os.reboot = function() calls[#calls + 1] = "reboot"; error(REBOOT, 0) end
    sleep     = function() calls[#calls + 1] = "sleep" end
    print     = function(...)
        local parts = {}
        for i = 1, select("#", ...) do parts[i] = tostring((select(i, ...))) end
        printed[#printed + 1] = table.concat(parts, " ")
    end

    local chunk = assert(loadfile(path))
    local ok, err = pcall(chunk)

    package.loaded["turtle_base"] = saved.base
    os.reboot, sleep, print = saved.reboot, saved.sleep, saved.print

    local rebooted = (not ok) and err == REBOOT
    -- Anything else escaping the script is the bug this card fixes for
    -- delivery: a crash reaching the shell prompt. Surface it, don't swallow it.
    local escaped = (not ok) and err ~= REBOOT and tostring(err) or nil
    return calls, printed, rebooted, escaped
end

local function indexOf(list, item)
    for i, v in ipairs(list) do if v == item then return i end end
    return nil
end

return {
    ["a support turtle flushes its log before rebooting after a crash"] =
    function(assert_eq)
        local calls = runScript("support_turtle.lua", "crash")
        local f, r = indexOf(calls, "flushLogs"), indexOf(calls, "reboot")
        assert_eq(r ~= nil, true, "precondition: support already reboots after a crash")
        assert_eq(f ~= nil, true,
            "the crash handler must flush the log -- the loop that would have "
            .. "sent the fatal line is the thing that just died")
        assert_eq(f ~= nil and r ~= nil and f < r, true,
            "and flush BEFORE rebooting, or the reboot wipes the queue")
    end,

    ["a delivery turtle flushes its log before rebooting after a crash"] =
    function(assert_eq)
        local calls = runScript("delivery_turtle.lua", "crash")
        local f, r = indexOf(calls, "flushLogs"), indexOf(calls, "reboot")
        assert_eq(f ~= nil and r ~= nil and f < r, true,
            "delivery must flush its last lines before rebooting, the same as "
            .. "support -- calls were: " .. table.concat(calls, ", "))
    end,

    -- The one that proves a delivery turtle no longer stops at a shell prompt.
    ["a delivery turtle reboots after its control loop crashes"] =
    function(assert_eq)
        local calls, printed, rebooted, escaped = runScript("delivery_turtle.lua", "crash")
        assert_eq(escaped, nil,
            "a control-loop crash must not escape startup.lua -- that leaves the "
            .. "turtle at the shell prompt until someone restarts it by hand")
        assert_eq(rebooted, true, "it must reboot instead")
        local said = table.concat(printed, "\n")
        assert_eq(said:find("[DELIVERY] Fatal crash: " .. BOOM, 1, true) ~= nil, true,
            "and say why first, in support's words with the delivery prefix -- got: " .. said)
    end,

    -- Support's shape reboots after a clean return too, and the signed-off
    -- handler puts os.reboot() outside the `if not ok` for delivery the same
    -- way. A clean return is not a crash, so it must not claim to be one.
    ["a delivery turtle whose run loop returns reboots without a crash report"] =
    function(assert_eq)
        local calls, printed, rebooted, escaped = runScript("delivery_turtle.lua", "return")
        assert_eq(escaped, nil, "a clean return must not raise")
        assert_eq(rebooted, true, "and must still reboot, as support does")
        assert_eq(indexOf(calls, "flushLogs"), nil, "without the crash-path flush")
        assert_eq(table.concat(printed, "\n"):find("Fatal crash", 1, true), nil,
            "and without reporting a crash that did not happen")
    end,
}
