"""Checks in real Minecraft what the simulator models but could not verify (assumptions.lua, 'unverified - needs the local test
server'): digging with a full inventory (the overflow lies on the ground; suck picks it up), falling blocks, and liquids.
Results go into the report notes and <run>/mechanics_results.json."""
import json
import os
import time

NAME = "probe_mechanics"
LUA = os.path.join(os.path.dirname(__file__), "..", "lua", "mechanics_probe.lua")


def steps(ctx):
    c = ctx.control
    raw = ctx._raw
    x, y, z = 136, 120, -200
    raw.command("fill %d %d %d %d %d %d minecraft:air" % (x - 4, y - 2, z - 10, x + 4, y + 6, z + 6))
    front = (x, y, z - 1)
    items = {i: ("minecraft:cobblestone", 64) for i in range(16)}
    new = c.spawn_turtle(x, y, z, "SUPPORT", right="minecraft:diamond_pickaxe", startup=os.path.abspath(LUA), fuel=20000, items=items)
    ctx.note("probe turtle is computer #%d, front cell %s" % (new, front))
    disk = os.path.join(ctx.run, "world", "computercraft", "computer", str(new))
    result = {}

    def go(step):
        with open(os.path.join(disk, "go_" + step), "w") as f:
            f.write("go")

    def read():
        try:
            with open(os.path.join(disk, "mech.json")) as f:
                return json.loads(f.read())
        except (OSError, ValueError):
            return {}

    def entity_count(pos, dist=2):
        out = raw.command("execute positioned %d %d %d if entity @e[type=minecraft:item,distance=..%d]" % (pos[0], pos[1], pos[2], dist))
        return 0 if "failed" in out else int("".join(ch for ch in out.split("count:")[-1] if ch.isdigit()) or 1)

    def block(pos, name):
        return "passed" in raw.command("execute if block %d %d %d %s" % (pos[0], pos[1], pos[2], name))

    # A: full inventory, stone in front
    raw.command("setblock %d %d %d minecraft:stone" % front)
    go("A")
    ctx.wait_until(lambda: "A_dig" in read(), 120, poll=3)
    time.sleep(2)
    result["A_dig"] = read().get("A_dig")
    result["A_item_entities_at_dug_cell"] = entity_count(front)
    result["A_full_slots_after"] = read().get("A_full_slots_after")
    ctx.note("A: dig with a full inventory -> %s; item entities lying near the dug cell: %s" % (result["A_dig"], result["A_item_entities_at_dug_cell"]))
    go("A2")
    ctx.wait_until(lambda: "A_suck_front" in read(), 120, poll=3)
    result["A_drop_front"] = read().get("A_drop_front")
    result["A_suck_front"] = read().get("A_suck_front")
    ctx.note("A: drop into the empty cell in front -> %s; suck -> %s" % (result["A_drop_front"], result["A_suck_front"]))

    # B: stone in front with gravel stacked above it
    raw.command("kill @e[type=minecraft:item,distance=..6]")
    raw.command("setblock %d %d %d minecraft:stone" % front)
    raw.command("setblock %d %d %d minecraft:gravel" % (front[0], front[1] + 1, front[2]))
    raw.command("setblock %d %d %d minecraft:gravel" % (front[0], front[1] + 2, front[2]))
    go("B")
    ctx.wait_until(lambda: "B_above_after" in read(), 120, poll=3)
    result["B_dig"] = read().get("B_dig")
    result["B_front_after"] = read().get("B_front_after")
    result["B_above_after"] = read().get("B_above_after")
    result["B_gravel_in_dug_cell_by_command"] = block(front, "minecraft:gravel")
    ctx.note("B: dig the stone under two gravel -> %s; 6 s later the cell in front is %s and the cell above it %s" % (
        result["B_dig"], result["B_front_after"], result["B_above_after"]))

    # C: a water source in front
    raw.command("fill %d %d %d %d %d %d minecraft:air" % (front[0] - 2, front[1] - 1, front[2] - 3, front[0] + 2, front[1] + 3, front[2]))   # not the turtle: it is one cell behind the front
    raw.command("setblock %d %d %d minecraft:water" % front)
    go("C")
    ctx.wait_until(lambda: "done" in read(), 120, poll=3)
    for k in ("C_detect", "C_inspect", "C_dig", "C_forward"):
        result[k] = read().get(k)
    ctx.note("C: water in front: detect %s, inspect %s, dig %s, forward %s" % (result["C_detect"], result["C_inspect"], result["C_dig"], result["C_forward"]))
    with open(os.path.join(ctx.run, "mechanics_results.json"), "w") as f:
        json.dump(result, f, indent=1)
    ctx.expect("done" in read(), "the mechanics probe ran to the end")
