"""Shakeout Task 3 proof (NOT RUN YET, 2026-11-10: the test server was in use): Control.set_slot(..., tag=...) gives a turtle an
ender chest tuned to bay 1's frequency.

Slot numbering: NBT slot 0 = Lua slot 1 (set_slot/get_slot take NBT numbers, the Lua probes use Lua numbers).

  1. FIND the frequency. The world copy's bay 1 has an ender chest under a dock; its block data is read with block_data
     (a scan of bay 1's dock cells at y 66 and 65 for a block whose data has "Frequency"). Whatever is found is noted
     verbatim: the exact SNBT is not recorded anywhere in this repo, and the block-entity layout of Frequency may differ from
     the item-stack tag layout (it may need BlockEntityTag). The read-back check in step 3 catches a mismatch.
  2. READER: a turtle is spawned on an air cell beside bay 1's chest. Its Lua (written to the run folder, installed as its
     startup) lists every "inventory" peripheral it touches every 2 s and writes the diamond count to reader.json. If no air
     cell touches the chest the run fails loudly (nothing is measured).
  3. GIVE: a placer turtle is spawned (it starts once, with no chest, and its stale ender_probe.json is deleted), shut down,
     given an ender chest (NBT slot 0) with that tag via set_slot and a diamond (NBT slot 1); get_slot must read the same tag.
  4. PLACE: it is turned on; it places the chest, selects Lua slot 2 and drops the diamond. The reader's diamond count must go
     from N to N+1: the only way that can happen is the placed chest being on bay 1's frequency. Both the placer's own
     results (placed, drop, failure reason) and the count change are asserted, so each step can fail.

Side effects: the run leaves one diamond in bay 1's chest and the reader and placer turtles (and the placed chest) standing in the
world, so use a throwaway world copy. Reader candidates that see no inventory are removed again.

Run through sandbox/t2/scenario.py like the other scenarios, on a world copy with bay 1 built."""
import json
import os
import re
import time

NAME = "shakeout_ender_tag"
BAY1_X = 157
DOCK_DX = range(-4, 5)
DOCK_ZS = (-2806, -2810, -2797, -2793)
ENDER_ITEM = "enderstorage:ender_chest"

PLACER_LUA = '''
local r = {}
r.chest = turtle.getItemDetail(1)
turtle.select(1)
local ok, why = turtle.place()
r.placed = ok
r.place_why = why
turtle.select(2)
local dok, dwhy = turtle.drop(1)
r.drop = dok
r.drop_why = dwhy
local f = fs.open("ender_probe.json", "w"); f.write(textutils.serialiseJSON(r)); f.close()
'''

