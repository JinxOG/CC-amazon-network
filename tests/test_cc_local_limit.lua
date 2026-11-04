-- The local-variable limit as CC:Tweaked's Lua (Cobalt) applies it (W3, 2026-11-03).
--
-- Cobalt refuses to load a file in which, at any point, the locals alive in a
-- function PLUS the locals alive in every function enclosing it (a `local
-- function` counting its own name) exceed 200: "function at line N has more than
-- 200 local variables". Desktop Lua counts each function on its own, so a file
-- over Cobalt's limit compiles, runs and passes every other test here, and then
-- does not boot in the game. Measured on the test server (run w3-fence-flood-b):
-- one function with 199 locals loads, 200 does not; 150 in the main chunk plus a
-- local function holding 49 loads, 50 does not, used or not; locals in finished
-- blocks (do, if, elseif, while, for, repeat) are freed. central_server.lua's
-- server.run was at 197 on 1.9.158; db099c4 and e2f8049 took it to 203 and the
-- server stopped booting on the game, while the simulator ran it happily.
--
-- The counts come from luac's own listing (luac -l -l): each function's locals
-- with the pcs where they are alive, and the pc of each CLOSURE, which says what
-- the enclosing function had alive when it made the child. luac here is 5.4,
-- whose generic `for` keeps four hidden locals where Cobalt keeps three, so this
-- count can only come out higher than Cobalt's, never lower.
--
--   lua tests/test_cc_local_limit.lua file.lua ...   prints each file's worst point
local LIMIT = 200

local function listing(path)
    local p = assert(io.popen('luac -l -l -p "' .. path .. '" 2>&1', "r"))
    local out = p:read("*a")
    p:close()
    return out
end

local function parse(text)
    local funcs, root, cur, section = {}, nil, nil, nil
    for line in (text .. "\n"):gmatch("(.-)\r?\n") do
        local kind, fline, addr = line:match("^(%a+) <.*:(%d+),%d+> %(%d+ instructions? at (%x+)%)")
        if kind == "main" or kind == "function" then
            cur = { line = tonumber(fline), instrs = {}, closures = {}, ranges = {} }
            funcs[addr:upper()] = cur
            root = root or addr:upper()
            section = nil
        elseif cur then
            if line:match("^constants %(") then section = "constants"
            elseif line:match("^locals %(") then section = "locals"
            elseif line:match("^upvalues %(") then section = "upvalues"
            elseif section == "locals" then
                -- names such as "(for state)" hold spaces: the two pcs are the last fields
                local s, e = line:match("(%d+)%s+(%d+)%s*$")
                if s then cur.ranges[#cur.ranges + 1] = { tonumber(s), tonumber(e) } end
            elseif section == nil then
                local pc, src, op, rest = line:match("^%s*(%d+)%s+%[(%d+)%]%s+(%w+)%s*(.*)$")
                if pc then
                    pc = tonumber(pc)
                    cur.instrs[#cur.instrs + 1] = { pc = pc, line = tonumber(src) }
                    if op == "CLOSURE" then
                        local child = rest:match(";%s*(%x+)")
                        if child then cur.closures[#cur.closures + 1] = { pc = pc, addr = child:upper() } end
                    end
                end
            end
        end
    end
    return funcs, root
end

-- In the listing's own pc numbering a local is alive while start <= pc < end.
local function alive(f, pc)
    local n = 0
    for _, r in ipairs(f.ranges) do if r[1] <= pc and pc < r[2] then n = n + 1 end end
    return n
end

-- luac 5.4 starts a `local function`'s name after its CLOSURE; Cobalt declares it
-- before the body, as the 5.2 parser does. So a local starting at the next pc is
-- counted for the child too -- which also counts the x of `local x = function`,
-- one too many: the safe direction.
local function aliveForChild(f, pc)
    local n = alive(f, pc)
    for _, r in ipairs(f.ranges) do if r[1] == pc + 1 then n = n + 1 end end
    return n
end

-- The longest chain of alive locals anywhere in the file: count, line, the line
-- of the function it is in.
local function worst(path)
    local funcs, root = parse(listing(path))
    local best = { n = 0, line = 0, fline = 0 }
    local function walk(addr, outer)
        local f = funcs[addr]
        if not f then return end
        for _, ins in ipairs(f.instrs) do
            local n = outer + alive(f, ins.pc)
            if n > best.n then best = { n = n, line = ins.line, fline = f.line } end
        end
        for _, c in ipairs(f.closures) do walk(c.addr, outer + aliveForChild(f, c.pc)) end
    end
    if root then walk(root, 0) end
    return best
end

local function luacWorks()
    local p = io.popen("luac -v 2>&1", "r")
    local v = p and p:read("*a") or ""
    if p then p:close() end
    return v:find("Lua") ~= nil
end

local function probe(outer, inner, blocks)
    local t = {}
    for i = 1, outer do t[#t + 1] = "local o" .. i .. " = " .. i end
    t[#t + 1] = "local function f()"
    for i = 1, inner do t[#t + 1] = (blocks and "do local v%d = %d end" or "local v%d = %d"):format(i, i) end
    t[#t + 1] = "end"
    local path = os.tmpname()
    local h = assert(io.open(path, "w"))
    h:write(table.concat(t, "\n"))
    h:close()
    local n = worst(path).n
    os.remove(path)
    return n
end

-- The fleet's programs: every Lua file at the repository root.
local function fleetFiles()
    local p = io.popen(package.config:sub(1, 1) == "\\" and 'dir /b *.lua 2>nul' or 'ls *.lua 2>/dev/null', "r")
    local files = {}
    for name in p:read("*a"):gmatch("[^\r\n]+") do files[#files + 1] = name end
    p:close()
    table.sort(files)
    return files
end

if arg and arg[0] and arg[0]:find("test_cc_local_limit") and #arg > 0 then
    for _, path in ipairs(arg) do
        local w = worst(path)
        print(string.format("%s: %d of %d at line %d (function at line %d)%s", path, w.n, LIMIT, w.line, w.fline,
            w.n > LIMIT and "  OVER" or ""))
    end
    return
end

return {
    -- The checker must be able to fail: each case is what the game itself said.
    ["the local-limit count matches what the game loaded and refused"] = function(assert_eq)
        assert_eq(luacWorks(), true, "luac must be on the PATH for this check")
        local cases = {
            { 0, 199, false, true }, { 0, 200, false, false },
            { 150, 49, false, true }, { 150, 50, false, false },
            { 0, 260, true, true },
        }
        for _, c in ipairs(cases) do
            local n = probe(c[1], c[2], c[3])
            assert_eq(n <= LIMIT, c[4], string.format("%d outer + %d inner%s counted %d; the game %s it",
                c[1], c[2], c[3] and " in blocks" or "", n, c[4] and "loaded" or "refused"))
        end
    end,

    ["every fleet program loads under the game's local-variable limit"] = function(assert_eq)
        assert_eq(luacWorks(), true, "luac must be on the PATH for this check")
        local files = fleetFiles()
        assert_eq(#files > 10, true, "found the fleet's Lua files (" .. #files .. ")")
        for _, name in ipairs(files) do
            local w = worst(name)
            assert_eq(w.n <= LIMIT, true, string.format(
                "%s: %d locals alive at line %d (function at line %d) counting the functions around it; "
                .. "the game refuses to load above %d", name, w.n, w.line, w.fline, LIMIT))
        end
    end,
}
