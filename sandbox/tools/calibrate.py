"""Compares the sandbox with the live fleet on what the live logs record. Offline: it reads files that were saved earlier
(by an engineer, with the user's say-so); it never contacts the live server.

usage: python sandbox/tools/calibrate.py <live-log-dir> [<sandbox-run-dir> ...]

<live-log-dir> holds the log pages saved from the bridge:
    scan-<date>.json    GET /logs/<date>?contains=scan%20by%20node_&limit=5000&order=head
    head-<date>.json    GET /logs/<date>?limit=3000&order=head           (idle-fleet samples: RS probes, loop rollups)
For each sandbox run folder it prints the same figures, side by side.
"""
import glob
import json
import os
import re
import statistics
import sys
from datetime import datetime


def ts(s):
    return datetime.fromisoformat(s.replace("Z", "+00:00")).timestamp()


def batch_intervals(lines):
    """Seconds between consecutive 'Sector (x,z) Y=n scan by node_N' lines of one node: one per 25-ore batch."""
    by = {}
    for l in lines:
        m = re.match(r"Sector \((-?\d+),(-?\d+)\) Y=(-?\d+) scan by (node_\d+)", l["msg"])
        if m:
            by.setdefault(m.group(4), []).append(ts(l["ts"]))
    out = []
    for times in by.values():
        times.sort()
        out += [b - a for a, b in zip(times, times[1:]) if 5 < b - a < 300]
    return out


def describe(label, xs, unit="s"):
    if not xs:
        print(f"{label}: no data")
        return
    xs = sorted(xs)
    print(f"{label}: n={len(xs)} median={statistics.median(xs):.1f}{unit} p25={xs[len(xs) // 4]:.1f} p75={xs[3 * len(xs) // 4]:.1f}")


def live(dirpath):
    lines = []
    for f in sorted(glob.glob(os.path.join(dirpath, "scan-*.json"))):
        with open(f, "r", encoding="utf-8") as fh:
            lines += json.load(fh).get("lines", [])
    iv = batch_intervals(lines)
    describe("live    25-ore batch interval", iv)
    if iv:
        print(f"         = {25 / statistics.median(iv) * 60:.1f} ores per minute per miner")
    rs = []
    for f in sorted(glob.glob(os.path.join(dirpath, "head-*.json"))):
        with open(f, "r", encoding="utf-8") as fh:
            for l in json.load(fh).get("lines", []):
                m = re.search(r"RS probe: listItems (\d+)ms", l["msg"])
                if m:
                    rs.append(int(m.group(1)))
    describe("live    RS listItems", rs, "ms")


def sandbox(run_dir):
    lines = []
    for f in sorted(glob.glob(os.path.join(run_dir, "logs", "*.txt"))):
        with open(f, "r", encoding="utf-8", errors="replace") as fh:
            for line in fh:
                m = re.match(r"(\S+)\s{2}(\S+)\s+(\S+)\s+(.*)", line.rstrip("\n"))
                if m and m.group(2).startswith("server"):
                    lines.append({"ts": m.group(1), "msg": m.group(4)})
    iv = batch_intervals(lines)
    describe(f"sandbox {os.path.basename(run_dir)[:30]} batch interval", iv)
    try:
        with open(os.path.join(run_dir, "state.json"), "r", encoding="utf-8") as fh:
            st = json.load(fh)
        print(f"         pushBuildMs={st.get('pushBuildMs')} rsBuildMs={st.get('rsBuildMs')} rsPollMs={st.get('rsPollMs')}")
    except OSError:
        pass


if __name__ == "__main__":
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    live(sys.argv[1])
    for d in sys.argv[2:]:
        sandbox(d)
