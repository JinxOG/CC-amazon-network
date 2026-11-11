"""Watchdog for a live t2 run: fails fast on the three ways a 1x run gets silently voided.

    python sandbox/t2/watch_run.py <run-id> [--idle-min 10] [--poll 120] [--max-hours 6] [--schedule <run>/schedule.json]

With --schedule (the shakeout's fault schedule) the watchdog knows which silences are on purpose: a quiet window (the entry's
quiet_ms) excuses the silence, and a game server that is gone INSIDE a scheduled restart's window is expected, not STOPPED; pids.json
is re-read every poll, so a relaunched server's new pid counts. The windows are anchored at when each fault ACTUALLY began
(<run>/shakeout/faults.jsonl: wall_ms, and the log time to turn that into a clock time), not at the planned t_ms, because a restart
that fired late would otherwise be a VOID. Without --schedule nothing below changes. --max-hours then defaults to 26 instead of 6.

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
4 the server process is gone; 6 the fleet never came up at all.
"""
import argparse
import datetime
import glob
import json
import os
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import run as runmod  # noqa: E402

SLEEP_IDS = (42, 107, 131)   # 42 entering sleep, 107 resumed, 131 firmware S3 times
SERVER_RESTART_FAULTS = ("world_restart", "restart_burst5", "disk_full")   # the faults that stop the game server process
RESTART_QUIET_S = 600        # one restart and the fleet registering again (schedule.RESTART_QUIET_MS)
RELAUNCH_GRACE_S = 300       # a server may stay down this long after its window closes before it counts as gone


def log_state(run):
    """(total lines, fleet lines, newest mtime) across the bridge's own log files.

    FLEET lines are counted apart from the total on purpose. The bridge writes
    its own "busy rollup" once a minute whether or not anything else is alive,
    so a run whose CC SERVER COMPUTER never started still grows its log
    steadily and looks healthy to a plain line count. That is not theoretical:
    run w1-scan-a came up with computer #95 off, pushed nothing for 15 minutes,
    and sat there until the pin timed out, while every rollup ticked along.
    A line whose source is a node or the server computer is the only evidence
    that the fleet itself is running.
    """
    lines, fleet, newest = 0, 0, 0.0
    for f in glob.glob(os.path.join(run, "bridge", "logs", "*.txt")):
        try:
            with open(f, encoding="utf8", errors="replace") as h:
                for line in h:
                    lines += 1
                    if "node_" in line or "server#" in line or "warehouse#" in line:
                        fleet += 1
            newest = max(newest, os.path.getmtime(f))
        except OSError:
            pass
    return lines, fleet, newest


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


def default_max_hours(schedule_path):
    """6 hours as ever; a 24-hour shakeout watched with --schedule gets 26 so the run's own end comes first."""
    return 26.0 if schedule_path else 6.0


def _epoch(stamp):
    try:
        return datetime.datetime.strptime(stamp, "%Y-%m-%dT%H:%M:%S").timestamp()
    except (TypeError, ValueError):
        return None


def _read_jsonl(path):
    out = []
    try:
        with open(path, encoding="utf8", errors="replace") as f:
            for line in f:
                try:
                    out.append(json.loads(line))
                except ValueError:
                    pass
    except OSError:
        pass
    return out


ANCHOR_PHASES = ("start", "begin", "retry")      # lines that say a fault really began; a "fail" line is not one
START_OPEN_CAP_S = 1800                          # a fault that has started but not logged its begin stays open this long past quiet_ms


def quiet_windows(run, schedule_path, now=None):
    """[{start, end, fault, id, restart}] in epoch seconds: when the fleet is EXPECTED to be silent.

    The start is when the fault really began: the earliest start/begin/retry line for the entry in faults.jsonl gives wall_ms (ms
    since the schedule started) and its log time; the schedule's own epoch is the earliest (log time - wall_ms) seen on such a line,
    since a line is logged after the call that took the time. Failing that, the schedule file's mtime: the run driver writes
    schedule.json just before it starts firing, so it is the schedule's start to within seconds. An entry with no line yet uses its
    planned t_ms. The length is the schedule's quiet_ms; a begin that took long (a restart) extends the window to when its line
    was logged. A fault whose `start` line is there but no begin or fail yet is still running its verb (a restart takes minutes):
    its window stays open (end = now), capped at quiet_ms + 30 minutes. A fault that failed outright has no window. A restart
    fault's end also opens a restart-sized window (a disk fill is undone with another restart).
    """
    now = time.time() if now is None else now
    try:
        with open(schedule_path, encoding="utf8") as f:
            doc = json.load(f)
        entries = doc["entries"] if isinstance(doc, dict) else doc
    except (OSError, ValueError, KeyError, TypeError):
        return []
    lines = _read_jsonl(os.path.join(run, "shakeout", "faults.jsonl"))
    t0s = [_epoch(l.get("time")) - l["wall_ms"] / 1000.0 for l in lines
           if l.get("phase") in ANCHOR_PHASES and isinstance(l.get("wall_ms"), (int, float)) and _epoch(l.get("time")) is not None]
    if t0s:
        epoch0 = min(t0s)
    else:
        try:
            epoch0 = os.path.getmtime(schedule_path)
        except OSError:
            return []
    out = []
    for e in entries:
        quiet_s = (e.get("quiet_ms") or 0) / 1000.0
        restart = e.get("fault") in SERVER_RESTART_FAULTS
        if quiet_s <= 0 and not restart:
            continue
        mine = [l for l in lines if l.get("id") == e.get("id") and isinstance(l.get("wall_ms"), (int, float))]
        phases = {l.get("phase") for l in mine}
        anchors = [l for l in mine if l.get("phase") in ANCHOR_PHASES]
        if "fail" in phases and "begin" not in phases:
            continue
        start = epoch0 + (min(l["wall_ms"] for l in anchors) if anchors else e.get("t_ms", 0)) / 1000.0
        end = start + (quiet_s if quiet_s > 0 else RESTART_QUIET_S)
        for l in mine:
            if l.get("phase") == "begin" and _epoch(l.get("time")) is not None:
                end = max(end, _epoch(l["time"]))
            if l.get("phase") == "end" and restart:
                at = epoch0 + l["wall_ms"] / 1000.0
                out.append({"start": at, "end": at + RESTART_QUIET_S, "fault": e.get("fault"), "id": e.get("id"), "restart": True})
        if "start" in phases and not phases & {"begin", "fail", "undo", "end"}:
            end = max(end, min(now, start + (quiet_s if quiet_s > 0 else RESTART_QUIET_S) + START_OPEN_CAP_S))
        out.append({"start": start, "end": end, "fault": e.get("fault"), "id": e.get("id"), "restart": restart})
    return out


