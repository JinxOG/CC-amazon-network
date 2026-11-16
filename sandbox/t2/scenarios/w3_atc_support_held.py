"""W3, 2026-11-16: the 160,-2752 turtle of T2 shakeout-side-c (pin aca0380), layer 2, ONE pair. A support waited 180 s for
HOLE_READY and gave up while the ATC still held its delivery at the dock; the delivery then went down alone -- without the
chunk loading its support carries -- and froze in ground nobody loads (11 times in 3 hours). The fix: the delivery says
"still coming" (HOLE_PENDING) every 20 s until HOLE_READY, and never goes out without its support; a job it gives up on
goes back, and the warehouse is told to drop it so the job's next holder is served.

  1. The ATC is placed (as in w3_atc_pair.py); the arrivals side is force-loaded; once the first pair is known every
     other delivery and support is held, so the same pair takes every try.
  2. PART 1: a holder computer takes crossing J1 (every departure needs it) through the ATC for 260 s, from just before
     the first order. The delivery waits over 180 s at its dock.
  3. PART 2: a second holder takes J1 on the delivery's next HOLE_READY and keeps it 720 s, longer than the delivery's
     600 s wait for its support at the hole. The delivery gives up -- and must not go out alone.
CHECKS (each with its evidence): part 1 -- the delivery was held over 180 s at its dock; its support did not give up;
nobody went down alone; they went down together; the job completed. Part 2 -- the delivery gave up waiting ("never
staged"); its support stood down; the delivery never went down the hole without its support; the job, sent again, was
served (no warehouse timeout, no stray recall) and completed. At the end the ATC holds nothing and every turtle is
on its dock. Pin the commit under test. 1x."""
import datetime
import importlib.util
import os
import re
import tempfile

NAME = "w3_atc_support_held"
DEST = {"x": 196, "y": 67, "z": -2761}
HOLD_A_S = 260
HOLD_B_S = 720
_spec = importlib.util.spec_from_file_location("w3_atc_pair", os.path.join(os.path.dirname(os.path.abspath(__file__)), "w3_atc_pair.py"))
_pair = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_pair)

# Holds J1 for HOLD_MS from the moment it starts, then lets it go.
HOLDER_NOW = r'''
local proto = require("protocol")
local m = peripheral.find("modem")
m.open(9999)
local n = 0
local function say(t, p) n = n + 1; p.nonce = n; proto.send(m, proto.CH_ATC, proto.encode(t, "node_hog_a", "atc", p)) end
local stop = os.epoch("utc") + HOLD_MS
while os.epoch("utc") < stop do say(proto.MSG.ATC_ENTER, { sec = "J1", route = {} }); sleep(20) end
say(proto.MSG.ATC_LEAVE, { sec = "J1" })
print("holder a: left J1")
while true do sleep(3600) end
'''.replace("HOLD_MS", str(HOLD_A_S * 1000))

# Waits for a HOLE_READY, then holds J1 for HOLD_MS (as w3_atc_partner_left.py).
HOLDER_ON_READY = r'''
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
local function say(t, p) n = n + 1; p.nonce = n; proto.send(m, proto.CH_ATC, proto.encode(t, "node_hog_b", "atc", p)) end
local stop = os.epoch("utc") + HOLD_MS
while os.epoch("utc") < stop do say(proto.MSG.ATC_ENTER, { sec = "J1", route = {} }); sleep(20) end
say(proto.MSG.ATC_LEAVE, { sec = "J1" })
print("holder b: left J1")
while true do sleep(3600) end
'''.replace("HOLD_MS", str(HOLD_B_S * 1000))


def now_iso():
    return datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%S")


