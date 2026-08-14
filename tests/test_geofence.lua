local function fresh()
    package.loaded["geofence"] = nil
    return require("geofence")
end

return {
    ["inactive fence permits everything"] = function(assert_eq)
        local g = fresh()
        assert_eq(g.isActive(), false)
        assert_eq(g.contains(99999, -99999), true)
    end,

    ["anchor confines movement to the chunk block"] = function(assert_eq)
        local g = fresh()
        g.setAnchorChunk(0, 0, 1)          -- chunks -1..1 => blocks -16..31
        assert_eq(g.isActive(), true)
        assert_eq(g.contains(0, 0), true)
        assert_eq(g.contains(-16, -16), true, "far corner of chunk -1")
        assert_eq(g.contains(31, 31), true, "far corner of chunk 1")
        assert_eq(g.contains(-17, 0), false, "chunk -2 is outside")
        assert_eq(g.contains(32, 0), false, "chunk 2 is outside")
        assert_eq(g.contains(0, 32), false)
    end,

    ["the fence is grid-aligned, not centred on the anchor block"] = function(assert_eq)
        -- The bug this whole redesign exists to prevent: a loader placed at the
        -- high edge of its chunk loads the SAME chunks as one at the low edge.
        local g = fresh()
        g.setAnchorBlock(15, 15, 1)        -- block 15,15 is still chunk 0,0
        assert_eq(g.contains(31, 31), true)
        assert_eq(g.contains(32, 32), false,
            "a block-radius fence would wrongly allow this")
        assert_eq(g.contains(-16, -16), true,
            "a block-radius fence would wrongly forbid this")
    end,

    ["a sector's 33x33 work area fits a radius-1 fence exactly"] = function(assert_eq)
        -- SECTOR_STEP=32, SCAN_RADIUS=16 => centre c, area [c-16, c+16].
        -- Sector centres are multiples of 32, so they land on chunk boundaries.
        local g = fresh()
        g.setAnchorBlock(0, 0, 1)          -- loader in the sector's anchor chunk
        assert_eq(g.contains(-16, -16), true, "sector min corner")
        assert_eq(g.contains(16, 16), true,  "sector max corner")
    end,

    ["check reports the reason on breach"] = function(assert_eq)
        local g = fresh()
        g.setAnchorChunk(0, 0, 1)
        local ok, reason = g.check(400, 0)
        assert_eq(ok, false)
        assert_eq(reason, "geofence_breach")
    end,

    ["clear releases the fence"] = function(assert_eq)
        local g = fresh()
        g.setAnchorChunk(0, 0, 1)
        g.clear()
        assert_eq(g.isActive(), false)
        assert_eq(g.contains(9999, 9999), true)
    end,

    ["chunkOf floors to 16-block chunks including negatives"] = function(assert_eq)
        local g = fresh()
        local cx, cz = g.chunkOf(0, 0)
        assert_eq(cx, 0); assert_eq(cz, 0)
        cx, cz = g.chunkOf(15, 15)
        assert_eq(cx, 0); assert_eq(cz, 0)
        cx, cz = g.chunkOf(16, -1)
        assert_eq(cx, 1); assert_eq(cz, -1)
        cx, cz = g.chunkOf(-1, -17)
        assert_eq(cx, -1); assert_eq(cz, -2)
    end,

    ["anchor() returns the current anchor with its chunkRadius"] = function(assert_eq)
        local g = fresh()
        assert_eq(g.anchor(), nil)
        g.setAnchorChunk(3, -4, 1)
        local a = g.anchor()
        assert_eq(a.cx, 3)
        assert_eq(a.cz, -4)
        assert_eq(a.chunkRadius, 1)
    end,

    ["negative anchor chunk still honours grid alignment, not block-centred radius"] = function(assert_eq)
        -- Anchor chunk -1,-1 => blocks -16..-1. Fence covers chunks -2..0 => blocks -32..15.
        local g = fresh()
        g.setAnchorBlock(-1, -1, 1)
        local acx, acz = g.chunkOf(-1, -1)
        assert_eq(acx, -1); assert_eq(acz, -1)
        assert_eq(g.contains(-32, -32), true, "low edge of allowed chunk range")
        assert_eq(g.contains(15, 15), true, "high edge of allowed chunk range")
        assert_eq(g.contains(-33, -1), false, "one block past the low edge")
        assert_eq(g.contains(16, -1), false, "one block past the high edge")
    end,

    ["a loader at the low edge of its chunk loads the same footprint as the high edge"] = function(assert_eq)
        -- This is the exact defect a block-radius fence has: a loader at block
        -- (0,0) (low edge of chunk 0,0) and one at (15,15) (high edge of the
        -- same chunk) must produce IDENTICAL fences, because both occupy the
        -- same chunk.
        local gLow = fresh()
        gLow.setAnchorBlock(0, 0, 1)
        local gHigh = fresh()
        gHigh.setAnchorBlock(15, 15, 1)

        local probes = { {-16,-16}, {31,31}, {-17,0}, {32,0}, {0,-17}, {0,32} }
        for _, p in ipairs(probes) do
            assert_eq(gLow.contains(p[1], p[2]), gHigh.contains(p[1], p[2]),
                string.format("low-edge and high-edge anchors disagree at %d,%d", p[1], p[2]))
        end
    end,
}