def quiet_reference(last_growth, windows, now):
    """The moment silence is counted from: the last fleet growth, or the end of a quiet window that has begun (capped at now,
    so a window in progress holds the count at zero)."""
    ref = last_growth
    for w in windows:
        if w["start"] <= now:
            ref = max(ref, min(now, w["end"]))
    return ref


def server_down_expected(windows, now):
    """True while a scheduled server restart is under way (its window, plus a grace for the relaunch)."""
    return any(w["restart"] and w["start"] <= now <= w["end"] + RELAUNCH_GRACE_S for w in windows)


def main(argv=None):
    ap = argparse.ArgumentParser()
    ap.add_argument("run_id")
    ap.add_argument("--idle-min", type=float, default=10.0, help="minutes of no new fleet log lines before failing")
    ap.add_argument("--poll", type=int, default=120, help="seconds between checks")
    ap.add_argument("--dead-min", type=float, default=8.0,
                    help="minutes with NO node/server line before calling the fleet dead")
    ap.add_argument("--max-hours", type=float, default=None, help="default 6 (26 with --schedule)")
    ap.add_argument("--schedule", default=None, help="the run's schedule.json: its quiet windows are expected silence")
    a = ap.parse_args(argv)
    if a.max_hours is None:
        a.max_hours = default_max_hours(a.schedule)

    run = runmod.run_dir(a.run_id)
    t0 = time.time()
    pids = {}
    try:
        with open(runmod.pids_path(run)) as f:
            pids = json.load(f)
    except (OSError, ValueError):
        pass

    last_lines, last_fleet, _ = log_state(run)
    last_growth = time.time()
    print("watching %s (idle limit %.0f min, fleet silence limit %.0f min, poll %ds)"
          % (a.run_id, a.idle_min, a.dead_min, a.poll), flush=True)

    while time.time() - t0 < a.max_hours * 3600:
        time.sleep(a.poll)
        now = time.time()
        windows = quiet_windows(run, a.schedule) if a.schedule else []
        lines, fleet, newest = log_state(run)
        if fleet > last_fleet:
            last_fleet, last_growth = fleet, now
        elif lines > last_lines:
            last_lines = lines
        idle = (now - (quiet_reference(last_growth, windows, now) if windows else last_growth)) / 60.0
        print("%s  +%5.1f min  %6d fleet lines (%d total)  quiet %4.1f min"
              % (time.strftime("%H:%M:%S"), (now - t0) / 60.0, fleet, lines, idle), flush=True)

        # The fleet never came up at all. Separate from QUIET because the cause
        # and the response are different: a run with no fleet lines has nothing
        # to measure and should be restarted, not waited on.
        if fleet == 0 and (now - t0) / 60.0 >= a.dead_min:
            print("NO FLEET: %.1f min in and not one line from a node or the server computer "
                  "(%d bridge lines). The CC server computer is probably off -- check "
                  "`computercraft dump` for it before trusting anything in this run."
                  % ((now - t0) / 60.0, lines), flush=True)
            return 6

        slept = slept_since(t0)
        if slept:
            print("VOID: the host slept during this run -- nothing in it is evidence either way:", flush=True)
            for s in slept:
                print("  " + s, flush=True)
            return 2

        if a.schedule:      # a restart changes the server's pid: read it again every poll
            try:
                with open(runmod.pids_path(run)) as f:
                    pids = json.load(f)
            except (OSError, ValueError):
                pass
        srv = pids.get("server")
        if srv and not alive(srv) and a.schedule and server_down_expected(windows, now):
            print("  (server %s is down inside a scheduled restart window: expected)" % srv, flush=True)
        elif srv and not alive(srv):
            print("STOPPED: the server process (%s) is gone after %.1f min" % (srv, (now - t0) / 60.0), flush=True)
            return 4

        if idle >= a.idle_min:
            print("QUIET: no new fleet log line for %.1f min -- the run is not progressing" % idle, flush=True)
            return 3

    print("time limit reached (%.1f h) with the run still live" % a.max_hours, flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