def steps(ctx):
    ctx.wait_registered(14, 300)
    c = ctx.control
    pin = getattr(ctx, "pin", None) or "HEAD"
    tmp = tempfile.mkdtemp(prefix="w3held")
    ctx.note("forceload the arrivals side: %s" % c.command("forceload add 224 -2816 271 -2769").strip()[:100])
    start = os.path.join(tmp, "atc_startup.lua")
    with open(start, "w", encoding="utf8", newline="\n") as f:
        f.write(_pair.show(pin, "atc.lua"))
    files = {name: _pair.show(pin, name) for name in _pair.ATC_FILES}
    files["role.txt"] = "atc"
    t_atc = now_iso()
    spots = []

    def spot():
        x, y, z = c.free_spot()
        while (x, y, z) in spots:
            z += 3
        spots.append((x, y, z))
        return x, y, z
    aid = c.spawn_computer(*spot(), start, files=files)
    ctx.expect(bool(ctx.wait_until(lambda: [l for l in ctx.log_lines("settled: rebuilt") if l[:19] >= t_atc], 240)),
               "the ATC came online and settled")
    ctx.wait_until(lambda: len([l for l in ctx.log_lines("ATC heard") if l[:19] >= t_atc]) >= 10, 180)
    proto_text = _pair.show(pin, "protocol.lua")
    ctx.expect("HOLE_PENDING" in proto_text, "the pinned commit carries HOLE_PENDING (the commit under test)")

    def since(needle, t):
        return [l for l in ctx.log_lines(needle) if l[:19] >= t]

    def by(lines, who):
        return [l for l in lines if ("[%s]" % who) in l or ("%s#" % who) in l]

    def server_done(j, t):
        return [l for l in since("Job complete: %s" % j, t) if "server#" in l and l.rstrip().endswith(j)] if j else []

    # ── PART 1: held at the dock over 180 s ─────────────────────────────────────────────────────────────────────
    hstart = os.path.join(tmp, "holder_a.lua")
    with open(hstart, "w", encoding="utf8", newline="\n") as f:
        f.write(HOLDER_NOW)
    ha = c.spawn_computer(*spot(), hstart, files={"protocol.lua": proto_text})
    ctx.note("holder a #%d: holds J1 %d s from now" % (ha, HOLD_A_S))
    ctx.wait_game(15)
    t1 = now_iso()
    ctx.dispatch("ORDER_DELIVERY", {"items": [{"name": "minecraft:cobblestone", "count": 16}], "destination": DEST})
    went = ctx.wait_until(lambda: since("Dispatched job_", t1), 300)
    m = went and re.search(r"Dispatched (job_\d+) \[DELIVER\] -> (node_\d+)\s+support (job_\d+) -> (node_\d+)", went[0])
    ctx.expect(bool(m), "a delivery and its support were dispatched (%s)" % (went[:1] if went else "nothing"))
    if not m:
        return
    job1, dname, sjob1, sname = m.groups()
    held = []
    for name, t in sorted((ctx.state().get("turtles") or {}).items()):
        if t.get("role") in ("DELIVERY", "SUPPORT") and name not in (dname, sname):
            ctx.dispatch("HOLD_TURTLE", {"turtleId": name, "reason": NAME})
            held.append(name)
    ctx.note("pair %s + %s; held the others: %s" % (dname, sname, held))

    done1 = ctx.wait_until(lambda: server_done(job1, t1) and server_done(sjob1, t1), 3600)
    ctx.wait_game(60)
    waits = [l for l in by(since("Still waiting", t1), dname) if "ATC: departure" in l]
    longest = max([int(x) for x in (re.findall(r"Still waiting (\d+)s", " ".join(waits)) or ["0"])])
    ctx.expect(longest >= 180, "%s was held at its dock over 180 s by the ATC (longest wait %d s): the checks below have "
               "something to judge" % (dname, longest))
    gave = by(since("No HOLE_READY", t1), sname) + since("no_hole_ready_from_delivery", t1)
    ctx.expect(not gave, "%s did not give up on its delivery (%s)" % (sname, gave[0][-140:] if gave else "none"))
    alone = since("going down alone", t1) + since("not going out without", t1)
    ctx.expect(not alone, "nobody went out without its support (%s)" % (alone[0][-140:] if alone else "none"))
    joint = by(since("Support staged", t1), dname)
    ctx.expect(bool(joint), "%s and %s went down together (%d 'Support staged')" % (dname, sname, len(joint)))
    ctx.expect(bool(done1), "%s and its support's %s completed (the server's lines)" % (job1, sjob1))
    if not done1:
        return

    # ── PART 2: the support cannot reach the hole in 600 s ──────────────────────────────────────────────────────
    bstart = os.path.join(tmp, "holder_b.lua")
    with open(bstart, "w", encoding="utf8", newline="\n") as f:
        f.write(HOLDER_ON_READY)
    hb = c.spawn_computer(*spot(), bstart, files={"protocol.lua": proto_text})
    ctx.note("holder b #%d: holds J1 %d s from the next HOLE_READY" % (hb, HOLD_B_S))
    ctx.wait_game(15)
    t2 = now_iso()
    ctx.dispatch("ORDER_DELIVERY", {"items": [{"name": "minecraft:cobblestone", "count": 16}], "destination": DEST})
    went2 = ctx.wait_until(lambda: since("Dispatched job_", t2), 600)
    m2 = went2 and re.search(r"Dispatched (job_\d+) \[DELIVER\] -> (node_\d+)\s+support (job_\d+) -> (node_\d+)", went2[0])
    ctx.expect(bool(m2) and m2.group(2) == dname, "the second order went to the same pair (%s)" % (went2[:1] if went2 else "nothing"))
    if not m2:
        return
    job2 = m2.group(1)
    gaveUp = ctx.wait_until(lambda: by(since("never staged in", t2), dname), 1500)
    ctx.expect(bool(gaveUp), "%s gave up waiting for its support at the hole ('never staged'): the checks below have "
               "something to judge (%s)" % (dname, gaveUp[:1] if gaveUp else "nothing"))
    stood = ctx.wait_until(lambda: by(since("stood me down", t2), sname), 300)
    ctx.expect(bool(stood), "%s stood down (%s)" % (sname, stood[:1] if stood else "nothing"))
    done2 = ctx.wait_until(lambda: server_done(job2, t2), 4800)
    ctx.wait_game(120)
    # Each of the delivery's descents is the moment of a 'Support staged' (logged a moment before it), so: as many
    # descents as 'Support staged' lines, no more.
    desc = by(since("Descending dispatch hole", t2), dname)
    joint2 = by(since("Support staged", t2), dname)
    ctx.expect(len(desc) <= len(joint2), "%s never went down the hole without its support (%d descents, %d together)"
               % (dname, len(desc), len(joint2)))
    bad = [l for l in since("Job %s retry" % job2, t2) if "warehouse_chest_timeout" in l or ": recalled" in l]
    ctx.expect(not bad, "the job sent again was served, with no warehouse timeout or stray recall (%s)"
               % (bad[0][-120:] if bad else "none"))
    ctx.expect(bool(done2), "%s was delivered all the same (the server's 'Job complete')" % job2)

    for n in held:
        ctx.dispatch("RELEASE_TURTLE", {"turtleId": n})
    ctx.wait_game(120)
    last = (since("section(s) held", t1) or [""])[-1]
    ctx.expect(" 0 section(s) held" in last, "the ATC holds no section at the end (%s)" % last[-120:])
    turtles = ctx.state().get("turtles") or {}
    off = [n for n, t in turtles.items() if t.get("dockX") is not None and not (t.get("x") == t.get("dockX") and t.get("z") == t.get("dockZ"))]
    ctx.expect(turtles and not off, "every registered turtle is on its dock at the end (%d of %d not: %s)" % (len(off), len(turtles), off))
    c.shutdown([aid, ha, hb])
