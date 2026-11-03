-- The updater strips comments and indentation from the Lua it writes to a
-- computer's disk (W3 disk card, part 4, the user's ruling 2026-11-02). The
-- default CC disk is 1,000,000 bytes and the server's own code took ~425 KB of
-- it (central_server.lua alone 351 KB), leaving state ~500 KB at most. The repo
-- copy stays readable. Every line break is KEPT, so a crash report's line
-- number still points at the repo's line.

package.path = "./?.lua;" .. package.path

-- The updater is a script; with this flag it hands back its minifier and stops.
local function minifier()
    _G.__UPDATER_MINIFY_ONLY = true
    local chunk = assert(loadfile("updater.lua"))
    local m = chunk()
    _G.__UPDATER_MINIFY_ONLY = nil
    return m
end

local function lines(s)
    local n = 1
    for _ in s:gmatch("\n") do n = n + 1 end
    return n
end

local function luaFiles()
    local out = {}
    local p = io.popen("git ls-files \"*.lua\"")
    for name in p:lines() do
        if not name:find("^sandbox/vendor/") then out[#out + 1] = name end
    end
    p:close()
    return out
end

local function read(path)
    local f = assert(io.open(path, "rb")); local s = f:read("*a"); f:close()
    return (s:gsub("\r\n", "\n"))
end

return {
    ["a line comment goes, its line stays"] = function(assert_eq)
        local m = minifier()
        local out = m("local a = 1 -- one\n-- a whole comment line\nlocal b = 2\n")
        assert_eq(out, "local a = 1\n\nlocal b = 2\n")
    end,

    ["a long comment goes, keeping its line breaks; inline it becomes a space"] = function(assert_eq)
        local m = minifier()
        assert_eq(m("x = 1 --[[ a\nb ]] y = 2\n"), "x = 1\ny = 2\n")
        assert_eq(m("x = a--[==[c]==]b\n"), "x = a b\n")
    end,

    ["indentation and trailing spaces go"] = function(assert_eq)
        local m = minifier()
        assert_eq(m("if x then\n    return 1   \nend\n"), "if x then\nreturn 1\nend\n")
    end,

    ["text inside quotes is untouched, even with -- in it"] = function(assert_eq)
        local m = minifier()
        local src = 'local s = "a -- b" .. \'c -- d\' .. "e\\"--f"\n'
        assert_eq(m(src), src)
    end,

    ["a long string is copied exactly, indentation and all"] = function(assert_eq)
        local m = minifier()
        local src = "local s = [[\n    -- not a comment\n    kept  ]] .. [==[ ]] ]==]\n"
        assert_eq(m(src), src)
    end,

    ["every Lua file in the repo still compiles and keeps its line count"] = function(assert_eq)
        local m = minifier()
        local bad = {}
        for _, name in ipairs(luaFiles()) do
            local src = read(name)
            local out = m(src)
            local ok, err = load(out, "=" .. name)
            if not ok and load(src, "=" .. name) then bad[#bad + 1] = name .. ": " .. tostring(err) end
            if lines(out) ~= lines(src) then bad[#bad + 1] = name .. ": " .. lines(src) .. " lines -> " .. lines(out) end
        end
        assert_eq(table.concat(bad, "; "), "")
    end,

    ["the server's code shrinks to under 200 KB"] = function(assert_eq)
        local m = minifier()
        local out = m(read("central_server.lua"))
        assert_eq(#out < 200000, true, "central_server.lua stripped: " .. #out .. " bytes")
    end,
}
