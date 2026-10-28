"""Stops the 1x queue after the run in progress (the user's ruling of 2026-10-27, docs/mail/BATON.md: finish the run in progress, then stop the queue and hand the
test server to the baton holder). Waits for the scenario process to end, then stops the queue driver before it can start the next run, and takes down anything
the driver started in the gap.

    python -I -u sandbox/t2/queue_stop_after.py <pid of the scenario in progress> <pid of the queue driver> [<its parent pid> ...]
"""
import os
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import run_queue as q  # noqa: E402
import run_queue3 as q3  # noqa: E402


def running_scenarios():
    ps = ("Get-CimInstance Win32_Process | Where-Object { $_.Name -match 'python' -and $_.CommandLine -match 'scenario[.]py' } | "
          "ForEach-Object { $_.ProcessId.ToString() + ' ' + $_.CommandLine }")
    out = subprocess.run(["powershell", "-NoProfile", "-Command", ps], capture_output=True, text=True).stdout.strip().splitlines()
    return [l for l in out if l.strip()]


def main():
    child = int(sys.argv[1])
    drivers = [int(x) for x in sys.argv[2:]]
    while q.alive(child):
        time.sleep(0.2)
    for pid in drivers:
        subprocess.run(["taskkill", "/F", "/PID", str(pid)], capture_output=True)
    time.sleep(2)
    strays = running_scenarios()
    for line in strays:                                  # the driver started the next run in the gap: stop it and clean its folder
        pid, _, cmd = line.partition(" ")
        run_id = cmd.split("--run-id")[1].split()[0] if "--run-id" in cmd else None
        subprocess.run(["taskkill", "/F", "/PID", pid], capture_output=True)
        if run_id:
            q3.cleanup(run_id)
            print("stopped the stray run %s" % run_id, flush=True)
    print("queue stopped after the run in progress; strays handled: %d" % len(strays), flush=True)
    # no mail: the ruling asks for none (no progress messages)


if __name__ == "__main__":
    main()
