"""Direct measurement of a turtle's reboot time on T2 at 1x: how long from turning a computer on until its fleet program is running
(its first event, and its first [INIT] log line at the bridge). Idle fleet, control mod with the event log on.

    python -I sandbox/t2/reboot_time.py <run-id> [samples]
"""
import datetime
import glob
import os
import re
import statistics
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import control as ctl  # noqa: E402
import run as runmod  # noqa: E402


def main():
    rid = sys.argv[1]
    n = int(sys.argv[2]) if len(sys.argv) > 2 else 6
    run = runmod.start(rid)
    c = ctl.Control(rid)
    t0 = time.time()
    while time.time() - t0 < 300 and len(c.computers()) < 25:
        time.sleep(5)
    time.sleep(90)
    c.events_log("on")
    nodes = [i for i in sorted(c.computers()) if c.role_of(i) in ("DELIVERY", "SUPPORT")][:n]
    first_event, first_init = [], []
    for cid in nodes:
        c.shutdown([cid])
        time.sleep(5)
        mark_ms = int(time.time() * 1000)
        c.turn_on([cid])
        deadline = time.time() + 60
        ev = None
        while time.time() < deadline and ev is None:
            ev = next((e["utc"] for e in c.t2_lines("events") if e["computer"] == cid and e["utc"] >= mark_ms), None)
            time.sleep(0.5)
        init = None
        while time.time() < deadline + 30 and init is None:
            for f in glob.glob(os.path.join(run, "bridge", "logs", "*.txt")):
                for line in open(f, encoding="utf8", errors="replace"):
                    if ("node_%d#" % cid) in line:
                        t = datetime.datetime.strptime(line[:23], "%Y-%m-%dT%H:%M:%S.%f").replace(tzinfo=datetime.timezone.utc).timestamp() * 1000
                        if t >= mark_ms and (init is None or t < init):
                            init = t
            if init is None:
                time.sleep(1)
        print("computer %d: first event +%s ms, first log line of the node at the bridge +%s ms" % (cid, ev - mark_ms if ev else None, int(init - mark_ms) if init else None), flush=True)
        if ev:
            first_event.append(ev - mark_ms)
        if init:
            first_init.append(init - mark_ms)
        time.sleep(10)
    for name, v in (("first event", first_event), ("first log line", first_init)):
        if v:
            print("%s: n=%d min %d median %d max %d ms" % (name, len(v), min(v), statistics.median(v), max(v)), flush=True)
    runmod.stop(rid)


if __name__ == "__main__":
    main()
