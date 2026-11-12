"""Shakeout Task 3 proof: Control.set_slot(..., tag=...) gives a turtle an
ender chest tuned to bay 1's frequency.

Slot numbering: NBT slot 0 = Lua slot 1 (set_slot/get_slot take NBT numbers, the Lua probes use Lua numbers).

  1. FIND the frequency. Bay 1 has ender chests at y 66 directly under its dock cells (y 67); the block under every dock cell
     (world.dock_cells(), bay 1 first) is read with block_data and the first with "Frequency" is used. Whatever is found is noted
     verbatim: the exact SNBT is not recorded anywhere in this repo, and the block-entity layout of Frequency may differ from
     the item-stack tag layout (it may need BlockEntityTag). The read-back check in step 3 catches a mismatch.
  2. READER: the chests are boxed in by floor, so the reader stands IN an air dock cell (never one a fleet turtle holds) with a
     chest of the same Frequency below it, as real turtles do. Its Lua (the run folder, its startup) wraps peripheral
     "bottom" and lists it every 2 s (nothing is moved), writing the diamond count to reader.json. If no such cell
     exists the run fails loudly with the chests found.
  3. GIVE: a placer turtle is spawned (it starts once, with no chest, and its stale ender_probe.json is deleted), shut down,
     given an ender chest (NBT slot 0) with that tag via set_slot and a diamond (NBT slot 1); get_slot must read the same tag.
  4. PLACE: it is turned on; it places the chest, selects Lua slot 2 and drops the diamond. The reader's diamond count must go
     from N to N+1: the only way that can happen is the placed chest being on bay 1's frequency. Both the placer's own
     results (placed, drop, failure reason) and the count change are asserted, so each step can fail.

  5. LINK ON 0,10,0: the fuel chest (0,0,0) is refilled by an RS exporter, so a drop into it proves nothing either way. On
     frequency 0,10,0 (free space, no exporter) one turtle places its own chest and counts it; a second places a chest and
     drops a diamond; the first must count N -> N+1.
  The connection check for the fuel frequency is taking an item OUT of the freshly placed chest (a new chest holds items only
  if it is linked); the reader's count is supporting evidence. Spawned turtles need an Owner (Control.owner_snbt), else
  turtle.place is refused.

Side effects: the run leaves one diamond in bay 1's chest and the reader and placer turtles (and the placed chest) standing in the
world, so use a throwaway world copy.

Run through sandbox/t2/scenario.py like the other scenarios, on a world copy with bay 1 built."""
import json
import os
import re
import time

from shakeout import world as shakeout_world   # dock_cells() reads waypoints.lua (sandbox/t2 is on the path: the runner put it there)

NAME = "shakeout_ender_tag"
ENDER_ITEM = "enderstorage:ender_chest"

PLACER_LUA = '''
local r = {tries = {}}
r.chest = turtle.getItemDetail(1)
turtle.select(1)
-- the first cell that takes the chest wins; every refusal is recorded so a failure names why
local dirs = {
  {"front", turtle.place, turtle.drop, turtle.detect, turtle.inspect, turtle.suck},
  {"down", turtle.placeDown, turtle.dropDown, turtle.detectDown, turtle.inspectDown, turtle.suckDown},
  {"up", turtle.placeUp, turtle.dropUp, turtle.detectUp, turtle.inspectUp, turtle.suckUp},
}
for turn = 0, 3 do
  if turn > 0 then turtle.turnRight() end
  for i, d in ipairs(dirs) do
    if turn == 0 or i == 1 then
      if not r.placed then
        turtle.select(1)
        local ok, why = d[2]()
        local _, info = d[5]()
        r.tries[#r.tries + 1] = {d[1], turn, ok, why, d[4](), info and info.name}
        if ok then
          r.placed = true
          r.place_dir = d[1]
          -- a bay chest may be full (the dock chests of frequency 0,0,0 are the fuel chests), so take one item OUT first:
          -- that proves the connection by itself and makes room for the diamond
          turtle.select(3)
          local sok, swhy = false, "skipped"
          if not fs.exists("nosuck") then sok, swhy = d[6]() end   -- a whole stack: a full chest then has a free slot
          r.suck = sok
          r.suck_why = swhy
          local got = turtle.getItemDetail(3)
          r.sucked = got and got.name
          r.sucked_n = got and got.count
          turtle.select(2)
          local dok, dwhy = d[3](1)
          r.drop = dok
          r.drop_why = dwhy
        end
      end
    end
  end
end
if not r.placed then r.placed = false end
local f = fs.open("ender_probe.json", "w"); f.write(textutils.serialiseJSON(r)); f.close()
'''

