"""Shakeout Task 5, the T2 proof of the fleet: PLACEMENT and LOADER IDENTITY. T2 only; NOT RUN YET (written 2026-11-10).

    python sandbox/t2/scenario.py sandbox/t2/scenarios/shakeout_fleet_proof.py --pin <sha>      (1x; a few hours)

1. PLACEMENT: shakeout.setup(ctx) builds the world and places 160 fresh turtles with dock_assignments.dat seeded while the
   dispatch computer is off; its checks: every placed turtle registers, the server's dock for each is the cell it stands in,
   it reports standing there, and no SERVER 'Assigned dock ... to <node>' / 'Dock moved' / 'No free docks' line names a placed
   turtle (shakeout.PLACEMENT_RX: the node the server's line names, not the source of a turtle's own 'Assigned dock' line).
2. LOADER IDENTITY (spec 4.2.5; memory "copied turtles share a chunk ticket"): two miners are sent to one-sector mine jobs
   1,024 blocks apart (every other miner held); once both have placed their loaders, control.chunk_loaders() must list both
   loaders' computers at least 1,000 blocks apart.
   THE EVIDENCE OF TWO IDENTITIES is that the two loaders carry DIFFERENT chunky uuids: AP keys its ticket by that uuid, and
   copied loaders shared one (2026-10-06).
   "BOTH STILL HOLD" is checked 15 game minutes later, past the miners' own 600 s chunky lease (exactly when copied loaders let
   go) -- but a loader being listed only says its computer is loaded, and a miner standing within a chunk of its loader WITH
   its own chunky upgrade equipped would keep that chunk loaded by itself. So the hold check counts only a look at which each
   miner either has no chunky upgrade equipped (mine mode: modem + pickaxe; read from its block's Left/RightUpgrade) or is
   more than one chunk from its loader; it waits up to HOLD_LOOK_S for such a look, and says so if none comes.
   The zones: (1920,-2624), the T2 scenarios' usual one, and (2944,-2624), 1,024 blocks east. An ORDER_MINE takes sector
   CENTRES (memory "ORDER_MINE takes centres"): x1 = x2, z1 = z2 is one sector.
"""
import importlib.util
import math
import os

from shakeout import fleet  # noqa: E402  (sandbox/t2 is on the path: the runner put it there)

NAME = "shakeout_fleet_proof"
ZONES = [(1920, -2624), (2944, -2624)]
HOLD_AFTER_S = 15 * 60          # game seconds past both placements: beyond the miners' 600 s chunky lease
HOLD_LOOK_S = 30 * 60           # then up to this long for a look the miners' own chunky upgrades cannot explain
CHUNKY = "advancedperipherals:chunky_turtle"

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


def own_ticket_near(ctx, miner_cid, loader):
    """True when the miner could be holding its loader's chunk by itself: its chunky upgrade equipped and it within one
    chunk of the loader. (None when the miner cannot be read: counted as could.)"""
    c = ctx.control
    try:
        pos = tuple(c.computers()[miner_cid]["pos"])
        ups = [fleet._value(c.block_data(pos, side)) or "" for side in ("LeftUpgrade", "RightUpgrade")]
    except Exception:  # noqa: BLE001
        return None
    chunky = any(CHUNKY in u for u in ups)
    near = abs((pos[0] >> 4) - loader["chunk_x"]) <= 1 and abs((pos[2] >> 4) - loader["chunk_z"]) <= 1
    return chunky and near


def steps(ctx):
    placed = drv.setup(ctx)
    loaders = ctx.shakeout_fleet["loaders"]
    miners = sorted((n for n, cell in placed.items() if cell["type"] == "MINER"), key=lambda n: (placed[n]["x"], placed[n]["z"]))
    two = [miners[0], miners[-1]]                    # worker bay 2's first dock and support bay 5's last: both sides of the base
    ctx.expect(all(n in loaders for n in two), "the two miners carry fresh loaders (%s)" % {n: loaders.get(n) for n in two})
    held = [n for n in miners if n not in two]
    for n in held:
        ctx.dispatch("HOLD_TURTLE", {"turtleId": n, "reason": "shakeout_fleet_proof: only %s mine" % " and ".join(two)})

    def unheld():    # the server's own 'HOLD: <node> is not offered work' line is the evidence a hold landed
        text = "\n".join(ctx.log_lines("HOLD: node_"))
        return [n for n in held if ("HOLD: %s " % n) not in text]
    ctx.wait_until(lambda: not unheld(), 120)
    missing = unheld()
    ctx.expect(not missing, "the server holds every other miner (%d of %d; not held: %s; 'duplicate ignored' lines: %d)"
               % (len(held) - len(missing), len(held), missing[:8], len(ctx.log_lines("duplicate ignored"))))
    if missing:
        return
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
               "THE IDENTITY EVIDENCE: the two loaders have different chunky uuids, so two tickets (%s, %s)"
               % (first[0].get("uuid"), first[1].get("uuid")))
    ctx.wait_game(HOLD_AFTER_S)
    miner_of = {loaders[n]: int(n.replace("node_", "")) for n in two if n in loaders}

    def clean_look():
        ls = placed_loaders(ctx, wanted)
        if len(ls) != 2:
            return None
        near = {l["computer"]: own_ticket_near(ctx, miner_of[l["computer"]], l) for l in ls}
        return (ls, near) if all(v is False for v in near.values()) else None
    look = ctx.wait_until(clean_look, HOLD_LOOK_S)
    later = placed_loaders(ctx, wanted)
    ctx.note("chunk_loaders() from %d game s after the placements: %s; clean look %s" % (HOLD_AFTER_S, later, look))
    ctx.expect(bool(look), "both loaders still hold their chunks past the 600 s lease, at a look where neither miner's own "
               "chunky upgrade could be holding the chunk (%s; %d of 2 listed at the last look)"
               % (look[1] if look else "no such look in %d game s" % HOLD_LOOK_S, len(later)))
