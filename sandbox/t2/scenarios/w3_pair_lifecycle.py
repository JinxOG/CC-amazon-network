"""W3, 2026-11-17: layer 2 for R1, R2 and R4 of docs/superpowers/specs/2026-11-17-delivery-pair-and-hole-design.md, ONE pair.
The user's rules: one pair in the dispatch hole at a time; a pair leaves only when both are home and have accepted; it
keeps together; a jam that only a timer clears is a failure.

  1. The ATC is placed (as in w3_atc_pair.py); the arrivals side is force-loaded; once the pair is known every other
     delivery and support is held, so the same pair takes every order.
  2. PART A (R4 -- side-e jam 2 began this way): while the delivery is up at its destination and its support holds
     below it, the server computer is shut down 90 s, and every message TO THE SUPPORT on the turtles' local channel
     is lost for 60 s (its delivery's DESCENDED among them, sent once). The pair must keep together.
  3. PART B (R1 -- side-e jam 1): a second order; once the support is following its delivery out, that job is
     cancelled and a third order is placed at once. The only support the server could offer is the one still out.
CHECKS (each with its evidence): A -- the server was down and the support's messages lost while it held (evidence);
the support never took its delivery for gone nor found its own way home; the job completed. B -- the third order came
while its only support was still out (evidence); it was not paired until that support was home; no delivery waited
at the hole for a support that never staged; the third order completed. At the end: no jam cleared by a timer
("never staged", "Gave up after 120s", "silent ... booking dropped", "Partner silent"), the ATC holds nothing,
every turtle is on its dock. Pin the commit under test. 1x."""
import datetime
import importlib.util
import os
import re
import tempfile

NAME = "w3_pair_lifecycle"
DEST = {"x": 196, "y": 67, "z": -2761}
_spec = importlib.util.spec_from_file_location("w3_atc_pair", os.path.join(os.path.dirname(os.path.abspath(__file__)), "w3_atc_pair.py"))
_pair = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_pair)


def now_iso():
    return datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%S")


