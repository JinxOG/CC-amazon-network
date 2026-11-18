"""The server-deafness numbers SPEC-OWNER asked for after T2 shakeout-24h-b (W3, 2026-11-18), from a T2 run's bridge log.

    python -I tools/deaf_metrics.py <run folder> [--from HH:MM] [--to HH:MM]

Prints: LOOP STALL count, the worst and the median stall (ms) and the slowest step's spread; "Server unreachable" lines
per 10 minutes, fleet-wide; MINE jobs sent back to the queue, by reason; deliveries completed. --from/--to (UTC) limit
the window, so a short proof run and a 24 h run can be compared over the same span.
"""
import collections
import glob
import os
import re
import statistics
import sys

STALL = re.compile(r"LOOP STALL: deaf for (\d+)ms(?: \S+ slowest step (\S+))?")
STALL_ANY = re.compile(r"LOOP STALL.*?(\d+)\s*ms")
QUEUED = re.compile(r"Job queued: (job_\d+) \[(\w+)\]")
BACK = re.compile(r"Job (job_\d+) back to queue \(from [^:]+: (.*)\)")
DONE = re.compile(r"server#.*Job complete: (job_\d+)\s*$")


def main(argv):
    if not argv:
        print(__doc__)
        return 2
    run = argv[0]
    lo = hi = None
    if "--from" in argv:
        lo = argv[argv.index("--from") + 1]
    if "--to" in argv:
        hi = argv[argv.index("--to") + 1]
    files = sorted(glob.glob(os.path.join(run, "bridge", "logs", "*.txt")))
    stalls, steps, unreachable = [], collections.Counter(), collections.Counter()
    kind, back, done = {}, collections.Counter(), set()
    for path in files:
        with open(path, encoding="utf8", errors="replace") as f:
            for line in f:
                m = QUEUED.search(line)
                if m:
                    kind[m.group(1)] = m.group(2)      # job types from the whole log, not just the window
                hm = line[11:16]
                if lo and hm < lo:
                    continue
                if hi and hm >= hi:
                    continue
                if "LOOP STALL" in line:
                    m = STALL.search(line) or STALL_ANY.search(line)
                    if m:
                        stalls.append(int(m.group(1)))
                        if m.re is STALL and m.group(2):
                            steps[m.group(2)] += 1
                if "Server unreachable" in line:
                    unreachable[line[:15] + "0"] += 1
                m = BACK.search(line)
                if m and kind.get(m.group(1)) == "MINE":
                    reason = m.group(2).split(":")[0].strip()
                    back[reason] += 1
                m = DONE.search(line)
                if m and kind.get(m.group(1)) == "DELIVER":
                    done.add(m.group(1))
    print("run: %s  window: %s..%s" % (os.path.basename(run.rstrip("/\\")), lo or "start", hi or "end"))
    if stalls:
        print("LOOP STALLs: %d, worst %d ms, median %d ms; slowest steps: %s"
              % (len(stalls), max(stalls), statistics.median(stalls), dict(steps.most_common(4))))
    else:
        print("LOOP STALLs: 0")
    per = sorted(unreachable.items())
    print("'Server unreachable' per 10 min (fleet-wide): %s" % ", ".join("%s %d" % (k[11:16], v) for k, v in per))
    print("  total %d over %d ten-minute windows" % (sum(unreachable.values()), len(per)))
    print("MINE jobs sent back: %d %s" % (sum(back.values()), dict(back)))
    print("DELIVER jobs completed: %d" % len(done))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
