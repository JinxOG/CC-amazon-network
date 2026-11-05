"""W3, the ATC card: a delivery pair must not split at the dispatch hole (fix 4392dcb), layer 2, ONE pair (a delivery and
its support). Same story as sandbox/scenarios/w3_atc_pair_split.lua on the real game:

  1. The ATC computer is placed by the runner, as in w3_atc_pair.py.
  2. A second computer, the HOLDER, listens to the turtles' local channel. The moment it hears a delivery call its support
     to the hole (HOLE_READY) -- the delivery has just left crossing J1 behind -- it steps into J1 through the ATC and
     then says nothing, as a turtle that died there would. The ATC lets a silent holder go after 3 minutes; meanwhile the
     support's way to the hole (through J1) is held back.
  3. The delivery must WAIT for its support and go down with it ('Support staged'); the delivery completes; both dock;
     nobody's return home fails. Before the fix the delivery went down alone after 60 s and the support was stranded.

Pin the commit under test. 1x: the ATC's timers are real-time epoch milliseconds."""
import importlib.util
import os
import re
import tempfile

NAME = "w3_atc_pair_split"
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
  if ch == proto.CH_LOCAL and type(msg) == "table" and msg.type == proto.MSG.HOLE_READY then
    proto.send(m, proto.CH_ATC, proto.encode(proto.MSG.ATC_ENTER, "node_hog", "atc", { sec = "J1", route = {}, nonce = 1 }))
    print("holder: took J1 on " .. tostring(msg.from) .. "'s HOLE_READY")
    break
  end
end
while true do sleep(3600) end
'''


def steps(ctx):
    ctx.wait_registered(14, 300)
    c = ctx.control
    pin = getattr(ctx, "pin", None) or "HEAD"
    tmp = tempfile.mkdtemp(prefix="w3split")

    # THE ARRIVALS SIDE OF THE BASE DOES NOT RUN IN THIS WORLD COPY (w3-chunk-tick-probe-b, 2026-11-05): computers placed
    # at x 160, 200, 220 ran; at x 226 (chunk column 14, beside the arrivals hole) none started, at z -2786, -2795, -2801.
    # In runs -a and -b the delivery froze on stepping to 228,67,-2801 (no events at all for 180 s, then a fresh boot).
    # The simulator models the base as loaded to x 260; the holding line reaches x 256. Load chunks 14-16, z -176..-174.
    out = c.command("forceload add 224 -2816 271 -2769")
    ctx.note("forceload the arrivals side (chunks 14..16, -176..-174): %s" % out.strip()[:120])

    # 1. The ATC computer.
    start = os.path.join(tmp, "atc_startup.lua")
    with open(start, "w", encoding="utf8", newline="\n") as f:
        f.write(_pair.show(pin, "atc.lua"))
    files = {name: _pair.show(pin, name) for name in _pair.ATC_FILES}
    files["role.txt"] = "atc"
    online0 = len(ctx.log_lines("ATC online"))
    x, y, z = c.free_spot()
    aid = c.spawn_computer(x, y, z, start, files=files)
    ctx.note("ATC computer #%d at %d,%d,%d from %s" % (aid, x, y, z, pin))
    ctx.expect(bool(ctx.wait_until(lambda: len(ctx.log_lines("ATC online")) > online0, 180)), "the ATC came online")
    ctx.expect(bool(ctx.wait_until(lambda: ctx.log_lines("settled: rebuilt"), 120)), "it settled and rebuilt")
    ctx.wait_until(lambda: len(ctx.log_lines("ATC heard")) >= 10, 180)

    # 2. The holder, waiting for a HOLE_READY.
    hstart = os.path.join(tmp, "holder_startup.lua")
    with open(hstart, "w", encoding="utf8", newline="\n") as f:
        f.write(HOLDER)
    hx, hy, hz = c.free_spot()
    if (hx, hy, hz) == (x, y, z):
        hx += 3
    hid = c.spawn_computer(hx, hy, hz, hstart, files={"protocol.lua": _pair.show(pin, "protocol.lua")})
    ctx.note("holder computer #%d at %d,%d,%d" % (hid, hx, hy, hz))

    # 3. One delivery: one pair.
    item = "minecraft:cobblestone"
    dx, dy, dz = c.free_spot()
    if (dx, dy, dz) in ((x, y, z), (hx, hy, hz)):
        dz += 6
    sent0 = len(ctx.log_lines("Dispatched job_"))
    docked0 = len(ctx.log_lines("Docked at bay"))
    failed0 = len(ctx.log_lines("Return home failed"))
    ctx.dispatch("ORDER_DELIVERY", {"items": [{"name": item, "count": 16}], "destination": {"x": dx, "y": dy, "z": dz}})
    went = ctx.wait_until(lambda: ctx.log_lines("Dispatched job_")[sent0:], 300)
    ctx.expect(bool(went), "the delivery was dispatched (%s)" % (went[:1] if went else "nothing"))
    if not went:
        return
    m = re.search(r"Dispatched (job_\d+) \[DELIVER\] -> (node_\d+)\s+support job_\d+ -> (node_\d+)", went[0])
    ctx.expect(bool(m), "with a support (%s)" % went[0][-90:])
    if not m:
        return
    job, dname, sname = m.group(1), m.group(2), m.group(3)

    done = ctx.wait_until(lambda: ctx.log_lines("Job complete: %s" % job), 2400)
    held = 0
    for l in ctx.log_lines("departure waiting to be let in (busy at J1)"):
        if sname in l:
            s = re.search(r"Still waiting (\d+)s", l)
            held = max(held, int(s.group(1)) if s else 0)
    ctx.expect(held > 60, "%s was held back over 60 s by the silent holder of J1 (longest wait %d s): the check below has "
               "something to judge" % (sname, held))
    joint = [l for l in ctx.log_lines("Support staged") if dname in l]
    ctx.expect(bool(joint), "%s waited for its support and they went down together (%s)" % (dname, joint[:1]))
    ctx.expect(bool(done), "%s completed" % job)
    docked = {n: bool(ctx.wait_until(lambda n=n: [l for l in ctx.log_lines("Docked at bay")[docked0:] if n in l], 900)) for n in (dname, sname)}
    ctx.expect(all(docked.values()), "both docked (%s)" % docked)
    failed = ctx.log_lines("Return home failed")[failed0:]
    ctx.expect(not failed, "nobody's return home failed (%s)" % (failed[:1] or "none"))
    c.shutdown([hid, aid])
