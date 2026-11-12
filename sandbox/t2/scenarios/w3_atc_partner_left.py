"""W3, the card "TOP PRIORITY (shakeout blocker) - ATC x delivery/support deadlock at the dispatch hole" (fix 1a77441),
layer 2, ONE pair. Same story as sandbox/scenarios/w3_atc_partner_left.lua on the real game:

  1. The ATC computer is placed by the runner (as in w3_atc_pair.py); the arrivals side is force-loaded (the test world's
     chunk column x 224-239 does not tick: w3-chunk-tick-probe-b).
  2. A HOLDER computer listens to the turtles' local channel. On the delivery's HOLE_READY it steps into crossing J1
     through the ATC and KEEPS TALKING (so the ATC never sweeps it) for 720 s -- longer than the delivery's 600 s wait for
     its support -- then leaves J1. The support's way to the hole needs J1.
  3. So the delivery gives up and goes down alone. Its support must STAND DOWN: never go down the hole after it, and not
     hold the dispatch hole (DH). Before the fix the support went down after the delivery had gone and held DH for good.

Pin the commit under test. 1x: the ATC's timers are real-time epoch milliseconds. Lines are matched by their own
timestamps (the log files are not in arrival order)."""
import datetime
import importlib.util
import os
import re
import tempfile

NAME = "w3_atc_partner_left"
HOLD_S = 720
_spec = importlib.util.spec_from_file_location("w3_atc_pair", os.path.join(os.path.dirname(os.path.abspath(__file__)), "w3_atc_pair.py"))
_pair = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_pair)

HOLDER = r'''
local proto = require("protocol")
local m = peripheral.find("modem")
m.open(proto.CH_LOCAL)
m.open(9999)
while true do
  local _, _, ch, _, raw = os.pullEvent("modem_message")
  local msg = type(raw) == "table" and raw or textutils.unserialise(tostring(raw))
  if ch == proto.CH_LOCAL and type(msg) == "table" and msg.type == proto.MSG.HOLE_READY then break end
end
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


def steps(ctx):
    ctx.wait_registered(14, 300)
    c = ctx.control
    pin = getattr(ctx, "pin", None) or "HEAD"
    tmp = tempfile.mkdtemp(prefix="w3left")
    out = c.command("forceload add 224 -2816 271 -2769")
    ctx.note("forceload the arrivals side (chunks 14..16, -176..-174): %s" % out.strip()[:120])

    # 1. The ATC computer.
    start = os.path.join(tmp, "atc_startup.lua")
    with open(start, "w", encoding="utf8", newline="\n") as f:
        f.write(_pair.show(pin, "atc.lua"))
    files = {name: _pair.show(pin, name) for name in _pair.ATC_FILES}
    files["role.txt"] = "atc"
    t_atc = now_iso()
    x, y, z = c.free_spot()
    aid = c.spawn_computer(x, y, z, start, files=files)
    ctx.note("ATC computer #%d at %d,%d,%d from %s" % (aid, x, y, z, pin))
    ctx.expect(bool(ctx.wait_until(lambda: [l for l in ctx.log_lines("ATC online") if l[:19] >= t_atc], 180)), "the ATC came online")
    ctx.expect(bool(ctx.wait_until(lambda: [l for l in ctx.log_lines("settled: rebuilt") if l[:19] >= t_atc], 120)),
               "it settled and rebuilt")
    ctx.wait_until(lambda: len([l for l in ctx.log_lines("ATC heard") if l[:19] >= t_atc]) >= 10, 180)

    # 2. The holder.
    hstart = os.path.join(tmp, "holder_startup.lua")
    with open(hstart, "w", encoding="utf8", newline="\n") as f:
        f.write(HOLDER)
    hx, hy, hz = c.free_spot()
    if (hx, hy, hz) == (x, y, z):
        hx += 3
    hid = c.spawn_computer(hx, hy, hz, hstart, files={"protocol.lua": _pair.show(pin, "protocol.lua")})
    ctx.note("holder computer #%d at %d,%d,%d (holds J1 %d s after the HOLE_READY)" % (hid, hx, hy, hz, HOLD_S))

    # 3. One delivery: one pair.
    dx, dy, dz = c.free_spot()
    if (dx, dy, dz) in ((x, y, z), (hx, hy, hz)):
        dz += 6
    t0 = now_iso()
    ctx.dispatch("ORDER_DELIVERY", {"items": [{"name": "minecraft:cobblestone", "count": 16}],
                                    "destination": {"x": dx, "y": dy, "z": dz}})

    def since(needle):
        return [l for l in ctx.log_lines(needle) if l[:19] >= t0]
    went = ctx.wait_until(lambda: since("Dispatched job_"), 300)
    ctx.expect(bool(went), "the delivery was dispatched (%s)" % (went[:1] if went else "nothing"))
    if not went:
        return
    m = re.search(r"Dispatched (job_\d+) \[DELIVER\] -> (node_\d+)\s+support job_\d+ -> (node_\d+)", went[0])
    ctx.expect(bool(m), "with a support (%s)" % went[0][-90:])
    if not m:
        return
    job, dname, sname = m.group(1), m.group(2), m.group(3)

    alone = ctx.wait_until(lambda: [l for l in since("never staged in") if dname in l], 1200)
    ctx.expect(bool(alone), "%s gave up waiting for its support and went down alone (%s): the checks below have something "
               "to judge" % (dname, alone[:1] if alone else "nothing"))
    stood = ctx.wait_until(lambda: [l for l in since("went down without me") if sname in l], 300)
    ctx.expect(bool(stood), "%s stood down (%s)" % (sname, stood[:1] if stood else "nothing"))
    done = ctx.wait_until(lambda: since("Job complete: %s" % job), 2400)
    ctx.expect(bool(done), "%s completed, the delivery alone" % job)
    ctx.wait_game(120)
    descents = [l for l in since("Descending dispatch hole") if sname in l]
    holding = [l for l in since("holding position") if sname in l]
    ctx.expect(not descents and not holding, "%s never went down the hole after it (%d descents, %d 'holding position')"
               % (sname, len(descents), len(holding)))
    summaries = since("section(s) held")
    last = summaries[-1] if summaries else ""
    ctx.expect(bool(summaries) and "DH=" not in last, "nobody holds the dispatch hole at the end (last ATC summary: %s)"
               % last[-120:])
    t = (ctx.state().get("turtles") or {}).get(sname) or {}
    ctx.expect(t.get("x") == t.get("dockX") and t.get("z") == t.get("dockZ"),
               "%s is on its own dock (%s,%s,%s; dock %s,%s)" % (sname, t.get("x"), t.get("y"), t.get("z"),
                                                                 t.get("dockX"), t.get("dockZ")))
    c.shutdown([hid, aid])