READER10_LUA = '''
-- places its own chest in front (a turtle with an Owner can), then counts what the chest holds every 2 s
turtle.select(1)
local ok, why = turtle.place()
while true do
  local n, total, names = 0, 0, {}
  local inv = peripheral.wrap("front")
  if inv and peripheral.hasType("front", "inventory") then
    for _, st in pairs(inv.list()) do
      if st.name == "minecraft:diamond" then n = n + st.count end
      total = total + st.count
      names[st.name] = true
    end
  end
  local f = fs.open("reader.json", "w"); f.write(textutils.serialiseJSON({diamonds = n, total = total, names = names, placed = ok, why = why, inventories = inv and 1 or 0, t = os.epoch("utc")})); f.close()
  sleep(2)
end
'''

READER_LUA = '''
while true do
  local n, seen = 0, 0
  local inv = peripheral.wrap("bottom")
  local total, names = 0, {}
  if inv and peripheral.hasType("bottom", "inventory") then
    seen = 1
    for _, st in pairs(inv.list()) do
      if st.name == "minecraft:diamond" then n = n + st.count end
      total = total + st.count
      names[st.name] = true
    end
  end
  local f = fs.open("reader.json", "w"); f.write(textutils.serialiseJSON({diamonds = n, total = total, names = names, inventories = seen, t = os.epoch("utc")})); f.close()
  sleep(2)
end
'''


def frequency_of(text):
    """'Frequency:{...}' out of block/item data (whitespace removed) by balanced-brace matching, or None."""
    i = text.find("Frequency")
    if i < 0:
        return None
    j = text.find("{", i)
    if j < 0:
        return None
    depth = 0
    for k in range(j, len(text)):
        if text[k] == "{":
            depth += 1
        elif text[k] == "}":
            depth -= 1
            if depth == 0:
                return re.sub(r"\s+", "", "Frequency:" + text[j:k + 1])
    return None


FACING = {(1, 0): "east", (-1, 0): "west", (0, 1): "south", (0, -1): "north"}


def facing_for(raw, x, y, z):
    """A facing whose front cell is air with a solid block under it (somewhere to place a chest), or None."""
    return next((f for (dx, dz), f in FACING.items()
                 if "Test passed" in raw.command("execute if block %d %d %d air" % (x + dx, y, z + dz))
                 and "Test passed" in raw.command("execute unless block %d %d %d air" % (x + dx, y - 1, z + dz))), None)


def frequency_pairs(text):
    """{'middle': 0, 'left': 0, 'right': 0} from any text holding a Frequency compound (the key order differs between the block
    data, the item tag and get_slot, so strings are never compared)."""
    f = frequency_of(re.sub(r"(?<=\d)[bBsSlLfFdD]", "", text)) or ""
    return {k: int(v) for k, v in re.findall(r"(\w+):(-?\d+)", f.replace("Frequency:", "", 1))}


def ordered_docks(cells):
    """Dock cells (from waypoints.lua via world.dock_cells, never re-typed), bay 1 first, then the other bays."""
    return sorted(cells, key=lambda d: (d["bay"] != 1, d["bay"], d["side"], d["z"], d["x"]))


def chests_under_docks(c, cells, seen):
    """[(dock cell, chest pos, block data)] for every dock cell with a Frequency block directly below it (y-1), in
    ordered_docks order. Whatever else is seen under a dock is appended to `seen` as (pos, text)."""
    out = []
    for d in ordered_docks(cells):
        pos = (d["x"], d["y"] - 1, d["z"])
        data = c.block_data(pos)
        if "Frequency" in data:
            out.append((d, pos, data))
        elif "Found no" not in data and "has no" not in data:
            seen.append((pos, data[:80]))
    return out


def pick_reader_dock(raw, chests, freq):
    """(dock cell, chest pos) of the first dock cell that is AIR right now (a parked turtle is never removed or moved) and has
    under it a chest whose Frequency equals `freq`, or None. `chests` is chests_under_docks' output."""
    for d, pos, data in chests:
        if frequency_of(data) != freq:
            continue
        if "Test passed" in raw.command("execute if block %d %d %d air" % (d["x"], d["y"], d["z"])):
            return d, pos
    return None


