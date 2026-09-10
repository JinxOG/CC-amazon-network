-- Every file a role requires must be a file that role is sent.
--
-- This exists because the failure it catches has already happened. On
-- 2026-08-27 an OTA shipped a central_server.lua that required cloudstore
-- before the deployment entry for cloudstore.lua existed, and the server did
-- not start at all -- "module 'cloudstore' not found" on boot. A missing
-- require does not degrade gracefully in CC: the computer refuses to run.
--
-- WHAT IT DOES NOT CATCH, stated because the sentence above invites the wrong
-- conclusion: central_server's cloudstore require is pcall'd TODAY, so this
-- test would not flag its removal now. It caught that class of failure when the
-- require was unprotected, and it catches it for every unprotected require in
-- the fleet -- but a pcall'd require that the role actually needs is invisible
-- here, because a pcall is the file saying it can live without it. If a module
-- is load-bearing, require it plainly and this test will guard it.
--
-- The check is cheap and the alternative is remembering. Adding a require to a
-- shared file is a one-line edit that looks harmless in review and bricks every
-- machine in a role on the next update, and the person who pays for it is the
-- operator, in the world, with a mining job running.
--
-- SOURCE-PARSING. updater.lua reads role.txt and starts downloading at load, so
-- it cannot be required here; its manifest is read as text. That makes this
-- weaker than a test that ran the real thing -- it is pinned to the shape of
-- those two tables -- but the property it guards has no other reachable seam,
-- and a parse failure is loud rather than silently green (see the explicit
-- count assertions below, which is what stops "found no roles" from passing).

package.path = "./?.lua;" .. package.path

local NL = string.char(10)

local function readFile(path)
    local f = assert(io.open(path, "r"), "cannot open " .. path)
    local s = f:read("*a")
    f:close()
    return s
end

-- Comments stripped before anything is matched. protocol.lua's header shows
-- `require("protocol")` as usage documentation, and a scanner that cannot tell
-- a comment from a line of code reports protocol.lua as depending on itself.
local function codeOnly(src)
    return (src:gsub("%-%-[^" .. NL .. "]*", ""))
end

-- ─── The manifest, as updater.lua states it ──────────────────────────────────

