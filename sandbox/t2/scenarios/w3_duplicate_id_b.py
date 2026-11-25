"""W3, the duplicate-id card, layer 2, with the shakeout's stand-in player (sandbox/t2/shakeout/player.py).

w3-duplicate-id-a (94ce931) proved the alarm on the real game: a /cloned delivery was named "duplicate_id: node_102 heard at
154,67,-2806 and 160,67,-2793" in about 80 s. Four checks failed there for the scenario's own reasons: the copy homed through the
cell where the ATC computer stood (a homing delivery could dig a computer until 60d2143), the copy was removed at the cell it had
left, and the radio log was off. Here, as the 24-hour run will do it (the user's ruling, 2026-11-24: the test models a player):

  1. Radio log on. The ATC computer is placed in the far corner of the free area; the copy beside the docks, so the copy's
     way home does not cross it.
  2. An idle DELIVERY on its dock is /cloned: two computers with one id.
  3. The real Player runs (the run loop's PLAYER_DELAY_S, 600 s): it removes every named copy but the first and dispatches
     RELEASE_TURTLE.
  CHECKS: the alarm with both places; the ATC ban; the player's faults.jsonl start and end (ok); the RELEASE intervention; the
  survivor's "UNPARKED"; the ATC's "unbanned"; no turtle left at the removed cells; and an order given to that id completes.

Pin a commit with 6c34062 (the release) and 60d2143. Run at --tickrate 20: the duplicate check's windows are real time."""
import datetime
import importlib
import importlib.util
import json
import os
import re
import sys
import tempfile
import time

NAME = "w3_duplicate_id_b"
_spec = importlib.util.spec_from_file_location("w3_atc_pair", os.path.join(os.path.dirname(os.path.abspath(__file__)), "w3_atc_pair.py"))
_pair = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_pair)
sys.path.insert(0, os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))))


def now_iso():
    return datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%S")


class _PlayerCtx:
    """What shakeout.player.Player needs of the shakeout's ctx, over this runner's ctx."""

    def __init__(self, ctx):
        self._ctx, self.run, self.interventions = ctx, ctx.run, []
        self._raw = ctx.control

    def dispatch(self, type_, params=None):
        return self._ctx.dispatch(type_, params)

    def note(self, text):
        self._ctx.note(text)


def far_spot(c, y=67):
    """A free 2-high spot searched from the far corner of control.free_spot's area, INSIDE the box the test world keeps
    loaded with no turtle there (x 112-207, z -2848..-2769, chunk_watch's BOX): w3-duplicate-id-b first placed the ATC at
    199,67,-2751, outside it, and the computer never appeared ("never appeared in the computer list")."""
    for x in range(199, 159, -3):
        for z in range(-2770, -2791, -3):
            if all("Test passed" in c.command("execute if block %d %d %d air" % (x, y + k, z)) for k in range(2)):
                return (x, y, z)
    raise RuntimeError("no free far spot")


