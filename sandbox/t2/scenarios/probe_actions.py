"""Times turtle actions in real CC:Tweaked (spawns a probe turtle high above the base; run at tick rate 20) and writes the
results into the run report as notes and into <run>/probe_results.json. Used to check and replace the unverified action
times in sandbox/timings.lua (fidelity gap 4)."""
import json
import os
import time

NAME = "probe_actions"
LUA = os.path.join(os.path.dirname(__file__), "..", "lua", "action_probe.lua")


def steps(ctx):
    c = ctx.control
    # a clear column of sky above the base: nothing within 25 blocks around, 45 up
    x, y, z = 136, 120, -200
    ctx.note("probe turtle at %s" % ((x, y, z),))
    for dx, dy, dz in ((0, 0, -1), ):
        pass
    # stone in front (north), a chest below, free air everywhere else (the sky)
    ctx._raw.command("fill %d %d %d %d %d %d minecraft:air" % (x - 3, y - 2, z - 26, x + 3, y + 45, z + 26))
    ctx._raw.command("setblock %d %d %d minecraft:stone" % (x, y, z - 1))
    ctx._raw.command("setblock %d %d %d minecraft:chest" % (x, y - 1, z))
    # the donor code is irrelevant: the probe replaces the startup
    new = c.spawn_turtle(x, y, z, "SUPPORT", right="minecraft:diamond_pickaxe", startup=os.path.abspath(LUA), fuel=20000,
                         items={0: ("minecraft:cobblestone", 64)})
    ctx.note("probe turtle is computer #%d" % new)
    done = ctx.wait_until(lambda: "probe_results.json" in c.list_disk(new) and b'"done"' in c.read_disk(new, "probe_results.json"), 900, poll=15)
    ctx.expect(done, "the probe finished")
    data = json.loads(c.read_disk(new, "probe_results.json"))
    with open(os.path.join(ctx.run, "probe_results.json"), "w") as f:
        json.dump(data, f, indent=1)
    for k, v in sorted(data.items()):
        if isinstance(v, dict) and "per_ms" in v:
            ctx.note("%-14s %7.1f ms per call  (%d ok of %d)" % (k, v["per_ms"], v["ok"], v["n"]))
        elif isinstance(v, dict) or isinstance(v, str):
            ctx.note("%-14s %s" % (k, json.dumps(v)))