-- One manifest entry -> { src = "x.lua", dst = "y.lua" }. Plain strings ship
-- under their own name; the table form renames, and the DESTINATION name is
-- what a require has to resolve against on the target computer.
local function entriesIn(block)
    local out = {}
    for line in (block .. NL):gmatch("([^" .. NL .. "]*)" .. NL) do
        local src = line:match('src%s*=%s*"([%w_]+%.lua)"')
        if src then
            local dst = line:match('dst%s*=%s*"([%w_]+%.lua)"') or src
            out[#out + 1] = { src = src, dst = dst }
        else
            local plain = line:match('^%s*"([%w_]+%.lua)"%s*,')
            if plain then out[#out + 1] = { src = plain, dst = plain } end
        end
    end
    return out
end

local function manifest()
    local src = readFile("updater.lua")

    local commonBlock = src:match("local COMMON = {(.-)" .. NL .. "}")
    assert(commonBlock, "updater.lua's COMMON table moved or changed shape")
    local common = entriesIn(commonBlock)

    local rolesBlock = src:match("local ROLE_FILES = {(.-)" .. NL .. "}")
    assert(rolesBlock, "updater.lua's ROLE_FILES table moved or changed shape")

    local roles = {}
    for name, body in rolesBlock:gmatch("(%u+)%s*=%s*{(.-)" .. NL .. "%s*}") do
        local files = {}
        for _, e in ipairs(common)              do files[#files + 1] = e end
        for _, e in ipairs(entriesIn(body))     do files[#files + 1] = e end
        roles[name] = files
    end
    return roles, common
end

-- ─── What each file asks for ─────────────────────────────────────────────────

-- Hard requires only. A pcall'd require is a deliberate "this role may not have
-- it" -- turtle_base does exactly that for geofence and equipment, which
-- delivery and support turtles are never sent -- and treating those as missing
-- would make this test fail on correct code, which is how a check gets deleted.
local function hardRequires(path)
    local src = codeOnly(readFile(path))
    -- Blank out the optional form first, so its argument cannot be picked up by
    -- the general pattern below.
    src = src:gsub("pcall%s*%(%s*require%s*,%s*\"[%w_]+\"", "pcall(require")
    local out = {}
    for name in src:gmatch('require%s*%(%s*"([%w_]+)"') do out[#out + 1] = name end
    return out
end

local suite = {}

suite["every role is sent every module its own files require"] = function(assert_eq)
    local roles = manifest()

    local roleCount = 0
    for _ in pairs(roles) do roleCount = roleCount + 1 end
    -- A parse that silently found nothing would make this test pass for every
    -- possible manifest. DELIVERY, SUPPORT, MINER, LOADER, WAREHOUSE, SERVER,
    -- ADMIN.
    assert_eq(roleCount, 7,
        "expected seven roles in updater.lua's ROLE_FILES — a parse that finds "
        .. "none would make every assertion below vacuous")

    local checked = 0
    for role, files in pairs(roles) do
        local shipped = {}
        for _, e in ipairs(files) do shipped[e.dst] = true end

        for _, e in ipairs(files) do
            for _, req in ipairs(hardRequires(e.src)) do
                checked = checked + 1
                assert_eq(shipped[req .. ".lua"] or false, true, string.format(
                    "%s ships %s, which requires '%s', but %s.lua is not in that "
                    .. "role's manifest — on a real update that computer stops "
                    .. "booting entirely", role, e.src, req, req))
            end
        end
    end

    assert_eq(checked > 20, true,
        "expected the scan to find real requires across the fleet, got "
        .. checked .. " — a require pattern that matches nothing passes this "
        .. "test whatever the manifest says")
end

-- install.lua is the OTHER way a computer gets its files, and it has its own
-- copy of the same lists. A file added to one and not the other produces a
-- fleet that updates correctly and cannot be reinstalled -- which is only
-- discovered when someone replaces a turtle that got dug up.
suite["install.lua ships the same modules as updater.lua"] = function(assert_eq)
    local roles = manifest()
    local install = readFile("install.lua")

    -- install.lua's profile names are lower-case, and it has no SERVER-only
    -- stress_test equivalent; compare per role on the modules that matter --
    -- the ones something in that role actually requires.
    local profiles = {}
    for name, body in install:match("local PROFILES = {(.-)" .. NL .. "}")
                             :gmatch("(%a+)%s*=%s*{(.-)" .. NL .. "%s*}") do
        local set = {}
        for dst in body:gmatch('name%s*=%s*"([%w_]+%.lua)"') do set[dst] = true end
        profiles[name:upper()] = set
    end

    local n = 0
    for _ in pairs(profiles) do n = n + 1 end
    assert_eq(n, 7, "expected seven install profiles — got " .. n)

    local checked = 0
    for role, files in pairs(roles) do
        local set = profiles[role]
        assert_eq(set ~= nil, true, "install.lua has no profile for " .. role)
        for _, e in ipairs(files) do
            for _, req in ipairs(hardRequires(e.src)) do
                -- startup.lua renaming means install may hold the role's entry
                -- file under a different name; only shared MODULES are compared,
                -- which is exactly what a require resolves against.
                checked = checked + 1
                assert_eq(set[req .. ".lua"] or false, true, string.format(
                    "updater sends %s.lua to %s but install.lua's profile does "
                    .. "not — a fresh computer would install and never boot",
                    req, role))
            end
        end
    end
    assert_eq(checked > 20, true,
        "expected real requires to compare, got " .. checked)
end

-- The manifest above can only be self-consistent. It cannot make the program
-- that READS it be the current version -- and on 2026-09-10 that distinction
-- cost the whole fleet.
--
-- turtle_base.lua gained `require("logship")` in the same release that added
-- logship.lua to COMMON. Both tests above passed, because the manifest was
-- correct. But the updater doing the work on each turtle was the PREVIOUS
-- version, running from the PREVIOUS list: it shipped the new turtle_base and
-- the new updater.lua, rebooted, and fifteen turtles came up at a shell prompt
-- saying "module 'logship' not found".
--
-- The fix is that the updater notices it has replaced ITSELF and starts over
-- before it touches any role file. This test pins that ordering, which is the
-- entire property: doing the check after the role files have already landed
-- would be the same bug with more steps.
--
-- SOURCE-ORDERING, and weaker than the two above. updater.lua reads role.txt
-- and starts downloading at load, so its loop is not reachable here. What can
-- be pinned is the order, which is the thing at risk of being tidied back.
suite["the updater restarts when it has replaced its own file list (SOURCE-ORDERING, weaker)"] =
function(assert_eq)
    -- Comments stripped first. This file's own history: a source assertion in
    -- test_control_loop.lua matched a COMMENTED-OUT call and stayed green when
    -- the line was commented out. Every one of the anchors below appears in the
    -- prose of updater.lua as well as in its code.
    local src = codeOnly(readFile("updater.lua"))

    local capture  = src:find("local selfBefore = readSelf()", 1, true)
    local common   = src:find("for _, file in ipairs(COMMON) do", 1, true)
    local compare  = src:find("selfAfter ~= selfBefore", 1, true)
    local relaunch = src:find('shell.run("updater")', 1, true)
    local roleLoop = src:find("for _, entry in ipairs(ROLE_FILES[role]) do", 1, true)

    assert_eq(capture ~= nil, true, "the updater no longer reads its own file")
    assert_eq(common ~= nil, true, "the COMMON download loop moved or vanished")
    assert_eq(compare ~= nil, true, "the self-change comparison moved or vanished")
    assert_eq(relaunch ~= nil, true, "the relaunch moved or vanished")
    assert_eq(roleLoop ~= nil, true, "the role download loop moved or vanished")

    assert_eq(capture < common, true,
        "the updater must read its own bytes BEFORE downloading COMMON, or it "
        .. "compares the new file against itself and never notices the change")
    assert_eq(common < compare, true,
        "and compare AFTER, because updater.lua arrives as part of COMMON")
    assert_eq(compare < roleLoop, true,
        "and the comparison must come BEFORE the role files are downloaded. "
        .. "Checking afterwards ships the new turtle_base from the old list "
        .. "first, which is exactly the failure of 2026-09-10 with more steps")
    assert_eq(relaunch < roleLoop, true,
        "the relaunch must happen before any role file lands, for the same reason")
end

return suite
