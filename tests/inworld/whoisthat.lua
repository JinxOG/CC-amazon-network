-- whoisthat.lua — can a turtle read the COMPUTER ID off a turtle item?
--
-- If it can, identity stops being a labelling problem: the server already knows
-- every node's role, so a miner holding an unknown advanced turtle could simply
-- ask "what is node N?" and get an authoritative answer. No labels, no renaming,
-- no node-ID churn. Strictly better than matching a display-name prefix.
--
-- If it cannot, that whole approach is dead on arrival and the prefix stands.
--
-- The game clearly knows -- the tooltip reads "Computer ID: 119". The question is
-- whether getItemDetail exposes it, or only a hash of the NBT.
--
-- Run on any turtle holding at least one advanced turtle item. Output is kept
-- short deliberately: a CC terminal is ~19 lines and the verdict must not scroll
-- off, which is exactly what happened with the last probe.

local LOADER = "computercraft:turtle_advanced"

-- Anything whose key or value looks like it carries an identity.
local function interesting(k, v)
    local key = tostring(k):lower()
    return key:find("id") or key:find("computer") or key:find("label")
        or key:find("nbt") or type(v) == "table"
end

local slots, hit = {}, nil

for s = 1, 16 do
    local p = turtle.getItemDetail(s)
    if p and p.name == LOADER then slots[#slots + 1] = s end
end

if #slots == 0 then
    print("No advanced turtle in the inventory. Put one in and rerun.")
    return
end

for _, s in ipairs(slots) do
    local d = turtle.getItemDetail(s, true) or {}
    print(("-"):rep(46))
    print("slot " .. s .. "  " .. tostring(d.displayName or d.name))
    for k, v in pairs(d) do
        if interesting(k, v) then
            if type(v) == "table" then
                local n = 0
                for tk in pairs(v) do n = n + 1 end
                print("  " .. tostring(k) .. " = <table, " .. n .. " keys>")
                for tk, tv in pairs(v) do
                    print("     " .. tostring(tk) .. " = " .. tostring(tv))
                end
            else
                print("  " .. tostring(k) .. " = " .. tostring(v))
                if tostring(k):lower():find("id") then hit = tostring(k) end
            end
        end
    end
end

print(("="):rep(46))
if hit then
    print("VERDICT: an id-like field EXISTS -> " .. hit)
    print("  Ask the server what that node is. Labels not needed.")
else
    print("VERDICT: NO readable computer id.")
    print("  Only name/displayName/tags and an nbt HASH are exposed.")
    print("  A held turtle cannot be named, so the server cannot be")
    print("  asked about it. The display-name prefix stands.")
end
print(("="):rep(46))
