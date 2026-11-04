"""W3 card "TOP PRIORITY - Base air-traffic control computer", layer 2, with ONE turtle pair (the user's rule: one pair at a
time). Same story as the simulator's w3_atc_base150 'atc' fault, on the real game:

  1. The ATC computer is placed in the test world by the runner (control.spawn_computer), with the atc profile's files from
     the pinned commit: protocol, updater, logship, waypoints, and atc.lua as startup.lua. Nothing else is on its disk.
  2. It must come online, settle, rebuild from the fleet's reports, and the fleet must hear it ('ATC heard').
  3. One mining job, one miner (and its loader): the departure must be ADMITTED by the ATC ('admitted node_N').
  4. Once the pair is out of the base, the ATC is switched OFF and the miner is recalled. While it is off no turtle may stand
     in a base section it was not in when the ATC went down (safe when down: no grant, no new section).
  5. The ATC is switched back on: it rebuilds, and the pair gets home and docks.

Pin the commit under test (the fleet must carry the ATC gate). 1x: the ATC's timers are real-time epoch milliseconds."""
import os
import re
import subprocess
import tempfile

import run as runmod  # noqa: E402  (sandbox/t2 is on the path: the runner put it there)

NAME = "w3_atc_pair"
ATC_FILES = ("protocol.lua", "updater.lua", "logship.lua", "waypoints.lua")
DOWN_S = 300                                             # how long the ATC stays off


def show(pin, path):
    return subprocess.run(["git", "-C", runmod.REPO, "show", "%s:%s" % (pin, path)], capture_output=True,
                          check=True).stdout.decode("utf8").replace("\r\n", "\n")


def positions(ctx):
    t = ctx.state().get("turtles") or {}
    items = t.items() if isinstance(t, dict) else ((e.get("id"), e) for e in t)
    out = {}
    for tid, e in items:
        p = (e or {}).get("position") or (e or {}).get("pos") or e     # /state carries x, y, z on the entry itself
        if isinstance(p, dict) and all(isinstance(p.get(k), (int, float)) for k in ("x", "y", "z")):
            out[tid or e.get("id")] = (int(p["x"]), int(p["y"]), int(p["z"]))
    return out


def at_dock(p):
    if p[1] != 67 or p[2] not in (-2806, -2810, -2797, -2793):
        return False
    return any(dx != 0 and -4 <= dx <= 4 for dx in (p[0] - (157 + 14 * b) for b in range(5)))


def in_base(p):
    """The building's traffic floor, the two shafts and the arrivals column: where the ATC grants sections."""
    x, y, z = p
    if y == 67 and 143 <= x <= 228 and -2813 <= z <= -2782 and not at_dock(p):
        return True
    if (x, z) in ((143, -2813), (228, -2782)) and 60 <= y <= 66:
        return True
    return (x, z) == (228, -2782) and y >= 67


