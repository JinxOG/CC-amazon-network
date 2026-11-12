"""W3, the card "Healthy docked turtles end with NEEDS HANDS 'facing unknown' set (146 of 150 in passing ATC sims)" (fix
13b04c2), layer 2, ONE turtle (a delivery: the bug was in the roles with no hardware check).

A stuck_no_fix NEEDS HANDS was cleared only by a passing hardware check, which only miners run, so on a delivery or support
it stayed for good. Here: the ATC is placed; then the ATC and one docked delivery are switched off, the ATC is switched on
and, while it is still settling (15 s, it refuses every step), the delivery: it cannot measure its facing, says
stuck_no_fix, and the server raises NEEDS HANDS. Once the ATC settles the delivery measures, finds itself at its dock and
reports "docked". The flag must clear: in the server's log and in the bridge's /state. Pin the commit under test. 1x."""
import datetime
import importlib.util
import os
import tempfile

NAME = "w3_stuck_flag_clears"
_spec = importlib.util.spec_from_file_location("w3_atc_pair", os.path.join(os.path.dirname(os.path.abspath(__file__)), "w3_atc_pair.py"))
_pair = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_pair)


def now_iso():
    return datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%S")


def steps(ctx):
    ctx.wait_registered(14, 300)
    c = ctx.control
    pin = getattr(ctx, "pin", None) or "HEAD"
    tmp = tempfile.mkdtemp(prefix="w3flag")
    c.command("forceload add 224 -2816 271 -2769")
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
    ctx.wait_game(30)

    turtles = ctx.state().get("turtles") or {}
    pick = None
    for name, t in sorted(turtles.items()):
        if t.get("role") == "DELIVERY" and t.get("status") == "IDLE" and t.get("x") == t.get("dockX") \
                and t.get("z") == t.get("dockZ") and not t.get("needsHands"):
            pick = name
            break
    ctx.expect(pick is not None, "found an idle docked delivery turtle (%s)" % pick)
    if not pick:
        return
    cid = int(pick.split("_")[1])
    ctx.note("the turtle: %s (#%d)" % (pick, cid))

    # THE TEST: both off; the ATC on; the delivery on while the ATC settles.
    c.shutdown([cid, aid])
    ctx.wait_game(5)
    t0 = now_iso()
    c.turn_on([aid])
    c.turn_on([cid])

    def since(needle):
        return [l for l in ctx.log_lines(needle) if l[:19] >= t0 and pick in l]
    raised = ctx.wait_until(lambda: since("stuck_no_fix"), 300)
    ctx.expect(bool(raised), "%s could not measure while the ATC settled, and the server raised NEEDS HANDS (%s): the check "
               "below has something to judge" % (pick, raised[:1] if raised else "nothing"))
    cleared = ctx.wait_until(lambda: [l for l in since("docked --") if "cleared" in l], 600)
    ctx.expect(bool(cleared), "the server cleared it when %s reported docked (%s)" % (pick, cleared[:1] if cleared else "nothing"))
    ctx.wait_game(30)
    t = (ctx.state().get("turtles") or {}).get(pick) or {}
    ctx.expect(not t.get("needsHands"), "/state shows no NEEDS HANDS on %s (%r)" % (pick, t.get("needsHands")))
    ctx.expect(t.get("x") == t.get("dockX") and t.get("z") == t.get("dockZ"), "%s is on its dock (%s,%s,%s)"
               % (pick, t.get("x"), t.get("y"), t.get("z")))
    c.shutdown([aid])
