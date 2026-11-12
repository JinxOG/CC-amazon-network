"""Controls for shakeout_ender_tag's refusal ("Cannot place block here" for a set_slot-made enderstorage:ender_chest).

One placer turtle (spawned at y 68 over air with a solid floor, like a delivery turtle at its drop point) holds, in Lua slots
1-4: cobblestone, an UNTAGGED ender chest, the ender chest with the dock chests' tag, and an ender chest whose tag is copied
VERBATIM (get_slot) from a real world-copy delivery turtle's chest slot. For each slot it tries placeDown, then front (four
turns), then up, and records every refusal. A real delivery turtle of the world copy then runs a one-shot probe that places its OWN
chest the same way (the probe replaces its startup for the run and the original is put back). The block data of the spawned placer
and of the real turtle are noted (owner / upgrade fields). Nothing here is a fleet change; use a throwaway world copy."""
import json
import os
import re
import shutil

NAME = "shakeout_ender_controls"

PROBE_LUA = '''
local out = {}
local function tryplace(label, slot)
  local d = turtle.getItemDetail(slot, true)
  local r = {label = label, slot = slot, item = d and d.name, nbt = d and d.nbt, tries = {}}
  turtle.select(slot)
  local fns = {{"down", turtle.placeDown}, {"front", turtle.place}, {"up", turtle.placeUp}}
  for turn = 0, 3 do
    if turn > 0 then turtle.turnRight() end
    for _, f in ipairs(fns) do
      if (turn == 0 or f[1] == "front") and not r.placed then
        local ok, why = f[2]()
        r.tries[#r.tries + 1] = {f[1], turn, ok, why}
        if ok then r.placed = f[1] end
      end
    end
  end
  out[#out + 1] = r
end
local slots = {}
local f = fs.open("probe_slots.json", "r"); if f then slots = textutils.unserialiseJSON(f.readAll()); f.close() end
for _, s in ipairs(slots) do tryplace(s[1], s[2]) end
local o = fs.open("probe_result.json", "w"); o.write(textutils.serialiseJSON(out)); o.close()
'''


def balanced(text, start):
    depth = 0
    for k in range(start, len(text)):
        if text[k] == "{":
            depth += 1
        elif text[k] == "}":
            depth -= 1
            if depth == 0:
                return text[start:k + 1]
    return None


def tag_of(stack_text):
    """The SNBT after 'tag:' of a get_slot result, or None."""
    m = re.search(r"tag:\s*\{", stack_text)
    return balanced(stack_text, m.end() - 1) if m else None


def result_of(c, cid, name="probe_result.json"):
    try:
        with open(os.path.join(c.disks, str(cid), name)) as f:
            return json.loads(f.read())
    except (OSError, ValueError):
        return None


def write_disk(c, cid, name, text):
    with open(os.path.join(c.disks, str(cid), name), "w", newline="\n") as f:
        f.write(text)


def no_items(text):
    return re.sub(r"Items:\s*\[.*?\](?=,\s*\w+:|\})", "Items:[...]", text, flags=re.S)[:1500]


