"""W3 card "A refused move retries hundreds of times a second and floods the log" (fix 024587d), layer 2. Same story as
sandbox/scenarios/w3_fence_flood.lua. One turtle is spawned in the sky at x=276 (the w3_head_on column, its chunk
force-loaded for the run) with the fleet's code and a program that fences it in with a lease whose ceiling is its own
height, then asks to climb as fast as it can for 30 seconds -- the caller that spins on a refusal. Its program counts
every refusal and every 'refusing move' line it prints, and writes them to w3_result.txt. The fence must still refuse
every climb; the line must appear at most once per 10 s (so 4 at most), the repeat must say how many were held back, and
the half-second wait must keep the attempts to a few a second. On the code before the fix every attempt prints a line.
Pin 024587d or later. 1x, a few minutes."""
import os
import tempfile
import time

NAME = "w3_fence_flood"
X, Z, Y = 276, -2790, 160
FORCELOAD = (256, -2800, 296, -2780)
SECONDS = 30
# The loop yields with a queued event, not sleep(0): sleep takes a tick, which would cap the old code at 20 a second
# and hide the spin the card is about.
SCRIPT = '''local base = require("turtle_base")
base.gpsSync()
local p = base.getPos()
base.geofence.setLease(p.x - 16, p.z - 16, p.x + 15, p.z + 15, p.y)
local lines, refused, held = 0, 0, ""
local orig = print
print = function(...)
    local parts = {}
    for i = 1, select("#", ...) do parts[i] = tostring((select(i, ...))) end
    local s = table.concat(parts, " ")
    if s:find("refusing move", 1, true) then lines = lines + 1 end
    if s:find("held back", 1, true) then held = s end
    return orig(...)
end
local t0 = os.epoch("utc")
while os.epoch("utc") - t0 < %d do
    local ok, why = base.move.up()
    if not ok and why == "geofence_breach" then refused = refused + 1 end
    os.queueEvent("w3_spin"); os.pullEvent("w3_spin")
end
print = orig
local q = base.getPos()
local f = fs.open("w3_result.txt", "w")
f.write(string.format("%%d|%%d|%%d|%%d|%%s", refused, lines, os.epoch("utc") - t0, q.y or -1, held:gsub("|", "/")))
f.close()
''' % (SECONDS * 1000)


def steps(ctx):
    ctx.wait_registered(14, 300)
    c = ctx.control
    fx1, fz1, fx2, fz2 = FORCELOAD
    ctx.note("forceload: %s" % c.command("forceload add %d %d %d %d" % (fx1, fz1, fx2, fz2)))
    ctx.wait_game(3)
    for y in (Y, Y + 1):
        ctx.expect("passed" in c.command("execute if block %d %d %d minecraft:air" % (X, y, Z)), "the spot %d,%d,%d is air" % (X, y, Z))
    tmp = tempfile.mkdtemp(prefix="w3_fence_flood_")
    prog = os.path.join(tmp, "flood.lua")
    with open(prog, "w", encoding="utf-8", newline="\n") as f:
        f.write(SCRIPT)
    cid = c.spawn_turtle(X, Y, Z, "MINER", fuel=100000, startup=prog)       # THE TEST: climb into a ceiling, 30 s
    ctx.note("spawned #%d at %d,%d,%d under a lease ceiling of y=%d" % (cid, X, Y, Z, Y))

    def result():
        try:
            return c.read_disk(cid, "w3_result.txt").decode()
        except OSError:
            return None

    deadline = time.time() + 300
    while time.time() < deadline and not result():
        time.sleep(2)
    r = result()
    ctx.note("result (refused|lines|ms|y|held line): %s" % r)
    ctx.expect(bool(r), "the turtle finished its 30 s and wrote a result")
    if not r:
        c.shutdown([cid])
        return
    refused, lines, ms, y, held = r.split("|", 4)
    refused, lines, ms, y = int(refused), int(lines), int(ms), int(y)
    ctx.expect(y == Y, "the fence held: still at y=%d (y=%d)" % (Y, y))
    ctx.expect(refused >= 20, "the climb was refused again and again (%d refusals)" % refused)
    ctx.expect(lines <= SECONDS // 10 + 1, "but logged at most once per 10 s (%d 'refusing move' lines for %d refusals)" % (lines, refused))
    ctx.expect("identical refusal" in held, "and a later line says how many were held back (%r)" % held)
    rate = refused / (ms / 1000.0) if ms else 0
    ctx.expect(rate <= 3, "the repeat waits: %.1f attempts a second, not hundreds" % rate)
    c.shutdown([cid])
    c.command("forceload remove %d %d %d %d" % (fx1, fz1, fx2, fz2))
