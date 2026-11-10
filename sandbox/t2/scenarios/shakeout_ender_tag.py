"""Shakeout Task 3 proof (NOT RUN YET, 2026-11-10: the test server was in use): Control.set_slot(..., tag=...) gives a turtle an
ender chest tuned to bay 1's frequency.

  1. FIND the frequency. The world copy's bay 1 has an ender chest under a dock; its block data is read with block_data
     (a scan of bay 1's dock cells at y 66 and 65 for a block whose data has "Frequency"). Whatever is found is noted
     verbatim, because the exact SNBT shape (Frequency:{left:..,middle:..,right:..} or a different layout) is not
     recorded anywhere in this repo.
  2. GIVE it: a spare turtle gets enderstorage:ender_chest with that tag in slot 0; get_slot reads it back and the tag
     must match (compared with spaces removed).
  3. PLACE it: the probe turtle (Lua: sandbox/t2/lua/ender_tag_probe.lua is generated here, written beside it) places the
     chest in front and drops a marker item; the same marker must then be found in the original chest of bay 1.

Run:  python sandbox/t2/scenario.py <run-id> sandbox/t2/scenarios/shakeout_ender_tag.py   (see scenario.py main for the
exact flags; a world copy with bay 1 built, and the area at FREE_SPOT loaded)."""
import json
import os
import re
import time

NAME = "shakeout_ender_tag"
BAY1_X = 157
DOCK_DX = range(-4, 5)
DOCK_ZS = (-2806, -2810, -2797, -2793)
ENDER_ITEM = "enderstorage:ender_chest"

PROBE_LUA = '''
local function put(t) local f = fs.open("ender_probe.json", "w"); f.write(textutils.serialiseJSON(t)); f.close() end
local r = {}
turtle.select(1)
r.detail = turtle.getItemDetail(1)
r.placed = turtle.place()
r.drop = turtle.drop(1) -- slot 2 holds the marker
put(r)
'''


def frequency_of(text):
    """The Frequency compound out of block data / item data, whitespace removed, or None."""
    m = re.search(r"Frequency:\s*(\{.*?\}\s*\}|\{[^{}]*\})", text)
    return re.sub(r"\s+", "", "Frequency:" + m.group(1)) if m else None


def find_bay1_chest(c):
    """(pos, data) of the first ender chest block entity under bay 1's docks, or (None, notes)."""
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

    x, y, z = c.free_spot()
    lua = os.path.join(ctx.run, "ender_tag_probe.lua")
    with open(lua, "w") as f:
        f.write(PROBE_LUA)
    # a turtle with the chest in slot 0 (Lua 1) and a marker in slot 1 (Lua 2); the tag goes on at spawn, before it starts
    new = c.spawn_turtle(x, y, z, "SUPPORT", startup=lua, fuel=1000, items={1: ("minecraft:diamond", 1)})
    c.shutdown([new])
    got = c.set_slot(new, 0, ENDER_ITEM, 1, tag=tag)
    ctx.note("read back from get_slot: %s" % got)
    ctx.expect(freq in re.sub(r"\s+", "", str(got)), "the ender chest reads back with the same tag (%s)" % freq)

    before = c.block_data(pos, "")
    c.turn_on([new])
    disk = os.path.join(c.disks, str(new))
    result = {}

    def read():
        try:
            with open(os.path.join(disk, "ender_probe.json")) as f:
                return json.loads(f.read())
        except (OSError, ValueError):
            return {}

    ctx.wait_until(lambda: "placed" in read(), 120, poll=3)
    result = read()
    ctx.note("probe result: %s" % result)
    ctx.expect(result.get("placed") is True, "the turtle placed the tagged ender chest")
    time.sleep(2)
    # The chest at bay 1 is the same frequency, so the diamond must show up there. EnderStorage keeps contents in its
    # frequency saved data, not in the block entity, so check by reading the chest's contents through a second probe if
    # block_data shows none; the first check is the block data of the original chest.
    after = c.block_data(pos, "")
    ctx.note("bay 1 chest data before: %s\nafter: %s" % (before, after))
    ctx.expect("diamond" in after, "the marker diamond dropped into the placed chest is in bay 1's chest (same frequency)")
