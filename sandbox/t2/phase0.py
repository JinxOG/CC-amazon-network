"""T2 phase 0: start the test server once on a world copy with the safe HTTP rules, nobody logged in, and record
start-up time, memory and tick time. Writes <run>/phase0.json and prints a summary.

    python sandbox/t2/phase0.py <run-id> [--minutes N] [--world DIR]
"""
import json
import os
import re
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(__file__))
import prepare_run  # noqa: E402
from rcon import Rcon  # noqa: E402

ROOT = prepare_run.ROOT_DEFAULT
WORLD = "G:/TurtleOS-Sandbox/worlds/unpacked/2026-10-18_1700/world_live"


def java17():
    base = os.path.expandvars(r"%APPDATA%\ModrinthApp\meta\java_versions")
    for d in sorted(os.listdir(base)):
        if "17" in d and os.path.exists(os.path.join(base, d, "bin", "java.exe")):
            return os.path.join(base, d, "bin", "java.exe")
    raise SystemExit("no Java 17 found in the Modrinth app's java_versions")


def working_set_mb(pid):
    out = subprocess.run(["powershell", "-NoProfile", "-Command", "(Get-Process -Id %d).WorkingSet64/1MB" % pid],
                         capture_output=True, text=True).stdout.strip()
    try:
        return round(float(out), 1)
    except ValueError:
        return None


def start(run):
    cc = os.path.join(run, "world", "serverconfig", "computercraft-server.toml")
    with open(cc, encoding="utf8") as f:
        if not prepare_run.rules_are_safe(f.read()):
            raise SystemExit("refusing to start: unsafe HTTP rules in " + cc)
    log = open(os.path.join(run, "console.log"), "wb")
    args = [java17(), "@user_jvm_args.txt", "@libraries/net/minecraftforge/forge/1.20.1-47.4.20/win_args.txt", "nogui"]
    return subprocess.Popen(args, cwd=run, stdout=log, stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL), log


def main():
    run_id = sys.argv[1]
    minutes = int(sys.argv[sys.argv.index("--minutes") + 1]) if "--minutes" in sys.argv else 5
    world = sys.argv[sys.argv.index("--world") + 1] if "--world" in sys.argv else WORLD
    t0 = time.time()
    run = prepare_run.prepare(run_id, world)
    prep_s = time.time() - t0
    host, port, pw = open(os.path.join(run, "rcon.txt")).read().split()
    t_start = time.time()
    proc, log = start(run)
    result = {"run": run, "prepare_s": round(prep_s, 1), "tps_samples": [], "memory_mb": []}
    done_at = None
    console = os.path.join(run, "console.log")
    while time.time() - t_start < 1500:
        time.sleep(2)
        if proc.poll() is not None:
            result["exited_early"] = proc.returncode
            break
        text = open(console, encoding="utf8", errors="replace").read()
        m = re.search(r"Done \(([\d.]+)s\)!", text)
        if m:
            done_at = time.time()
            result["startup_s_reported"] = float(m.group(1))
            break
    result["startup_s_wall"] = round((done_at or time.time()) - t_start, 1)
    if done_at and proc.poll() is None:
        rc = None
        for _ in range(30):
            try:
                rc = Rcon(host, int(port), pw, timeout=90)
                break
            except OSError:
                time.sleep(2)
        if rc:
            end = time.time() + minutes * 60
            while time.time() < end and proc.poll() is None:
                tps = rc.command("forge tps")
                result["tps_samples"].append({"t": round(time.time() - done_at), "text": tps})
                result["memory_mb"].append(working_set_mb(proc.pid))
                time.sleep(15)
            result["list"] = rc.command("list")
            try:
                rc.command("stop")
            except Exception:
                pass
            rc.close()
    try:
        proc.wait(timeout=180)
    except subprocess.TimeoutExpired:
        proc.kill()
    log.close()
    text = open(console, encoding="utf8", errors="replace").read()
    result["console_lines"] = text.count("\n")
    result["error_lines"] = [l for l in text.splitlines() if "/ERROR]" in l or "Exception" in l][:40]
    with open(os.path.join(run, "phase0.json"), "w") as f:
        json.dump(result, f, indent=1)
    print(json.dumps({k: v for k, v in result.items() if k not in ("tps_samples", "error_lines")}, indent=1))
    print("last tps:", result["tps_samples"][-1]["text"] if result["tps_samples"] else None)
    print("errors:", len(result["error_lines"]))


if __name__ == "__main__":
    main()
