"""Cost of the finished control mod: idle mean tick time with the mod and without it, alternating (with, without, with, without) so drift
cancels. Each run: fleet booted and idle at 1x, 30 `forge tps` samples (5 minutes) after a 60 s settle.

    python -I sandbox/t2/cost_ab_mod.py

The jar is moved out of the server's mods folder for the 'without' runs and put back at the end (also on an error)."""
import json
import os
import shutil
import statistics
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import prove_mod as pm  # noqa: E402
import run as runmod  # noqa: E402

MODS = r"G:\TurtleOS-Sandbox\testserver\server\mods"
HELD = r"G:\TurtleOS-Sandbox\gradle\held"
JAR = "t2control-0.1.0.jar"


def one(run_id, with_mod):
    os.makedirs(HELD, exist_ok=True)
    held = os.path.join(HELD, JAR)
    live = os.path.join(MODS, JAR)
    if with_mod and not os.path.exists(live):
        shutil.move(held, live)
    if not with_mod and os.path.exists(live):
        shutil.move(live, held)
    runmod.start(run_id)
    vals = pm.sample_tick(run_id, seconds=300, every=10)
    runmod.stop(run_id)
    return vals


def main():
    out = []
    try:
        for i, with_mod in enumerate((True, False, True, False)):
            vals = one("costab-%d" % i, with_mod)
            out.append({"with_mod": with_mod, "mean": statistics.mean(vals), "median": statistics.median(vals), "n": len(vals), "min": min(vals), "max": max(vals)})
            print(json.dumps(out[-1]), flush=True)
    finally:
        held = os.path.join(HELD, JAR)
        if os.path.exists(held) and not os.path.exists(os.path.join(MODS, JAR)):
            shutil.move(held, os.path.join(MODS, JAR))
    w = [r for r in out if r["with_mod"]]
    n = [r for r in out if not r["with_mod"]]
    mean_w, mean_n = statistics.mean(r["mean"] for r in w), statistics.mean(r["mean"] for r in n)
    med_w, med_n = statistics.mean(r["median"] for r in w), statistics.mean(r["median"] for r in n)
    print("mean tick: with %.2f ms, without %.2f ms (%+.1f%%); median: with %.2f, without %.2f (%+.1f%%)"
          % (mean_w, mean_n, (mean_w / mean_n - 1) * 100, med_w, med_n, (med_w / med_n - 1) * 100), flush=True)


if __name__ == "__main__":
    main()
