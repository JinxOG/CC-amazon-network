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
}
