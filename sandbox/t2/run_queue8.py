"""Queue, eighth version (2026-10-27 evening): W1's 1.9.154 comparison (three_sectors at 10x on 0a0f664 and on its parent, for ore by sector, batch count and problems) goes first; the rest is what was left of the seventh. Seventh version (2026-10-27 noon): W3's stale-re-send fix f25c84c is the pin for the no-GPS reboot and for a re-run of W1's late-GPS scenario (narrowed to the contract, one game hour after the hosts return). Sixth version: : the fifth plus W3's two batches of short layer-2 runs and the updater run, ahead of the journal re-run and the ack/radio series: takes over from run_queue3.py when the run in progress ends, and puts the not-yet-live changes first
(W1's late-GPS fix 119bdfa, then W3's GPS 3 journal run with the corrected scenario) ahead of the ack/radio series and the optional legacy runs.

    python -I -u sandbox/t2/run_queue8.py <pid of the scenario in progress> <pid of the old queue driver(s)...>
"""
import os
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import run_queue as q  # noqa: E402
import run_queue3 as q3  # noqa: E402

W1_FIX = "119bdfab6c08445932b90157046e375bf3df2acf"
ORE_CHEST = "ff54ed040a088cc0a12bf4ed5b0f43d722b8b654"      # 1.9.153, contains 119bdfa
PARENT = "127189d9033107df14287ee24205cbd3a83e88dd"          # 0a0f664~1
OREPASS = "0a0f6643c8585fe2a4574191ede25c7a5aa34d64"          # 1.9.154: the per-ore table.sort became a single pass
RUNS = [
    # W1 / head engineer: must alter nothing observable; compare ore by sector, batch count and problems with the 1x references and with the parent at the same speed
    ("ts-10x-parent", "three_sectors.py", ["--pin", PARENT, "--tickrate", "200"]),
    ("ts-10x-1.9.154", "three_sectors.py", ["--pin", OREPASS, "--tickrate", "200"]),
    ("w3-boxed-in", "w3_boxed_in.py", ["--pin", q3.BFC, "--t2logs"]),
    ("w3-zone-topup", "w3_zone_topup.py", ["--pin", q3.BFC, "--t2logs"]),
    ("gps3-journal-1x-b", "w3_gps3_journal.py", ["--pin", q.GPS3, "--t2logs"]),
] + [r for r in q3.RUNS
          if r[0] not in ("gps2-1x-b", "mine-zone-1x", "gps3-cost-before", "gps3-cost-after", "legacy-dock-idle")]


def main():
    child = int(sys.argv[1])
    old_drivers = [int(x) for x in sys.argv[2:]]
    while q.alive(child):
        time.sleep(0.2)
    for pid in old_drivers:
        subprocess.run(["taskkill", "/F", "/PID", str(pid)], capture_output=True)
    time.sleep(1)
    stray = os.path.join(q.LOGS, "ack1x-new-1")
    if os.path.isdir(stray):                      # the old driver got as far as starting its next run
        q3.cleanup("ack1x-new-1")
    time.sleep(30)
    for run_id, scen, extra in RUNS:
        for attempt in (1, 2):
            t0 = time.time()
            code, tail = q3.one(run_id, scen, extra)
            print("%s (try %d): exit %s after %.2f h; %s" % (run_id, attempt, code, (time.time() - t0) / 3600, tail), flush=True)
            if code == 0 and os.path.exists(os.path.join(q.LOGS, run_id, "report.md")):
                break
            q3.cleanup(run_id)
        else:
            q3.notify("T2 queue: %s failed twice" % run_id,
                      "The 1x queue run %s (%s) failed twice. Last output: %s" % (run_id, scen, tail) + chr(10) + "The queue moves on; this one needs a look.")
            continue
        if scen.startswith("ack_loss"):
            n, a, b = q.ack_loss(run_id)
            print("%s: parked ack loss %.2f%% (%d acks of %d beats, %d baseline lines)" % (run_id, 100 * (1 - a / b) if b else float("nan"), a, b, n), flush=True)
    q3.notify("T2 queue: finished (the queue has gone idle)", "The 1x queue has run every item (see queue8.out); the test server is idle.")


if __name__ == "__main__":
    main()
