local stub = require("tests.stub_cc")

local function fresh(equipped, inv, stubExtra)
    local opts = { equipped = equipped, inv = inv }
    for k, v in pairs(stubExtra or {}) do opts[k] = v end
    stub.install(opts)
    package.loaded["equipment"] = nil
    return require("equipment")
end

-- Registry names, matching equipment.ITEMS verbatim (see equipment.lua).
-- The brief's own snippets use short kinds ("modem", "chunky", "pickaxe");
-- those don't exist in the world and must be converted here, since the
-- stub's `equipped`/inventory tables are keyed by registry name only.
local PICKAXE = "minecraft:diamond_pickaxe"
local CHUNKY  = "advancedperipherals:chunk_controller"
local MODEM   = "computercraft:wireless_modem_advanced"

-- Functions, not shared table literals: stub_cc stores whatever table is
-- passed as opts.equipped and mutates it in place on every equip/unequip
-- (c.equipped[side] = ...). A single shared E_TRAVEL/E_MINE table reused
-- across tests gets permanently corrupted by the first test that swaps
-- anything, silently poisoning every later test that reuses the same
-- constant -- and since pairs() iteration order over the suite table is
-- unspecified, that shows up as order-dependent flakiness rather than a
-- deterministic failure. Each call must build a fresh table.
local function E_TRAVEL() return { left = MODEM, right = CHUNKY } end
local function E_MINE()   return { left = MODEM, right = PICKAXE } end

local function fullInv(extra)
    local inv = {
        [1]  = { name = "advancedperipherals:geo_scanner", count = 1 },
        [2]  = { name = "computercraft:turtle_advanced",  count = 1 },
        [14] = { name = "minecraft:coal",                 count = 32 },
        [15] = { name = "enderstorage:ender_chest",       count = 1 },
        [16] = { name = "enderstorage:ender_chest",       count = 1 },
    }
    for k, v in pairs(extra or {}) do inv[k] = v end
    return inv
end

local LOADER = "computercraft:turtle_advanced"

-- The upgrade-derived displayName a turtle carrying chunky + ender modem reports.
-- Probed in-world 2026-08-22: a placed LOADER and a SUPPORT turtle both read
-- exactly this, which is the entire reason the prefix has to come from a real
-- os.setComputerLabel rather than from this string.
local CHUNKY_NAME = "Advanced Chunky Ender Turtle"

-- Swap in a loader_state whose hasPlaced() answers as the test needs. equipment
-- pcall-requires the module lazily, so seeding package.loaded is enough. Returns
-- a restore function; every test that calls this MUST call it, or the fake leaks
-- into later suites through the shared module table.
local function withLoaderState(placed)
    local saved = package.loaded["loader_state"]
    package.loaded["loader_state"] = { hasPlaced = function() return placed end }
    return function() package.loaded["loader_state"] = saved end
end

