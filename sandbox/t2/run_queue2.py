"""Queue, second version (2026-10-22): GPS 2 layer 2 is run again after the harness bug found in gps2-1x (gps_down shut the server down too), then
the mine-zone run for W3's ddefd50, then the GPS 3 cost pair and the rest of the series. Takes over from run_queue.py when the run it is on ends.

    python -I -u sandbox/t2/run_queue2.py <pid of the scenario in progress> <pid of the old queue driver(s)...>
"""
import os
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import run_queue as q  # noqa: E402

DDEFD50 = "ddefd50ba932cb935b57c6e94e4cd3680900003e"
RUNS = [
    ("gps2-1x-b", "w3_gps2_server_check.py", ["--pin", q.GPS2, "--t2logs"]),
    ("mine-zone-1x", "w3_keeps_mine_zone.py", ["--pin", DDEFD50, "--t2logs"]),
    ("gps3-cost-before", "three_sectors.py", ["--pin", q.NOJOURNAL]),
    ("gps3-cost-after", "three_sectors.py", ["--pin", q.GPS3]),
    ("ack1x-new-1", "ack_loss_parked_1x.py", ["--pin", q.NEW, "--t2logs"]),
    ("rl5-1x", "radio_loss_5.py", ["--t2logs"]),
    ("rl5-gps-only-1x", "radio_loss_5_gps_only.py", ["--t2logs"]),
    ("rl5-gps6-1x", "radio_loss_5_gps6.py", ["--t2logs"]),
    ("ack1x-old-2", "ack_loss_parked_1x.py", ["--install", q.OLD, "--t2logs"]),
    ("ack1x-new-2", "ack_loss_parked_1x.py", ["--pin", q.NEW, "--t2logs"]),
]


def main():
    child = int(sys.argv[1])
    old_drivers = [int(x) for x in sys.argv[2:]]
    while q.alive(child):
        time.sleep(0.2)
    for pid in old_drivers:
        subprocess.run(["taskkill", "/F", "/PID", str(pid)], capture_output=True)
    time.sleep(1)
    # the old driver may have started its next run in the gap: take it down by its own tool and clear its folder
    for stray in ("gps3-cost-before",):
        d = os.path.join(q.LOGS, stray)
        if os.path.isdir(d):
            subprocess.run([sys.executable, "-I", os.path.join(q.HERE, "run.py"), "stop", stray], capture_output=True)
            time.sleep(20)
            subprocess.run(["powershell", "-NoProfile", "-Command", "Get-CimInstance Win32_Process | Where-Object { $_.CommandLine -match 'scenario.py' } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force }"], capture_output=True)
            subprocess.run(["powershell", "-NoProfile", "-Command", "Remove-Item -Recurse -Force '%s'" % d], capture_output=True)
    time.sleep(30)
    for run_id, scen, extra in RUNS:
        t0 = time.time()
        p = subprocess.run([sys.executable, "-I", "-u", os.path.join(q.HERE, "scenario.py"), os.path.join(q.HERE, "scenarios", scen), "--run-id", run_id] + extra,
                           capture_output=True, text=True, encoding="utf-8", errors="replace")
        print("%s: exit %s after %.2f h; %s" % (run_id, p.returncode, (time.time() - t0) / 3600, (p.stdout + p.stderr).strip()[-200:]), flush=True)
        if scen.startswith("ack_loss"):
            n, a, b = q.ack_loss(run_id)
            print("%s: parked ack loss %.2f%% (%d acks of %d beats, %d baseline lines)" % (run_id, 100 * (1 - a / b) if b else float("nan"), a, b, n), flush=True)


if __name__ == "__main__":
    main()