READER_LUA = '''
while true do
  local n, seen = 0, 0
  for _, name in ipairs(peripheral.getNames()) do
    if peripheral.hasType(name, "inventory") then
      seen = seen + 1
      for _, st in pairs(peripheral.call(name, "list")) do
        if st.name == "minecraft:diamond" then n = n + st.count end
      end
    end
  end
  local f = fs.open("reader.json", "w"); f.write(textutils.serialiseJSON({diamonds = n, inventories = seen, t = os.epoch("utc")})); f.close()
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


def find_bay1_chest(c):
    """(pos, data) of the first block with a Frequency under bay 1's docks, or (None, notes)."""
    seen = []
    for dz in DOCK_ZS:
        for dx in DOCK_DX:
            for y in (66, 65):
                pos = (BAY1_X + dx, y, dz)
                out = c.block_data(pos)
                if "Frequency" in out:
                    return pos, out
                if "Found no" not in out and "has no" not in out:
                    seen.append((pos, out[:80]))
    return None, seen


FACING = {(1, 0): "east", (-1, 0): "west", (0, 1): "south", (0, -1): "north"}


def in_dock_area(p):
    """True for a cell of the bay 1 dock rows or the aisles and return lanes around them (y 67, bay 1's x range, z from the
    outermost dock rows plus 4 cells each way for the aisles/return lanes): the reader must not park there."""
    x, y, z = p
    return y == 67 and BAY1_X - 5 <= x <= BAY1_X + 5 and min(DOCK_ZS) - 4 <= z <= max(DOCK_ZS) + 4


def reader_candidates(raw, pos):
    """[(cell, facing)] of air cells touching pos, never in the dock area. The facing points at the chest when it is to the side, so
    the chest is in FRONT of the turtle (its modem is on the left, and a chest on the left is not wrapped as an inventory)."""
    x, y, z = pos
    out = []
    for dx, dy, dz in ((1, 0, 0), (-1, 0, 0), (0, 0, 1), (0, 0, -1), (0, -1, 0), (0, 1, 0)):
        p = (x + dx, y + dy, z + dz)
        if in_dock_area(p) or "Test passed" not in raw.command("execute if block %d %d %d air" % p):
            continue
        out.append((p, FACING.get((-dx, -dz), "north")))   # the chest lies at (-dx, -dz) from the candidate
    return out


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
    pos, data = find_bay1_chest(c)
    if pos is None:
        ctx.note("no block with a Frequency under bay 1; blocks with data seen: %s" % (data[:10],))
        ctx.expect(False, "found bay 1's ender chest (a block with Frequency under a bay 1 dock cell)")
        return
    ctx.note("bay 1 chest at %s, block data: %s" % (pos, data))
    freq = frequency_of(data)
    ctx.expect(freq is not None, "could parse a Frequency from the block data: %s" % freq)
    if not freq:
        return
    tag = "{%s}" % freq

    # ---- the reader, beside bay 1's chest ----
    cands = reader_candidates(raw, pos)
    ctx.note("reader candidate cells (not in the dock area): %s" % (cands,))
    ctx.expect(bool(cands), "an air cell outside the dock area touches bay 1's chest at %s, for the reader turtle" % (pos,))
    reader_lua = os.path.join(ctx.run, "ender_reader.lua")
    write_probe(ctx, reader_lua, READER_LUA)
    reader, r0 = None, {}
    for spot, facing in cands:
        reader = c.spawn_turtle(spot[0], spot[1], spot[2], "SUPPORT", startup=reader_lua, fuel=100, facing=facing)
        ctx.wait_until(lambda: "diamonds" in disk_json(c, reader, "reader.json"), 120, poll=3)
        r0 = disk_json(c, reader, "reader.json")
        ctx.note("reader #%d at %s facing %s, first reading: %s" % (reader, spot, facing, r0))
        if r0.get("inventories", 0) >= 1:
            break
        c.shutdown([reader])
        raw.command("setblock %d %d %d minecraft:air" % spot)      # not wrapping the chest: take it away, try the next cell
    ctx.expect(r0.get("inventories", 0) >= 1, "the reader sees an inventory peripheral (bay 1's chest) -- else the count proves nothing")
    if not r0.get("inventories"):
        return
    n_before = r0["diamonds"]

    # ---- the placer: start once with no chest, then clean up the stale result before the real run ----
    x, y, z = c.free_spot()
    facing = next((f for (dx, dz), f in FACING.items()
                   if "Test passed" in raw.command("execute if block %d %d %d air" % (x + dx, y, z + dz))), None)
    ctx.expect(facing is not None, "the placer's spot %s has an air cell beside it to place the chest into" % ((x, y, z),))
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
    ctx.expect(freq in re.sub(r"\s+", "", str(got)), "the ender chest reads back with the same tag (%s)" % freq)

    c.turn_on([new])
    done = ctx.wait_until(lambda: "placed" in disk_json(c, new, "ender_probe.json"), 120, poll=3)
    result = disk_json(c, new, "ender_probe.json")
    ctx.expect(bool(done), "the placer finished its probe (ender_probe.json written)")
    ctx.note("placer result: %s" % result)
    ctx.expect(result.get("placed") is True, "the turtle placed the tagged ender chest (%s)" % result.get("place_why"))
    ctx.expect(result.get("drop") is True, "the turtle dropped the diamond into it (%s)" % result.get("drop_why"))

    # ---- the connection: the reader beside bay 1's chest must now count one more diamond ----
    ctx.wait_until(lambda: disk_json(c, reader, "reader.json").get("diamonds") != n_before, 60, poll=3)
    time.sleep(3)
    n_after = disk_json(c, reader, "reader.json").get("diamonds")
    ctx.note("diamonds seen by the reader: before %s, after %s" % (n_before, n_after))
    ctx.expect(n_after == n_before + 1, "bay 1's chest gained exactly the dropped diamond (%s -> %s): the placed chest is on bay 1's frequency"
               % (n_before, n_after))
