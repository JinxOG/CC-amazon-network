-- loaderid.lua — can a chunk loader be told apart from a mined-up fleet turtle?
--
-- equipment.ITEMS.LOADER_TURTLE is computercraft:turtle_advanced, which every
-- miner, loader and delivery turtle in this fleet also is. equipment.isLoaderItem
-- can match on displayName instead, but only if displayName actually differs
-- between a loader and a fleet turtle IN THIS PACK. Nothing on the dev machine
-- can answer that. This does.
--
-- Run on any turtle. Put BOTH in its inventory if you can:
--   * a chunk loader turtle (one of the fleet's spares)
--   * any other advanced turtle -- ideally a labelled one, e.g. a spare miner
--
-- One is enough to be useful; two makes the answer conclusive.

local LOADER = "computercraft:turtle_advanced"

print(("="):rep(52))
print("Advanced turtles in inventory:")
print(("="):rep(52))

local found = 0
local names = {}

for s = 1, 16 do
    local plain = turtle.getItemDetail(s)
    if plain and plain.name == LOADER then
        found = found + 1
        local d = turtle.getItemDetail(s, true)
        local disp = d and d.displayName or nil
        names[#names + 1] = disp
        print(string.format("slot %2d:", s))
        print("   name        = " .. tostring(plain.name))
        print("   displayName = " .. tostring(disp))
        if d and d.nbt then print("   nbt         = " .. tostring(d.nbt)) end
    end
end

print(("="):rep(52))

if found == 0 then
    print("No advanced turtle found. Put a loader in the inventory and rerun.")
    return
end

-- The three answers that matter, in the order they change the decision.
if names[1] == nil then
    print("VERDICT: displayName is nil -- the detailed query does not carry it.")
    print("  Labelling is NOT viable. equipment.LOADER_LABEL must stay nil and")
    print("  the loader_state cross-check is the only signal available.")
elseif found >= 2 then
    local allSame = true
    for i = 2, #names do
        if names[i] ~= names[1] then allSame = false end
    end
    if allSame then
        print("VERDICT: both turtles report the SAME displayName:")
        print("  " .. tostring(names[1]))
        print("  Labelling does NOT discriminate as-is. Either label the loaders")
        print("  (see below) or fall back to the loader_state cross-check alone.")
    else
        print("VERDICT: the turtles differ by displayName. Labelling WORKS.")
        for i, n in ipairs(names) do
            print(string.format("  [%d] %s", i, tostring(n)))
        end
        print("  Set equipment.LOADER_LABEL to whichever of these is the LOADER.")
    end
else
    print("VERDICT: one turtle seen, displayName = " .. tostring(names[1]))
    print("  Useful but not conclusive. Rerun holding a second advanced turtle")
    print("  of the other kind to confirm the two actually differ.")
end

print("")
print("If loaders and fleet turtles do NOT differ, give the loaders a label:")
print("  run this ON a loader turtle:  os.setComputerLabel(\"LOADER\")")
print("  then break it, and rerun this probe holding it.")
print("A turtle's label becomes its item displayName and survives place/break,")
print("so a labelled loader is distinguishable from an unlabelled fleet turtle.")
print(("="):rep(52))
