"""W3, the bridge update's size ceiling (fix 89ff6c6 and after; SPEC-OWNER's ruling of 2026-11-12, fix 1), layer 2.

T2 run shakeout-faults-a (pin 81bed3e): after the bridge restarted for bridge_slow, the server cleared its log acks and
replayed every ring at 40 lines a source; with 160 turtles that update was over the bridge's 1 MB limit, refused (413,
1,032 times) and re-sent at the same size for ever: from 04:32 the bridge's rollups read pushes=0 to the end of the run.

Here: the shakeout fleet (shakeout.setup: 160 turtles), the feeder keeping it working for WARM_S so every ring fills, then
bridge_down and bridge_slow (the two faults that restart the bridge), one after the other, as the shakeout fires them.

CHECKS (each with its evidence count):
  * the replay was bigger than one update, so the checks below have something to judge: the server's 'Bridge update at its
    512 KB cap' line after a bridge restart;
  * after EVERY bridge start once the fleet is built ('bridge up' in the bridge's own log), a rollup with pushes > 0 within
    120 s, and no rollup with pushes=0 after that until the next bridge start or the end -- measured from the bridge's
    rollups, never from the server's say-so;
  * the server's own lines reach the log after the last fault (the symptom in faults-a: none after 04:31:12).
FIX 3 rides along (the duplicate key, SPEC-OWNER's ruling fix 3), right after the fleet is built, as shakeout-fleet-d met it:
HOLD_TURTLE for every placed turtle posted back to back with NO spacing (straight to /command, not ctx.dispatch, which spaces
its posts 3 ms apart since 2026-11-12). Every one must be held and none dropped as a duplicate; then all are released.
Pin the commit under test. 1x. About 2.5 real hours."""
import datetime
import importlib.util
import os
import re
import time

import run as runmod  # noqa: E402  (sandbox/t2 is on the path: the runner put it there)

from shakeout import schedule  # noqa: E402  (sandbox/t2 is on the path: the runner put it there)

NAME = "w3_push_cap"
SEED = int(os.environ.get("SHAKEOUT_SEED") or 1)
WARM_S = int(os.environ.get("W3_PUSH_CAP_WARM_S") or 3600)
TAIL_S = 10 * 60
RESUME_S = 120

_spec = importlib.util.spec_from_file_location("shakeout_driver", os.path.join(os.path.dirname(os.path.abspath(__file__)), "shakeout.py"))
drv = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(drv)

ROLLUP = re.compile(r"busy rollup: pushes=(\d+)")


def when(line):
    """A log line's own UTC time (the files are not in arrival order: match by timestamp, never by position)."""
    try:
        return datetime.datetime.strptime(line[:23], "%Y-%m-%dT%H:%M:%S.%f")
    except ValueError:
        return None


def the_schedule():
    base = {e["fault"]: e for e in schedule.one_of_each(seed=SEED)}
    down = dict(base["bridge_down"], id="f001", t_ms=WARM_S * 1000)
    slow = dict(base["bridge_slow"], id="f002")
    slow["args"] = dict(slow["args"], ms=1000)   # as in shakeout-faults-a (its proxy measured a 1,005 ms ping)
    slow["t_ms"] = down["t_ms"] + schedule.window_ms(down) + down["quiet_ms"] + 5 * 60 * 1000
    return [down, slow]


def unspaced_holds(ctx, names):
    """Fix 3: HOLD_TURTLE for each of `names`, back to back, no gap; every one held, none dropped as a duplicate."""
    t0 = datetime.datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%S")
    started = time.monotonic()
    for n in names:
        runmod.bridge_post("/command", {"type": "HOLD_TURTLE", "params": {"turtleId": n, "reason": "w3_push_cap unspaced"}})
    took_ms = (time.monotonic() - started) * 1000
    ctx.note("posted %d HOLD_TURTLE back to back in %.0f ms (%.2f ms apart; shakeout-fleet-d lost 29 of 126 that way)"
             % (len(names), took_ms, took_ms / max(1, len(names))))
    ctx.wait_game(60)
    held = {n for n in names for l in ctx.log_lines("HOLD: %s is not offered work" % n) if l[:19] >= t0}
    dups = [l for l in ctx.log_lines("duplicate ignored (HOLD_TURTLE)") if l[:19] >= t0]
    ctx.expect(len(held) == len(names) and not dups, "unspaced holds: %d of %d turtles held, %d dropped as duplicates"
               % (len(held), len(names), len(dups)))
    for n in names:
        ctx.dispatch("RELEASE_TURTLE", {"turtleId": n})
    ctx.wait_game(30)


