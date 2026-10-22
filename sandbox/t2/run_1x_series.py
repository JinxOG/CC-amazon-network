"""The 1x series the head engineer asked for (2026-10-22): ack-loss replays on old and current code at 1x, the 5% radio-loss job at 1x,
then a second run of each ack-loss replay. One run after the other (a run is about 4.2 real hours), each result line printed as it lands.

    python -I -u sandbox/t2/run_1x_series.py > series.out
"""
import os
import re
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
OLD = "6cc2bae94ce25c8b95ad5bd6289733cdae93b4b7"     # 1.9.107, the commit before the ack-loss fix
NEW = "aa00793bb1a6d3e6c8927c7670ef12cfd785e06e"     # 1.9.150
RUNS = [
    ("ack1x-old-1", "ack_loss_parked_1x.py", ["--install", OLD, "--t2logs"]),
    ("ack1x-new-1", "ack_loss_parked_1x.py", ["--pin", NEW, "--t2logs"]),
    ("rl5-1x", "radio_loss_5.py", ["--t2logs"]),
    ("ack1x-old-2", "ack_loss_parked_1x.py", ["--install", OLD, "--t2logs"]),
    ("ack1x-new-2", "ack_loss_parked_1x.py", ["--pin", NEW, "--t2logs"]),
]
LOGS = r"G:\TurtleOS-Sandbox\testserver\runs"


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
    for run_id, scen, extra in RUNS:
        subprocess.run(["taskkill", "/F", "/IM", "java.exe"], capture_output=True) if False else None
        t0 = time.time()
        p = subprocess.run([sys.executable, "-I", "-u", os.path.join(HERE, "scenario.py"), os.path.join(HERE, "scenarios", scen), "--run-id", run_id] + extra,
                           capture_output=True, text=True, encoding="utf-8", errors="replace")
        print("%s: exit %s after %.1f h; %s" % (run_id, p.returncode, (time.time() - t0) / 3600, (p.stdout + p.stderr).strip()[-200:]), flush=True)
        if scen.startswith("ack_loss"):
            n, a, b = ack_loss(run_id)
            print("%s: parked ack loss %.2f%% (%d acks of %d beats, %d baseline lines)" % (run_id, 100 * (1 - a / b) if b else float("nan"), a, b, n), flush=True)


if __name__ == "__main__":
    main()
