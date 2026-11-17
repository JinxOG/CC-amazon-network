"""W3, 2026-11-17: layer 2 for the card "A turtle that handed its job back on STUCK carries on with the job when it can
move again" (56cd393), ONE pair. Sim w3_side_atc: blocked in the base, node_36 said STUCK and handed job_0035 back -- and
went on waiting to move forward, for a job no longer its own, telling its support "still coming" for 4 h. Now a turtle
whose job is handed back while blocked in the base gives way: the trip ends, a departure fails (its support is told) and
it goes home.

  1. The ATC is placed (as in w3_atc_pair.py); the arrivals side is force-loaded.
  2. THE FAULT: a turtle that is ON but runs nothing (a probe program that only sleeps) is placed in the departure lane
     W1 at 149,67,-2803 -- in the way, and nothing the ATC knows of: a live turtle a delivery cannot turn on or pass.
  3. One order; once the pair is known every other delivery and support is held.
  4. Once the delivery has given way and is home, the blocker is removed; the job, handed back, goes out again.
CHECKS (each with its evidence): the blocker stood in W1 and was ON (evidence); the delivery reported STUCK and handed
its job back (the fault reached it); it gave way; it went home; its support was home too and did not wait on; the
delivery did not carry on with the handed-back job; with the blocker gone the job completed; the ATC holds nothing at
the end; every registered turtle is on its dock. Pin the commit under test. 1x."""
import datetime
import importlib.util
import os
import re
import tempfile

NAME = "w3_stuck_gives_way"
DEST = {"x": 196, "y": 67, "z": -2761}
BLOCK = (149, 67, -2803)
_spec = importlib.util.spec_from_file_location("w3_atc_pair", os.path.join(os.path.dirname(os.path.abspath(__file__)), "w3_atc_pair.py"))
_pair = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_pair)


def now_iso():
    return datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%S")


