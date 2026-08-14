-- Minimal CC:Tweaked stand-ins so turtle modules can be loaded and driven
-- headlessly. Only models what the mining code actually touches; anything
-- unimplemented raises so gaps surface as test errors rather than silence.
--
-- Equipment is identified by registry name (e.g. "minecraft:diamond_pickaxe"),
-- not by peripheral type -- in-world probing found turtle.getEquippedLeft/
-- Right return the equipped item's detail table while peripheral.getType
-- returns nil for a pickaxe side, so that's what this stub mirrors.
local M = {}

-- The only equipped upgrade that shows up as a peripheral type at all;
-- pickaxe and chunk controller sides report nil from getType in-world, and
-- find() must agree with that or callers probing by type get a false miss.
local PERIPHERAL_TYPE_BY_NAME = {
    ["computercraft:wireless_modem_advanced"] = "modem",
}

function M.install(opts)
    opts = opts or {}
    local c = {
        inv      = opts.inv or {},
        equipped = opts.equipped or { left = nil, right = nil },
        pos      = opts.pos or { x = 0, y = 64, z = 0, facing = 0 },
        world    = opts.world or {},        -- "x,y,z" -> block name
        events   = opts.events or {},       -- queue of {name, ...}
        selected = 1,
        fuel     = opts.fuel or 100000,
    }
    -- facing lives only on c.pos; c.facing would drift out of sync with it
    -- the moment either got written independently, so there's one owner.

    local function key(x, y, z) return x .. "," .. y .. "," .. z end
    local function below() return key(c.pos.x, c.pos.y - 1, c.pos.z) end
    local function ahead()
        local dx, dz = 0, 0
        if     c.pos.facing == 0 then dz = -1
        elseif c.pos.facing == 1 then dx =  1
        elseif c.pos.facing == 2 then dz =  1
        else                          dx = -1 end
        return key(c.pos.x + dx, c.pos.y, c.pos.z + dz)
    end

    local function firstEmpty()
        for s = 1, 16 do if not c.inv[s] then return s end end
        return nil
    end

    -- Mirrors real CC:Tweaked dig semantics: scan every slot for a
    -- same-item stack with room before falling back to an empty slot, and
    -- cap stacks at 64 rather than growing them unbounded. Returns false
    -- (rather than mutating anything) when no slot can take the item, so
    -- callers can decide not to destroy the block.
    local function collectDug(name)
        for s = 1, 16 do
            local i = c.inv[s]
            if i and i.name == name and i.count < 64 then
                i.count = i.count + 1
                return true
            end
        end
        local s = firstEmpty()
        if s then
            c.inv[s] = { name = name, count = 1 }
            return true
        end
        return false
    end

    turtle = {
        select        = function(s) c.selected = s; return true end,
        getSelectedSlot = function() return c.selected end,
        getItemCount  = function(s) local i = c.inv[s or c.selected]; return i and i.count or 0 end,
        getItemDetail = function(s) return c.inv[s or c.selected] end,
        getItemSpace  = function(s) local i = c.inv[s or c.selected]; return 64 - (i and i.count or 0) end,
        getFuelLevel  = function() return c.fuel end,
        getFuelLimit  = function() return 100000 end,
        refuel        = function() return true end,

        detect     = function() return c.world[ahead()] ~= nil end,
        detectDown = function() return c.world[below()] ~= nil end,
        inspect    = function()
            local b = c.world[ahead()]
            if b then return true, { name = b, tags = {} } end
            return false
        end,
        inspectDown = function()
            local b = c.world[below()]
            if b then return true, { name = b, tags = {} } end
            return false
        end,

        place = function()
            local i = c.inv[c.selected]
            if not i then return false, "Nothing to place" end
            if c.world[ahead()] then return false, "Cannot place block here" end
            c.world[ahead()] = i.name
            i.count = i.count - 1
            if i.count <= 0 then c.inv[c.selected] = nil end
            return true
        end,
        dig = function()
            if c.equipped.left ~= "minecraft:diamond_pickaxe" and c.equipped.right ~= "minecraft:diamond_pickaxe" then
                return false, "No tool to dig with"
            end
            local b = c.world[ahead()]
            if not b then return false, "Nothing to dig here" end
            if not collectDug(b) then return false, "No space for item" end
            c.world[ahead()] = nil
            return true
        end,
        digDown = function()
            if c.equipped.left ~= "minecraft:diamond_pickaxe" and c.equipped.right ~= "minecraft:diamond_pickaxe" then
                return false, "No tool to dig with"
            end
            -- Miner descends by digging down, so this is real ore collection
            -- in practice -- must route through the same collectDug path as
            -- dig(), including its full-inventory failure, not just clear
            -- the block.
            local b = c.world[below()]
            if not b then return false, "Nothing to dig here" end
            if not collectDug(b) then return false, "No space for item" end
            c.world[below()] = nil
            return true
        end,

        equipLeft  = function() return M._equip(c, "left")  end,
        equipRight = function() return M._equip(c, "right") end,
        getEquippedLeft  = function() return M._equippedDetail(c, "left")  end,
        getEquippedRight = function() return M._equippedDetail(c, "right") end,

        forward = function() return M._move(c, "forward") end,
        back    = function() return M._move(c, "back")    end,
        up      = function() return M._move(c, "up")      end,
        down    = function() return M._move(c, "down")    end,
        turnLeft  = function() c.pos.facing = (c.pos.facing - 1) % 4; return true end,
        turnRight = function() c.pos.facing = (c.pos.facing + 1) % 4; return true end,

        transferTo = function(dest, n)
            -- Transferring a slot into itself must be a no-op: the merge
            -- logic below reads the old count, replaces the slot with a
            -- new table, then nils the slot out once the (orphaned) old
            -- table's count hits zero -- net effect was wiping the slot.
            if dest == c.selected then return true end
            local src = c.inv[c.selected]
            if not src then return false end
            n = n or src.count
            -- n = n or src.count treats an explicit 0 as truthy (0 is not
            -- falsy in Lua), so without this guard the merge below still
            -- ran and wrote a { count = 0 } phantom entry into an empty
            -- dest slot. Real CC leaves the slot nil.
            if n <= 0 then return true end
            local d = c.inv[dest]
            if d and d.name ~= src.name then return false end
            c.inv[dest] = { name = src.name, count = (d and d.count or 0) + n }
            src.count = src.count - n
            if src.count <= 0 then c.inv[c.selected] = nil end
            return true
        end,
        dropDown = function() c.inv[c.selected] = nil; return true end,
        drop     = function() c.inv[c.selected] = nil; return true end,
        suckDown = function() return false end,
    }

    peripheral = {
        -- Only the modem registers as a peripheral type; the pickaxe and
        -- chunk controller are turtle upgrades that getType can't see, which
        -- is what in-world probing showed for this CC:Tweaked version.
        getType = function(side)
            return PERIPHERAL_TYPE_BY_NAME[c.equipped[side]]
        end,
        find = function(kind)
            -- Must resolve through the same name->type table as getType:
            -- equipped now stores registry names, and comparing those
            -- directly against a peripheral type (the old behaviour) made
            -- find("modem") silently return nil with a modem equipped.
            for _, side in ipairs({ "left", "right" }) do
                if PERIPHERAL_TYPE_BY_NAME[c.equipped[side]] == kind then
                    return { transmit = function() end, open = function() end,
                             isOpen = function() return true end }
                end
            end
            return nil
        end,
        wrap = function() return nil end,
    }

    -- os already exists as a real Lua table (os.exit, os.time, ...); add
    -- the CC-specific pieces rather than replacing it, so run.lua's own
    -- os.exit call still works after install() runs.
    os.pullEvent = function(filter)
        while true do
            local ev = table.remove(c.events, 1)
            if not ev then
                error("stub_cc: no more queued events (os.pullEvent)", 2)
            end
            -- Real CC discards events that don't match the filter rather
            -- than requeuing them, so a non-match just continues the loop.
            if not filter or ev[1] == filter then
                return table.unpack(ev)
            end
        end
    end

    textutils = {
        serialise = function(t) return M._serialise(t) end,
        unserialise = function(s) return M._unserialise(s) end,
    }

    c.pos.facing = c.pos.facing or 0
    return c