def steps(ctx):
    ctx.wait_registered(14, 300)
    c = ctx.control
    pin = getattr(ctx, "pin", None) or "HEAD"
    tmp = tempfile.mkdtemp(prefix="w3life")
    ctx.note("forceload the arrivals side: %s" % c.command("forceload add 224 -2816 271 -2769").strip()[:100])
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
    proto_text = _pair.show(pin, "protocol.lua")
    ctx.expect("PAIR_GO" in proto_text and "PAIR_ALIVE" in proto_text, "the pinned commit carries R1 and R4 (the commit under test)")
    m = re.search(r"CH_LOCAL\s*=\s*(\d+)", proto_text)
    ch_local = int(m.group(1)) if m else 5
    server = next((i for i in sorted(c.computers()) if (c.role_of(i) or "").strip().upper() == "SERVER"), None)
    ctx.expect(server is not None, "the server computer is found (#%s)" % server)

    def since(needle, t):
        return [l for l in ctx.log_lines(needle) if l[:19] >= t]

    def by(lines, who):
        return [l for l in lines if ("[%s]" % who) in l or ("%s#" % who) in l]

    def server_done(j, t):
        return [l for l in since("Job complete: %s" % j, t) if "server#" in l and l.rstrip().endswith(j)] if j else []

    def dispatch(t):
        went = ctx.wait_until(lambda: [l for l in since("Dispatched job_", t) if "[DELIVER]" in l], 900)
        mm = went and re.search(r"Dispatched (job_\d+) \[DELIVER\] -> (node_\d+)\s+support (job_\d+) -> (node_\d+)", went[0])
        return (mm.groups(), went[0]) if mm else (None, None)

    # ── PART A: a server crash and lost messages while the pair is out ──────────────────────────────────────────
    tA = now_iso()
    ctx.dispatch("ORDER_DELIVERY", {"items": [{"name": "minecraft:cobblestone", "count": 16}], "destination": DEST})
    got, line = dispatch(tA)
    ctx.expect(bool(got), "a pair was dispatched (%s)" % line)
    if not got:
        return
    jobA, dname, sjobA, sname = got
    held = []
    for name, t in sorted((ctx.state().get("turtles") or {}).items()):
        if t.get("role") in ("DELIVERY", "SUPPORT") and name not in (dname, sname):
            ctx.dispatch("HOLD_TURTLE", {"turtleId": name, "reason": NAME})
            held.append(name)
    ctx.note("pair %s + %s; held the others: %s" % (dname, sname, held))
    holding = ctx.wait_until(lambda: by(since("holding position", tA), sname), 1800, poll=2)
    ctx.expect(bool(holding), "%s held below %s while it delivered (%s)" % (sname, dname, holding[:1] if holding else "nothing"))
    if not holding or server is None:
        return
    sid = int(sname.split("_")[1])             # on the test server a turtle's node id is its computer id
    tFault = now_iso()
    reply = c.radio_loss(0, 60000, 1.0, channel=ch_local, to=sid)
    c.shutdown([server])
    ctx.note("server #%d shut down; every message to #%d on channel %d lost for 60 s: %s" % (server, sid, ch_local, reply))
    ctx.wait_game(90)
    c.turn_on([server])
    doneA = ctx.wait_until(lambda: server_done(jobA, tA), 2400)
    gone = by(since("Partner silent", tFault), sname) + by(since("Partner offline", tFault), sname)
    alone = by(since("retracing the", tFault), sname) + by(since("way home is shut", tFault), sname)
    ctx.expect(bool(since("online", tFault)), "the server came back (evidence that it was down)")
    ctx.expect(not gone, "%s never took its delivery for gone (%s)" % (sname, gone[0][-120:] if gone else "none"))
    ctx.expect(not alone, "%s never had to find its own way home (%s)" % (sname, alone[0][-120:] if alone else "none"))
    ctx.expect(bool(doneA), "%s completed (the server's line)" % jobA)

    # ── PART B: a support offered while still out ────────────────────────────────────────────────────────────────
    tB = now_iso()
    ctx.dispatch("ORDER_DELIVERY", {"items": [{"name": "minecraft:cobblestone", "count": 16}], "destination": DEST})
    gotB, lineB = dispatch(tB)
    ctx.expect(bool(gotB) and gotB[3] == sname, "the second order went to the same pair (%s)" % lineB)
    if not gotB:
        return
    jobB = gotB[0]
    following = ctx.wait_until(lambda: by(since("Following node_", tB), sname), 1200, poll=2)
    ctx.expect(bool(following), "%s was out, following (%s)" % (sname, following[:1] if following else "nothing"))
    tC = now_iso()
    ctx.dispatch("CANCEL_JOB", {"jobId": jobB})
    ctx.dispatch("ORDER_DELIVERY", {"items": [{"name": "minecraft:cobblestone", "count": 16}], "destination": DEST})
    gotC, lineC = dispatch(tC)
    jobC = gotC and gotC[0]
    ctx.expect(bool(gotC), "the third order was dispatched (%s)" % lineC)
    doneC = ctx.wait_until(lambda: server_done(jobC, tC), 3600) if jobC else None
    # Paired only once home: the support's first "Docked" after the third order's dispatch comes before it departs.
    tDisp = lineC[:23] if lineC else tC
    docked = [l for l in by(since("Docked at bay", tC), sname) if l[:23] > tDisp]
    departed = [l for l in by(since("Departing via dispatch lane", tC), sname) if l[:23] > tDisp]
    early = bool(docked) and (not departed or docked[0][:23] < departed[0][:23])
    ctx.expect(not early, "%s was not paired until it was home (%s)" % (sname, docked[0][-80:] if early else "docked before it was paired"))
    staged = since("never staged in", tC)
    ctx.expect(not staged, "no delivery waited at the hole for a support that never staged (%s)" % (staged[0][-120:] if staged else "none"))
    ctx.expect(bool(doneC), "%s completed (the server's line)" % jobC)

    for n in held:
        ctx.dispatch("RELEASE_TURTLE", {"turtleId": n})
    ctx.wait_game(120)
    markers = [l for l in since("never staged in", tA) + since("Gave up after 120s", tA) + since("Partner silent", tA)
               if True] + [l for l in since("booking dropped", tA) if re.search(r"silent \d+s: booking dropped", l)]
    ctx.expect(not markers, "no jam was cleared by a timer (%d: %s)" % (len(markers), markers[0][-120:] if markers else "none"))
    last = (since("section(s) held", tA) or [""])[-1]
    ctx.expect(" 0 section(s) held" in last, "the ATC holds no section at the end (%s)" % last[-120:])
    turtles = ctx.state().get("turtles") or {}
    off = [n for n, t in turtles.items() if t.get("dockX") is not None and not (t.get("x") == t.get("dockX") and t.get("z") == t.get("dockZ"))]
    ctx.expect(turtles and not off, "every registered turtle is on its dock at the end (%d of %d not: %s)" % (len(off), len(turtles), off))
    c.shutdown([aid])
