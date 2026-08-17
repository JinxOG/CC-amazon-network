-- Guards the constraint that delivery behaviour is untouched by the mining
-- rework. Asserts on the delivery-relevant protocol surface, which is what
-- support_turtle's delivery branch and delivery_turtle both depend on.
local proto = require("protocol")

return {
    ["delivery coordination messages still exist"] = function(assert_eq)
        for _, t in ipairs({ "HOLE_READY", "SUPPORT_STAGED", "POSITION_UPDATE",
                            "RETURN_TO_DOCK", "ASCENDING", "DESCENDED",
                            "JOB_ABORT" }) do
            assert_eq(proto.MSG[t], t, "delivery message " .. t .. " must remain")
        end
    end,

    ["SUPPORT_FOLLOW job type still exists"] = function(assert_eq)
        assert_eq(proto.JOB.SUPPORT_FOLLOW, "SUPPORT_FOLLOW")
    end,

    ["heartbeat stays backward compatible with 4 args"] = function(assert_eq)
        local p = proto.payloadHeartbeat("IDLE", 100, { x = 1, y = 2, z = 3 }, "job_1")
        assert_eq(p.status, "IDLE")
        assert_eq(p.jobId, "job_1")
        assert_eq(p.phase, nil, "phase must be nil for non-miners")
        assert_eq(p.chunk, nil)
    end,

    -- The assertions above only pin protocol.lua and would pass even if
    -- support_turtle.lua were deleted outright. These two actually exercise
    -- the file: loadfile catches syntax damage the harness never runs
    -- (support_turtle.lua can't be require()'d), and the pattern search
    -- requires the literal dispatch comparison "msg.type == proto.MSG.X",
    -- not just the name appearing anywhere (e.g. in a comment).
    -- SUPPORT_STAGED is deliberately excluded: support_turtle.lua never
    -- compares msg.type against it (it's emitted by turtle_base.lua's
    -- depart(), not consumed here), so any check for it here could only
    -- match the name in a comment and would not be discriminating.
    ["support_turtle.lua still loads and still handles delivery messages"] = function(assert_eq)
        assert_eq(loadfile("support_turtle.lua") ~= nil, true, "support_turtle.lua must still be valid Lua")
        local f = assert(io.open("support_turtle.lua", "r"))
        local src = f:read("*a")
        f:close()
        for _, t in ipairs({ "HOLE_READY", "POSITION_UPDATE", "ASCENDING", "DESCENDED", "RETURN_TO_DOCK" }) do
            assert_eq(src:find("msg%.type%s*==%s*proto%.MSG%." .. t) ~= nil, true,
                "support_turtle.lua must still dispatch on " .. t)
        end
    end,
}