def steps(ctx):
    c = ctx.control
    raw = ctx._raw
    probe = os.path.join(ctx.run, "probe.lua")
    with open(probe, "w") as f:
        f.write(PROBE_LUA)

    # ---- a real delivery turtle's chest, verbatim ----
    comps = c.computers()
    real = None
    for cid in sorted(comps):
        if c.role_of(cid) != "DELIVERY":
            continue
        for slot in (15, 14, 13, 12):
            try:
                got = c.get_slot(cid, slot)
            except Exception:
                continue
            if "enderstorage" in got:
                real = (cid, slot, got)
                break
        if real:
            break
    ctx.expect(real is not None, "found a real world-copy DELIVERY turtle holding an enderstorage chest")
    real_tag = None
    if real:
        ctx.note("real delivery turtle #%d NBT slot %d (pos %s): %s" % (real[0], real[1], comps[real[0]]["pos"], real[2]))
        real_tag = tag_of(real[2])

    # ---- the placer ----
    spot = None
    for x in range(160, 200, 3):
        for z in range(-2790, -2750, 3):
            if all("Test passed" in raw.command("execute if block %d %d %d air" % (x, 67 + k, z)) for k in range(3)) and \
               "Test passed" in raw.command("execute unless block %d 66 %d air" % (x, z)):
                spot = (x, 68, z)
                break
        if spot:
            break
    ctx.expect(spot is not None, "a spot with air at y 67-69 and a solid floor at y 66 for the placer")
    if not spot:
        return
    new = c.spawn_turtle(spot[0], spot[1], spot[2], "SUPPORT", startup=probe, fuel=1000, facing="north", start=False)
    c.shutdown([new])
    write_disk(c, new, "probe_slots.json", json.dumps([["cobblestone", 1], ["ender_untagged", 2], ["ender_dock_tag", 3], ["ender_real_copy", 4]]))
    stale = os.path.join(c.disks, str(new), "probe_result.json")
    if os.path.exists(stale):
        os.remove(stale)
    c.set_slot(new, 0, "minecraft:cobblestone", 4)
    ctx.note("slot2 untagged: %s" % c.set_slot(new, 1, "enderstorage:ender_chest", 1))
    dock_tag = "{Frequency:{middle:0,left:0,right:0}}"
    ctx.note("slot3 dock tag: %s" % c.set_slot(new, 2, "enderstorage:ender_chest", 1, tag=dock_tag))
    if real_tag:
        ctx.note("slot4 verbatim copy of the real tag %s: %s" % (real_tag, c.set_slot(new, 3, "enderstorage:ender_chest", 1, tag=real_tag)))
    ctx.note("placer block data (no Items): %s" % no_items(c.block_data(c._pos(new))))
    if real:
        ctx.note("real turtle block data: %s" % no_items(c.block_data(comps[real[0]]["pos"])))
    c.turn_on([new])
    done = ctx.wait_until(lambda: result_of(c, new) is not None, 120, poll=3)
    ctx.expect(bool(done), "the placer finished its probe")
    for r in result_of(c, new) or []:
        ctx.note("placer %s: placed=%s nbt=%s tries=%s" % (r["label"], r.get("placed"), r.get("nbt"), r["tries"]))
        ctx.expect(bool(r.get("placed")), "placer variant %s placed (%s)" % (r["label"], r["tries"][0][3] if r["tries"] else "?"))

    # ---- the real turtle places its own chest ----
    if not real:
        return
    cid, slot = real[0], real[1]
    c.shutdown([cid])
    d = os.path.join(c.disks, str(cid))
    orig = os.path.join(d, "startup.lua")
    keep = os.path.join(ctx.run, "real_startup_%d.lua" % cid)
    shutil.copy(orig, keep)
    shutil.copy(probe, orig)
    write_disk(c, cid, "probe_slots.json", json.dumps([["real_own_chest", slot + 1]]))
    if os.path.exists(os.path.join(d, "probe_result.json")):
        os.remove(os.path.join(d, "probe_result.json"))
    ctx.interventions.append({"verb": "install_probe_on_real_turtle", "args": [repr(cid)], "kwargs": {"slot_lua": slot + 1},
                              "game_seconds": ctx.game_seconds()})
    c.turn_on([cid])
    done = ctx.wait_until(lambda: result_of(c, cid) is not None, 120, poll=3)
    ctx.expect(bool(done), "the real turtle #%d finished its probe" % cid)
    for r in result_of(c, cid) or []:
        ctx.note("real turtle %s: placed=%s nbt=%s tries=%s" % (r["label"], r.get("placed"), r.get("nbt"), r["tries"]))
        ctx.expect(bool(r.get("placed")), "real turtle #%d placed its own chest (%s)" % (cid, r["tries"][0][3] if r["tries"] else "?"))
    c.shutdown([cid])
    shutil.copy(keep, orig)