end

-- Swap the selected inventory slot with the upgrade on `side`, matching
-- CC:Tweaked semantics: empty slot unequips into it, occupied slot swaps.
-- NOTE: equipping from a stack of count > 1 discards the remainder (only
-- one item becomes the equipped upgrade) -- unmodelled here because every
-- upgrade in this system is only ever held as count 1, so the gap never
-- gets exercised.
function M._equip(c, side)
    local item = c.inv[c.selected]
    local cur  = c.equipped[side]
    local UPGRADES = {
        ["minecraft:diamond_pickaxe"] = true,
        ["computercraft:wireless_modem_advanced"] = true,
        ["advancedperipherals:chunk_controller"] = true,
    }

    if item and not UPGRADES[item.name] then
        return false, "Not a valid upgrade"
    end
    c.equipped[side] = item and item.name or nil
    c.inv[c.selected] = cur and { name = cur, count = 1 } or nil
    return true
end

-- getEquippedLeft/Right report the equipped item's detail table, matching
-- in-world behaviour on sides peripheral.getType can't identify.
function M._equippedDetail(c, side)
    local name = c.equipped[side]
    if not name then return nil end
    return { name = name, count = 1 }
end

function M._move(c, dir)
    if dir == "up"   then c.pos.y = c.pos.y + 1; return true end
    if dir == "down" then c.pos.y = c.pos.y - 1; return true end
    local dx, dz = 0, 0
    if     c.pos.facing == 0 then dz = -1
    elseif c.pos.facing == 1 then dx =  1
    elseif c.pos.facing == 2 then dz =  1
    else                          dx = -1 end
    if dir == "back" then dx, dz = -dx, -dz end
    c.pos.x = c.pos.x + dx
    c.pos.z = c.pos.z + dz
    return true
