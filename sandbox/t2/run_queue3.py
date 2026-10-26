"""Queue, third version (2026-10-26): the same order as run_queue2.py, but a failed run cleans up after itself (server, bridge, run folder) and is tried
once more, so one server that does not start cannot cascade into every run after it (it did, on 2026-10-22). The optional legacy runs are last.

    python -I -u sandbox/t2/run_queue3.py > queue3.out
"""
import os
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import run_queue as q  # noqa: E402

DDEFD50 = "ddefd50ba932cb935b57c6e94e4cd3680900003e"
BFC = q.NOJOURNAL
RUNS = [
    ("gps2-1x-b", "w3_gps2_server_check.py", ["--pin", q.GPS2, "--t2logs"]),
    ("mine-zone-1x", "w3_keeps_mine_zone.py", ["--pin", DDEFD50, "--t2logs"]),
    ("gps3-cost-before", "three_sectors.py", ["--pin", BFC]),
    ("gps3-cost-after", "three_sectors.py", ["--pin", q.GPS3]),
    ("ack1x-new-1", "ack_loss_parked_1x.py", ["--pin", q.NEW, "--t2logs"]),
    ("rl5-1x", "radio_loss_5.py", ["--t2logs"]),
    ("rl5-gps-only-1x", "radio_loss_5_gps_only.py", ["--t2logs"]),
    ("rl5-gps6-1x", "radio_loss_5_gps6.py", ["--t2logs"]),
    ("ack1x-old-2", "ack_loss_parked_1x.py", ["--install", q.OLD, "--t2logs"]),
    ("ack1x-new-2", "ack_loss_parked_1x.py", ["--pin", q.NEW, "--t2logs"]),
    # optional (W3, 2026-10-22): legacy cards, only if the watcher cannot judge them from the live logs
    ("legacy-dock-idle", "w3_dock_idle_reboot.py", ["--pin", BFC, "--t2logs"]),
    ("legacy-recheck", "w3_recheck_reboot.py", ["--pin", BFC, "--t2logs"]),
    ("legacy-stray-owner", "w3_stray_owner.py", ["--pin", BFC, "--t2logs"]),
    ("legacy-witness", "w3_witness_comms_gap.py", ["--pin", BFC, "--t2logs"]),
]


def cleanup(run_id):
    """Stops whatever a failed run left behind: its server by its own tool, any bridge still running for it, then its folder."""
    subprocess.run([sys.executable, "-I", os.path.join(q.HERE, "run.py"), "stop", run_id], capture_output=True)
    time.sleep(10)
    ps = ("Get-CimInstance Win32_Process | Where-Object { ($_.Name -eq 'java.exe' -and $_.CommandLine -match 'win_args') -or "
          "($_.Name -eq 'node.exe' -and $_.CommandLine -match 'server\\.js' -and $_.CommandLine -notmatch 'Codex') } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force }")
    subprocess.run(["powershell", "-NoProfile", "-Command", ps], capture_output=True)
    time.sleep(10)
    d = os.path.join(q.LOGS, run_id)
    subprocess.run(["powershell", "-NoProfile", "-Command", "Remove-Item -Recurse -Force '%s' -ErrorAction SilentlyContinue" % d], capture_output=True)


def one(run_id, scen, extra):
    p = subprocess.run([sys.executable, "-I", "-u", os.path.join(q.HERE, "scenario.py"), os.path.join(q.HERE, "scenarios", scen), "--run-id", run_id] + extra,
                       capture_output=True, text=True, encoding="utf-8", errors="replace")
    return p.returncode, (p.stdout + p.stderr).strip()[-200:]


def main():
    for run_id, scen, extra in RUNS:
        for attempt in (1, 2):
            t0 = time.time()
            code, tail = one(run_id, scen, extra)
            print("%s (try %d): exit %s after %.2f h; %s" % (run_id, attempt, code, (time.time() - t0) / 3600, tail), flush=True)
            if code == 0 and os.path.exists(os.path.join(q.LOGS, run_id, "report.md")):
                break
            cleanup(run_id)
        else:
            continue
        if scen.startswith("ack_loss"):
            n, a, b = q.ack_loss(run_id)
            print("%s: parked ack loss %.2f%% (%d acks of %d beats, %d baseline lines)" % (run_id, 100 * (1 - a / b) if b else float("nan"), a, b, n), flush=True)


if __name__ == "__main__":
    main()
