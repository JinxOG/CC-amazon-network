-- The ore ender chest's own place/recover record.
--
-- node_181, 2026-10-08: DUMPING at 22:48:33, a reboot at 22:52 left the chest
-- placed in the world near 2048,16,-3392, slot 16 empty at boot, and the miner
-- benched until the user handed it a new chest. Nothing on disk said a chest was
-- out there, so nothing could go back for it.
--
-- Same contract as loader_state and for the same reason: written BEFORE the
-- place and cleared only once the chest is confirmed back aboard, so a crash at
-- any instant errs toward "we may have one out there".
package.path = "./?.lua;" .. package.path

local stub = require("tests.stub_cc")
os.epoch = os.epoch or function() return os.time() * 1000 end

local function fresh()
    stub.install({})
    package.loaded["chest_state"] = nil
    return require("chest_state")
end

return {
    ["nothing recorded on a clean start"] = function(assert_eq)
        local cs = fresh()
        assert_eq(cs.hasPlaced(), false)
        assert_eq(cs.get(), nil)
    end,

    ["a recorded chest survives a reboot"] = function(assert_eq)
        local cs = fresh()
        assert_eq(cs.record(2048, 16, -3392), true)
        package.loaded["chest_state"] = nil
        local cs2 = require("chest_state")
        local r = cs2.get()
        assert_eq(r ~= nil, true, "the record must outlive the process")
        assert_eq(r.x, 2048); assert_eq(r.y, 16); assert_eq(r.z, -3392)
        assert_eq(cs2.hasPlaced(), true)
    end,

    ["clearing it means no chest is out there"] = function(assert_eq)
        local cs = fresh()
        cs.record(1, 2, 3)
        cs.clear()
        assert_eq(cs.hasPlaced(), false)
        package.loaded["chest_state"] = nil
        assert_eq(require("chest_state").hasPlaced(), false, "and it stays cleared")
    end,

    -- The caller MUST NOT place on a false return: without the record on disk a
    -- crash after placement strands the chest with nothing recording why, which
    -- is the whole failure this module exists to prevent.
    ["a record that cannot be written is reported, not assumed"] = function(assert_eq)
        local cs = fresh()
        local realOpen = fs.open
        fs.open = function(p, mode) if mode == "w" then return nil end return realOpen(p, mode) end
        local ok, why = cs.record(5, 6, 7)
        fs.open = realOpen
        assert_eq(ok, false, "a full disk must not read as a successful record")
        assert_eq(why, "chest_state_write_failed")
        assert_eq(cs.hasPlaced(), false,
            "and memory must not claim a placement we could not persist")
    end,

    ["a truncated file is treated as no chest, not a crash"] = function(assert_eq)
        local cs = fresh()
        local f = fs.open("chest_state.dat", "w"); f.write("{ x = 1, y ="); f.close()
        package.loaded["chest_state"] = nil
        assert_eq(require("chest_state").hasPlaced(), false,
            "a half-written file must not brick the miner on boot")
    end,
}
