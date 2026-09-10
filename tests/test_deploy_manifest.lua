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

return suite