end

-- Real textutils.serialise/unserialise round-trip Lua values through a
-- Lua-literal string. Only the plain-table/string/number/boolean subset
-- the mining code needs is supported.
function M._serialise(t)
    local ty = type(t)
    if ty == "string" then return string.format("%q", t) end
    if ty == "number" or ty == "boolean" then return tostring(t) end
    if ty == "nil" then return "nil" end
    if ty == "table" then
        local parts = {}
        for k, v in pairs(t) do
            local key
            if type(k) == "number" then
                key = "[" .. k .. "]"
            elseif type(k) == "string" and k:match("^[%a_][%w_]*$") then
                key = k
            else
                key = "[" .. M._serialise(k) .. "]"
            end
            table.insert(parts, key .. " = " .. M._serialise(v))
        end
        return "{" .. table.concat(parts, ", ") .. "}"
    end
    error("Cannot serialise type " .. ty, 0)
end

-- Matches real CC:Tweaked's implementation exactly, including the empty
-- environment table as load()'s 4th argument -- that's what stops loaded
-- input from reaching globals. Deliberately not stricter than this: real
-- CC:Tweaked's unserialise("1+1") returns 2 (load-and-call has no notion
-- of "is this a literal"), so this stub must return 2 there too rather
-- than rejecting non-literal-but-valid input as an invented safeguard.
function M._unserialise(s)
    local func = load("return " .. s, "unserialise", "t", {})
    if func then
        local ok, result = pcall(func)
        if ok then return result end
    end
    return nil
end

return M