return {
    -- Every advanced turtle in the fleet is one item id, so before labelling is
    -- configured the name check is nearly all there is and must behave as it
    -- always did. This is the no-regression floor for the whole mechanism.
    ["an unconfigured prefix accepts any advanced turtle, as before"] =
    function(assert_eq)
        local eq = fresh(E_TRAVEL(), fullInv())
        assert_eq(eq.LOADER_PREFIX, nil, "the prefix must ship unconfigured")
        assert_eq(eq.isLoaderItem({ name = LOADER, displayName = CHUNKY_NAME }), true,
            "unconfigured, a chunky turtle still counts — old behaviour")
        assert_eq(eq.isLoaderItem({ name = "minecraft:cobblestone" }), false,
            "a non-turtle is never a loader")
    end,

    -- THE probe finding (W1, 2026-08-22). displayName is composed from equipment,
    -- not identity, so a support turtle -- modem + chunky permanently, which is
    -- its entire job -- reads byte-identical to a loader. Setting that string as
    -- the expected value would make isLoaderItem accept half the fleet as chunk
    -- loaders. This test exists to stop anyone ever trying it.
    ["the default chunky name must never be usable as the prefix"] =
    function(assert_eq)
        local eq = fresh(E_TRAVEL(), fullInv())
        eq.LOADER_PREFIX = CHUNKY_NAME              -- the tempting mistake
        local support = eq.isLoaderItem({ name = LOADER, displayName = CHUNKY_NAME })
        eq.LOADER_PREFIX = nil
        assert_eq(support, true,
            "documents the trap: a support turtle passes, which is why a real "
            .. "os.setComputerLabel prefix is required instead of this string")
    end,

    -- Prefix, not equality: the label doubles as proto.selfId(), so each loader
    -- needs its own. Labelling all three "LOADER" would collapse them into one
    -- registry entry.
    ["a configured prefix accepts differently-labelled loaders and rejects the rest"] =
    function(assert_eq)
        local eq = fresh(E_TRAVEL(), fullInv())
        eq.LOADER_PREFIX = "LOADER-"
        local l160    = eq.isLoaderItem({ name = LOADER, displayName = "LOADER-160" })
        local l161    = eq.isLoaderItem({ name = LOADER, displayName = "LOADER-161" })
        local support = eq.isLoaderItem({ name = LOADER, displayName = CHUNKY_NAME })
        local miner   = eq.isLoaderItem({ name = LOADER, displayName = "node_119" })
        eq.LOADER_PREFIX = nil
        assert_eq(l160, true, "LOADER-160 must be recognised")
        assert_eq(l161, true, "LOADER-161 must be recognised too — hence a prefix")
        assert_eq(support, false, "an unlabelled support turtle must not pass")
        assert_eq(miner, false, "a labelled fleet turtle must not pass")
    end,

    -- #"" is 0, so a bare "" prefix would match every string and silently accept
    -- everything -- the failure would look exactly like working code.
    ["an empty prefix is treated as unconfigured, not as matching everything"] =
    function(assert_eq)
        local eq = fresh(E_TRAVEL(), fullInv())
        eq.LOADER_PREFIX = ""
        local labelled = eq.loaderLabelled()
        eq.LOADER_PREFIX = nil
        assert_eq(labelled, false, "an empty prefix must not count as configured")
    end,

    -- The one exclusion available with no operator action at all. Because the
    -- name reports equipment, a turtle reading as a mining turtle is provably not
    -- a loader -- loaders carry chunky and nothing else. This is what would have
    -- caught the observed case: node_119 was in mine phase when it was dug.
    ["a turtle visibly holding a digging tool is never a loader"] =
    function(assert_eq)
        local eq = fresh(E_TRAVEL(), fullInv())
        assert_eq(eq.LOADER_PREFIX, nil, "precondition: unconfigured")
        assert_eq(eq.isLoaderItem({ name = LOADER, displayName = "Advanced Ender Mining Turtle" }),
            false, "the dug-up miner from the observed incident must be excluded")
        assert_eq(eq.isLoaderItem({ name = LOADER, displayName = "Advanced Mining Turtle" }),
            false, "and the same turtle with no modem")
        assert_eq(eq.isLoaderItem({ name = LOADER, displayName = CHUNKY_NAME }), true,
            "a chunky turtle carries no digging tool and must still pass")
    end,

    -- findLoaderSlot is what placeLoader and validate consult. It must skip the
    -- corpse and keep looking rather than returning the first turtle it sees.
    ["findLoaderSlot skips a fleet turtle and finds the real loader deeper"] =
    function(assert_eq)
        local inv = fullInv()
        inv[2] = { name = LOADER, count = 1, displayName = "node_119" }   -- corpse in the loader slot
        inv[6] = { name = LOADER, count = 1, displayName = "LOADER-160" }
        local eq = fresh(E_TRAVEL(), inv)
        eq.LOADER_PREFIX = "LOADER-"
        local slot = eq.findLoaderSlot()
        eq.LOADER_PREFIX = nil
        assert_eq(slot, 6, "must skip the corpse in slot 2 and find the real loader in slot 6")
    end,

    -- The signal that needs no unverified API: the disk record says the loader is
    -- standing in the world, so the advanced turtle in the inventory is someone
    -- else's. This is what closes the observed case before any labelling exists.
    ["a turtle carried while the record says placed is reported as foreign"] =
    function(assert_eq)
        local restore = withLoaderState(true)
        local eq = fresh(E_TRAVEL(), fullInv())      -- slot 2 holds an advanced turtle
        local slot = eq.findLoaderSlot()
        local foreign = eq.foreignTurtleSlot()
        restore()
        assert_eq(slot, 2, "possession alone still finds it — that is the trap")
        assert_eq(foreign, 2, "but the placement record proves it is not ours")
    end,

    ["no placement record means no foreign turtle"] = function(assert_eq)
        local restore = withLoaderState(false)
        local eq = fresh(E_TRAVEL(), fullInv())
        local foreign = eq.foreignTurtleSlot()
        restore()
        assert_eq(foreign, nil, "carrying the loader with nothing placed is the normal case")
    end,

    -- Departing on a corpse is the Invariant A violation: the miner fences itself
    -- to a chunk on the assumption something is loading it, and may place the
    -- corpse as that loader.
    ["travel mode refuses to depart carrying a turtle that cannot be ours"] =
    function(assert_eq)
        local restore = withLoaderState(true)
        local eq = fresh(E_TRAVEL(), fullInv({ [3] = { name = PICKAXE, count = 1 } }))
        local ok, reason = eq.validate("travel")
        restore()
        assert_eq(ok, false, "must not validate for travel with a foreign turtle aboard")
        assert_eq(reason, "foreign_turtle_carried")
    end,

    ["travel mode validates when modem+chunky equipped and cargo present"] = function(assert_eq)
        local eq = fresh(E_TRAVEL(), fullInv({ [3] = { name = PICKAXE, count = 1 } }))
        local ok, reason = eq.validate("travel")
        assert_eq(ok, true, reason or "should validate")
    end,

    ["travel mode fails when the loader turtle is missing"] = function(assert_eq)
        local inv = fullInv({ [3] = { name = PICKAXE, count = 1 } })
        inv[2] = nil
        local eq = fresh(E_TRAVEL(), inv)
        local ok, reason = eq.validate("travel")
        assert_eq(ok, false)
        assert_eq(reason, "loader_turtle_missing")
    end,

    ["travel mode fails when chunky is not equipped"] = function(assert_eq)
        local eq = fresh(E_MINE(), fullInv({ [3] = { name = CHUNKY, count = 1 } }))
        local ok, reason = eq.validate("travel")
        assert_eq(ok, false)
        assert_eq(reason, "chunky_not_equipped")
    end,

    ["mine mode fails when an ender chest is missing"] = function(assert_eq)
        local inv = fullInv({ [3] = { name = CHUNKY, count = 1 } })
        inv[16] = nil
        local eq = fresh(E_MINE(), inv)
        local ok, reason = eq.validate("mine")
        assert_eq(ok, false)
        assert_eq(reason, "ore_ec_missing")
    end,

    ["toMineMode swaps chunky out for pickaxe"] = function(assert_eq)
        local eq = fresh(E_TRAVEL(), fullInv({ [3] = { name = PICKAXE, count = 1 } }))
        local ok, reason = eq.toMineMode()
        assert_eq(ok, true, reason)
        assert_eq(eq.sideOf("pickaxe") ~= nil, true, "pickaxe should be equipped")
        assert_eq(eq.sideOf("chunky"), nil, "chunky should be stowed")
        assert_eq(eq.sideOf("modem") ~= nil, true, "modem must stay equipped")
    end,

    ["toMineMode refuses when no pickaxe is carried"] = function(assert_eq)
        local eq = fresh(E_TRAVEL(), fullInv())
        local ok, reason = eq.toMineMode()
        assert_eq(ok, false)
        assert_eq(reason, "pickaxe_missing")
    end,

    ["retrieval keeps chunky and pickaxe on simultaneously"] = function(assert_eq)
        local eq = fresh(E_MINE(), fullInv({ [3] = { name = CHUNKY, count = 1 } }))
        local ok, reason = eq.retrievalSwapIn()
        assert_eq(ok, true, reason)
        assert_eq(eq.sideOf("chunky") ~= nil, true, "chunky must be on")
        assert_eq(eq.sideOf("pickaxe") ~= nil, true, "pickaxe must stay on")
        assert_eq(eq.sideOf("modem"), nil, "modem is the one sacrificed")
    end,

    ["retrievalSwapOut restores the modem and keeps chunky"] = function(assert_eq)
        local eq = fresh(E_MINE(), fullInv({ [3] = { name = CHUNKY, count = 1 } }))
        assert_eq(eq.retrievalSwapIn(), true)
        local ok, reason = eq.retrievalSwapOut()
        assert_eq(ok, true, reason)
        assert_eq(eq.sideOf("modem") ~= nil, true, "modem restored")
        assert_eq(eq.sideOf("chunky") ~= nil, true, "chunky retained")
        assert_eq(eq.sideOf("pickaxe"), nil, "pickaxe stowed")
    end,

    ["reconcile re-equips a modem left in inventory"] = function(assert_eq)
        local eq = fresh({ left = nil, right = CHUNKY },
                         fullInv({ [4] = { name = MODEM, count = 1 } }))
        local ok, reason = eq.reconcile()
        assert_eq(ok, true, reason)
        assert_eq(eq.sideOf("modem") ~= nil, true, "modem must be re-equipped")
        assert_eq(eq.sideOf("chunky") ~= nil, true, "chunky must be retained")
    end,

    ["reconcile prefers chunky over pickaxe when both are stowed"] = function(assert_eq)
        local eq = fresh({ left = MODEM, right = nil },
                         fullInv({ [3] = { name = PICKAXE, count = 1 },
                                   [5] = { name = CHUNKY,  count = 1 } }))
        local ok = eq.reconcile()
        assert_eq(ok, true)
        assert_eq(eq.sideOf("chunky") ~= nil, true,
            "chunk safety outranks digging when recovering")
    end,

    -- Forces the actual priority conflict: pickaxe occupies one side, and
    -- both chunky and modem are loose in inventory competing for the single
    -- side that starts empty. reconcile() must restore chunky first -- if it
    -- restored modem first instead, chunky would be left with no empty side
    -- and no fallback (only the modem path evicts the pickaxe), stranding
    -- chunk safety while comms came back. This is the case the two older
    -- reconcile tests never exercised: in both of those, one of chunky/modem
    -- was already correctly equipped, so block order never mattered.
    ["reconcile restores chunky before modem when both compete for the only free side"] = function(assert_eq)
        local eq = fresh({ left = PICKAXE, right = nil },
                         fullInv({ [3] = { name = CHUNKY, count = 1 },
                                   [4] = { name = MODEM,  count = 1 } }))
        local ok, reason = eq.reconcile()
        assert_eq(ok, true, reason)
        assert_eq(eq.sideOf("chunky") ~= nil, true,
            "chunk safety must win the race for the only empty side")
    end,

    -- Finding-1 regression: if the chunky swap() itself fails (not just "no
    -- slot available"), reconcile() must not paper over it by reporting
    -- success once the unrelated modem side checks out. Forces a real
    -- equip failure via the stub's equipFail hook, since a genuine chunky
    -- item can never fail the stub's item-validity check on its own.
    ["reconcile does not report success when the chunky swap itself fails"] = function(assert_eq)
        local eq = fresh({ left = MODEM, right = nil },
                         fullInv({ [3] = { name = CHUNKY, count = 1 } }),
                         { equipFail = { right = true } })
        local ok, reason = eq.reconcile()
        assert_eq(ok, false, "must not report success")
        assert_eq(reason, "chunky_unrecoverable")
        assert_eq(eq.sideOf("chunky"), nil,
            "chunk safety genuinely was not restored")
    end,

    -- Task 8a fix pass 3: the transition needed to reach retrieval mode
    -- (chunky+pickaxe) from chunky+modem -- the state reconcile() leaves
    -- behind after a reboot mid-retrieval with both sides full, since it
    -- displaces the pickaxe, not the modem, there. Without this, nothing
    -- could ever swap the modem back off to resume digging.
    ["toRetrieveMode swaps modem out for pickaxe, keeping chunky on"] = function(assert_eq)
        local eq = fresh({ left = MODEM, right = CHUNKY },
                         fullInv({ [3] = { name = PICKAXE, count = 1 } }))
        local ok, reason = eq.toRetrieveMode()
        assert_eq(ok, true, reason)
        assert_eq(eq.sideOf("pickaxe") ~= nil, true, "pickaxe should be equipped")
        assert_eq(eq.sideOf("modem"), nil, "modem should be stowed")
        assert_eq(eq.sideOf("chunky") ~= nil, true, "chunky must stay equipped throughout")
    end,

    ["toRetrieveMode refuses when no pickaxe is carried"] = function(assert_eq)
        local eq = fresh({ left = MODEM, right = CHUNKY }, fullInv())
        local ok, reason = eq.toRetrieveMode()
        assert_eq(ok, false)
        assert_eq(reason, "pickaxe_missing")
        assert_eq(eq.sideOf("modem") ~= nil, true, "must not touch equipment on refusal")
        assert_eq(eq.sideOf("chunky") ~= nil, true)
    end,

    ["toRetrieveMode refuses when modem is not equipped"] = function(assert_eq)
        local eq = fresh({ left = nil, right = CHUNKY },
                         fullInv({ [3] = { name = PICKAXE, count = 1 } }))
        local ok, reason = eq.toRetrieveMode()
        assert_eq(ok, false)
        assert_eq(reason, "modem_not_equipped")
    end,

    ["toRetrieveMode is a no-op success when pickaxe is already equipped"] = function(assert_eq)
        local eq = fresh(E_MINE(), fullInv({ [3] = { name = CHUNKY, count = 1 } }))
        -- Already modem+pickaxe (no chunky equipped at all here, but that's
        -- fine -- this only checks the "nothing to swap" early-return path).
        local ok = eq.toRetrieveMode()
        assert_eq(ok, true)
    end,

    -- Task 4: comms.init() in turtle_base.lua calls peripheral.find("modem")
    -- to decide whether to attempt recovery, and re-checks the same call to
    -- decide whether recovery worked -- not eq.sideOf("modem"), which every
    -- other reconcile test above asserts against. This exercises that exact
    -- API so a future change that keeps sideOf("modem") true but breaks
    -- peripheral.find("modem") (e.g. a stub/registry mismatch) is caught
    -- here even though it would slip past the sideOf-based assertions.
    ["reconcile recovers a stowed modem such that peripheral.find(\"modem\") sees it"] = function(assert_eq)
        local eq = fresh({ left = nil, right = CHUNKY },
                         fullInv({ [4] = { name = MODEM, count = 1 } }))
        assert_eq(peripheral.find("modem"), nil, "precondition: no modem equipped")
        local ok, reason = eq.reconcile()
        assert_eq(ok, true, reason)
        assert_eq(peripheral.find("modem") ~= nil, true, "modem now findable")
    end,
}
