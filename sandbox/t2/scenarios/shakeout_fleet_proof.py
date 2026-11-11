"""Shakeout Task 5, the T2 proof of the fleet: PLACEMENT and LOADER IDENTITY. T2 only; NOT RUN YET (written 2026-11-10).

    python sandbox/t2/scenario.py sandbox/t2/scenarios/shakeout_fleet_proof.py --pin <sha>      (1x; a few hours)

1. PLACEMENT: shakeout.setup(ctx) builds the world and places 160 fresh turtles with dock_assignments.dat seeded while the
   dispatch computer is off; its checks: every placed turtle registers, the server's dock for each is the cell it stands in,
   it reports standing there, and no 'Assigned dock' / 'Dock moved' / 'No free docks' line names a placed turtle.
2. LOADER IDENTITY (spec 4.2.5; memory "copied turtles share a chunk ticket"): two miners are sent to one-sector mine jobs
   1,024 blocks apart (every other miner held); once both have placed their loaders, control.chunk_loaders() must list both
   loaders' computers, at least 1,000 blocks apart, with different chunky uuids -- and still list both 15 game minutes later,
   past the miners' own 600 s chunky lease, which is exactly when copied loaders let go (2026-10-06). One ticket shared
   between them would show as one loader listed, or one gone by the second look.
   The zones: (1920,-2624), the T2 scenarios' usual one, and (2944,-2624), 1,024 blocks east. An ORDER_MINE takes sector
   CENTRES (memory "ORDER_MINE takes centres"): x1 = x2, z1 = z2 is one sector.
"""
import importlib.util
import math
import os

NAME = "shakeout_fleet_proof"
ZONES = [(1920, -2624), (2944, -2624)]
HOLD_AFTER_S = 15 * 60          # game seconds past both placements: beyond the miners' 600 s chunky lease

_spec = importlib.util.spec_from_file_location("shakeout_driver", os.path.join(os.path.dirname(os.path.abspath(__file__)), "shakeout.py"))
drv = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(drv)


def placed_loaders(ctx, wanted):
    try:
        return [l for l in ctx.control.chunk_loaders() if l.get("computer") in wanted]
    except Exception as ex:  # noqa: BLE001 - the mod's answer is the evidence; an error is noted and counts as nothing seen
        ctx.note("chunk_loaders() failed: %s" % ex)
        return []


def distance(a, b):
    return math.hypot((a["chunk_x"] - b["chunk_x"]) * 16, (a["chunk_z"] - b["chunk_z"]) * 16)


def steps(ctx):
    placed = drv.setup(ctx)
    loaders = ctx.shakeout_fleet["loaders"]
    miners = sorted((n for n, cell in placed.items() if cell["type"] == "MINER"), key=lambda n: (placed[n]["x"], placed[n]["z"]))
    two = [miners[0], miners[-1]]                    # worker bay 2's first dock and support bay 5's last: both sides of the base
    ctx.expect(all(n in loaders for n in two), "the two miners carry fresh loaders (%s)" % {n: loaders.get(n) for n in two})
    for n in miners:
        if n not in two:
            ctx.dispatch("HOLD_TURTLE", {"turtleId": n, "reason": "shakeout_fleet_proof: only %s mine" % " and ".join(two)})
    ctx.wait_game(10)
    sent0 = len(ctx.log_lines("Dispatched job_"))
    for x, z in ZONES:
        ctx.dispatch("ORDER_MINE", {"x1": x, "z1": z, "x2": x, "z2": z, "minerCount": 1})
    went = ctx.wait_until(lambda: (lambda ls: ls if len(ls) >= 2 else None)(ctx.log_lines("Dispatched job_")[sent0:]), 600) or []
    ctx.expect(len(went) >= 2 and all(any(n in l for l in went) for n in two),
               "both mine jobs went to the two free miners (%s)" % [l[-120:] for l in went[:4]])
    wanted = {loaders[n] for n in two if n in loaders}
    both = ctx.wait_until(lambda: (lambda ls: ls if len(ls) >= 2 else None)(placed_loaders(ctx, wanted)), 3 * 3600)
    first = both or placed_loaders(ctx, wanted)
    ctx.note("chunk_loaders() at both placements: %s" % first)
    ctx.expect(len(first) == 2, "chunk_loaders() lists both new loaders once they are placed (%d of 2: %s)" % (len(first), first))
    if len(first) != 2:
        return
    d = distance(first[0], first[1])
    ctx.expect(d >= 1000, "the two loaders stand at least 1,000 blocks apart (%.0f)" % d)
    ctx.expect(first[0].get("uuid") != first[1].get("uuid") and all(l.get("uuid") for l in first),
               "the two loaders have different chunky uuids (%s, %s)" % (first[0].get("uuid"), first[1].get("uuid")))
    ctx.wait_game(HOLD_AFTER_S)
    later = placed_loaders(ctx, wanted)
    ctx.note("chunk_loaders() %d game s later: %s" % (HOLD_AFTER_S, later))
    ctx.expect(len(later) == 2 and {l["computer"] for l in later} == {l["computer"] for l in first},
               "both loaders still hold their chunks %d game s later, past the 600 s lease (%d of 2)" % (HOLD_AFTER_S, len(later)))
