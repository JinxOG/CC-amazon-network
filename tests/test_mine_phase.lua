-- Task 6: protocol additions for solo-miner phase reporting.
--
-- Covers: the MINE_PHASE message type and proto.PHASE constants exist with
-- the exact values Task 7 (server handler) and Task 8 (miner) will reference
-- by name; payloadMinePhase shapes its payload correctly; and the
-- payloadHeartbeat backward-compatibility guarantee -- a 4-argument call
-- must produce exactly today's payload (new fields nil, not present-but-
-- empty), and a 5-argument call must carry phase/chunk/commsGap through.

package.path = "./?.lua;" .. package.path

local function fresh()
    package.loaded["protocol"] = nil
    return require("protocol")
end

return {

    ["MSG.MINE_PHASE exists with the exact value used on the wire"] = function(assert_eq)
        local proto = fresh()
        assert_eq(proto.MSG.MINE_PHASE, "MINE_PHASE")
    end,

    ["proto.PHASE constants exist with the exact values later tasks match on"] = function(assert_eq)
        local proto = fresh()
        assert_eq(proto.PHASE.DEPARTING, "DEPARTING")
        assert_eq(proto.PHASE.TRAVELLING, "TRAVELLING")
        assert_eq(proto.PHASE.PLACING_LOADER, "PLACING_LOADER")
        assert_eq(proto.PHASE.SWAP_TO_PICKAXE, "SWAP_TO_PICKAXE")
        assert_eq(proto.PHASE.SCANNING, "SCANNING")
        assert_eq(proto.PHASE.MINING, "MINING")
        assert_eq(proto.PHASE.DUMPING, "DUMPING")
        assert_eq(proto.PHASE.SWAP_TO_CHUNKY, "SWAP_TO_CHUNKY")
        assert_eq(proto.PHASE.RETRIEVING, "RETRIEVING")
        assert_eq(proto.PHASE.RETURNING, "RETURNING")
        assert_eq(proto.PHASE.DOCKED, "DOCKED")
    end,

    ["payloadMinePhase carries jobId, phase, detail and a fresh timestamp"] = function(assert_eq)
        local proto = fresh()
        os.epoch = os.epoch or function() return os.time() * 1000 end
        local p = proto.payloadMinePhase("job_9", proto.PHASE.RETRIEVING, "digging loader up")
        assert_eq(p.jobId, "job_9")
        assert_eq(p.phase, "RETRIEVING")
        assert_eq(p.detail, "digging loader up")
        if type(p.ts) ~= "number" then
            error("payloadMinePhase: ts must be a number, got " .. type(p.ts))
        end
    end,

    ["payloadMinePhase tolerates a nil detail"] = function(assert_eq)
        local proto = fresh()
        os.epoch = os.epoch or function() return os.time() * 1000 end
        local p = proto.payloadMinePhase("job_9", proto.PHASE.SCANNING, nil)
        assert_eq(p.detail, nil)
    end,

    ["an encoded MINE_PHASE message round-trips through decode"] = function(assert_eq)
        -- proto.decode() rejects any msg.type not present in proto.MSG as
        -- "unknown message type" -- this pins that MINE_PHASE was actually
        -- added to that table, not just given a builder function.
        local proto = fresh()
        os.epoch = os.epoch or function() return os.time() * 1000 end
        local payload = proto.payloadMinePhase("job_1", proto.PHASE.MINING, nil)
        local msg = proto.encode(proto.MSG.MINE_PHASE, "miner_1", "server", payload)
        local ok, decoded = proto.decode(msg)
        assert_eq(ok, true)
        assert_eq(decoded.type, "MINE_PHASE")
        assert_eq(decoded.payload.phase, "MINING")
    end,

    -- ─── Heartbeat backward compatibility ───────────────────────────────────
    -- This is the guarantee every existing call site (delivery, support,
    -- android, warehouse) depends on: calling with the original 4 arguments
    -- must produce exactly the payload shape those roles have always sent,
    -- with phase/chunk/commsGap nil rather than present-but-empty. If a
    -- later edit ever made `extra` default to a non-nil-producing table
    -- (e.g. `extra = extra or {phase = "UNKNOWN"}`), this test must fail.

    ["4-argument payloadHeartbeat call is unchanged on the wire"] = function(assert_eq)
        local proto = fresh()
        local p = proto.payloadHeartbeat("WORKING", 500, { x = 1, y = 2, z = 3 }, "job_5")
        assert_eq(p.status, "WORKING")
        assert_eq(p.fuel, 500)
        assert_eq(p.position.x, 1)
        assert_eq(p.jobId, "job_5")
        assert_eq(p.version, proto.VERSION)
        assert_eq(p.phase, nil)
        assert_eq(p.chunk, nil)
        assert_eq(p.commsGap, nil)

        -- Field-count pin: nil-valued keys (phase/chunk/commsGap) do not
        -- appear in pairs() at all, so only the 5 populated base fields
        -- (status, fuel, position, jobId, version) show up here. Guards
        -- against `extra = extra or {}` being replaced with something that
        -- injects a truthy/non-nil placeholder for the new fields.
        local count = 0
        for _ in pairs(p) do count = count + 1 end
        assert_eq(count, 5)
    end,

    ["5-argument payloadHeartbeat call carries phase/chunk/commsGap through"] = function(assert_eq)
        local proto = fresh()
        local p = proto.payloadHeartbeat("WORKING", 500, { x = 1, y = 2, z = 3 }, "job_5", {
            phase = proto.PHASE.RETRIEVING,
            chunk = { cx = 4, cz = -2 },
            commsGap = true,
        })
        assert_eq(p.phase, "RETRIEVING")
        assert_eq(p.chunk.cx, 4)
        assert_eq(p.chunk.cz, -2)
        assert_eq(p.commsGap, true)
        -- Base fields untouched by the extension.
        assert_eq(p.status, "WORKING")
        assert_eq(p.fuel, 500)
        assert_eq(p.jobId, "job_5")
    end,

    ["5-argument call with an empty extra table behaves like the 4-argument call"] = function(assert_eq)
        local proto = fresh()
        local p = proto.payloadHeartbeat("IDLE", 100, nil, nil, {})
        assert_eq(p.phase, nil)
        assert_eq(p.chunk, nil)
        assert_eq(p.commsGap, nil)
    end,

}