def steps(ctx):
    ctx.wait_registered(14, 300)
    c = ctx.control
    pin = getattr(ctx, "pin", None) or "HEAD"

    # 1. The ATC computer, placed by the runner.
    tmp = tempfile.mkdtemp(prefix="w3atc")
    start = os.path.join(tmp, "startup.lua")
    with open(start, "w", encoding="utf8", newline="\n") as f:
        f.write(show(pin, "atc.lua"))
    files = {name: show(pin, name) for name in ATC_FILES}
    files["role.txt"] = "atc"
    online0 = len(ctx.log_lines("ATC online"))
    x, y, z = c.free_spot()
    aid = c.spawn_computer(x, y, z, start, files=files)
    ctx.note("ATC computer #%d placed at %d,%d,%d with atc.lua and %s from %s" % (aid, x, y, z, ", ".join(ATC_FILES), pin))

    # 2. Online, settled, heard.
    on = ctx.wait_until(lambda: len(ctx.log_lines("ATC online")) > online0, 180)
    ctx.expect(bool(on), "the ATC came online (%s)" % (ctx.log_lines("ATC online")[-1:] or "nothing"))
    settled = ctx.wait_until(lambda: ctx.log_lines("settled: rebuilt"), 120)
    ctx.expect(bool(settled), "it settled and rebuilt from the fleet's reports (%s)" % (settled[-1:] if settled else "nothing"))
    heard = ctx.wait_until(lambda: (lambda n: n if len(n) >= 10 else None)(
        {m.group(1) for l in ctx.log_lines("ATC heard") for m in [re.search(r"(node_\d+)", l)] if m}), 180)
    ctx.expect(bool(heard), "the fleet heard it: %d turtle(s) logged 'ATC heard' (need 10 of 14)" % len(heard or ()))

    # 3. One miner out, admitted by the ATC.
    ctx.dispatch("ORDER_MINE", {"x1": 1920, "z1": -2624, "x2": 1984, "z2": -2624, "minerCount": 1})
    went = ctx.wait_until(lambda: ctx.log_lines("Dispatched job_"), 600)
    ctx.expect(bool(went), "the job was dispatched")
    if not went:
        return
    miner = went[0].split("-> ")[1].split()[0]
    admitted = ctx.wait_until(lambda: [l for l in ctx.log_lines("admitted %s:" % miner)], 300)
    ctx.expect(bool(admitted), "the ATC admitted %s's departure (%s)" % (miner, admitted[:1] if admitted else "nothing"))
    out = ctx.wait_until(lambda: (lambda p: p if p and not in_base(p) and not at_dock(p) and p[1] > 80 else None)(
        positions(ctx).get(miner)), 900)
    ctx.expect(bool(out), "%s left the base (%s)" % (miner, out))
    ctx.wait_game(60)

    # 4. THE TEST: the ATC goes down, and the miner is called home while it is down.
    before = positions(ctx)
    inside0 = {t for t, p in before.items() if in_base(p)}
    ctx.note("turtles in a base section when the ATC went down: %s" % (sorted(inside0) or "none"))
    c.shutdown([aid])
    t_down = ctx.game_seconds()
    ctx.dispatch("RECALL_ALL", {"reason": "w3_atc_pair"})
    entered, closest, samples = [], None, 0
    while ctx.game_seconds() - t_down < DOWN_S:
        ctx.wait_game(10)
        samples += 1
        for t, p in positions(ctx).items():
            if in_base(p) and t not in inside0 and t not in [e[0] for e in entered]:
                entered.append((t, p))
        p = positions(ctx).get(miner)
        if p:
            d = abs(p[0] - 228) + abs(p[2] + 2782)
            closest = d if closest is None else min(closest, d)
    ctx.expect(samples >= 20, "positions sampled while the ATC was down (%d samples)" % samples)
    # The evidence: the miner reached the base and asked to come in while nobody could answer. (w3-atc-pair-b: it waited at
    # 204,200,-2813, over the building, 55 blocks from the arrivals hole by x+z -- a distance bar of 40 failed a true wait.)
    waiting = [l for l in ctx.log_lines("no answer from the ATC") if miner in l]
    ctx.expect(len(waiting) >= 2 and closest is not None and closest <= 80, "%s came back and waited at the base while the "
               "ATC was down (closest %s blocks from the arrivals hole; %d 'no answer from the ATC' lines, last %s): the "
               "check below has something to judge" % (miner, closest, len(waiting), waiting[-1:]))
    ctx.expect(not entered, "no turtle stepped into a base section while the ATC was down (%s)" % (entered or "none"))

    # 5. Back on: the pair gets home.
    settled0 = len(ctx.log_lines("settled: rebuilt"))
    c.turn_on([aid])
    again = ctx.wait_until(lambda: len(ctx.log_lines("settled: rebuilt")) > settled0, 180)
    ctx.expect(bool(again), "the ATC came back and rebuilt (%s)" % (ctx.log_lines("settled: rebuilt")[-1:]))
    docked = ctx.wait_until(lambda: [l for l in ctx.log_lines("Docked at bay") if miner in l], 900)
    ctx.expect(bool(docked), "%s docked after the ATC came back (%s)" % (miner, docked[-1:] if docked else "nothing"))
    ctx.wait_game(60)
    end = positions(ctx)
    stray = {t: p for t, p in end.items() if in_base(p)}
    ctx.expect(not stray, "nobody left standing in the base at the end (%s)" % (stray or "none"))
    errs = [l for l in ctx.log_lines("STUCK ") if "node_" in l]
    ctx.expect(not errs, "no turtle reported STUCK (%d)" % len(errs))