def steps(ctx):
    placed = drv.setup(ctx)
    unspaced_holds(ctx, sorted(placed))
    t_built = datetime.datetime.utcnow()
    ctx.dispatch("ORDER_MINE", {"x1": 1920, "z1": -2624, "x2": 1984, "z2": -2624, "minerCount": 2})
    sched = the_schedule()
    path = schedule.write_schedule(os.path.join(ctx.run, "schedule.json"), sched, seed=SEED, kind="w3_push_cap")
    span_s = max(e["t_ms"] + schedule.window_ms(e) + e["quiet_ms"] for e in sched) / 1000.0 + TAIL_S
    ctx.note("schedule %s: %s; %.1f real hours" % (path, [(e["id"], e["fault"], e["t_ms"] // 1000, e["args"]) for e in sched],
                                                   span_s / 3600))
    drv.run_loop(ctx, sched, span_s)

    ups = sorted(t for t in (when(l) for l in ctx.log_lines("bridge up")) if t and t > t_built)
    rollups = sorted((when(l), int(ROLLUP.search(l).group(1))) for l in ctx.log_lines("busy rollup: pushes=")
                     if when(l) and ROLLUP.search(l))
    # The cap line is said once a backlog: in run w3-push-cap-a it came at the first failed push of bridge_down's outage
    # (the share halves on a failure), BEFORE the restart, and the replay that followed did not say it again. So it is
    # looked for from shortly before the first fault, and the replay's size is read from the bridge's own rollups:
    # write_kb in the first rollup after each start (940 KB there; the old code sent that as one update).
    t_fault = t_built + datetime.timedelta(seconds=WARM_S - 120)
    capped = [l for l in ctx.log_lines("Bridge update at its") if when(l) and when(l) > t_fault]
    first_kb = []
    for up in ups:
        after = sorted((when(l), l) for l in ctx.log_lines("busy rollup: pushes=") if when(l) and when(l) > up)
        m = after and re.search(r"write_kb=([\d.]+)", after[0][1])
        first_kb.append(float(m.group(1)) if m else 0.0)
    ctx.expect(bool(capped) and max(first_kb or [0]) > 512, "the replay after a bridge restart was bigger than one update, "
               "so the checks below have something to judge (%d 'at its cap' line(s); KB written in the first minute after "
               "each bridge start: %s)" % (len(capped), first_kb))
    ctx.expect(len(ups) >= 3, "the bridge started at least 3 times after the fleet was built (bridge_down's restart, "
               "bridge_slow's move to 3001 and back): %d" % len(ups))
    end = rollups[-1][0] if rollups else None
    for i, up in enumerate(ups):
        nxt = ups[i + 1] if i + 1 < len(ups) else (end or up) + datetime.timedelta(seconds=1)
        mine = [(t, n) for t, n in rollups if up < t < nxt]
        first = next(((t, n) for t, n in mine if n > 0), None)
        resumed = first is not None and (first[0] - up).total_seconds() <= RESUME_S + 5
        later_zero = [t for t, n in mine if first and t > first[0] and n == 0]
        ctx.expect(resumed and not later_zero,
                   "bridge start %s: pushes resumed %s after it, and %d of the %d rollups after that read pushes=0"
                   % (up.strftime("%H:%M:%S"), ("%.0f s" % (first[0] - up).total_seconds()) if first else "never",
                      len(later_zero), len([1 for t, n in mine if first and t > first[0]])))
    last = ups[-1] if ups else t_built
    server_after = [l for l in ctx.log_lines("server#") if when(l) and when(l) > last + datetime.timedelta(seconds=RESUME_S)]
    ctx.expect(len(server_after) >= 10, "the server's own lines reach the log after the last bridge start (%d)" % len(server_after))


def after_stop(ctx):
    return drv.after_stop(ctx)