def write_probe(ctx, path, text):
    """Writes a probe's Lua into the run folder and records it as an intervention (it becomes a turtle's startup)."""
    with open(path, "w") as f:
        f.write(text)
    ctx.interventions.append({"verb": "write_file", "args": [repr(path)], "kwargs": {"text": repr(text[:300])},
                              "game_seconds": ctx.game_seconds()})


def disk_json(c, cid, name):
    try:
        with open(os.path.join(c.disks, str(cid), name)) as f:
            return json.loads(f.read())
    except (OSError, ValueError):
        return {}


def steps(ctx):
    c = ctx.control
    raw = ctx._raw
    cells = shakeout_world.dock_cells()
    seen = []
    chests = chests_under_docks(c, cells, seen)
    if not chests:
        ctx.note("no block with a Frequency under any dock cell; blocks with data seen: %s" % (seen[:10],))
        ctx.expect(False, "found an ender chest (a block with Frequency) under a dock cell")
        return
    d0, pos, data = chests[0]
    ctx.note("first chest at %s (bay %s, under dock %s), block data: %s" % (pos, d0["bay"], (d0["x"], d0["y"], d0["z"]), data))
    ctx.note("all chests under docks: %s" % ([(p, frequency_of(t), dd["bay"]) for dd, p, t in chests],))
    freq = frequency_of(data)
    ctx.expect(freq is not None, "could parse a Frequency from the block data: %s" % freq)
    if not freq:
        return
    tag = "{%s}" % freq

    # ---- the reader: IN an air dock cell, reading the chest below it ----
    picked = pick_reader_dock(raw, chests, freq)
    ctx.expect(picked is not None, "an air dock cell has under it an ender chest on frequency %s (chests found: %d), for the reader turtle"
               % (freq, len(chests)))
    if picked is None:
        return
    dock, cpos = picked
    spot = (dock["x"], dock["y"], dock["z"])
    ctx.note("reader dock cell %s (bay %s), chest below at %s" % (spot, dock["bay"], cpos))
    reader_lua = os.path.join(ctx.run, "ender_reader.lua")
    write_probe(ctx, reader_lua, READER_LUA)
    reader = c.spawn_turtle(spot[0], spot[1], spot[2], "SUPPORT", startup=reader_lua, fuel=100, facing="north")
    ctx.wait_until(lambda: "diamonds" in disk_json(c, reader, "reader.json"), 120, poll=3)
    r0 = disk_json(c, reader, "reader.json")
    ctx.note("reader #%d at %s, first reading: %s" % (reader, spot, r0))
    ctx.expect(r0.get("inventories", 0) >= 1, "the reader sees the chest below it as an inventory peripheral -- else the count proves nothing")
    if not r0.get("inventories"):
        return
    n_before = r0["diamonds"]
    t_before = r0.get("total")

    # ---- the placer: start once with no chest, then clean up the stale result before the real run ----
    x, y, z = c.free_spot()
    facing = facing_for(raw, x, y, z)
    ctx.expect(facing is not None, "the placer's spot %s has an air cell beside it with a solid block under it to place the chest into" % ((x, y, z),))
    if facing is None:
        return
    placer_lua = os.path.join(ctx.run, "ender_placer.lua")
    write_probe(ctx, placer_lua, PLACER_LUA)
    new = c.spawn_turtle(x, y, z, "SUPPORT", startup=placer_lua, fuel=1000, facing=facing)   # spawn turns it on: first run has no chest
    c.shutdown([new])
    stale = os.path.join(c.disks, str(new), "ender_probe.json")
    if os.path.exists(stale):
        os.remove(stale)
        ctx.interventions.append({"verb": "delete_disk_file", "args": [repr(new), repr("ender_probe.json")], "kwargs": {},
                                  "game_seconds": ctx.game_seconds()})
    got = c.set_slot(new, 0, ENDER_ITEM, 1, tag=tag)          # NBT 0 = Lua 1
    c.set_slot(new, 1, "minecraft:diamond", 1)                # NBT 1 = Lua 2
    ctx.note("read back from get_slot: %s" % got)
    ctx.expect(bool(frequency_pairs(freq)) and frequency_pairs(freq) == frequency_pairs(str(got)),
               "the ender chest reads back with the same tag (%s vs %s)" % (frequency_pairs(freq), frequency_pairs(str(got))))

    c.turn_on([new])
    done = ctx.wait_until(lambda: "placed" in disk_json(c, new, "ender_probe.json"), 120, poll=3)
    result = disk_json(c, new, "ender_probe.json")
    ctx.expect(bool(done), "the placer finished its probe (ender_probe.json written)")
    ctx.note("placer result: %s" % result)
    ctx.expect(result.get("placed") is True, "the turtle placed the tagged ender chest (%s)" % result.get("place_why"))
    ctx.expect(result.get("suck") is True and result.get("sucked") in (r0.get("names") or {}),
               "the turtle took an item OUT of the placed chest and it is one bay 1's chest holds (%s x%s; chest holds %s; %s)"
               % (result.get("sucked"), result.get("sucked_n"), sorted(r0.get("names") or {}), result.get("suck_why")))
    # The fuel chest (frequency 0,0,0) is kept topped up with coal by an RS exporter, so a freed slot is refilled at once and a
    # drop into it may say "No space for items" whatever the link: the drop is only noted here, and proven on frequency 0,10,0 below.
    now = disk_json(c, reader, "reader.json")
    ctx.note("fuel chest: the turtle's drop of the diamond: %s (%s); the reader's diamonds %s -> %s, total %s -> %s" % (
        result.get("drop"), result.get("drop_why"), n_before, now.get("diamonds"), t_before, now.get("total")))

    # ---- frequency 0,10,0 (the delivery hand-off chest, free space, no exporter): a second linked chest reads what the first got ----
    tag10 = "{Frequency:{left:0,middle:10,right:0}}"
    x2, y2, z2 = c.free_spot()
    f2 = facing_for(raw, x2, y2, z2)
    ctx.expect(f2 is not None, "a spot %s for the 0,10,0 reader's own chest" % ((x2, y2, z2),))
    if f2 is None:
        return
    r10_lua = os.path.join(ctx.run, "ender_reader10.lua")
    write_probe(ctx, r10_lua, READER10_LUA)
    reader10 = c.spawn_turtle(x2, y2, z2, "SUPPORT", startup=r10_lua, fuel=100, facing=f2, items={0: (ENDER_ITEM, 1, tag10)})
    ctx.wait_until(lambda: "diamonds" in disk_json(c, reader10, "reader.json"), 120, poll=3)
    q0 = disk_json(c, reader10, "reader.json")
    ctx.note("0,10,0 reader #%d first reading: %s" % (reader10, q0))
    ctx.expect(q0.get("placed") is True and q0.get("inventories") == 1,
               "the 0,10,0 reader placed its chest and sees it as an inventory (%s)" % q0.get("why"))
    if not q0.get("inventories"):
        return
    x3, y3, z3 = c.free_spot()
    f3 = facing_for(raw, x3, y3, z3)
    ctx.expect(f3 is not None, "a spot %s for the 0,10,0 giver" % ((x3, y3, z3),))
    if f3 is None:
        return
    giver = c.spawn_turtle(x3, y3, z3, "SUPPORT", startup=placer_lua, fuel=1000, facing=f3)
    c.shutdown([giver])
    if os.path.exists(os.path.join(c.disks, str(giver), "ender_probe.json")):
        os.remove(os.path.join(c.disks, str(giver), "ender_probe.json"))
    with open(os.path.join(c.disks, str(giver), "nosuck"), "w") as fh:
        fh.write("1")
    ctx.interventions.append({"verb": "write_disk_file", "args": [repr(giver), repr("nosuck")], "kwargs": {}, "game_seconds": ctx.game_seconds()})
    c.set_slot(giver, 0, ENDER_ITEM, 1, tag=tag10)
    c.set_slot(giver, 1, "minecraft:diamond", 1)
    c.turn_on([giver])
    ctx.wait_until(lambda: "placed" in disk_json(c, giver, "ender_probe.json"), 120, poll=3)
    g = disk_json(c, giver, "ender_probe.json")
    ctx.note("0,10,0 giver result: %s" % g)
    ctx.expect(g.get("placed") is True and g.get("drop") is True,
               "the 0,10,0 giver placed its chest and dropped the diamond (%s / %s)" % (g.get("place_why"), g.get("drop_why")))
    ctx.wait_until(lambda: disk_json(c, reader10, "reader.json").get("diamonds") != q0.get("diamonds"), 60, poll=3)
    time.sleep(3)
    q1 = disk_json(c, reader10, "reader.json")
    ctx.note("0,10,0 reader: before %s, after %s" % (q0, q1))
    ctx.expect(q1.get("diamonds") == q0.get("diamonds", 0) + 1,
               "the 0,10,0 reader's chest gained exactly the giver's diamond (%s -> %s): two placed chests on one frequency are linked"
               % (q0.get("diamonds"), q1.get("diamonds")))