def steps(ctx):
    ctx.wait_registered(14, 300)
    c = ctx.control
    pin = getattr(ctx, "pin", None) or "HEAD"
    tmp = tempfile.mkdtemp(prefix="w3dupb")
    ctx.note("radio log: %s" % str(c.radio_log("on")).strip()[:80])

    # 1. The ATC computer, in the far corner.
    start = os.path.join(tmp, "atc_startup.lua")
    with open(start, "w", encoding="utf8", newline="\n") as f:
        f.write(_pair.show(pin, "atc.lua"))
    files = {name: _pair.show(pin, name) for name in _pair.ATC_FILES}
    files["role.txt"] = "atc"
    t_atc = now_iso()
    ax, ay, az = far_spot(c)
    aid = c.spawn_computer(ax, ay, az, start, files=files)
    ctx.note("ATC computer #%d at %d,%d,%d from %s" % (aid, ax, ay, az, pin))
    ctx.expect(bool(ctx.wait_until(lambda: [l for l in ctx.log_lines("ATC online") if l[:19] >= t_atc], 180)), "the ATC came online")
    ctx.wait_until(lambda: [l for l in ctx.log_lines("settled: rebuilt") if l[:19] >= t_atc], 120)

    # 2. An idle delivery on its dock, and its copy beside the docks.
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
    if abs(tx - ax) + abs(tz - az) < 12:
        ctx.note("the copy's spot %d,%d,%d is near the ATC: moved 6 west" % (tx, ty, tz))
        tx -= 6
    t0 = now_iso()
    out = c.command("clone %d %d %d %d %d %d %d %d %d" % (pos + pos + (tx, ty, tz)))
    ctx.note("clone %s at %s to %d,%d,%d: %s" % (tid, pos, tx, ty, tz, out.strip()[:120]))
    c.turn_on([cid])

    def since(needle, t=None):
        return [l for l in ctx.log_lines(needle) if l[:19] >= (t or t0)]

    hands = ctx.wait_until(lambda: [l for l in since("duplicate_id: %s heard at" % tid) if "NEEDS HANDS" in l], 300)
    ctx.expect(bool(hands), "NEEDS HANDS duplicate_id for %s within 5 min of the copy (%s)" % (tid, hands[:1] if hands else "nothing"))
    if not hands:
        return
    named = re.findall(r"(-?\d+),(-?\d+),(-?\d+)", hands[0].split("heard at", 1)[1])
    cells = [tuple(int(v) for v in p) for p in named]
    ctx.expect(len(set(cells)) >= 2, "it names the places (%s)" % cells)
    ban = ctx.wait_until(lambda: [l for l in since("banned (duplicate id)") if tid in l], 120)
    ctx.expect(bool(ban), "the ATC dropped and refused the id (%s)" % (ban[:1] if ban else "nothing"))

    # 3. The stand-in player, as the run loop runs it.
    player_mod = importlib.import_module("shakeout.player")
    pctx = _PlayerCtx(ctx)
    p0 = time.time()
    player = player_mod.Player(pctx, p0)
    faults = os.path.join(ctx.run, "shakeout", "faults.jsonl")

    def player_lines():
        try:
            with open(faults, encoding="utf8") as f:
                return [json.loads(l) for l in f if l.strip()]
        except OSError:
            return []

    deadline = p0 + player_mod.PLAYER_DELAY_S + 300
    while time.time() < deadline and not [r for r in player_lines() if r.get("phase") == "end"]:
        player.tick(time.time())
        time.sleep(10)
    lines = player_lines()
    begun = [r for r in lines if r.get("phase") == "start" and r.get("node") == tid]
    ended = [r for r in lines if r.get("phase") == "end" and r.get("node") == tid]
    ctx.expect(bool(begun), "the player saw the alarm (%s)" % (begun[:1] if begun else "nothing"))
    ctx.expect(bool(ended) and ended[0].get("ok") is True, "the player removed the copy and released the hold (%s)" % (ended[:1] if ended else "nothing"))
    for iv in pctx.interventions:
        ctx.note("player intervention: %s %s %s" % (iv.get("verb"), iv.get("args"), iv.get("kwargs")))
    ctx.expect(any(iv.get("verb") == "dispatch" and "RELEASE_TURTLE" in str(iv.get("args")) for iv in pctx.interventions),
               "the RELEASE_TURTLE intervention is recorded")
    t1 = now_iso()
    rel = ctx.wait_until(lambda: [l for l in since("duplicate_id released", t0) if tid in l], 120)
    ctx.expect(bool(rel), "the server released it (%s)" % (rel[:1] if rel else "nothing"))
    unp = ctx.wait_until(lambda: [l for l in since("UNPARKED", t0) if tid in l], 180)
    ctx.expect(bool(unp), "%s moved again: UNPARKED (%s)" % (tid, unp[:1] if unp else "nothing"))
    unb = ctx.wait_until(lambda: [l for l in since("unbanned (its duplicate seen to)", t0) if tid in l], 120)
    ctx.expect(bool(unb), "the ATC takes it again (%s)" % (unb[:1] if unb else "nothing"))
    removed = ended[0].get("removed") if ended else []
    left = [cell for cell in (removed or [])
            if any("Test passed" in c.command("execute if block %d %d %d %s" % (cell[0], cell[1], cell[2], k))
                   for k in ("computercraft:turtle_normal", "computercraft:turtle_advanced"))]
    ctx.expect(not left, "no turtle at the removed cells (%s of %s)" % (left, removed))

    # An order given to that id completes: one pair at a time, until the dispatcher picks it (at most 4 orders).
    home = ctx.wait_until(lambda: (lambda s: s if s.get("x") == s.get("dockX") and s.get("z") == s.get("dockZ") else None)(
        (ctx.state().get("turtles") or {}).get(tid) or {}), 600)
    ctx.expect(bool(home), "%s is home on its dock after the release" % tid)
    job = None
    for i in range(4):
        dx, dy, dz = c.free_spot()
        dz += 3 * i
        ti = now_iso()
        ctx.dispatch("ORDER_DELIVERY", {"items": [{"name": "minecraft:cobblestone", "count": 16}],
                                        "destination": {"x": dx, "y": dy, "z": dz}})
        went = ctx.wait_until(lambda: [l for l in ctx.log_lines("Dispatched job_") if l[:19] >= ti], 300)
        if not went:
            break
        m = re.search(r"Dispatched (job_\d+)", went[0])
        if tid in went[0] and m:
            job = m.group(1)
            break
        if m:
            ctx.wait_until(lambda: [l for l in ctx.log_lines("Job complete: %s" % m.group(1)) if l[:19] >= ti], 2400)
    ctx.expect(job is not None, "an order went to %s after the release (%s)" % (tid, job))
    if job:
        done = ctx.wait_until(lambda: [l for l in ctx.log_lines("Job complete: %s" % job) if l[:19] >= t1], 2400)
        ctx.expect(bool(done), "and completed (%s)" % job)
    c.shutdown([aid])
