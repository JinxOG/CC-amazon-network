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


REPO = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))


def notify(subject, body):
    """Mails SPEC-OWNER (a file under docs/mail, committed and pushed) so a stalled queue surfaces in hours, not days (the 2026-10-22 stall
    went unseen for four days). Never raises: a failed notification must not stop the queue."""
    try:
        out = subprocess.run([sys.executable, "-I", os.path.join(REPO, "tools", "mail.py"), "new", "--to", "SPEC-OWNER", "--from", "SANDBOX",
                              "--kind", "info", "--subject", subject], capture_output=True, text=True, cwd=REPO).stdout.strip().splitlines()
        path = os.path.join(REPO, out[-1])
        with open(path, "a", encoding="utf-8") as f:
            f.write(chr(10) + body + chr(10))
        subprocess.run(["git", "add", path], cwd=REPO, capture_output=True)
        subprocess.run(["git", "commit", "-m", "mail: SANDBOX queue notice" + chr(10) * 2 + "Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>"], cwd=REPO, capture_output=True)
        subprocess.run(["git", "-c", "rebase.autoStash=true", "pull", "--rebase", "origin", "master"], cwd=REPO, capture_output=True)
        subprocess.run(["git", "push", "origin", "HEAD:master"], cwd=REPO, capture_output=True)
    except Exception as e:  # noqa: BLE001
        print("could not send the notice: %s" % e, flush=True)


def keep_failure_evidence(run_id):
    """Copies what a failed start left behind (the bridge's own output, the tail of the server console) to testserver/failures/ before the run folder is
    deleted: 'the bridge did not come up' recurred on the first attempt after a run ended and its cause was lost with the folder."""
    try:
        dest = os.path.join(os.path.dirname(q.LOGS), "failures")
        os.makedirs(dest, exist_ok=True)
        stamp = time.strftime("%Y%m%d-%H%M%S")
        for rel, name in (("bridge/bridge.out", "bridge"), ("console.log", "console")):
            src = os.path.join(q.LOGS, run_id, rel)
            if os.path.exists(src):
                with open(src, "rb") as f:
                    data = f.read()[-20000:]
                with open(os.path.join(dest, "%s-%s-%s.txt" % (run_id, stamp, name)), "wb") as f:
                    f.write(data)
    except OSError:
        pass


def cleanup(run_id):
    keep_failure_evidence(run_id)
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
            notify("T2 queue: %s failed twice" % run_id,
                   "The 1x queue run %s (%s) failed twice. Last output: %s" % (run_id, scen, tail)
                   + chr(10) + "The queue moves on to the next run; this one needs a look.")
            continue
        if scen.startswith("ack_loss"):
            n, a, b = q.ack_loss(run_id)
            print("%s: parked ack loss %.2f%% (%d acks of %d beats, %d baseline lines)" % (run_id, 100 * (1 - a / b) if b else float("nan"), a, b, n), flush=True)


if __name__ == "__main__":
    main()
    notify("T2 queue: finished (the queue has gone idle)", "The 1x queue has run every item (see queue3.out); the test server is idle.")
