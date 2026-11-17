"""W3, 2026-11-17: layer 2 for the card "A turtle killed by CC's timeout stays off where it stands" (7294978), as the sim
w3_dead_turtle_lane does it. T2 shakeout-side-f: CC's timeout terminated #210 in the base's departure lane; a terminated
computer stays OFF where it stands, and node_211 bumped into it 323 times. A turtle stopped by a turtle that is OFF turns
it back on (a turtle next to another computer can: turnOn / isOn); it boots, recovers like any rebooted turtle, and the
reviver gives way.

ONE PAIR MOVING AT A TIME: the first pair goes out; the moment its delivery stands in the departure lane (W1), its
computer is shut down, as CC's timeout does -- that pair is then stopped (the delivery off, its support on its dock).
Only then is a second order placed; its pair must come past the dead turtle.
CHECKS (each with its evidence): the delivery was OFF in W1 (evidence, from the game's computer list); a turtle that met
it turned it back on; it came back on; the second order completed; the first order completed; the ATC holds nothing at
the end; every turtle is on its dock. NOTE (not a check): how the second pair got its way -- a dead turtle can say
nothing, so its booking goes only when the ATC finds it silent. Pin the commit under test. 1x."""
import datetime
import importlib.util
import os
import re
import tempfile

NAME = "w3_dead_turtle_lane"
DEST1 = {"x": 124, "y": 67, "z": -2824}
DEST2 = {"x": 130, "y": 67, "z": -2824}
WHITE_Z, RED_Z, DH_X, BAY1_X, FLOOR_Y = -2803, -2801, 143, 157, 67
_spec = importlib.util.spec_from_file_location("w3_atc_pair", os.path.join(os.path.dirname(os.path.abspath(__file__)), "w3_atc_pair.py"))
_pair = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_pair)


def now_iso():
    return datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%S")


def in_w1(pos):
    """waypoints.atcSection's W1: the floor of the taxiway strip, between the dispatch corner and bay 1's crossing,
    not on the red lane."""
    if not pos:
        return False
    x, y, z = pos
    return y == FLOOR_Y and WHITE_Z <= z < RED_Z and DH_X < x < BAY1_X


def steps(ctx):
    ctx.wait_registered(14, 300)
    c = ctx.control
    pin = getattr(ctx, "pin", None) or "HEAD"
    tmp = tempfile.mkdtemp(prefix="w3dead")
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
    ctx.expect("turned it back on" in _pair.show(pin, "turtle_base.lua"), "the pinned commit carries the revive (the commit under test)")

    def since(needle, t):
        return [l for l in ctx.log_lines(needle) if l[:19] >= t]

    def server_done(j, t):
        return [l for l in since("Job complete: %s" % j, t) if "server#" in l and l.rstrip().endswith(j)] if j else []

    t1 = now_iso()
    ctx.dispatch("ORDER_DELIVERY", {"items": [{"name": "minecraft:cobblestone", "count": 16}], "destination": DEST1})
    went = ctx.wait_until(lambda: [l for l in since("Dispatched job_", t1) if "[DELIVER]" in l], 900)
    mm = went and re.search(r"Dispatched (job_\d+) \[DELIVER\] -> (node_\d+)\s+support (job_\d+) -> (node_\d+)", went[0])
    ctx.expect(bool(mm), "the first pair was dispatched (%s)" % (went[:1] if went else "nothing"))
    if not mm:
        return
    job1, d1, _, s1 = mm.groups()
    cid = int(d1.replace("node_", ""))
    hit = ctx.wait_until(lambda: in_w1((c.computers().get(cid) or {}).get("pos")), 600, poll=0.5)
    pos = (c.computers().get(cid) or {}).get("pos")
    ctx.expect(bool(hit), "%s (computer #%d) stood in the departure lane W1 (%s)" % (d1, cid, pos))
    if not hit:
        return
    c.shutdown([cid])                                       # THE FAULT: terminated where it stands, as CC's timeout does
    ctx.wait_game(5)
    st = c.computers().get(cid) or {}
    ctx.expect(st.get("on") is False and in_w1(st.get("pos")),
               "%s was OFF in W1 at %s: the checks below have something to judge" % (d1, st.get("pos")))
    tDead = now_iso()
    ctx.note("%s (support %s) shut down in W1 at %s" % (d1, s1, st.get("pos")))

    ctx.dispatch("ORDER_DELIVERY", {"items": [{"name": "minecraft:cobblestone", "count": 16}], "destination": DEST2})

    def second():
        for l in since("Dispatched job_", tDead):
            m2 = re.search(r"Dispatched (job_\d+) \[DELIVER\]", l)
            if m2 and m2.group(1) != job1:
                return m2.group(1)
        return None

    revived = ctx.wait_until(lambda: since("turned it back on", tDead), 1800)
    ctx.expect(bool(revived), "a turtle that met it turned it back on (%s)" % (revived[0][-130:] if revived else "nobody"))
    on = ctx.wait_until(lambda: (c.computers().get(cid) or {}).get("on") is True, 120, poll=1)
    ctx.expect(bool(on), "%s came back on" % d1)
    j2 = ctx.wait_until(second, 600)
    done2 = ctx.wait_until(lambda: server_done(second(), t1), 2400)
    ctx.expect(bool(done2), "the second order was delivered (%s)" % second())
    done1 = ctx.wait_until(lambda: server_done(job1, t1), 2400)
    ctx.expect(bool(done1), "the first order was delivered too (%s)" % job1)

    ctx.wait_game(120)
    dropped = [l for l in since("booking dropped", tDead) if re.search(r"silent \d+s: booking dropped", l)]
    ctx.note("how the second pair got its way: %d silence sweep(s) of the ATC (%s)"
             % (len(dropped), dropped[0][-110:] if dropped else "none"))
    last = (since("section(s) held", t1) or [""])[-1]
    ctx.expect(" 0 section(s) held" in last, "the ATC holds no section at the end (%s)" % last[-120:])
    turtles = ctx.state().get("turtles") or {}
    away = [n for n, t in turtles.items() if t.get("dockX") is not None and not (t.get("x") == t.get("dockX") and t.get("z") == t.get("dockZ"))]
    ctx.expect(turtles and not away, "every registered turtle is on its dock at the end (%d of %d not: %s)" % (len(away), len(turtles), away))
    c.shutdown([aid])
