"""Queue, tenth version (2026-10-27 evening): the ninth's remaining list, plus a way to add runs WITHOUT stopping the driver (every earlier change meant swapping
the driver while a run was in flight). Before each run the driver reads G:\\TurtleOS-Sandbox\\testserver\\queue_extra.jsonl, one JSON object per line:

    {"id": "w3-leftover-coal-b", "scenario": "w3_leftover_coal.py", "args": ["--pin", "<40-hex sha>", "--t2logs"], "where": "front"}

`where` is "front" (run next) or "back" (after everything already queued). The file is emptied once read. Notices go to SPEC-OWNER as in run_queue3.

    python -I -u sandbox/t2/run_queue10.py <pid of the scenario in progress> <pid of the old queue driver(s)...>
"""
import json
import os
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import run_queue as q  # noqa: E402
import run_queue3 as q3  # noqa: E402
import run_queue9 as q9  # noqa: E402

EXTRA = os.path.join(os.path.dirname(q.LOGS), "queue_extra.jsonl")
DONE = ("ts-10x-parent",)         # the run in progress when this driver takes over
PENDING = [r for r in q9.RUNS if r[0] not in DONE]
# W3's rewritten leftover-coal scenario (FORCE_REFUEL at fuel 70,000), ~5 game minutes, goes in with his other short runs
_i = next(i for i, r in enumerate(PENDING) if r[0] == "w3-zone-topup") + 1
PENDING.insert(_i, ("w3-leftover-coal-b", "w3_leftover_coal.py", ["--pin", q3.BFC, "--t2logs"]))


def read_extra():
    """Moves the queue_extra.jsonl items into PENDING and empties the file."""
    if not os.path.exists(EXTRA):
        return
    try:
        with open(EXTRA, encoding="utf-8") as f:
            text = f.read()
        open(EXTRA, "w").close()
    except OSError:
        return
    front, back = [], []
    for line in text.splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            o = json.loads(line)
            item = (o["id"], o["scenario"], list(o["args"]))
        except (ValueError, KeyError, TypeError) as e:
            print("ignored a bad queue_extra line (%s): %s" % (e, line[:120]), flush=True)
            continue
        (front if o.get("where", "back") == "front" else back).append(item)
        print("queue_extra: added %s (%s) at the %s" % (item[0], item[1], o.get("where", "back")), flush=True)
    PENDING[:0] = front
    PENDING.extend(back)


def main():
    child = int(sys.argv[1])
    old_drivers = [int(x) for x in sys.argv[2:]]
    while q.alive(child):
        time.sleep(0.2)
    for pid in old_drivers:
        subprocess.run(["taskkill", "/F", "/PID", str(pid)], capture_output=True)
    time.sleep(1)
    stray = os.path.join(q.LOGS, "ts-10x-1.9.154")
    if os.path.isdir(stray):                      # the old driver got as far as starting its next run
        q3.cleanup("ts-10x-1.9.154")
    time.sleep(30)
    while True:
        read_extra()
        if not PENDING:
            break
        run_id, scen, extra = PENDING.pop(0)
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
    q3.notify("T2 queue: finished (the queue has gone idle)", "The 1x queue has run every item (see queue10.out); the test server is idle.")


if __name__ == "__main__":
    main()
