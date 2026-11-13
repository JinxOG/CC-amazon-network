"""Shakeout Task 5, the T2 proof of the fault scheduler: EVERY FAULT TYPE FIRED ONCE, in order, with a short schedule.
T2 only; NOT RUN YET (written 2026-11-10).

    python sandbox/t2/scenario.py sandbox/t2/scenarios/shakeout_faults_once.py --pin <sha>      (1x; about 4 real hours)

shakeout.setup(ctx) builds the world and the fleet; one mine job is ordered so a miner is out working when the one-turtle
faults and the chunk unload come (they prefer a turtle off its dock). Then schedule.one_of_each (every fault of
schedule.FAULTS once, in that order, each window short, each starting only after the one before has closed and its quiet time
has passed) is written to <run>/schedule.json and run by wall clock with shakeout.run_loop, which ends with teardown.

CHECKS, one per fault (check_each; each can fail): the fault's 'begin' is in <run>/shakeout/faults.jsonl WITH observed.ok --
one cheap read made right after the verb showing it took effect, so a verb that silently did nothing fails here -- its 'end'
too when it has a window to close (disk_full's end must also see diskFree back up), and at least one INTERVENTION names its
id. Each begin and end line carries its actual wall time (wall_ms, and began_ms on the end line).
Then: no filler file on any disk (run_loop's check), the server process alive and the bridge answering /ping at the end.
"""
import importlib.util
import json
import os

import run as runmod  # noqa: E402  (sandbox/t2 is on the path: the runner put it there)
from shakeout import schedule  # noqa: E402

NAME = "shakeout_faults_once"
SEED = int(os.environ.get("SHAKEOUT_SEED") or 1)
TAIL_S = 15 * 60

_spec = importlib.util.spec_from_file_location("shakeout_driver", os.path.join(os.path.dirname(os.path.abspath(__file__)), "shakeout.py"))
drv = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(drv)


def fault_log(ctx):
    path = os.path.join(ctx.run, "shakeout", "faults.jsonl")
    if not os.path.exists(path):
        return []
    with open(path, encoding="utf8") as f:
        return [json.loads(l) for l in f if l.strip()]


def check_each(ctx, sched):
    """One check per fault. A begin line and an intervention are not enough on their own (a verb whose reply nobody reads can
    do nothing and still log both): the begin's detail must carry observed.ok, the cheap read schedule.py makes right after
    the verb (the computer is off, the hosts are off, the tick rate reads back, the control mod said ok, diskFree fell to
    leave_bytes, the slot is empty, the fuel reads back ...); a window's end must be logged too, with its own end_observed:
    the computer back on, the hosts back on, the tick rate back, the bridge answering AND the fleet's pushes reaching it,
    diskFree back up."""
    log = fault_log(ctx)
    for e in sched:
        mine = [l for l in log if l.get("id") == e["id"]]
        phases = [l["phase"] for l in mine]
        has_end = schedule.APPLY[e["fault"]].end is not None
        marks = [i for i in ctx.interventions if i.get("fault") == e["id"]]
        begin = next((l for l in mine if l["phase"] == "begin"), {})
        observed = (begin.get("detail") or {}).get("observed") or {}
        end = next((l for l in mine if l["phase"] == "end"), {})
        # An end that measured nothing FAILS: until 2026-11-13 a missing end_observed read as ok, and bridge_down passed while the
        # dispatch computer's pushes were refused for the rest of the run (shakeout-faults-a).
        end_seen = (((end.get("detail") or {}).get("end_observed") or {"ok": False, "why": "the end measured nothing"})
                    if end else {"ok": not has_end})
        ok = bool(begin) and observed.get("ok") is True and (not has_end or bool(end)) and end_seen.get("ok") is True and bool(marks)
        ctx.expect(ok, "%s %s fired once and was seen to take effect: phases %s, observed %s%s, %d intervention(s)%s" % (
            e["id"], e["fault"], phases, observed, (", at the end %s" % end_seen) if end else "", len(marks),
            "" if ok else " -- errors: %s" % [l.get("error") for l in mine if l.get("error")]))


def steps(ctx):
    drv.setup(ctx)
    ctx.dispatch("ORDER_MINE", {"x1": 1920, "z1": -2624, "x2": 1984, "z2": -2624, "minerCount": 2})
    sched = schedule.one_of_each(seed=SEED)
    path = schedule.write_schedule(os.path.join(ctx.run, "schedule.json"), sched, seed=SEED, kind="one_of_each")
    span_s = (max(e["t_ms"] + schedule.window_ms(e) + e["quiet_ms"] for e in sched)) / 1000.0 + TAIL_S
    ctx.note("one_of_each schedule written to %s: %d faults over %.1f real hours" % (path, len(sched), span_s / 3600))
    drv.run_loop(ctx, sched, span_s)
    check_each(ctx, sched)
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
