"""Watchdog for a live t2 run: fails fast on the three ways a 1x run gets silently voided.

    python sandbox/t2/watch_run.py <run-id> [--idle-min 10] [--poll 120] [--max-hours 6]

A 1x test-server run takes tens of minutes to hours with nobody watching, and on 2026-11-02 three separate runs were
lost in ways that all LOOKED like fleet faults and were only noticed at the end:

  - the host suspended to RAM for 51 minutes (run w1-skip-b). On resume ComputerCraft terminated a computer for
    "running over by 3067 s", Minecraft reported 61,430 ticks behind, and the server marked all 17 turtles offline
    inside 18 ms. Nothing was wrong with the fleet. See
    docs/measurements/2026-11-02-host-sleep-destroys-a-1x-run.txt.
  - the fleet went quiet and stayed quiet while the scenario sat in a wait_until with hours left on its budget
    (run w1_skip_reason-1102-101833).
  - the run was healthy but its staging had silently done nothing, so it was measuring the wrong world (w1-skip-c).

The first two are what this watches. It prints one status line per poll and EXITS NON-ZERO the moment something is
wrong, which is the point: a background task that exits raises a notification, so a dead run is noticed in minutes
instead of at the two-hour mark. It changes nothing and reads only the run's own files plus the Windows event log.

The third is not detectable from outside, which is why staging now asserts its own commands (see
sandbox/t2/scenarios/w1_skip_reason.py).

Exit codes: 0 the run ended on its own or the time limit was reached; 2 the host slept; 3 the fleet went quiet;
4 the server process is gone.
"""
import argparse
import glob
import json
import os
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import run as runmod  # noqa: E402

SLEEP_IDS = (42, 107, 131)   # 42 entering sleep, 107 resumed, 131 firmware S3 times


def log_state(run):
    """(total lines, newest mtime) across the bridge's own log files."""
    lines, newest = 0, 0.0
    for f in glob.glob(os.path.join(run, "bridge", "logs", "*.txt")):
        try:
            with open(f, encoding="utf8", errors="replace") as h:
                lines += sum(1 for _ in h)
            newest = max(newest, os.path.getmtime(f))
        except OSError:
            pass
    return lines, newest


def slept_since(epoch):
    """Kernel-Power sleep events newer than `epoch`, as strings. [] when the log cannot be read."""
    ps = ("$t=[datetime]::FromFileTimeUtc(0).AddSeconds(%d);"
          "Get-WinEvent -FilterHashtable @{LogName='System';"
          "ProviderName='Microsoft-Windows-Kernel-Power'} -ErrorAction SilentlyContinue |"
          "Where-Object { $_.Id -in %s -and $_.TimeCreated.ToUniversalTime() -gt $t } |"
          "ForEach-Object { \"$($_.TimeCreated.ToUniversalTime().ToString('s')) Id=$($_.Id)\" }"
          % (epoch + 11644473600, ",".join(str(i) for i in SLEEP_IDS)))
    try:
        p = subprocess.run(["powershell", "-NoProfile", "-NonInteractive", "-Command", ps],
                           capture_output=True, text=True, encoding="utf-8", errors="replace", timeout=120)
    except (OSError, subprocess.SubprocessError):
        return []
    return [l.strip() for l in p.stdout.splitlines() if l.strip()]


def alive(pid):
    try:
        return runmod.alive(pid)
    except Exception:  # noqa: BLE001 - a missing pid is "gone", not a crash
        return False


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("run_id")
    ap.add_argument("--idle-min", type=float, default=10.0, help="minutes of no new fleet log lines before failing")
    ap.add_argument("--poll", type=int, default=120, help="seconds between checks")
    ap.add_argument("--max-hours", type=float, default=6.0)
    a = ap.parse_args()

    run = runmod.run_dir(a.run_id)
    t0 = time.time()
    pids = {}
    try:
        with open(runmod.pids_path(run)) as f:
            pids = json.load(f)
    except (OSError, ValueError):
        pass

    last_lines, _ = log_state(run)
    last_growth = time.time()
    print("watching %s (idle limit %.0f min, poll %ds)" % (a.run_id, a.idle_min, a.poll), flush=True)

    while time.time() - t0 < a.max_hours * 3600:
        time.sleep(a.poll)
        now = time.time()
        lines, newest = log_state(run)
        if lines > last_lines:
            last_lines, last_growth = lines, now
        idle = (now - last_growth) / 60.0
        print("%s  +%5.1f min  %6d fleet lines  quiet %4.1f min"
              % (time.strftime("%H:%M:%S"), (now - t0) / 60.0, lines, idle), flush=True)

        slept = slept_since(t0)
        if slept:
            print("VOID: the host slept during this run -- nothing in it is evidence either way:", flush=True)
            for s in slept:
                print("  " + s, flush=True)
            return 2

        srv = pids.get("server")
        if srv and not alive(srv):
            print("STOPPED: the server process (%s) is gone after %.1f min" % (srv, (now - t0) / 60.0), flush=True)
            return 4

        if idle >= a.idle_min:
            print("QUIET: no new fleet log line for %.1f min -- the run is not progressing" % idle, flush=True)
            return 3

    print("time limit reached (%.1f h) with the run still live" % a.max_hours, flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
