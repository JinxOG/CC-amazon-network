"""W3, the card "SHAKEOUT blocker - 1x side test: the base gridlocks at the ATC after an ATC crash and after radio loss"
(2026-11-14), layer 2, ONE pair. Same story as sandbox/scenarios/w3_depart_off_dock.lua on the real game, then the side
test's two ATC faults while that pair is in the base.

T2 shakeout-side-a: node_208 timed out waiting for the warehouse at its destination, was given the job straight back and
began it with a departure from where it stood; the route assumes the dock, so it drove through the support rows into a
parked turtle and held the outbound route for 50 minutes (the gridlock seen after the ATC crash). node_210, given its job
back inside the dispatch shaft, drove up into its own support (the gridlock after the radio blackout).

  1. The ATC is placed (as in w3_atc_pair.py); the arrivals side is force-loaded.
  2. One delivery to 196,67,-2761 (the side test's destination, south of the base); every other delivery is held, so the
     job can only come back to it; the warehouse computer is switched off, so it times out there.
  3. When the job comes back to it: the warehouse back on, and the ATC crashed for 2 minutes while the delivery heads home
     through the base; then a total radio blackout for 5 minutes.
CHECKS (each with its evidence count): the job came back while it was away from its dock; it went home first and was never
held by a turtle after; the job completed; the ATC came back and settled; after the blackout nobody reported STUCK, the ATC
holds no section, and every registered turtle is on its dock. Pin the commit under test. 1x."""
import datetime
import importlib.util
import os
import re
import tempfile

from shakeout import schedule  # noqa: E402  (sandbox/t2 is on the path: the runner put it there)

NAME = "w3_depart_off_dock"
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
    tmp = tempfile.mkdtemp(prefix="w3offdock")
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
    wid = schedule._role_computer(c, "WAREHOUSE")
    ctx.note("ATC computer #%d; warehouse computer #%d" % (aid, wid))

    t0 = now_iso()

    def since(needle, t=None):
        return [l for l in ctx.log_lines(needle) if l[:19] >= (t or t0)]
    ctx.dispatch("ORDER_DELIVERY", {"items": [{"name": "minecraft:cobblestone", "count": 16}], "destination": DEST})
    went = ctx.wait_until(lambda: since("Dispatched job_"), 300)
    m = went and re.search(r"Dispatched (job_\d+) \[DELIVER\] -> (node_\d+)(?:\s+support job_\d+ -> (node_\d+))?", went[0])
    ctx.expect(bool(m), "a delivery was dispatched (%s)" % (went[:1] if went else "nothing"))
    if not m:
        return
    job, dname, sname = m.group(1), m.group(2), m.group(3)
    held = []
    for name, t in sorted((ctx.state().get("turtles") or {}).items()):
        if t.get("role") == "DELIVERY" and name != dname:
            ctx.dispatch("HOLD_TURTLE", {"turtleId": name, "reason": "w3_depart_off_dock"})
            held.append(name)
    ctx.note("held the other deliveries: %s" % held)
    c.shutdown([wid])                                  # THE FAULT: no warehouse when the delivery gets there

    back = ctx.wait_until(lambda: [l for l in since("Dispatched %s [DELIVER] -> %s" % (job, dname)) if l[:19] > went[0][:19]], 2400)
    timeouts = [l for l in since("warehouse_chest_timeout") if job in l or dname in l]
    ctx.expect(bool(back) and bool(timeouts), "the job came back to %s while it was away from its dock (%d timeout line(s); %s)"
               % (dname, len(timeouts), back[:1] if back else "no second dispatch"))
    c.turn_on([wid])
    # THE SUPPORT GETS HOME (the stranded-supports ruling, 2026-11-14): its delivery's job failed out in the world; the
    # delivery brought it home through the tunnel before reporting the failure (c04c3ce). On eea9424 its support,
    # node_141, met rock at 228,60,-2762 and stayed there.
    if sname:
        brought = [l for l in since("bringing support %s home first" % sname) if dname in l]
        docked = ctx.wait_until(lambda: [l for l in since("Docked at bay") if sname in l], 900)
        failed_home = [l for l in since("Return home failed") if sname in l]
        ctx.expect(bool(brought), "%s held its failure back to bring %s home (%s)" % (dname, sname, brought[0][:160] if brought else "nothing"))
        ctx.expect(bool(docked) and not failed_home, "%s got home through the tunnel after its delivery's job failed (%s; %d 'Return home failed')"
                   % (sname, docked[0][:140] if docked else "never docked", len(failed_home)))
    if not back:
        return
    t_back = back[0][:19]

    # The ATC crashed while the delivery heads home through the base, then a total radio blackout.
    ctx.wait_game(20)
    c.shutdown([aid])
    ctx.wait_game(120)
    t_on = now_iso()
    c.turn_on([aid])
    ctx.expect(bool(ctx.wait_until(lambda: since("settled: rebuilt", t_on), 240)), "the ATC came back after its crash and settled")
    ctx.wait_game(60)
    c.radio_loss(0, 5 * 60 * 1000, 1.0)
    ctx.wait_game(5 * 60 + 10)
    t_after = now_iso()

    done = ctx.wait_until(lambda: since("Job complete: %s" % job), 3600)
    # Any way home: when its job failed (the job runner, 06a4983; with its support, c04c3ce) or when given it back (290eedd).
    home = [l for l in since("away from my dock", went[0][:19]) + since("home first, then reporting it", went[0][:19]) if dname in l]
    ctx.expect(bool(home), "%s went home before departing again (%d line(s): %s)" % (dname, len(home), home[0][:170] if home else "nothing"))
    held_by = [l for l in since("a turtle is blocking", t_back) if dname in l]
    ctx.expect(not held_by, "%s was never held by a turtle after the job came back (%d; %s)"
               % (dname, len(held_by), held_by[0][:170] if held_by else ""))
    ctx.expect(bool(done), "%s completed" % job)
    for n in held:
        ctx.dispatch("RELEASE_TURTLE", {"turtleId": n})
    ctx.wait_game(180)
    stuck = since("STUCK ", t_after)
    ctx.expect(not stuck, "nobody reported STUCK after the blackout (%d; %s)" % (len(stuck), stuck[0][:170] if stuck else ""))
    summaries = since("section(s) held", t_after)
    last = summaries[-1] if summaries else ""
    ctx.expect(bool(summaries) and " 0 section(s) held" in last, "the ATC holds no section at the end (%d summaries; last: %s)"
               % (len(summaries), last[-120:]))
    turtles = ctx.state().get("turtles") or {}
    off = [n for n, t in turtles.items() if t.get("dockX") is not None and not (t.get("x") == t.get("dockX") and t.get("z") == t.get("dockZ"))]
    ctx.expect(turtles and not off, "every registered turtle is on its dock at the end (%d of %d not: %s)"
               % (len(off), len(turtles), off))
    c.shutdown([aid])
