"""W3, 2026-11-17: layer 2 for the pair-dropout fix (c86612d), ONE pair. Side-g on bfd5341 (SPEC-OWNER, 2026-11-17):
after the server crash node_212 and node_214 sat "waiting for partner" for about 30 min with the ATC holding 0 sections,
and 9 turtles waited "after an older request" for 13-30 min. The sim (w3_side_atc) traced it: the support's wait to be
let out with its delivery gave up in the outage (departure_failed: no_word_from_delivery), the server retried the
support's half ALONE, and the delivery, never told, asked "waiting for partner" from its dock for hours -- the oldest
waiter, it held the whole return line.

  1. The ATC is placed (as in w3_atc_pair.py); the arrivals side is force-loaded; once the pair is known every other
     delivery and support is held.
  2. The moment the delivery logs "Pair on" (both halves accepted), a total radio blackout for 200 s: the support hears
     nothing from its delivery for longer than its 180 s and gives up.
  3. The server must call the pair off and tell the delivery; the job goes back and is paired again (only this pair
     is free, so the same two turtles, from their docks).
CHECKS (each with its evidence): the blackout began at "Pair on" (evidence); the support gave up with
no_word_from_delivery (evidence: the fault happened); the server called the pair off; the delivery was told and left
the ATC's line (no "waiting for partner" after the call-off); the job was paired again and completed; the ATC holds
nothing at the end; every turtle is on its dock. Pin the commit under test. 1x."""
import datetime
import importlib.util
import os
import re
import tempfile

NAME = "w3_pair_dropout"
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
    tmp = tempfile.mkdtemp(prefix="w3drop")
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
    server_text = _pair.show(pin, "central_server.lua")
    ctx.expect("(support half) failed" in server_text and "HALF A PAIR IS AHEAD OF NOBODY" in _pair.show(pin, "atc.lua"),
               "the pinned commit carries the pair-dropout fix (the commit under test)")

    def since(needle, t):
        return [l for l in ctx.log_lines(needle) if l[:19] >= t]

    def by(lines, who):
        return [l for l in lines if ("[%s]" % who) in l or ("%s#" % who) in l]

    def server_done(j, t):
        return [l for l in since("Job complete: %s" % j, t) if "server#" in l and l.rstrip().endswith(j)] if j else []

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

    # ── THE FAULT: a blackout from "Pair on", longer than the support's 180 s ────────────────────────────────────
    on = ctx.wait_until(lambda: by(since("Pair on", t1), dname), 600, poll=1)
    ctx.expect(bool(on), "%s logged 'Pair on' (%s)" % (dname, on[0][-80:] if on else "nothing"))
    if not on:
        return
    tLoss = now_iso()
    reply = c.radio_loss(0, 200000, 1.0)
    ctx.note("a total radio blackout for 200 s from 'Pair on' of %s: %s" % (dname, reply))
    gave = ctx.wait_until(lambda: [l for l in by(since("no_word_from_delivery", tLoss), sname)], 600)
    ctx.expect(bool(gave), "%s gave up on its silent delivery: the fault happened (%s)"
               % (sname, gave[0][-110:] if gave else "it never did -- this run cannot judge the fix"))
    off = ctx.wait_until(lambda: [l for l in since("off before it moved", tLoss) if job in l], 600)
    ctx.expect(bool(off), "the server called the pair off (%s)" % (off[0][-120:] if off else "nothing"))
    tOff = off[0][:19] if off else now_iso()
    done = ctx.wait_until(lambda: server_done(job, t1), 2400)
    ctx.expect(bool(done), "%s was paired again and completed (the server's line)" % job)
    stuck = [l for l in by(since("waiting for partner", tOff), dname)]
    redo = [l for l in since("Dispatched %s [DELIVER]" % job, tOff)]
    # A wait for partner AFTER the job went out again is the new pair's own short wait; before it, the stall.
    stall = [l for l in stuck if not redo or l[:23] < redo[0][:23]]
    ctx.expect(not stall, "%s did not wait for its gone partner after the call-off (%d: %s)"
               % (dname, len(stall), stall[0][-120:] if stall else "none"))
    retried = [l for l in since("Job %s retry" % sjob, tLoss)]
    ctx.expect(not retried, "the support's half was never retried alone (%s)" % (retried[0][-100:] if retried else "none"))

    for n in held:
        ctx.dispatch("RELEASE_TURTLE", {"turtleId": n})
    ctx.wait_game(120)
    markers = since("never staged in", t1) + since("Gave up after 120s", t1) + since("Partner silent", t1) \
        + [l for l in since("booking dropped", t1) if re.search(r"silent \d+s: booking dropped", l)]
    ctx.expect(not markers, "no jam was cleared by a timer (%d: %s)" % (len(markers), markers[0][-120:] if markers else "none"))
    last = (since("section(s) held", t1) or [""])[-1]
    ctx.expect(" 0 section(s) held" in last, "the ATC holds no section at the end (%s)" % last[-120:])
    turtles = ctx.state().get("turtles") or {}
    away = [n for n, t in turtles.items() if t.get("dockX") is not None and not (t.get("x") == t.get("dockX") and t.get("z") == t.get("dockZ"))]
    ctx.expect(turtles and not away, "every registered turtle is on its dock at the end (%d of %d not: %s)" % (len(away), len(turtles), away))
    c.shutdown([aid])
