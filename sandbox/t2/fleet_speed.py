"""Speed of a running T2 run with the fleet working: steps the tick rate and measures the game ticks per real second
actually reached, the mean tick time, and how many fleet log lines the bridge wrote.

    python sandbox/t2/fleet_speed.py <run-id> <rate> [rate ...]
"""
import glob
import json
import os
import re
import sys
import time

sys.path.insert(0, os.path.dirname(__file__))
import run as runmod  # noqa: E402
from rcon import Rcon  # noqa: E402


def gametime(rc):
    return int(re.search(r"(\d+)", rc.command("time query gametime")).group(1))


def log_lines(run):
    n = 0
    for f in glob.glob(os.path.join(run, "bridge", "logs", "*.txt")):
        with open(f, encoding="utf8", errors="replace") as h:
            n += sum(1 for _ in h)
    return n


def main():
    rid = sys.argv[1]
    rates = [int(a) for a in sys.argv[2:]]
    run = runmod.run_dir(rid)
    host, port, pw = open(os.path.join(run, "rcon.txt")).read().split()
    rc = Rcon(host, int(port), pw, timeout=120)
    out = []
    for rate in rates:
        rc.command("tickrate %d" % rate)
        time.sleep(15)
        g0, w0, l0 = gametime(rc), time.time(), log_lines(run)
        time.sleep(60)
        g1, w1, l1 = gametime(rc), time.time(), log_lines(run)
        tps = rc.command("forge tps")
        m = re.search(r"Overall: Mean tick time: ([\d.]+) ms", tps)
        step = {"rate": rate, "ticks_per_real_s": round((g1 - g0) / (w1 - w0), 2), "speed_x": round((g1 - g0) / (w1 - w0) / 20, 2),
                "mean_tick_ms": float(m.group(1)) if m else None, "log_lines_per_game_minute": round((l1 - l0) / ((g1 - g0) / 1200), 2)}
        print(json.dumps(step), flush=True)
        out.append(step)
    rc.command("tickrate 20")
    json.dump(out, open(os.path.join(run, "fleet_speed.json"), "w"), indent=1)
    print("done")


if __name__ == "__main__":
    main()
