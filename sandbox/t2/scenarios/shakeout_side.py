"""Shakeout plan Task 8 Step 3: THE 1x SIDE TEST on T2 (spec section 2, "The 1x side test"). T2 only.

    python sandbox/t2/scenario.py sandbox/t2/scenarios/shakeout_side.py --pin <sha>      (1x: no --tickrate; about 4 real hours)

Running fast hides radio loss and timeouts (ack loss 2.42% at 10x, 22.82% at 1x), so this run is at normal speed, with a
fleet the size of the live one: bay 1 only. shakeout.setup builds the same world as the 24-hour run and places only
SIDE_CELL's docks -- delivery bay 1 row A (8), support bay 1 row A (8) and four miners of worker bay 2 row A, 20 turtles (spec
owner's call; plan: "16 turtles plus 4 miners"). The seed is still numbered against every dock (fleet.place_fleet `only`).

Then schedule.side_test (3 real hours, the user's call 2026-11-12): a central-server crash, an ATC crash, one world restart and
one total radio blackout, 40 minutes apart, with a short radio loss or latency burst between each pair. run_loop fires it by
wall clock with the feeder sized for 20 turtles (SIDE_FEEDER) and ends with teardown and the end-of-run probe; the shakeout
report (the pass bar's counts) is written by after_stop once the server is stopped.

CHECKS: one per fault, that it fired and was seen to take effect (shakeout_faults_once.check_each); the game server up and the
bridge answering at the end. The pass bar itself is the report's: no turtle lost, everything recovered, none decommissioned.
If it fails it makes cards; it blocks the 24-hour run only if a turtle is decommissioned (spec).
"""
import importlib.util
import json
import os

import run as runmod  # noqa: E402  (sandbox/t2 is on the path: the runner put it there)
from shakeout import schedule  # noqa: E402

NAME = "shakeout_side"
SEED = int(os.environ.get("SHAKEOUT_SEED") or 1)
SIDE_FEEDER = {"min_jobs": 6, "sites": 1, "destinations": 4}


def _load(name, file):
    spec = importlib.util.spec_from_file_location(name, os.path.join(os.path.dirname(os.path.abspath(__file__)), file))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


drv = _load("shakeout_driver", "shakeout.py")
once = _load("shakeout_faults_once_checks", "shakeout_faults_once.py")


def SIDE_CELL(cl):
    """Bay 1 (delivery and support, row A) and four miners of worker bay 2 row A (the slots west of its centre)."""
    if cl["bay"] == 1 and cl["row"] == "A":
        return True
    return cl["type"] == "MINER" and cl["side"] == "WORKER" and cl["bay"] == 2 and cl["row"] == "A" and cl["slot"] < 0


def steps(ctx):
    placed = drv.setup(ctx, only=SIDE_CELL)
    roles = {}
    for cell in placed.values():
        roles[cell["type"]] = roles.get(cell["type"], 0) + 1
    ctx.expect(roles == {"DELIVERY": 8, "SUPPORT": 8, "MINER": 4}, "the side test's fleet is bay 1 plus four miners (%s)" % roles)
    sched = schedule.side_test(SEED)
    seconds = schedule.SIDE_HOURS * 3600
    path = schedule.write_schedule(os.path.join(ctx.run, "schedule.json"), sched, seed=SEED, hours=schedule.SIDE_HOURS,
                                   kind="side_test", fleet=len(placed))
    ctx.note("side test schedule written to %s: %d entries over %.1f real hours, fleet %s" % (path, len(sched),
                                                                                             schedule.SIDE_HOURS, roles))
    drv.run_loop(ctx, sched, seconds, feeder=SIDE_FEEDER)
    once.check_each(ctx, sched)
    try:
        pids = json.load(open(runmod.pids_path(ctx.run)))
        ctx.expect(runmod.alive(pids["server"]), "the game server is up at the end (pid %s)" % pids["server"])
    except (OSError, ValueError, KeyError) as ex:
        ctx.expect(False, "the game server's pid could not be read at the end: %s" % ex)
    try:
        runmod.bridge_get("/ping", 10)
        ctx.expect(True, "the bridge answers /ping on 3000 at the end")
    except Exception as ex:  # noqa: BLE001
        ctx.expect(False, "the bridge does not answer /ping on 3000 at the end: %s" % ex)


def after_stop(ctx):
    """The shakeout report, once the game server is stopped (scenario.py calls it): shakeout.after_stop."""
    return drv.after_stop(ctx)
