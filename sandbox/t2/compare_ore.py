"""Compares what mining runs produced, from their bridge logs: ore reported by sector, number of DUMPING phases (the ore batches), number of lines of
each severity, and every 'Skipped ...' line in both formats (the old "Skipped N unreachable ores (bedrock/fenced/blocked)" and the 1.9.154
"Skipped N of M attempted (scan S, B below Y=-58): fenced F"), so a rename cannot make a grep find nothing without anyone noticing.

    python -I sandbox/t2/compare_ore.py <run-id> [<run-id> ...]

W1's 1.9.154 test: the change must alter nothing observable, so ore by sector, batches and problems must be equal across the runs."""
import glob
import os
import re
import sys
import collections

RUNS = r"G:\TurtleOS-Sandbox\testserver\runs"


def lines_of(run):
    out = []
    for f in sorted(glob.glob(os.path.join(RUNS, run, "bridge", "logs", "*.txt"))):
        with open(f, encoding="utf8", errors="replace") as fh:
            out += [l.rstrip("\n") for l in fh]
    return out


def summarize(run):
    lines = lines_of(run)
    sectors = collections.OrderedDict()
    for l in lines:
        m = re.search(r"Sector \((-?\d+),(-?\d+)\) done by (\S+) \S+ (\d+) ore mined", l)
        if m:
            sectors.setdefault((int(m.group(1)), int(m.group(2))), []).append(int(m.group(4)))
    dumps = sum(1 for l in lines if "phase: DUMPING" in l and "server#" in l)
    sev = collections.Counter()
    for l in lines:
        m = re.match(r"\S+\s+\S+\s+(INFO|WARN|ERROR|FATAL)\s", l)
        if m:
            sev[m.group(1)] += 1
    skipped_old = [l.split("  ", 2)[-1].strip() for l in lines if re.search(r"Skipped \d+ unreachable ores", l)]
    skipped_new = [l.split("  ", 2)[-1].strip() for l in lines if re.search(r"Skipped \d+ of \d+ attempted", l)]
    return {"sectors": sectors, "dumps": dumps, "severity": dict(sev), "skipped_old": skipped_old, "skipped_new": skipped_new,
            "ore_total": sum(max(v) for v in sectors.values())}


def main():
    runs = sys.argv[1:]
    if not runs:
        print(__doc__)
        sys.exit(2)
    results = {r: summarize(r) for r in runs}
    for r, s in results.items():
        print("== %s" % r)
        print("   ore by sector (every 'done by' line, in order): %s" % {"%d,%d" % k: v for k, v in s["sectors"].items()})
        print("   ore total (largest per sector, summed): %d" % s["ore_total"])
        print("   DUMPING phases (batches): %d" % s["dumps"])
        print("   log lines by severity: %s" % s["severity"])
        print("   'Skipped' lines, old format: %d  new format: %d" % (len(s["skipped_old"]), len(s["skipped_new"])))
        for l in (s["skipped_old"] + s["skipped_new"])[:6]:
            print("      " + l[:200])
    if len(runs) > 1:
        base = results[runs[0]]
        for r in runs[1:]:
            s = results[r]
            print("-- %s vs %s: ore by sector %s, ore total %s, dumps %s" % (
                r, runs[0], "EQUAL" if s["sectors"] == base["sectors"] else "DIFFERENT",
                "equal" if s["ore_total"] == base["ore_total"] else "%d vs %d" % (s["ore_total"], base["ore_total"]),
                "equal" if s["dumps"] == base["dumps"] else "%d vs %d" % (s["dumps"], base["dumps"])))


if __name__ == "__main__":
    main()
