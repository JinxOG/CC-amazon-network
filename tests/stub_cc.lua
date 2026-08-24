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

-- Fuel values per item, matching CC:Tweaked. Only consulted when a stub is
-- installed with fuel realism on, which is the default.
local FUEL_PER_ITEM = {
    ["minecraft:coal"]       = 80,
    ["minecraft:charcoal"]   = 80,
    ["minecraft:coal_block"] = 800,
}

function M.install(opts)
    opts = opts or {}
    local c = {
        inv      = opts.inv or {},
        equipped = opts.equipped or { left = nil, right = nil },
        pos      = opts.pos or { x = 0, y = 64, z = 0, facing = 0 },
        world    = opts.world or {},        -- "x,y,z" -> block name
        -- Items dropped with no inventory in the target block: gone in-world,
        -- recorded here so a test can assert nothing was scattered.
        dropped  = {},
        events   = opts.events or {},       -- queue of {name, ...}
        selected = 1,
        fuel     = opts.fuel or 100000,
        -- peripheral.call bookkeeping: every call is recorded here so a test
        -- can assert the miner powers on the loader it just placed, and
        -- peripheralCallFails forces the call to throw so the caller's
        -- failure handling is exercisable.
        peripheralCalls    = {},
        placedTurtleOn     = false,
        peripheralCallFails = opts.peripheralCallFails or false,
        -- Forces equipLeft/equipRight to fail on the given side regardless
        -- of what's selected, e.g. { right = true }. Added for equipment.lua
        -- reconcile() coverage: M._equip's only real failure path is "item
        -- isn't a valid upgrade", which a genuine chunky/modem/pickaxe item
        -- never hits, so there was no way to exercise a caller's handling of
        -- a *failed* equip call without this. Defaults to {}, so no existing
        -- test observes any change.
        equipFail = opts.equipFail or {},
        -- Container contents keyed by BLOCK NAME, each a list of {name, count}
        -- stacks: { ["enderstorage:ender_chest"] = {{name="minecraft:coal",
        -- count=64}} }. Keying by block name rather than position is what lets
        -- a test model an empty dock station chest below the turtle and a
        -- stocked ender chest it deploys itself -- the two are different blocks
        -- but both are reached through the same turtle.suck* calls. nil means
        -- "no containers", so suck* returns false exactly as it always has and
        -- no existing test observes any change.
        containers = opts.containers,
        -- Fuel realism, now the DEFAULT. Pass realFuel = false to opt out.
        --
        -- This used to default off, so refuel() returned true and burned nothing
        -- unless a suite remembered to opt in. Any test touching fuel without
        -- opting in passed vacuously: a turtle that burns nothing looked exactly
        -- like one that burns coal, and a refuel that should have been REFUSED
        -- looked like a success. W1 hit that writing the coal-ore fix -- the
        -- refusal was the entire behaviour under test, and five new tests would
        -- have gone green asserting nothing had they not threaded realFuel through.
        --
        -- Flipping it was held off on the theory that suites relying on refuel()
        -- always succeeding would regress. Measured rather than assumed: the flip
        -- breaks nothing, all suites pass, so the theory was wrong and the
        -- faithful default is free.
        --
        -- Fourth fidelity gap of the same shape, after displayName on the plain
        -- getItemDetail, drop() succeeding onto nothing, and a missing inspectUp.
        -- The pattern: THE STUB WAS MOST GENEROUS EXACTLY WHERE CC'S REFUSALS
        -- CARRY THE MEANING. Anything here that cannot fail deserves suspicion.
        realFuel  = (opts.realFuel ~= false),
    }
    -- facing lives only on c.pos; c.facing would drift out of sync with it
    -- the moment either got written independently, so there's one owner.

    local function key(x, y, z) return x .. "," .. y .. "," .. z end
    local function below() return key(c.pos.x, c.pos.y - 1, c.pos.z) end
    local function above() return key(c.pos.x, c.pos.y + 1, c.pos.z) end
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
        -- Real CC:Tweaked returns name/count/damage from the plain form and only
        -- adds displayName, tags and nbt when `detailed` is true. Modelling that
        -- matters: equipment.findLoaderSlot deliberately uses the cheap query to
        -- filter by item name and the detailed one only for the few slots that
        -- are advanced turtles. A stub that handed out displayName either way
        -- would let a build that never asks for details pass here and then fail
        -- in-world, where the field simply is not there.
        getItemDetail = function(s, detailed)
            local i = c.inv[s or c.selected]
            if not i or detailed then return i end
            local plain = {}
            for k, v in pairs(i) do
                if k ~= "displayName" and k ~= "tags" and k ~= "nbt" then plain[k] = v end
            end
            return plain
        end,
        getItemSpace  = function(s) local i = c.inv[s or c.selected]; return 64 - (i and i.count or 0) end,
        getFuelLevel  = function() return c.fuel end,
        getFuelLimit  = function() return 100000 end,
        refuel        = function(n)
            if not c.realFuel then return true end
            local i = c.inv[c.selected]
            if not i then return false, "No items to combust" end
            local per = FUEL_PER_ITEM[i.name]
            if not per then return false, "Items not combustible" end
            local burn = math.min(i.count, n or i.count)
            c.fuel = math.min(c.fuel + burn * per, 100000)
            i.count = i.count - burn
            if i.count <= 0 then c.inv[c.selected] = nil end
            return true
        end,

        detect     = function() return c.world[ahead()] ~= nil end,
        detectDown = function() return c.world[below()] ~= nil end,
        detectUp   = function() return c.world[above()] ~= nil end,
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
        -- inspectUp was simply missing, which made turtle_base's INSPECT.up nil
        -- and isTurtleBlock("up") return false unconditionally. Any guard on the
        -- upward direction would have been untestable and passed silently while
        -- doing nothing in-world -- the same shape as the displayName and drop
        -- gaps. Third one found this session; see M._drop's note.
        inspectUp = function()
            local b = c.world[above()]
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

        equipLeft  = function()
            if c.equipFail.left then return false, "stub-forced equip failure" end
            return M._equip(c, "left")
        end,
        equipRight = function()
            if c.equipFail.right then return false, "stub-forced equip failure" end
            return M._equip(c, "right")
        end,
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
            -- Real CC:Tweaked never manufactures items or overflows a
            -- stack past 64: n is capped by what the source actually
            -- holds, then further capped by the destination's remaining
            -- room, and only the amount actually moved comes off the
            -- source. A destination already at 64 accepts nothing, which
            -- is a failed transfer, not a silent no-op success.
            n = math.min(n, src.count)
            local space = 64 - (d and d.count or 0)
            if space <= 0 then return false end
            local moved = math.min(n, space)
            c.inv[dest] = { name = src.name, count = (d and d.count or 0) + moved }
            src.count = src.count - moved
            if src.count <= 0 then c.inv[c.selected] = nil end
            return true
        end,
        -- Real CC's drop family is not "delete the slot and succeed". It used to
        -- be exactly that here, which collapsed three distinct outcomes into one
        -- and is how an unchecked placeDown() scattered ore across a zone for
        -- weeks while this suite stayed green: the ore chest was never placed,
        -- the drop "succeeded" anyway, and nothing in the model could tell a
        -- chest from the floor.
        --
        --   * empty selected slot          -> false, nothing happens
        --   * an inventory in the target   -> items go INTO it
        --   * no inventory in the target   -> items hit the ground and are LOST
        --
        -- Ground drops land in c.dropped so a test can assert that nothing was
        -- scattered, which is usually the real thing under test.
        dropDown = function(n) return M._drop(c, c.world[below()], n) end,
        dropUp   = function(n) return M._drop(c, c.world[above()], n) end,
        drop     = function(n) return M._drop(c, c.world[ahead()], n) end,

        -- suck* pull from c.container into the selected slot. Real CC fills the
        -- selected slot first and returns false when the container is empty,
        -- which is what refuelFromChest's `pulled == 0` branch keys off.
        suckDown = function(n) return M._suck(c, c.world[below()], n) end,
        suckUp   = function(n) return M._suck(c, c.world[above()], n) end,
        suck     = function(n) return M._suck(c, c.world[ahead()], n) end,
    }

    -- placeDown/placeUp/digUp mirror their front/down counterparts exactly.
    turtle.placeDown = function()
        local i = c.inv[c.selected]
        if not i then return false, "Nothing to place" end
        if c.world[below()] then return false, "Cannot place block here" end
        c.world[below()] = i.name
        i.count = i.count - 1
        if i.count <= 0 then c.inv[c.selected] = nil end
        return true
    end
    turtle.placeUp = function()
        local i = c.inv[c.selected]
        if not i then return false, "Nothing to place" end
        if c.world[above()] then return false, "Cannot place block here" end
        c.world[above()] = i.name
        i.count = i.count - 1
        if i.count <= 0 then c.inv[c.selected] = nil end
        return true
    end
    turtle.digUp = function()
        if c.equipped.left ~= "minecraft:diamond_pickaxe" and c.equipped.right ~= "minecraft:diamond_pickaxe" then
            return false, "No tool to dig with"
        end
        local b = c.world[above()]
        if not b then return false, "Nothing to dig here" end
        if not collectDug(b) then return false, "No space for item" end
        c.world[above()] = nil
        return true
    end

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

        -- Records every call so tests can assert the miner powers on the
        -- turtle it just placed. Real CC:Tweaked exposes an adjacent
        -- computer/turtle as a peripheral with turnOn/shutdown/reboot/isOn;
        -- a placed turtle starts OFF, so without turnOn it never boots and
        -- never runs startup.lua.
        call = function(side, method, ...)
            c.peripheralCalls[#c.peripheralCalls + 1] = { side = side, method = method }
            if c.peripheralCallFails then error("stub-forced peripheral.call failure", 0) end
            if method == "turnOn" then c.placedTurtleOn = true end
            return true
        end,
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

    -- In-memory fs, just enough for loader_state.lua's persistence to run
    -- headlessly. Real CC:Tweaked file handles are called dot-style (no
    -- implicit self) -- `h.write(text)`, not `h:write(text)` -- so write/
    -- writeLine below take a single argument to match that, and callers
    -- must use the same convention.
    local files = {}
    -- A real disk budget, because "out of space" is a behaviour this system has
    -- to survive rather than an environment it can assume away. saveJobs has been
    -- erroring into its own pcall on every test run -- fs.move, fs.copy and
    -- fs.getFreeSpace simply did not exist here -- so the whole persistence path
    -- was silently untested. Fifth stub fidelity gap, and the first that was an
    -- ABSENCE rather than an over-generous success.
    --
    -- Pass freeSpace to model a nearly-full disk. Writes and copies consume it,
    -- deletes refund it, and a rename costs nothing -- which is the entire point
    -- of the saveJobs fix.
    local freeSpace = opts.freeSpace or 1000000
    local function sizeOf(p) return files[p] and #files[p] or 0 end
    local function charge(n)
        if n > freeSpace then error("Out of space", 0) end
        freeSpace = freeSpace - n
    end

    fs = {
        open = function(path, mode)
            if mode == "r" then
                if not files[path] then return nil end
                local content = files[path]
                return {
                    readAll = function() return content end,
                    close   = function() end,
                }
            end
            local buf = {}
            return {
                write     = function(s) buf[#buf + 1] = s end,
                writeLine = function(s) buf[#buf + 1] = s .. "\n" end,
                close     = function()
                    local data = table.concat(buf)
                    charge(#data - sizeOf(path))
                    files[path] = data
                end,
            }
        end,
        exists = function(path) return files[path] ~= nil end,
        delete = function(path)
            freeSpace = freeSpace + sizeOf(path)
            files[path] = nil
        end,
        -- A second full copy has to fit. This is the call that fails on a nearly
        -- full disk, after the backup it is replacing has already been deleted.
        copy = function(from, to)
            if not files[from] then error("No such file", 0) end
            charge(#files[from])
            files[to] = files[from]
        end,
        -- A rename needs no additional space, so it cannot fail this way.
        move = function(from, to)
            if not files[from] then error("No such file", 0) end
            freeSpace = freeSpace + sizeOf(to)
            files[to], files[from] = files[from], nil
        end,
        getFreeSpace = function() return freeSpace end,
    }
    c.files = files
    c.freeSpace = function() return freeSpace end

    c.pos.facing = c.pos.facing or 0
    return c
end

-- Swap the selected inventory slot with the upgrade on `side`, matching
-- CC:Tweaked semantics: empty slot unequips into it, occupied slot swaps.
-- NOTE: equipping from a stack of count > 1 discards the remainder (only
-- one item becomes the equipped upgrade) -- unmodelled here because every
-- upgrade in this system is only ever held as count 1, so the gap never
-- gets exercised.
-- Pull one stack out of the container block named `blockName` into the selected
-- slot. Returns false when there is no such block, it holds no contents, or it
-- is empty -- which is the signal refuelFromChest uses to decide the chest had
-- no coal.
-- Known remaining gaps, so the next person does not rediscover them the way the
-- displayName and drop gaps were found -- both after they had already let a real
-- in-world failure through a green suite:
--   * containers are unbounded, so a drop into a FULL chest still succeeds here
--     and returns false in-world
--   * fuel is not consumed by turn/dig, only by movement
-- Add fidelity when a test needs it; do not assume the absence of a gap.
function M._drop(c, blockName, n)
    local i = c.inv[c.selected]
    if not i then return false, "No items to drop" end
    local moved = math.min(n or i.count, i.count)
    if moved <= 0 then return false, "No items to drop" end

    local contents = blockName and c.containers and c.containers[blockName]
    if contents then
        contents[#contents + 1] = { name = i.name, count = moved }
    else
        c.dropped[#c.dropped + 1] = { name = i.name, count = moved }
    end

    i.count = i.count - moved
    if i.count <= 0 then c.inv[c.selected] = nil end
    return true
end

function M._suck(c, blockName, n)
    if not blockName or not c.containers then return false end
    local contents = c.containers[blockName]
    if not contents or #contents == 0 then return false end
    local stack = contents[1]
    local dest  = c.inv[c.selected]
    if dest and dest.name ~= stack.name then return false end
    local room  = 64 - (dest and dest.count or 0)
    if room <= 0 then return false end
    local moved = math.min(stack.count, room, n or 64)
    if moved <= 0 then return false end
    if dest then dest.count = dest.count + moved
    else c.inv[c.selected] = { name = stack.name, count = moved } end
    stack.count = stack.count - moved
    if stack.count <= 0 then table.remove(contents, 1) end
    return true
end

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

-- Real CC:Tweaked turtle.forward()/back()/up()/down() refuse to move into an
-- occupied block (including another turtle) rather than silently gliding
-- through it. Added so tests can model a turtle physically blocking the
-- forward path (bypassForward's trigger condition) -- no existing test drove
-- movement into a placed world block before this, so this only adds
-- behaviour, it never changes an outcome any current test observes.
function M._move(c, dir)
    if dir == "up" or dir == "down" then
        local ny  = c.pos.y + (dir == "up" and 1 or -1)
        local key = c.pos.x .. "," .. ny .. "," .. c.pos.z
        if c.world[key] then return false, "Movement obstructed" end
        c.pos.y = ny
        return true
    end
    local dx, dz = 0, 0
    if     c.pos.facing == 0 then dz = -1
    elseif c.pos.facing == 1 then dx =  1
    elseif c.pos.facing == 2 then dz =  1
    else                          dx = -1 end
    if dir == "back" then dx, dz = -dx, -dz end
    local nx, nz = c.pos.x + dx, c.pos.z + dz
    local key = nx .. "," .. c.pos.y .. "," .. nz
    if c.world[key] then return false, "Movement obstructed" end
    c.pos.x, c.pos.z = nx, nz
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
