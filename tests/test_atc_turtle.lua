-- The turtle's half of the base ATC (turtle_base.lua, base.atc), without an ATC.
-- docs/superpowers/specs/2026-11-03-base-atc-design.md
local stub = require("tests.stub_cc")

local function fresh()
    local c = stub.install({ pos = { x = 0, y = 67, z = 0, facing = 0 } })
    gps = { locate = function() return c.pos.x, c.pos.y, c.pos.z end }
    package.loaded["turtle_base"] = nil
    package.loaded["geofence"] = nil
    local base = require("turtle_base")
    local sent = {}
    peripheral.find = function()
        return { transmit = function(ch, rr, body) sent[#sent + 1] = tostring(body) end,
                 open = function() end, isOpen = function() return true end, close = function() end }
    end
    base.recoverModem()
    return base, sent
end

return {
    -- 15 docked turtles in the 150-turtle boot rush (sim, 2026-11-03) were marked STUCK while they waited, and
    -- stayed ERROR -- which the server never dispatches -- after they were moving again.
    ["a turtle that reported STUCK goes back to its status once it moves again"] = function(assert_eq)
        local base, sent = fresh()
        local proto = require("protocol")
        base.setStatus(proto.STATUS.IDLE)
        base.atc.stallAt = os.clock() - base.atc.STUCK_S - 1
        base.atc.stalled("a test")
        assert_eq(base.statusForTest(), proto.STATUS.ERROR, "stuck past the bound: ERROR, so it is not dispatched")
        base.atc.progressed()
        assert_eq(base.statusForTest(), proto.STATUS.IDLE, "moving again: back to IDLE")
        local said = false
        for _, b in ipairs(sent) do if b:find("moving again", 1, true) then said = true end end
        assert_eq(said, true, "and the server is told")
    end,

    -- The 150-turtle week (sim 20261104-183352, 2026-09-23 06:52): a delivery aborted outside the depot went straight
    -- to holding slot 11, digging; its support, which cannot dig, lagged on the tunnel row at 160,60,-2813 when the
    -- delivery said "hold", was given slot 12 in turn -- through rock -- and was stranded in the departure tunnel.
    -- Every later departure piled up behind it: 105 deliveries waiting by hour 105.
    ["a support left behind on its delivery's path asks for its delivery's slot"] = function(assert_eq)
        local base, sent = fresh()
        local proto = require("protocol")
        base.setPartnerId("node_3060")
        local off = { x = 160, y = 60, z = -2813 }            -- on the tunnel row, in no slot's column
        local before = base.atc.preferSlot(off)
        local msg = proto.encode(proto.MSG.ASCENDING, "node_3060", "broadcast", { slot = 11 })
        os.queueEvent("modem_message", "top", 1, 1, msg, 5)
        base.receive(5)
        assert_eq(before, nil, "nothing to go on before the delivery says where it is")
        assert_eq(base.atc.preferSlot(off), 11, "the delivery's slot: the way there is the path it dug")
        base.setPartnerId("node_9")
        assert_eq(base.atc.preferSlot(off), nil, "a new partner forgets the last one's slot")
    end,

    ["a slot named by some other turtle is ignored"] = function(assert_eq)
        local base = fresh()
        local proto = require("protocol")
        base.setPartnerId("node_3060")
        local msg = proto.encode(proto.MSG.RETURN_TO_DOCK, "node_77", "broadcast", { slot = 4 })
        os.queueEvent("modem_message", "top", 1, 1, msg, 5)
        base.receive(5)
        assert_eq(base.atc.preferSlot({ x = 160, y = 60, z = -2813 }), nil)
    end,

    ["the delivery's hold and come-home signals carry its slot"] = function(assert_eq)
        local base, sent = fresh()
        local proto = require("protocol")
        base.atc.signalSupport(proto.MSG.ASCENDING, "node_93", 11)
        local body = sent[#sent] or ""
        assert_eq(body:find("ASCENDING", 1, true) ~= nil, true, "the signal went out (" .. body:sub(1, 80) .. ")")
        assert_eq(body:find("slot = 11", 1, true) ~= nil, true, "with the slot in it")
    end,

    -- The shakeout's per-bay 150 sim (w3_bay_types150, 2026-11-11): a delivery gave up waiting for its support and
    -- went down alone; the support went down after it anyway, ended at "Delivery ascending - holding position" and
    -- held the dispatch hole (DH) for the rest of the run. A support whose delivery has left must stand down.
    ["a support told its delivery has left gives up waiting to be let in"] = function(assert_eq)
        local c = stub.install({ pos = { x = 158, y = 67, z = -2806, facing = 0 } })
        gps = { locate = function() return c.pos.x, c.pos.y, c.pos.z end }
        package.loaded["turtle_base"] = nil
        package.loaded["geofence"] = nil
        local base = require("turtle_base")
        local proto = require("protocol")
        sleep = function() end
        base.initPositionForTest()
        base.setPartnerId("node_37")
        local asked = 0
        base.atc.ensure = function() return true end
        base.atc.ask = function()
            asked = asked + 1
            if asked > 50 then error("never gave up", 0) end
            if asked == 3 then
                os.queueEvent("modem_message", "top", 1, 1,
                    proto.encode(proto.MSG.PARTNER_LEFT, "node_37", "broadcast", {}), 5)
                base.receive(1)
            end
            return { ok = false, why = "after an older request" }
        end
        local ok, why = base.atc.book({ { x = 158, y = 67, z = -2811 }, { x = 143, y = 67, z = -2811 } }, "departure",
            function() return base.partnerLeft() and "partner_left" end)
        assert_eq(ok, false, "it gave up once its delivery said it had left")
        assert_eq(tostring(why):find("partner_left", 1, true) ~= nil, true, tostring(why))
        assert_eq(asked <= 4, true, "and promptly (" .. asked .. " asks)")
        base.setPartnerId("node_9")
        assert_eq(base.partnerLeft(), false, "a new partner starts with a clean slate")
    end,

    ["a word from some other turtle that it left does not stand a support down"] = function(assert_eq)
        local base = fresh()
        local proto = require("protocol")
        base.setPartnerId("node_37")
        os.queueEvent("modem_message", "top", 1, 1, proto.encode(proto.MSG.PARTNER_LEFT, "node_77", "broadcast", {}), 5)
        base.receive(1)
        assert_eq(base.partnerLeft(), false)
    end,

    ["a stall under the bound reports nothing"] = function(assert_eq)
        local base = fresh()
        local proto = require("protocol")
        base.setStatus(proto.STATUS.IDLE)
        base.atc.stallAt = os.clock() - 10
        base.atc.stalled("a short wait")
        assert_eq(base.statusForTest(), proto.STATUS.IDLE)
    end,
}
