"""W3, the card "TOP PRIORITY (shakeout blocker) - ATC x delivery/support deadlock at the dispatch hole", the second circle
(fix f942581), layer 2, ONE pair. Same story as sandbox/scenarios/w3_atc_support_gave_up.lua on the real game: before the
job a HOLDER computer takes crossing J1 through the ATC and keeps talking for 240 s, so the delivery waits to be let out
of its dock; its support gives up after 180 s without HOLE_READY and JOB_ABORTs it. The delivery must go down the hole
at once when it gets there, not wait 600 s for a support that has gone. Pin the commit under test. 1x."""
import datetime
import importlib.util
import os
import re
import tempfile

NAME = "w3_atc_support_gave_up"
HOLD_S = 240
_spec = importlib.util.spec_from_file_location("w3_atc_pair", os.path.join(os.path.dirname(os.path.abspath(__file__)), "w3_atc_pair.py"))
_pair = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_pair)

HOLDER = r'''
local proto = require("protocol")
local m = peripheral.find("modem")
m.open(9999)
local n = 0
local function say(t, p) n = n + 1; p.nonce = n; proto.send(m, proto.CH_ATC, proto.encode(t, "node_hog", "atc", p)) end
local stop = os.epoch("utc") + HOLD_MS
while os.epoch("utc") < stop do say(proto.MSG.ATC_ENTER, { sec = "J1", route = {} }); sleep(20) end
say(proto.MSG.ATC_LEAVE, { sec = "J1" })
print("holder: left J1")
while true do sleep(3600) end
'''.replace("HOLD_MS", str(HOLD_S * 1000))


def now_iso():
    return datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%S")


def secs(line):
    m = re.search(r"T(\d+):(\d+):([\d.]+)Z", line)
    return int(m.group(1)) * 3600 + int(m.group(2)) * 60 + float(m.group(3)) if m else None


def steps(ctx):
    ctx.wait_registered(14, 300)
    c = ctx.control
    pin = getattr(ctx, "pin", None) or "HEAD"
    tmp = tempfile.mkdtemp(prefix="w3gave")
    out = c.command("forceload add 224 -2816 271 -2769")
    ctx.note("forceload the arrivals side (chunks 14..16, -176..-174): %s" % out.strip()[:120])
    start = os.path.join(tmp, "atc_startup.lua")
    with open(start, "w", encoding="utf8", newline="\n") as f:
        f.write(_pair.show(pin, "atc.lua"))
    files = {name: _pair.show(pin, name) for name in _pair.ATC_FILES}
    files["role.txt"] = "atc"
    t_atc = now_iso()
    x, y, z = c.free_spot()
    aid = c.spawn_computer(x, y, z, start, files=files)
    ctx.expect(bool(ctx.wait_until(lambda: [l for l in ctx.log_lines("settled: rebuilt") if l[:19] >= t_atc], 240)),
               "the ATC came online and settled")
    ctx.wait_until(lambda: len([l for l in ctx.log_lines("ATC heard") if l[:19] >= t_atc]) >= 10, 180)

    hstart = os.path.join(tmp, "holder_startup.lua")
    with open(hstart, "w", encoding="utf8", newline="\n") as f:
        f.write(HOLDER)
    hx, hy, hz = c.free_spot()
    if (hx, hy, hz) == (x, y, z):
        hx += 3
    hid = c.spawn_computer(hx, hy, hz, hstart, files={"protocol.lua": _pair.show(pin, "protocol.lua")})
    ctx.note("holder computer #%d at %d,%d,%d holds J1 for %d s from now" % (hid, hx, hy, hz, HOLD_S))
    ctx.wait_game(10)

    dx, dy, dz = c.free_spot()
    if (dx, dy, dz) in ((x, y, z), (hx, hy, hz)):
        dz += 6
    t0 = now_iso()
    ctx.dispatch("ORDER_DELIVERY", {"items": [{"name": "minecraft:cobblestone", "count": 16}],
                                    "destination": {"x": dx, "y": dy, "z": dz}})

    def since(needle):
        return [l for l in ctx.log_lines(needle) if l[:19] >= t0]
    went = ctx.wait_until(lambda: since("Dispatched job_"), 300)
    m = went and re.search(r"Dispatched (job_\d+) \[DELIVER\] -> (node_\d+)\s+support (job_\d+) -> (node_\d+)", went[0])
    ctx.expect(bool(m), "a delivery and its support were dispatched (%s)" % (went[:1] if went else "nothing"))
    if not m:
        return
    job, dname, sjob, sname = m.group(1), m.group(2), m.group(3), m.group(4)
    gave = ctx.wait_until(lambda: [l for l in since("no_hole_ready_from_delivery") if sjob in l], 900)
    ctx.expect(bool(gave), "%s gave up waiting for HOLE_READY (%s): the checks below have something to judge"
               % (sname, gave[:1] if gave else "nothing"))
    done = ctx.wait_until(lambda: since("Job complete: %s" % job), 2400)
    heard = [l for l in since("gave up (") if dname in l]
    ctx.expect(bool(heard), "%s heard that its support gave up (%s)" % (dname, heard[:1] or "nothing"))
    at_hole = [l for l in since("At hole") if dname in l]
    down = [l for l in since("Descending dispatch hole") if dname in l]
    waited = (secs(down[0]) - secs(at_hole[0])) if at_hole and down else None
    ctx.expect(waited is not None and waited < 60, "%s did not wait at the hole for a support that had gone (%s s from "
               "'At hole' to 'Descending')" % (dname, waited))
    ctx.expect(bool(done), "%s completed" % job)
    ctx.wait_game(120)
    summaries = since("section(s) held")
    last = summaries[-1] if summaries else ""
    ctx.expect(bool(summaries) and "DH=" not in last, "nobody holds the dispatch hole at the end (%s)" % last[-120:])
    c.shutdown([hid, aid])
