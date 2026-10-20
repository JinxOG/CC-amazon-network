"""T2 phase 0, tick rate: starts a fresh run, then raises the tick rate step by step with the Clockworks mod's
/tick command (test server only) and records the speed actually reached (game ticks per real second), the mean tick
time and memory.

    python sandbox/t2/tick_probe.py <run-id> [rate ...]
"""
import json
import os
import re
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(__file__))
import phase0  # noqa: E402
import prepare_run  # noqa: E402
from rcon import Rcon  # noqa: E402


def gametime(rc):
    m = re.search(r"(\d+)", rc.command("time query gametime"))
    return int(m.group(1))


def main():
    run_id = sys.argv[1]
    rates = [int(a) for a in sys.argv[2:]] or [20, 40, 60, 100, 160]
    run = prepare_run.prepare(run_id, phase0.WORLD)
    host, port, pw = open(os.path.join(run, "rcon.txt")).read().split()
    proc, log = phase0.start(run)
    out = {"run": run, "steps": []}
    try:
        t0 = time.time()
        while time.time() - t0 < 900:
            time.sleep(3)
            if re.search(r"Done \([\d.]+s\)!", open(os.path.join(run, "console.log"), encoding="utf8", errors="replace").read()):
                break
        time.sleep(45)  # let the first ticks catch up
        rc = Rcon(host, int(port), pw, timeout=120)
        for rate in rates:
            reply = rc.command("tickrate %d" % rate)
            time.sleep(20)  # settle
            g0, w0 = gametime(rc), time.time()
            time.sleep(40)
            g1, w1 = gametime(rc), time.time()
            tps = rc.command("forge tps")
            m = re.search(r"Overall: Mean tick time: ([\d.]+) ms", tps)
            step = {"rate": rate, "command_reply": reply[:120], "ticks_per_real_second": round((g1 - g0) / (w1 - w0), 2),
                    "speed_x": round((g1 - g0) / (w1 - w0) / 20, 2), "mean_tick_ms": float(m.group(1)) if m else None,
                    "memory_mb": phase0.working_set_mb(proc.pid)}
            print(json.dumps(step), flush=True)
            out["steps"].append(step)
        rc.command("tickrate 20")
        rc.command("stop")
    finally:
        try:
            proc.wait(timeout=180)
        except subprocess.TimeoutExpired:
            proc.kill()
        log.close()
    with open(os.path.join(run, "tick_probe.json"), "w") as f:
        json.dump(out, f, indent=1)
    print("done")


if __name__ == "__main__":
    main()
