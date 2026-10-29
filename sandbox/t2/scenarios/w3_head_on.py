"""W3 card "Two turtles blocking each other for 120s fails the job permanently" (fix 8e32f82, live since 1.9.128), layer 2
with spawns (the plan the spec owner named, 2026-10-26). Same story as sandbox/scenarios/w3_head_on.lua. Two turtles are
spawned in one column in the sky at x=276 (outside the depot's no-dig margin; the chunk force-loaded for the run), 30
blocks apart, each with the fleet's code and a three-line program that calls base.move.to through the other's position:
one climbs, one descends. Each writes its result to w3_result.txt. Both must arrive, well inside the 120 s give-up; on
the code before the fix they wait 120 s and fail "blocked by turtle". Pin any build from 1.9.128 on. 1x, a few minutes."""
import os
import tempfile
import time

NAME = "w3_head_on"
X, Z, TOP, BOTTOM = 276, -2790, 160, 130
FORCELOAD = (256, -2800, 296, -2780)
SCRIPT = '''local base = require("turtle_base")
base.gpsSync()
local t0 = os.epoch("utc")
local ok, why = base.move.to(%d, %d, %d)
local p = base.getPos and base.getPos() or {}
local f = fs.open("w3_result.txt", "w")
f.write(string.format("%%s|%%s|%%s,%%s,%%s|%%d", tostring(ok), tostring(why), tostring(p.x), tostring(p.y), tostring(p.z), os.epoch("utc") - t0))
f.close()
'''


def steps(ctx):
    ctx.wait_registered(14, 300)
    c = ctx.control
    fx1, fz1, fx2, fz2 = FORCELOAD
    ctx.note("forceload: %s" % c.command("forceload add %d %d %d %d" % (fx1, fz1, fx2, fz2)))
    ctx.wait_game(3)
    for y in (TOP, BOTTOM):
        ctx.expect("passed" in c.command("execute if block %d %d %d minecraft:air" % (X, y, Z)), "the spot %d,%d,%d is air" % (X, y, Z))
    tmp = tempfile.mkdtemp(prefix="w3_head_on_")
    progs = {}
    for name, ty in (("down", BOTTOM), ("up", TOP)):
        path = os.path.join(tmp, name + ".lua")
        with open(path, "w", encoding="utf-8", newline="\n") as f:
            f.write(SCRIPT % (X, ty, Z))
        progs[name] = path
    down = c.spawn_turtle(X, TOP, Z, "MINER", fuel=100000, startup=progs["down"])    # THE TEST: one column,
    up = c.spawn_turtle(X, BOTTOM, Z, "MINER", fuel=100000, startup=progs["up"])     # one going each way
    ctx.note("spawned #%d at y=%d (descends) and #%d at y=%d (climbs)" % (down, TOP, up, BOTTOM))

    def result(cid):
        try:
            return c.read_disk(cid, "w3_result.txt").decode()
        except OSError:
            return None

    deadline = time.time() + 600
    while time.time() < deadline and not (result(down) and result(up)):
        time.sleep(2)
    rd, ru = result(down), result(up)
    ctx.note("descender: %s | climber: %s" % (rd, ru))
    ctx.expect(bool(rd) and rd.startswith("true|"), "the descender reached y=%d (%s)" % (BOTTOM, rd))
    ctx.expect(bool(ru) and ru.startswith("true|"), "the climber reached y=%d (%s)" % (TOP, ru))
    slow = max([int(r.rsplit("|", 1)[1]) for r in (rd, ru) if r and r.rsplit("|", 1)[1].isdigit()] or [0])
    ctx.expect(slow < 120000, "neither waited out the 120 s give-up (slowest %.1f s)" % (slow / 1000.0))
    c.shutdown([down, up])
    c.command("forceload remove %d %d %d %d" % (fx1, fz1, fx2, fz2))
