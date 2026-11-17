"""Deliveries per hour, departure waits and timer-cleared jams, from a sim or T2 run folder's logs.

The numbers SPEC-OWNER asked for, before and after each rule of docs/superpowers/specs/2026-11-17-delivery-pair-and-hole-design.md:
  deliveries/h   -- the server's "Job complete" for DELIVER jobs, over the span from the first dispatch to the last line
  departure wait -- per departure, the longest "Still waiting Ns -- ATC: departure waiting" a turtle logged before it was let in
  timer markers  -- "never staged in" (STAGE_WAIT_S), "Gave up after 120s" (blocked move), "silent ...: booking dropped"
                    (the ATC's sweep): each is a jam that only a timer cleared.
Usage: python tools/pair_metrics.py RUN_FOLDER [RUN_FOLDER ...]"""
import datetime
import glob
import os
import re
import sys


def lines(run):
    out = []
    for f in sorted(glob.glob(os.path.join(run, "logs", "*.txt")) + glob.glob(os.path.join(run, "bridge", "logs", "*.txt"))):
        with open(f, encoding="utf8", errors="replace") as h:
            out += [l.rstrip("\n") for l in h]
    out.sort()
    return out


def ts(l):
    try:
        return datetime.datetime.strptime(l[:23], "%Y-%m-%dT%H:%M:%S.%f")
    except ValueError:
        return None


def metrics(run):
    ls = lines(run)
    deliver, done = set(), set()
    first = None
    waits = {}       # (turtle, departure number) -> longest wait
    depno = {}
    for l in ls:
        m = re.search(r"Dispatched (job_\d+) \[DELIVER\]", l)
        if m:
            deliver.add(m.group(1))
            first = first or ts(l)
        m = re.search(r"server#\S*\s+INFO\s+Job complete: (job_\d+)\s*$", l)
        if m and m.group(1) in deliver:
            done.add(m.group(1))
        m = re.search(r"\[(node_\d+)\]\[WARN\] Still waiting (\d+)s .{0,3} ATC: departure waiting", l)
        if m:
            k = (m.group(1), depno.get(m.group(1), 0))
            waits[k] = max(waits.get(k, 0), int(m.group(2)))
        m = re.search(r"\[(node_\d+)\]\[INFO\] Departing via dispatch lane", l)
        if m:
            depno[m.group(1)] = depno.get(m.group(1), 0) + 1
    last = ts(ls[-1]) if ls else None
    hours = ((last - first).total_seconds() / 3600) if (first and last and last > first) else 0
    w = sorted(waits.values())
    markers = {
        "never staged": sum(1 for l in ls if "never staged in" in l),
        "gave up 120s": sum(1 for l in ls if "Gave up after 120s" in l),
        "swept live": sum(1 for l in ls if re.search(r"silent \d+s: booking dropped", l)),
        "partner silent": sum(1 for l in ls if "Partner silent" in l),
    }
    return {
        "run": os.path.basename(run.rstrip("/\\")),
        "delivered": len(done), "dispatched": len(deliver), "hours": round(hours, 2),
        "per_hour": round(len(done) / hours, 1) if hours else None,
        "departure_waits": len(w), "wait_mean_s": round(sum(w) / len(w)) if w else 0, "wait_max_s": w[-1] if w else 0,
        "markers": markers,
    }


if __name__ == "__main__":
    for r in sys.argv[1:]:
        print(metrics(r))
