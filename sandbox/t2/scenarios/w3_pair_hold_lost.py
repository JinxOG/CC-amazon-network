"""W3, 2026-11-17: layer 2 for the repeated hold notice (10f92a7), ONE pair; the T2 twin of the sim w3_pair_hold_lost.
T2 shakeout-side-h on 2272d671: after the server crash node_211 reached holding slot 11 and sent its support the hold
notice (ASCENDING: its slot and its path) ONCE, and it was lost. node_219 stood 8.5 min in another pair's path (it held
node_221 120 s), and told to come home planned its own way from 6 cells off, into rock, and retraced 158 steps.

  1. The ATC is placed (as in w3_atc_pair.py); the arrivals side is force-loaded; once the pair is known every other
     delivery and support is held.
  2. THE FAULT: on its way back, once the delivery is underground within 40 cells of the holding line, everything on the
     turtles' local channel that would reach its support is lost, until the delivery stands in its slot (its place in
     line logged) plus 3 s. The support lags where the loss began and never hears the first hold notice.
CHECKS (each with its evidence): the support lagged and the loss covered the delivery's arrival in its slot (evidence);
the support came up behind its delivery along its path ("Walked ... of my delivery's path"); it never had to find its own
way home (no "way home is shut", no retrace); the job completed; no jam was cleared by a timer; the ATC holds nothing at
the end; every registered turtle is on its dock. Pin the commit under test. 1x."""
import datetime
import importlib.util
import os
import re
import tempfile

NAME = "w3_pair_hold_lost"
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
    tmp = tempfile.mkdtemp(prefix="w3hold")
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
    ctx.expect("THE HOLD NOTICE IS REPEATED TOO" in _pair.show(pin, "turtle_base.lua"),
               "the pinned commit carries the repeated hold notice (the commit under test)")
    m = re.search(r"CH_LOCAL\s*=\s*(\d+)", proto_text)
    ch_local = int(m.group(1)) if m else 5

    def since(needle, t):
        return [l for l in ctx.log_lines(needle) if l[:19] >= t]

    def by(lines, who):
        return [l for l in lines if ("[%s]" % who) in l or ("%s#" % who) in l]

    def server_done(j, t):
        return [l for l in since("Job complete: %s" % j, t) if "server#" in l and l.rstrip().endswith(j)] if j else []

    def pos(name):
        t = (ctx.state().get("turtles") or {}).get(name) or {}
        return t.get("x"), t.get("y"), t.get("z")

    t1 = now_iso()
    ctx.dispatch("ORDER_DELIVERY", {"items": [{"name": "minecraft:cobblestone", "count": 16}], "destination": DEST})
    went = ctx.wait_until(lambda: [l for l in since("Dispatched job_", t1) if "[DELIVER]" in l], 900)
    mm = went and re.search(r"Dispatched (job_\d+) \[DELIVER\] -> (node_\d+)\s+support (job_\d+) -> (node_\d+)", went[0])
    ctx.expect(bool(mm), "a pair was dispatched (%s)" % (went[:1] if went else "nothing"))
    if not mm:
        return
    job, dname, sjob, sname = mm.groups()
    scid = int(sname.replace("node_", ""))
    held = []
    for name, t in sorted((ctx.state().get("turtles") or {}).items()):
        if t.get("role") in ("DELIVERY", "SUPPORT") and name not in (dname, sname):
            ctx.dispatch("HOLD_TURTLE", {"turtleId": name, "reason": NAME})
            held.append(name)
    ctx.note("pair %s + %s; held the others: %s" % (dname, sname, held))

    # ── THE FAULT: the support hears nothing for the delivery's last stretch to its slot ───────────────────────────
    delivered = ctx.wait_until(lambda: by(since("All items received", t1), dname), 1800)
    ctx.expect(bool(delivered), "%s delivered and turned for home" % dname)
    if not delivered:
        return

    def near():
        x, y, _ = pos(dname)
        return y == 60 and x is not None and x >= 216 and not by(since("Return: ", t1), dname)
    ok_near = ctx.wait_until(near, 900, poll=1)
    ctx.expect(bool(ok_near), "%s came back underground within 40 cells of the holding line (%s)" % (dname, pos(dname)))
    if not ok_near:
        return
    tLoss = now_iso()
    lagAt = pos(sname)
    ctx.note("loss to %s on channel %d from %s: %s" % (sname, ch_local, lagAt, c.radio_loss(0, 300000, 1.0, channel=ch_local, to=scid)))
    # In its slot: it logs its place in line only when it has to wait, so "Called up" (it reached the slot and left it)
    # counts too (w3-pair-hold-lost-a: called up at once, its "Return:" never came and the loss ran its full 300 s).
    inSlot = ctx.wait_until(lambda: by(since("Return: ", tLoss), dname) + by(since("Called up from holding slot", tLoss), dname),
                            600, poll=1)
    ctx.wait_game(3)
    ctx.note("loss cleared: %s" % c.radio_clear())
    dp, sp = pos(dname), pos(sname)
    apart = (abs(dp[0] - sp[0]) + abs(dp[2] - sp[2])) if None not in (dp[0], dp[2], sp[0], sp[2]) else None
    ctx.expect(bool(inSlot) and apart is not None and apart > 3,
               "%s lagged at %s while %s reached its slot under the loss: the checks below have something to judge (%s cells apart)"
               % (sname, lagAt, dname, apart))
    done = ctx.wait_until(lambda: server_done(job, t1) and server_done(sjob, t1), 2400)
    walked = by(since("of my delivery's path", tLoss), sname)
    ctx.expect(bool(walked), "%s came up behind its delivery along its path (%s)" % (sname, walked[0][-100:] if walked else "it did not"))
    alone = by(since("retracing the", tLoss), sname) + by(since("way home is shut", tLoss), sname)
    ctx.expect(not alone, "%s never had to find its own way home (%s)" % (sname, alone[0][-120:] if alone else "none"))
    ctx.expect(bool(done), "%s and %s completed (the server's lines)" % (job, sjob))

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
