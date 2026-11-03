"""Reads the capacity.csv a w3_capacity_week_* run writes (sandbox/scenarios/_w3_capacity.lua) and prints, per file on
the server's disk: its first, lowest, peak, median and last size, and the hour of its peak; then the lowest free space,
and the bytes each active job costs in jobs.dat (a least-squares fit of jobs.dat size against the active job count).

    python sandbox/tools/w3_capacity_report.py <run_dir> [<run_dir> ...]
"""
import os
import statistics
import sys


def load(run_dir):
    rows = []
    with open(os.path.join(run_dir, "capacity.csv"), encoding="utf-8") as f:
        next(f)
        for line in f:
            hour, free, mine, deliver, active, files = line.rstrip("\n").split(",", 5)
            sizes = {}
            for item in files.split(";"):
                if "=" in item:
                    name, n = item.rsplit("=", 1)
                    sizes[name] = int(n)
            rows.append({"hour": int(hour), "free": int(free), "mine": int(mine), "deliver": int(deliver),
                         "active": int(active), "files": sizes})
    return rows


def per_job(rows, name="jobs.dat"):
    pts = [(r["active"], r["files"][name]) for r in rows if name in r["files"]]
    if len(pts) < 3 or len({a for a, _ in pts}) < 2:
        return None
    mx, my = statistics.mean(a for a, _ in pts), statistics.mean(b for _, b in pts)
    sxx = sum((a - mx) ** 2 for a, _ in pts)
    slope = sum((a - mx) * (b - my) for a, b in pts) / sxx
    return slope, my - slope * mx, len(pts)


def report(run_dir):
    rows = load(run_dir)
    print("== %s: %d hourly samples (hours %d-%d)" % (os.path.basename(run_dir), len(rows), rows[0]["hour"], rows[-1]["hour"]))
    names = sorted({n for r in rows for n in r["files"]})
    table = []
    for n in names:
        seen = [(r["hour"], r["files"][n]) for r in rows if n in r["files"]]
        sizes = [s for _, s in seen]
        peak_hour = max(seen, key=lambda hs: hs[1])[0]
        table.append((max(sizes), n, sizes[0], min(sizes), statistics.median(sizes), sizes[-1], peak_hour, len(seen)))
    table.sort(reverse=True)
    print("%-26s %9s %9s %9s %9s %9s %6s %6s" % ("file", "first", "lowest", "peak", "median", "last", "peakh", "hours"))
    for peak, n, first, low, med, last, ph, k in table:
        print("%-26s %9d %9d %9d %9d %9d %6d %6d" % (n, first, low, peak, med, last, ph, k))
    low = min(rows, key=lambda r: r["free"])
    print("lowest free %d at hour %d (%d active jobs: %d mine, %d deliver); last free %d" % (
        low["free"], low["hour"], low["active"], low["mine"], low["deliver"], rows[-1]["free"]))
    print("active jobs: median %d, peak %d" % (statistics.median(r["active"] for r in rows), max(r["active"] for r in rows)))
    fit = per_job(rows)
    if fit:
        print("jobs.dat: %.0f bytes per active job + %.0f fixed (fit over %d samples)" % fit)
    used = [sum(r["files"].values()) for r in rows]
    print("bytes in files: lowest %d, peak %d, last %d" % (min(used), max(used), used[-1]))


if __name__ == "__main__":
    for d in sys.argv[1:]:
        report(d)
