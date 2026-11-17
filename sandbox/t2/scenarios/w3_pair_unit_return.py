"""W3, 2026-11-17: layer 2 for R2 and R3's return half of docs/superpowers/specs/2026-11-17-delivery-pair-and-hole-design.md,
ONE pair. R2: the pair's departure is admitted as one unit, both halves asking from their docks. R3: at the holding line the
support walks its delivery's own path up behind it, and RETURN_TO_DOCK is repeated until the support says it heard.

  1. The ATC is placed (as in w3_atc_pair.py); the arrivals side is force-loaded; once the pair is known every other
     delivery and support is held.
  2. PART 1 (R2): one order. The ATC must log the pair let in as one unit, and the delivery's wait at the hole is its
     support's walk.
  3. PART 2 (R3): the moment the delivery is called up from its holding slot, a total radio blackout for 60 s (every
     channel, every receiver): its first RETURN_TO_DOCK is lost. Its support must still come home behind it.
CHECKS (each with its evidence): the ATC let the pair in as one unit (evidence); the delivery waited at the hole under 60 s;
the come-home was lost (evidence: the delivery was called up and the loss started); the support never took its delivery
for gone nor found its own way home; the job completed; no jam cleared by a timer; the ATC holds nothing; every turtle is
on its dock. Pin the commit under test. 1x."""
import datetime
import importlib.util
import os
import re
import tempfile

NAME = "w3_pair_unit_return"
DEST = {"x": 196, "y": 67, "z": -2761}
_spec = importlib.util.spec_from_file_location("w3_atc_pair", os.path.join(os.path.dirname(os.path.abspath(__file__)), "w3_atc_pair.py"))
_pair = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_pair)


def now_iso():
    return datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%S")


def secs(l):
    return datetime.datetime.strptime(l[:23], "%Y-%m-%dT%H:%M:%S.%f")


def steps(ctx):
    ctx.wait_registered(14, 300)
    c = ctx.control
    pin = getattr(ctx, "pin", None) or "HEAD"
    tmp = tempfile.mkdtemp(prefix="w3unit")
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
    ctx.expect("HOME_HEARD" in proto_text and "admitted pair" in _pair.show(pin, "atc.lua"),
               "the pinned commit carries R2 and R3 (the commit under test)")
    m = re.search(r"CH_LOCAL\s*=\s*(\d+)", proto_text)
    ch_local = int(m.group(1)) if m else 5

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

    # ── PART 1: admitted as one unit ────────────────────────────────────────────────────────────────────────────
    asOne = ctx.wait_until(lambda: [l for l in since("admitted pair", t1) if dname in l and sname in l], 900)
    ctx.expect(bool(asOne), "the ATC let the pair in as one unit (%s)" % (asOne[0][-100:] if asOne else "nothing"))
    staged = ctx.wait_until(lambda: by(since("Support staged", t1), dname), 900)
    hole = by(since("At hole", t1), dname)
    wait = (secs(staged[0]) - secs(hole[0])).total_seconds() if (staged and hole) else None
    ctx.expect(wait is not None and wait < 60, "%s waited at the hole only for its support's walk (%s s)"
               % (dname, None if wait is None else int(wait)))

    # ── PART 2: the come-home lost ──────────────────────────────────────────────────────────────────────────────
    called = ctx.wait_until(lambda: by(since("Called up from holding slot", t1), dname), 2400, poll=2)
    ctx.expect(bool(called), "%s was called up from its holding slot (%s)" % (dname, called[:1] if called else "nothing"))
    if not called:
        return
    tLoss = now_iso()
    # A TOTAL RADIO BLACKOUT (SPEC-OWNER, 2026-11-17): every message on every channel lost for 60 s from the call-up --
    # the delivery's first RETURN_TO_DOCK with them, so its repeat-until-heard is exercised on the real game.
    reply = c.radio_loss(0, 60000, 1.0)
    ctx.note("a total radio blackout for 60 s from the call-up of %s: %s" % (dname, reply))
    done = ctx.wait_until(lambda: server_done(job, t1) and server_done(sjob, t1), 2400)
    gone = by(since("Partner silent", tLoss), sname)
    alone = by(since("retracing the", tLoss), sname) + by(since("way home is shut", tLoss), sname)
    ctx.expect(not gone, "%s never took its delivery for gone (%s)" % (sname, gone[0][-120:] if gone else "none"))
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
    off = [n for n, t in turtles.items() if t.get("dockX") is not None and not (t.get("x") == t.get("dockX") and t.get("z") == t.get("dockZ"))]
    ctx.expect(turtles and not off, "every registered turtle is on its dock at the end (%d of %d not: %s)" % (len(off), len(turtles), off))
    c.shutdown([aid])