def steps(ctx):
    ctx.wait_registered(14, 300)
    c = ctx.control
    pin = getattr(ctx, "pin", None) or "HEAD"
    tmp = tempfile.mkdtemp(prefix="w3stuck")
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
    ctx.expect("ITS JOB HANDED BACK, IT GIVES WAY" in _pair.show(pin, "turtle_base.lua"),
               "the pinned commit carries the give-way (the commit under test)")

    def since(needle, t):
        return [l for l in ctx.log_lines(needle) if l[:19] >= t]

    def by(lines, who):
        return [l for l in lines if ("[%s]" % who) in l or ("%s#" % who) in l]

    def server_done(j, t):
        return [l for l in since("Job complete: %s" % j, t) if "server#" in l and l.rstrip().endswith(j)] if j else []

    def docked(name):
        t = (ctx.state().get("turtles") or {}).get(name) or {}
        return t.get("dockX") is not None and t.get("x") == t.get("dockX") and t.get("z") == t.get("dockZ")

    # ── THE FAULT: a live turtle that never moves, in the departure lane ─────────────────────────────────────────
    probe = os.path.join(tmp, "blocker.lua")
    with open(probe, "w", encoding="utf8", newline="\n") as f:
        f.write("-- W3 t2 blocker: on, and does nothing\nwhile true do sleep(60) end\n")
    bid = c.spawn_turtle(BLOCK[0], BLOCK[1], BLOCK[2], "DELIVERY", facing="west", startup=probe)
    ctx.wait_game(5)
    st = c.computers().get(bid) or {}
    ctx.expect(st.get("on") is True and st.get("pos") == BLOCK,
               "a live blocker (computer #%d) stood in W1 at %s, on: the checks below have something to judge" % (bid, st.get("pos")))

    t1 = now_iso()
    ctx.dispatch("ORDER_DELIVERY", {"items": [{"name": "minecraft:cobblestone", "count": 16}], "destination": DEST})
    went = ctx.wait_until(lambda: [l for l in since("Dispatched job_", t1) if "[DELIVER]" in l], 900)
    mm = went and re.search(r"Dispatched (job_\d+) \[DELIVER\] -> (node_\d+)\s+support (job_\d+) -> (node_\d+)", went[0])
    ctx.expect(bool(mm), "a pair was dispatched (%s)" % (went[:1] if went else "nothing"))
    if not mm:
        return
    job, dname, sjob, sname = mm.groups()
    held = []
    for name, t in sorted((ctx.state().get("turtles") or {}).items()):
        if t.get("role") in ("DELIVERY", "SUPPORT") and name not in (dname, sname):
            ctx.dispatch("HOLD_TURTLE", {"turtleId": name, "reason": NAME})
            held.append(name)
    ctx.note("pair %s + %s; held the others: %s" % (dname, sname, held))

    stuck = ctx.wait_until(lambda: [l for l in by(since("STUCK", t1), dname) if "handing job" in l], 900)
    ctx.expect(bool(stuck), "%s reported STUCK and handed its job back (%s)" % (dname, stuck[0][-120:] if stuck else "it never did"))
    if not stuck:
        return
    tStuck = stuck[0][:19]
    gave = ctx.wait_until(lambda: by(since("giving way", tStuck), dname), 300)
    ctx.expect(bool(gave), "%s gave way (%s)" % (dname, gave[0][-110:] if gave else "it waited on"))
    home = ctx.wait_until(lambda: docked(dname), 600)
    ctx.expect(bool(home), "%s went home" % dname)
    shome = ctx.wait_until(lambda: docked(sname), 600)
    waitedOn = [l for l in by(since("Waiting for hole signal", tStuck), sname)]
    ctx.expect(bool(shome), "its support %s was home too (%d 'waiting for hole signal' after the STUCK)" % (sname, len(waitedOn)))

    # ── the way cleared: the handed-back job goes out again ─────────────────────────────────────────────────────
    tClear = now_iso()
    ctx.note("blocker removed: %s" % c.command("setblock %d %d %d air" % BLOCK).strip()[:80])
    done = ctx.wait_until(lambda: server_done(job, t1), 2400)
    ctx.expect(bool(done), "with the way clear, %s went out again and completed (the server's line)" % job)
    # Carrying on = leaving the depot after the STUCK for the job it handed back: any "Exited depot" / "At hole" of the
    # delivery before the job was dispatched to it again (if ever), to the end -- the way clearing is when it would.
    back = [l for l in since("Dispatched %s [DELIVER] -> %s" % (job, dname), tStuck)]
    carried = [l for l in by(since("Exited depot", tStuck), dname) + by(since("At hole", tStuck), dname)
               if not back or l[:23] < back[0][:23]]
    ctx.expect(not carried, "%s did not carry on with the job it handed back (%d: %s)"
               % (dname, len(carried), carried[0][-100:] if carried else "none"))

    for n in held:
        ctx.dispatch("RELEASE_TURTLE", {"turtleId": n})
    ctx.wait_game(120)
    markers = since("never staged in", t1) + since("Gave up after 120s", t1) + since("Partner silent", t1) \
        + [l for l in since("booking dropped", t1) if re.search(r"silent \d+s: booking dropped", l)]
    ctx.note("timer markers (the STUCK itself is the fault's own 160 s): %d %s" % (len(markers), markers[0][-110:] if markers else ""))
    last = (since("section(s) held", t1) or [""])[-1]
    ctx.expect(" 0 section(s) held" in last, "the ATC holds no section at the end (%s)" % last[-120:])
    turtles = ctx.state().get("turtles") or {}
    away = [n for n, t in turtles.items() if t.get("dockX") is not None and not (t.get("x") == t.get("dockX") and t.get("z") == t.get("dockZ"))]
    ctx.expect(turtles and not away, "every registered turtle is on its dock at the end (%d of %d not: %s)" % (len(away), len(turtles), away))
    c.shutdown([aid])
