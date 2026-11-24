"""W3, the card "SHAKEOUT blocker - payload-h: two turtles on one id (node_397) held the arrivals chain", layer 2.

T2 payload-h and payload-i: a hard kill in the restart burst left a moving turtle in two chunks, two computers with one id
(node_397; node_215 three times). The server's duplicate check (registry.dupCheck, 7af8311) and the reports a turtle sends
before its control loop runs (4d2617c) have unit tests but have never seen a real duplicate: none came up in payload-j.
Here we make one on purpose, as the crash does, in the real game:

  1. The ATC computer is placed (as in w3_atc_pair.py).
  2. An idle DELIVERY on its dock is copied with /clone to a free cell: the copy keeps the computer id, as the crash's copy
     did. Both run Turtle OS as node_N.
  3. CHECKS: the server raises NEEDS HANDS "duplicate_id: node_N heard at <dock> and <copy>" within 5 min, with both
     places; the ATC drops and refuses the id ("banned (duplicate id)"); node_N says PARKED; the next order goes to another
     pair; with the copy removed, the hold stays (a person clears it), and the original is still on its dock.

Pin the commit under test. Run at --tickrate 20: the check's windows are real-time epoch milliseconds."""
import datetime
import importlib.util
import os
import re
import tempfile

NAME = "w3_duplicate_id"
_spec = importlib.util.spec_from_file_location("w3_atc_pair", os.path.join(os.path.dirname(os.path.abspath(__file__)), "w3_atc_pair.py"))
_pair = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_pair)


def now_iso():
    return datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%S")


def steps(ctx):
    ctx.wait_registered(14, 300)
    c = ctx.control
    pin = getattr(ctx, "pin", None) or "HEAD"
    tmp = tempfile.mkdtemp(prefix="w3dup")

    # 1. The ATC computer.
    start = os.path.join(tmp, "atc_startup.lua")
    with open(start, "w", encoding="utf8", newline="\n") as f:
        f.write(_pair.show(pin, "atc.lua"))
    files = {name: _pair.show(pin, name) for name in _pair.ATC_FILES}
    files["role.txt"] = "atc"
    t_atc = now_iso()
    ax, ay, az = c.free_spot()
    aid = c.spawn_computer(ax, ay, az, start, files=files)
    ctx.note("ATC computer #%d at %d,%d,%d from %s" % (aid, ax, ay, az, pin))
    ctx.expect(bool(ctx.wait_until(lambda: [l for l in ctx.log_lines("ATC online") if l[:19] >= t_atc], 180)), "the ATC came online")
    ctx.wait_until(lambda: [l for l in ctx.log_lines("settled: rebuilt") if l[:19] >= t_atc], 120)

    # 2. An idle delivery on its dock, and its copy.
    def docked_delivery():
        for tid, t in (ctx.state().get("turtles") or {}).items():
            if (t.get("role") == "DELIVERY" and t.get("status") == "IDLE" and t.get("online")
                    and t.get("x") == t.get("dockX") and t.get("z") == t.get("dockZ") and not t.get("needsHands")):
                return tid, t
        return None
    pick = ctx.wait_until(docked_delivery, 300)
    ctx.expect(bool(pick), "an idle delivery on its dock to copy (%s)" % (pick[0] if pick else "none"))
    if not pick:
        return
    tid, t = pick
    cid = int(tid.split("_")[1])
    pos = (c.computers().get(cid) or {}).get("pos")
    ctx.expect(pos is not None, "%s is computer #%d at %s" % (tid, cid, pos))
    if pos is None:
        return
    tx, ty, tz = c.free_spot()
    if (tx, ty, tz) == (ax, ay, az):
        tx += 3
    t0 = now_iso()
    out = c.command("clone %d %d %d %d %d %d %d %d %d" % (pos + pos + (tx, ty, tz)))
    ctx.note("clone %s at %s to %d,%d,%d: %s" % (tid, pos, tx, ty, tz, out.strip()[:120]))
    c.turn_on([cid])
    both = [(cid_, e["pos"]) for cid_, e in c.computers().items() if cid_ == cid]
    ctx.note("computers with id %d after the clone: %s" % (cid, both))

    def since(needle):
        return [l for l in ctx.log_lines(needle) if l[:19] >= t0]

    # 3. The checks.
    hands = ctx.wait_until(lambda: [l for l in since("duplicate_id: %s heard at" % tid) if "NEEDS HANDS" in l], 300)
    ctx.expect(bool(hands), "NEEDS HANDS duplicate_id for %s within 5 min of the copy (%s)" % (tid, hands[:1] if hands else "nothing"))
    if hands:
        m = re.search(r"heard at (-?\d+),(-?\d+),(-?\d+) and (-?\d+),(-?\d+),(-?\d+)", hands[0])
        places = {tuple(int(v) for v in m.groups()[:3]), tuple(int(v) for v in m.groups()[3:])} if m else set()
        ctx.expect(len(places) == 2, "it names two places (%s)" % sorted(places))
        ctx.note("detected at %s, the copy made at %s" % (hands[0][:19], t0))
    ban = ctx.wait_until(lambda: [l for l in since("banned (duplicate id)") if tid in l], 120)
    ctx.expect(bool(ban), "the ATC dropped and refused the id (%s)" % (ban[:1] if ban else "nothing"))
    parked = ctx.wait_until(lambda: [l for l in since("PARKED: duplicate_id") if tid in l], 180)
    ctx.expect(bool(parked), "%s said it is parked (%d line(s))" % (tid, len(parked or [])))
    st = (ctx.state().get("turtles") or {}).get(tid) or {}
    ctx.expect(str(st.get("needsHands", "")).startswith("duplicate_id"), "/state shows %s needing hands: %s" % (tid, st.get("needsHands")))

    # One order: it must go to another pair.
    t1 = now_iso()
    dx, dy, dz = c.free_spot()
    if (dx, dy, dz) in ((ax, ay, az), (tx, ty, tz)):
        dz += 6
    ctx.dispatch("ORDER_DELIVERY", {"items": [{"name": "minecraft:cobblestone", "count": 16}],
                                    "destination": {"x": dx, "y": dy, "z": dz}})
    went = ctx.wait_until(lambda: [l for l in ctx.log_lines("Dispatched job_") if l[:19] >= t1], 300)
    ctx.expect(bool(went) and tid not in went[0], "the next order went to another pair (%s)" % (went[0][-90:] if went else "nothing"))

    # The copy removed: the hold stays for a person; the original is home.
    out = c.command("setblock %d %d %d air" % (tx, ty, tz))
    ctx.note("removed the copy at %d,%d,%d: %s" % (tx, ty, tz, out.strip()[:80]))
    ctx.wait_game(120)
    st = (ctx.state().get("turtles") or {}).get(tid) or {}
    ctx.expect(str(st.get("needsHands", "")).startswith("duplicate_id"), "the hold stays until a person clears it (%s)" % st.get("needsHands"))
    ctx.expect(st.get("x") == st.get("dockX") and st.get("z") == st.get("dockZ"),
               "the original %s is on its dock (%s,%s,%s)" % (tid, st.get("x"), st.get("y"), st.get("z")))
    if went:
        m = re.search(r"Dispatched (job_\d+)", went[0])
        if m:
            done = ctx.wait_until(lambda: [l for l in ctx.log_lines("Job complete: %s" % m.group(1)) if l[:19] >= t1], 2400)
            ctx.expect(bool(done), "that order completed (%s)" % m.group(1))
    c.shutdown([aid])
