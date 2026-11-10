-- base.setResumeIntent / base.mayResumeHere -- THE DEFAULT, which is the part
-- that protects the roles I was not allowed to touch.
--
-- WHY THIS FILE EXISTS. The resume-after-restart card changed turtle_base, which
-- EVERY role loads, to let a role say "do not announce a recovery, I intend to
-- resume where I stand". The miner opts in. Delivery and support are frozen
-- files and were deliberately not changed, so their behaviour must be bit-for-bit
-- what it was -- and the only thing guaranteeing that is the default inside
-- mayResumeHere.
--
-- That is the exact accident a file freeze exists to prevent: changing a frozen
-- role's behaviour without editing its file, through a shared dependency.
--
-- NOT PREVIOUSLY UNCOVERED, which I should be accurate about: flipping the
-- default to true also reddens the existing integration test "a turtle rebooted
-- outside the base says it is recovering and recovers its ledger before it
-- moves", because that turtle would stop announcing. So the default had indirect
-- cover already. What it did not have was a test that says WHY it matters or
-- that pins the other three answers -- an integration test failing on a changed
-- recovery line does not tell the next reader that two frozen roles depend on
-- this, and it says nothing about a predicate that raises or returns 1.
--
-- WHAT IT PINS, all four answers, because "cannot answer" and "said no" must
-- both read as no and only a literal true may read as yes:
--   no intent installed  -> false   (delivery and support: the old flight home)
--   intent returns true  -> true    (the miner, after the card)
--   intent raises        -> false   (a broken role cannot strand itself afield)
--   intent returns truthy-but-not-true -> false (1, "yes" and a table are not
--                                        consent; v == true is deliberate)
local stub = require("tests.stub_cc")

sleep = function() end
os.epoch = os.epoch or function() return os.time() * 1000 end

-- A freshly loaded turtle_base, exactly as a role gets it before it has called
-- anything. Reloaded per test because the intent is module state: a leaked
-- predicate from one case would make the next one pass for the wrong reason.
local function freshBase()
    local c = stub.install({
        pos      = { x = 0, y = 60, z = 0, facing = 0 },
        equipped = { left = "minecraft:diamond_pickaxe" },
    })
    gps = { locate = function() return c.pos.x, c.pos.y, c.pos.z end }
    package.loaded["turtle_base"] = nil
    package.loaded["geofence"]    = nil
    return require("turtle_base"), c
end

return {
    -- THE ONE THAT MATTERS MOST: the state delivery_turtle and support_turtle are
    -- in, since neither calls setResumeIntent and neither may be edited.
    ["a role that never sets a resume intent may not resume (delivery and support)"] =
    function(assert_eq)
        local base = freshBase()
        assert_eq(type(base.setResumeIntent), "function",
            "the hook must exist, or this file is testing nothing")
        assert_eq(base.mayResumeHere(), false,
            "with no intent installed mayResumeHere must be false -- this is the "
            .. "only thing keeping the frozen delivery and support roles on their "
            .. "old flight home, and they cannot opt in because their files may "
            .. "not be edited")
    end,

    ["a role that installs an intent returning true may resume (the miner)"] =
    function(assert_eq)
        local base = freshBase()
        base.setResumeIntent(function() return true end)
        assert_eq(base.mayResumeHere(), true,
            "an explicit true is the only thing that earns a resume")
    end,

    ["an intent that returns false, nil or nothing may not resume"] =
    function(assert_eq)
        local base = freshBase()
        base.setResumeIntent(function() return false end)
        assert_eq(base.mayResumeHere(), false, "explicit false")
        base.setResumeIntent(function() return nil end)
        assert_eq(base.mayResumeHere(), false, "nil")
        base.setResumeIntent(function() end)
        assert_eq(base.mayResumeHere(), false, "no return value at all")
    end,

    -- A MINER WHOSE PREDICATE RAISES MUST FLY HOME, not stand in a field. The
    -- predicate reads loader_state off disk, so a corrupt or half-written record
    -- is a real way for it to throw, and the old behaviour is the safe direction.
    ["an intent that raises may not resume, and does not propagate"] =
    function(assert_eq)
        local base = freshBase()
        base.setResumeIntent(function() error("disk is gone", 0) end)
        local ok, v = pcall(base.mayResumeHere)
        assert_eq(ok, true,
            "mayResumeHere must swallow the error -- it is called from boot "
            .. "recovery, where raising would take the whole recovery with it")
        assert_eq(v, false, "and answer no, because 'cannot answer' is not consent")
    end,

    -- TRUTHY IS NOT TRUE. Lua treats 0, 1, "" and {} as true, so a predicate that
    -- returned a count or a record would silently enable the resume path. The
    -- implementation tests v == true on purpose and this pins that choice.
    ["an intent returning something merely truthy may not resume"] =
    function(assert_eq)
        local base = freshBase()
        for _, v in ipairs({ 1, 0, "yes", "true" }) do
            base.setResumeIntent(function() return v end)
            assert_eq(base.mayResumeHere(), false,
                "a " .. type(v) .. " (" .. tostring(v) .. ") is not consent")
        end
        base.setResumeIntent(function() return {} end)
        assert_eq(base.mayResumeHere(), false, "a table is not consent")
    end,

    -- And a role may withdraw it: boot recovery runs once per boot, but a role
    -- that finishes its job has no order left to resume and must not keep the
    -- permission it had while working.
    ["a resume intent can be withdrawn"] = function(assert_eq)
        local base = freshBase()
        base.setResumeIntent(function() return true end)
        assert_eq(base.mayResumeHere(), true, "installed")
        base.setResumeIntent(nil)
        assert_eq(base.mayResumeHere(), false, "withdrawn")
    end,
}
