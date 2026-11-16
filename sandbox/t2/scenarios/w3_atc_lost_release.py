"""W3, 2026-11-15: the stale return booking of T2 shakeout-side-c (pin 360d551), layer 2, ONE pair. node_208 docked during a
radio loss with its ATC_LEAVE / ATC_CANCEL lost; R2-R5 stayed booked to it while it asked for a departure, and 12 of 20
jammed behind it. Fix 12e394f: a new route lets the old one go (atc.lua); a RECALL during a trip home starts no second one.

  1. The ATC is placed (as in w3_atc_pair.py); the arrivals side is force-loaded; every other delivery is held.
  2. One delivery; once it is "Clear of arrivals hole" on its way home inside the base, 80% of the radio messages TO THE
     ATC are dropped for 240 s (the control mod's radio loss, channel CH_ATC, receiver the ATC): its gate asks repeat and
     get through, its one-off leaves and cancel are each lost four times in five.
  3. Once it has docked: the ATC still names it (the stale booking: evidence); then a second delivery is ordered, which only
     it can take.
CHECKS (each with its evidence count): the stale booking was there after it docked; once its second departure was let in,
the ATC no longer held any section of the old return for it; the second job completed; the ATC holds nothing at the end;
every registered turtle is on its dock. Pin the commit under test. 1x."""
import datetime
import importlib.util
import os
import re
import tempfile

NAME = "w3_atc_lost_release"
DEST = {"x": 196, "y": 67, "z": -2761}
_spec = importlib.util.spec_from_file_location("w3_atc_pair", os.path.join(os.path.dirname(os.path.abspath(__file__)), "w3_atc_pair.py"))
_pair = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_pair)

RETURN_SECTIONS = re.compile(r"\b(R\d|ARR)=(node_\d+)")


def now_iso():
    return datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%S")


def ch_atc(pin):
    m = re.search(r"CH_ATC\s*=\s*(\d+)", _pair.show(pin, "protocol.lua"))
    return int(m.group(1)) if m else None


def steps(ctx):
    ctx.wait_registered(14, 300)
    c = ctx.control
    pin = getattr(ctx, "pin", None) or "HEAD"
    tmp = tempfile.mkdtemp(prefix="w3lost")
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
    chan = ch_atc(pin)
    ctx.note("ATC computer #%d; CH_ATC %s" % (aid, chan))

    t0 = now_iso()

    def since(needle, t=None):
        return [l for l in ctx.log_lines(needle) if l[:19] >= (t or t0)]
    ctx.dispatch("ORDER_DELIVERY", {"items": [{"name": "minecraft:cobblestone", "count": 16}], "destination": DEST})
    went = ctx.wait_until(lambda: since("Dispatched job_"), 300)
    m = went and re.search(r"Dispatched (job_\d+) \[DELIVER\] -> (node_\d+)", went[0])
    ctx.expect(bool(m), "a delivery was dispatched (%s)" % (went[:1] if went else "nothing"))
    if not m:
        return
    job1, dname = m.group(1), m.group(2)
    held = []
    for name, t in sorted((ctx.state().get("turtles") or {}).items()):
        if t.get("role") == "DELIVERY" and name != dname:
            ctx.dispatch("HOLD_TURTLE", {"turtleId": name, "reason": "w3_atc_lost_release"})
            held.append(name)
    ctx.note("held the other deliveries: %s" % held)

    clear = ctx.wait_until(lambda: [l for l in since("Clear of arrivals hole") if dname in l], 3600)
    ctx.expect(bool(clear), "%s came up the arrivals hole on its way home (%s)" % (dname, clear[:1] if clear else "nothing"))
    if not clear:
        return
    t_drop = now_iso()
    # THE FAULT: 80% of what reaches the ATC is lost for 4 minutes. Its asks at each gate are repeated every second and
    # get through; a release (ATC_LEAVE, ATC_CANCEL) is sent once, so each is lost four times in five. All of it lost,
    # it would only wait at the next gate and send its cancel after the loss.
    reply = c.radio_loss(0, 240 * 1000, 0.8, channel=chan, to=aid)
    ctx.note("dropping 80%% of the messages to the ATC (#%d, channel %s) for 240 s: %s" % (aid, chan, reply))
    docked = ctx.wait_until(lambda: [l for l in since("Docked at bay", t_drop) if dname in l], 900)
    ctx.expect(bool(docked), "%s docked during or after the loss (%s)" % (dname, docked[:1] if docked else "nothing"))
    ctx.wait_until(lambda: False, max(0, 250 - int((datetime.datetime.now(datetime.timezone.utc)
                                                    - datetime.datetime.strptime(t_drop, "%Y-%m-%dT%H:%M:%S").replace(tzinfo=datetime.timezone.utc)).total_seconds())))
    ctx.wait_game(70)
    after = [l for l in since("section(s) held", t_drop)]
    stale = [l for l in after if dname in l]
    ctx.expect(bool(stale), "the ATC still named %s once it was home: the stale booking the checks below judge (%s)"
               % (dname, stale[-1][-160:] if stale else "no summary named it -- nothing to judge"))

    t2 = now_iso()
    ctx.dispatch("ORDER_DELIVERY", {"items": [{"name": "minecraft:cobblestone", "count": 16}], "destination": DEST})
    went2 = ctx.wait_until(lambda: [l for l in since("Dispatched job_", t2) if ("-> %s " % dname) in l], 600)
    ctx.expect(bool(went2), "the second delivery went to %s (%s)" % (dname, went2[:1] if went2 else "nothing"))
    m2 = went2 and re.search(r"Dispatched (job_\d+) \[DELIVER\] -> node_\d+\s+support (job_\d+)", went2[0])
    job2, sjob2 = (m2.group(1), m2.group(2)) if m2 else (None, None)
    admitted = ctx.wait_until(lambda: [l for l in since("admitted %s:" % dname, t2)], 900)
    ctx.wait_game(70)
    sums = [l for l in since("section(s) held", admitted[0][:19] if admitted else t2)]
    leftover = [l for l in sums[:2] if any(who == dname for _, who in RETURN_SECTIONS.findall(l))]
    ctx.expect(bool(admitted) and bool(sums) and not leftover,
               "once its departure was let in the ATC held no section of the old return for %s (%d summaries judged; %s)"
               % (dname, len(sums[:2]), leftover[0][-160:] if leftover else "none"))
    # The SERVER's "Job complete" lines, the delivery's and its support's: the warehouse logs "[WH] Job complete" as soon
    # as it has served the delivery, minutes before either is home (run a's end checks ran while the support came in).
    def server_done(j):
        return [l for l in since("Job complete: %s" % j, t2) if "server#" in l] if j else []
    done = ctx.wait_until(lambda: server_done(job2) and server_done(sjob2), 3600)
    ctx.expect(bool(done), "%s and its support's %s completed (the server's lines)" % (job2, sjob2))
    for n in held:
        ctx.dispatch("RELEASE_TURTLE", {"turtleId": n})
    ctx.wait_game(120)
    last = (since("section(s) held") or [""])[-1]
    ctx.expect(" 0 section(s) held" in last, "the ATC holds no section at the end (%s)" % last[-120:])
    turtles = ctx.state().get("turtles") or {}
    off = [n for n, t in turtles.items() if t.get("dockX") is not None and not (t.get("x") == t.get("dockX") and t.get("z") == t.get("dockZ"))]
    ctx.expect(turtles and not off, "every registered turtle is on its dock at the end (%d of %d not: %s)" % (len(off), len(turtles), off))
    c.shutdown([aid])
