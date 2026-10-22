"""The 1x queue after the head engineer's priority change (2026-10-22): GPS 2 layer 2 first, then GPS 3 layer 2 (journal run and the 2% cost
pair), then the rest of the ack-loss / radio-loss series. One run after another, each result line printed as it lands.

    python -I -u sandbox/t2/run_queue.py <pid of the run in progress, or 0> > queue.out

With a pid: waits for that scenario process to end, and stops the older series driver (run_1x_series.py) before it can start its next run.
"""
import os
import re
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
OLD = "6cc2bae94ce25c8b95ad5bd6289733cdae93b4b7"     # 1.9.107, the commit before the ack-loss fix
NEW = "aa00793bb1a6d3e6c8927c7670ef12cfd785e06e"     # 1.9.150
GPS2 = "27fe82c26eb8df50380cae870187ebbe27f5ba6c"
GPS3 = "56ee64292a94c1c29c1b877fe7f332cd256a97e5"
NOJOURNAL = "bfc2770193d011f203ff3ce3f277962bf5851732"
RUNS = [
    ("gps2-1x", "w3_gps2_server_check.py", ["--pin", GPS2, "--t2logs"]),
    ("gps3-journal-1x", "w3_gps3_journal.py", ["--pin", GPS3, "--t2logs"]),
    ("gps3-cost-before", "three_sectors.py", ["--pin", NOJOURNAL]),
    ("gps3-cost-after", "three_sectors.py", ["--pin", GPS3]),
    ("ack1x-new-1", "ack_loss_parked_1x.py", ["--pin", NEW, "--t2logs"]),
    ("rl5-1x", "radio_loss_5.py", ["--t2logs"]),
    ("rl5-gps-only-1x", "radio_loss_5_gps_only.py", ["--t2logs"]),
    ("rl5-gps6-1x", "radio_loss_5_gps6.py", ["--t2logs"]),
    ("ack1x-old-2", "ack_loss_parked_1x.py", ["--install", OLD, "--t2logs"]),
    ("ack1x-new-2", "ack_loss_parked_1x.py", ["--pin", NEW, "--t2logs"]),
]
LOGS = r"G:\TurtleOS-Sandbox\testserver\runs"


def alive(pid):
    out = subprocess.run(["tasklist", "/FI", "PID eq %d" % pid, "/NH"], capture_output=True, text=True).stdout
    return str(pid) in out


def kill_old_driver():
    ps = ("Get-CimInstance Win32_Process | Where-Object { $_.CommandLine -match 'run_1x_series' } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force }")
    subprocess.run(["powershell", "-NoProfile", "-Command", ps], capture_output=True)


def stop_stray_scenarios(own_pid):
    ps = ("Get-CimInstance Win32_Process | Where-Object { $_.CommandLine -match 'scenario.py' -and $_.ProcessId -ne %d } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force }" % own_pid)
    subprocess.run(["powershell", "-NoProfile", "-Command", ps], capture_output=True)


def ack_loss(run_id):
    a = b = n = 0
    d = os.path.join(LOGS, run_id, "bridge", "logs")
    for f in os.listdir(d):
        for line in open(os.path.join(d, f), encoding="utf8", errors="replace"):
            m = re.search(r"\[(node_\d+)\]\[INFO\] loop baseline.*?(\d+) acks for (\d+) beats", line)
            if m:
                n += 1
                a += int(m.group(2))
                b += int(m.group(3))
    return n, a, b


def main():
    pid = int(sys.argv[1]) if len(sys.argv) > 1 else 0
    if pid:
        while alive(pid):
            time.sleep(0.2)
        kill_old_driver()
        time.sleep(1)
        stop_stray_scenarios(os.getpid())
        # if the old driver got as far as starting its next run before it was stopped, take that run's server down by its own tool
        stray = os.path.join(LOGS, "ack1x-new-1")
        if os.path.isdir(stray):
            subprocess.run([sys.executable, "-I", os.path.join(HERE, "run.py"), "stop", "ack1x-new-1"], capture_output=True)
            time.sleep(20)
            subprocess.run(["powershell", "-NoProfile", "-Command", "Remove-Item -Recurse -Force '%s'" % stray], capture_output=True)
        time.sleep(30)          # let the finished run's server and bridge go down
    for run_id, scen, extra in RUNS:
        t0 = time.time()
        p = subprocess.run([sys.executable, "-I", "-u", os.path.join(HERE, "scenario.py"), os.path.join(HERE, "scenarios", scen), "--run-id", run_id] + extra,
                           capture_output=True, text=True, encoding="utf-8", errors="replace")
        print("%s: exit %s after %.2f h; %s" % (run_id, p.returncode, (time.time() - t0) / 3600, (p.stdout + p.stderr).strip()[-200:]), flush=True)
        if scen.startswith("ack_loss"):
            n, a, b = ack_loss(run_id)
            print("%s: parked ack loss %.2f%% (%d acks of %d beats, %d baseline lines)" % (run_id, 100 * (1 - a / b) if b else float("nan"), a, b, n), flush=True)


if __name__ == "__main__":
    main()
