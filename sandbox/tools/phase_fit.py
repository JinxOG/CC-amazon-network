"""Times the phases of the three-sector job in a sandbox run and compares them with the live job_0206 (W3's report,
2026-10-20) and the T2 run at 10x. Used to fit the per-action times in sandbox/timings.lua (spec: calibration note).

    python sandbox/tools/phase_fit.py <run-dir>                       # phases of one run
    python sandbox/tools/phase_fit.py --grid move=350,400 dig=150,250 scan=1000,2000   # runs and ranks them
"""
import datetime
import itertools
import glob
import os
import re
import subprocess
import sys

LIVE = {"survey": 1762, "nonore_sectors": 467, "ore_sector": 9496, "rescan": 698, "remine": 757, "tail": 841, "total": 14021}
REPO = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))


def ts(line):
    return datetime.datetime.fromisoformat(line[:23].replace("Z", "") + "+00:00").timestamp()


def phases(run_dir):
    lines = []
    for f in sorted(glob.glob(os.path.join(run_dir, "logs", "*.txt"))):
        lines += open(f, encoding="utf8", errors="replace").read().splitlines()
    def first(pat, after=0):
        for l in lines:
            if re.search(pat, l) and ts(l) >= after:
                return ts(l)
        return None
    D = first(r"Dispatched job_")
    S = first(r"survey complete")
    sectors, prev = [], S
    for l in lines:
        m = re.search(r"Sector \(.*?\) done by \S+ \W+ (\d+) ore mined", l)
        if m and S and ts(l) >= S:
            sectors.append((ts(l) - prev, int(m.group(1)), ts(l)))
            prev = ts(l)
            if len(sectors) == 3:
                break
    M = first(r"mine complete — starting rescan") or first(r"mine complete")
    R = first(r"rescan found ore")
    E = first(r"re-mine exhausted")
    J = first(r"Job complete: job_")
    if None in (D, S, M, R, E, J) or len(sectors) < 3:
        return None
    return {"survey": S - D, "nonore_sectors": sum(d for d, ore, _ in sectors if ore == 0), "ore_sector": sum(d for d, ore, _ in sectors if ore > 0),
            "rescan": R - M, "remine": E - R, "tail": J - E, "total": J - D, "ore": sum(o for _, o, _ in sectors)}


def show(name, p):
    print("%-30s" % name + "".join("%10s" % (("%d" % p[k]) if k in p else "-") for k in LIVE) + "   ore %s" % p.get("ore"))


def score(p):
    return sum(((p[k] - LIVE[k]) / LIVE[k]) ** 2 for k in LIVE if k != "total")


def main():
    if sys.argv[1] != "--grid":
        show("live job_0206", LIVE)
        p = phases(sys.argv[1])
        show(os.path.basename(sys.argv[1]), p) if p else print("could not read the phases from", sys.argv[1])
        return
    axes = {a.split("=")[0]: [int(x) for x in a.split("=")[1].split(",")] for a in sys.argv[2:]}
    names = {"move": ["move_ms", "turn_ms", "up_ms", "down_ms"], "dig": ["dig_ms"], "scan": ["scan_ms"], "place": ["place_ms"]}
    print("%-30s" % "" + "".join("%10s" % k for k in LIVE))
    show("live job_0206", LIVE)
    results = []
    for combo in itertools.product(*axes.values()):
        tm = {}
        for axis, v in zip(axes, combo):
            for k in names[axis]:
                tm[k] = v
        tag = "_".join("%s%d" % (a, v) for a, v in zip(axes, combo))
        rd = "G:/TurtleOS-Sandbox/run/fit-" + tag
        if not os.path.exists(rd + "/logs"):
            env = dict(os.environ, SANDBOX_TIMINGS=",".join("%s=%d" % kv for kv in tm.items()))
            subprocess.run(["bash", "sandbox/sim", "run", "sandbox/scenarios/real_world_phases.lua", "--run-dir", rd], cwd=REPO,
                           capture_output=True, text=True, env=env)
        p = phases(rd)
        if p:
            show(tag, p)
            results.append((score(p), tag, p))
    results.sort(key=lambda r: r[0])
    print("\nbest by summed squared relative error over the phases:")
    for s, tag, p in results[:5]:
        print("%.4f %s" % (s, tag))


if __name__ == "__main__":
    main()
