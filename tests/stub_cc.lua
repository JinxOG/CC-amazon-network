-- Minimal CC:Tweaked stand-ins so turtle modules can be loaded and driven
-- headlessly. Only models what the mining code actually touches; anything
-- unimplemented raises so gaps surface as test errors rather than silence.
--
-- Equipment is identified by registry name (e.g. "minecraft:diamond_pickaxe"),
-- not by peripheral type -- in-world probing found turtle.getEquippedLeft/
-- Right return the equipped item's detail table while peripheral.getType
-- returns nil for a pickaxe side, so that's what this stub mirrors.
local M = {}

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
        log      = {},
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
            c.world[ahead()] = nil
            local s = c.selected
            if c.inv[s] and c.inv[s].name == b then c.inv[s].count = c.inv[s].count + 1
            else
                s = c.inv[s] and firstEmpty() or s
                if s then c.inv[s] = { name = b, count = 1 } end
            end
            return true
        end,
        digDown = function()
            if c.equipped.left ~= "minecraft:diamond_pickaxe" and c.equipped.right ~= "minecraft:diamond_pickaxe" then
                return false, "No tool to dig with"
            end
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
            local src = c.inv[c.selected]
            if not src then return false end
            n = n or src.count
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
            local e = c.equipped[side]
            if e == "computercraft:wireless_modem_advanced" then return "modem" end
            return nil
        end,
        find = function(kind)
            for _, side in ipairs({ "left", "right" }) do
                if c.equipped[side] == kind then
                    return { transmit = function() end, open = function() end,
                             isOpen = function() return true end }
                end
            end
            return nil
        end,
        wrap = function() return nil end,
    }

    c.pos.facing = c.pos.facing or 0
    M._ctl = c
    return c
end

-- Swap the selected inventory slot with the upgrade on `side`, matching
-- CC:Tweaked semantics: empty slot unequips into it, occupied slot swaps.
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

return M
