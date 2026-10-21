"""T2 run tool: one disposable test-server run, the real bridge beside it, started and stopped cleanly.

    python sandbox/t2/run.py start <run-id> [--world DIR] [--tickrate N] [--ram 6G]
    python sandbox/t2/run.py status <run-id>
    python sandbox/t2/run.py pin <run-id> <40-hex-commit>              # the real update path, fleet idle
    python sandbox/t2/run.py command <run-id> <TYPE> [json-params]     # POST /command to the local bridge
    python sandbox/t2/run.py stop <run-id>

`start` makes the run folder (prepare_run: world copy, HTTP rules rewritten and checked), copies the real server.js and
public/ from this worktree into <run>/bridge/ (logs land in <run>/bridge/logs), runs them with node from
testserver/bridge-deps, then starts the Minecraft server and waits for "Done". Both processes are started detached and
their pids kept in <run>/pids.json; `stop` stops the server over RCON and the bridge by pid, and nothing else.

The bridge listens on 127.0.0.1:3000 (the one address the computers' HTTP rules allow). The live server is never
named or contacted. The run's RCON password is passed to the bridge, so its Dynmap markers talk to this test server only.
"""
import json
import os
import re
import shutil
import subprocess
import sys
import time
import urllib.request

sys.path.insert(0, os.path.dirname(__file__))
import phase0  # noqa: E402
import prepare_run  # noqa: E402
from rcon import Rcon  # noqa: E402

ROOT = prepare_run.ROOT_DEFAULT
REPO = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
DETACHED = 0x00000008 | 0x00000200  # DETACHED_PROCESS | CREATE_NEW_PROCESS_GROUP


def run_dir(run_id):
    return os.path.join(ROOT, "runs", run_id)


def pids_path(run):
    return os.path.join(run, "pids.json")


def git(*args):
    return subprocess.run(["git", "-C", REPO] + list(args), capture_output=True, text=True).stdout.strip()


def prepare_bridge(run):
    """Copies the real bridge (server.js, package.json, public/) from this worktree into <run>/bridge."""
    b = os.path.join(run, "bridge")
    os.makedirs(b)
    for f in ("server.js", "package.json"):
        shutil.copy(os.path.join(REPO, f), os.path.join(b, f))
    shutil.copytree(os.path.join(REPO, "public"), os.path.join(b, "public"))
    prepare_run.junction(os.path.join(b, "node_modules"), os.path.join(ROOT, "bridge-deps", "node_modules"))
    with open(os.path.join(b, "BRIDGE_SOURCE.txt"), "w") as f:
        f.write("commit %s\ndirty files: %s\n" % (git("rev-parse", "HEAD"), git("status", "--short", "server.js", "public") or "none"))


def start_bridge(run, rcon_port, rcon_password):
    node = shutil.which("node")
    env = dict(os.environ, PORT="3000", RCON_HOST="127.0.0.1", RCON_PORT=str(rcon_port), RCON_PASSWORD=rcon_password)
    for k in ("DASH_USER", "DASH_PASS"):
        env.pop(k, None)
    out = open(os.path.join(run, "bridge", "bridge.out"), "wb")
    p = subprocess.Popen([node, "server.js"], cwd=os.path.join(run, "bridge"), env=env, stdout=out,
                         stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL, creationflags=DETACHED)
    return p.pid


def bridge_get(path, timeout=10):
    with urllib.request.urlopen("http://127.0.0.1:3000" + path, timeout=timeout) as r:
        return r.read().decode("utf8", "replace")


def bridge_post(path, obj, timeout=20):
    req = urllib.request.Request("http://127.0.0.1:3000" + path, data=json.dumps(obj).encode(), method="POST",
                                 headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return r.read().decode("utf8", "replace")


def start(run_id, world=None, tickrate=None, ram="6G"):
    run = prepare_run.prepare(run_id, world or phase0.WORLD, ram=ram)
    prepare_bridge(run)
    host, port, pw = open(os.path.join(run, "rcon.txt")).read().split()
    pids = {"run": run, "started": time.time()}
    pids["bridge"] = start_bridge(run, port, pw)
    for _ in range(30):
        try:
            bridge_get("/ping", 2)
            break
        except Exception:
            time.sleep(1)
    else:
        raise SystemExit("the bridge did not come up; see " + os.path.join(run, "bridge", "bridge.out"))
    proc, log = phase0.start(run)
    pids["server"] = proc.pid
    json.dump(pids, open(pids_path(run), "w"))
    t0 = time.time()
    console = os.path.join(run, "console.log")
    while time.time() - t0 < 900:
        time.sleep(2)
        if proc.poll() is not None:
            raise SystemExit("the server exited during start-up; see " + console)
        if re.search(r"Done \([\d.]+s\)!", open(console, encoding="utf8", errors="replace").read()):
            break
    else:
        raise SystemExit("the server did not finish starting in 15 minutes")
    pids["startup_s"] = round(time.time() - t0, 1)
    json.dump(pids, open(pids_path(run), "w"))
    if tickrate:
        rc = Rcon(host, int(port), pw, timeout=120)
        rc.command("tickrate %d" % tickrate)
        rc.close()
    return run


def stop(run_id):
    run = run_dir(run_id)
    pids = json.load(open(pids_path(run)))
    host, port, pw = open(os.path.join(run, "rcon.txt")).read().split()
    try:
        rc = Rcon(host, int(port), pw, timeout=120)
        rc.command("tickrate 20")
        rc.command("stop")
        rc.close()
    except Exception as e:
        print("rcon stop failed:", e)
    for _ in range(90):
        if not alive(pids["server"]):
            break
        time.sleep(2)
    else:
        subprocess.run(["taskkill", "/F", "/PID", str(pids["server"])], capture_output=True)
    subprocess.run(["taskkill", "/F", "/PID", str(pids["bridge"])], capture_output=True)
    pids["stopped"] = time.time()
    json.dump(pids, open(pids_path(run), "w"))


def fleet_versions():
    """({node: version}, the server's version) from the local bridge's /state."""
    d = json.loads(bridge_get("/state"))
    return {n: t.get("version") for n, t in (d.get("turtles") or {}).items()}, d.get("version")


def code_version(sha):
    """The proto.VERSION of the fleet code at this commit."""
    txt = git("show", sha + ":protocol.lua")
    m = re.search(r'proto\.VERSION\s*=\s*"([^"]+)"', txt)
    return m.group(1) if m else None


def pin(run_id, sha, wait_s=900):
    """Puts the fleet on commit `sha` through the REAL update path: UPDATE_ALL with the commit as its ref
    (central_server stageFanOut -> proto.stageUpdateRef -> updater.lua, fetching raw.githubusercontent.com/<sha>/...).
    Waits until the server and every registered turtle report that commit's version. The commit must already be on
    GitHub, and the fleet should be idle. Returns the versions seen."""
    if not re.fullmatch(r"[0-9a-f]{40}", sha):
        raise SystemExit("pin needs a full 40-hex commit id")
    want = code_version(sha)
    if not want:
        raise SystemExit("cannot read proto.VERSION at " + sha)
    before, server_before = fleet_versions()
    bridge_post("/command", {"type": "UPDATE_ALL", "params": {"ref": sha}})
    t0 = time.time()
    seen = None
    while time.time() - t0 < wait_s:
        time.sleep(10)
        try:
            vers, server_v = fleet_versions()
        except Exception:
            continue  # the server computer restarts onto the new code first
        seen = (vers, server_v)
        if vers and server_v == want and all(v == want for v in vers.values()):
            break
    else:
        raise SystemExit("pin timed out: wanted %s, saw server %s and turtles %s" % (
            want, seen and seen[1], sorted(set((seen[0] or {}).values())) if seen else None))
    lines = ["commit " + sha, "version " + want,
             "before: server %s, turtles %s" % (server_before, sorted(set(before.values()))),
             "seconds: %d" % (time.time() - t0)]
    with open(os.path.join(run_dir(run_id), "PINNED.txt"), "w") as f:
        f.write("\n".join(lines) + "\n")
    return seen


def alive(pid):
    out = subprocess.run(["tasklist", "/FI", "PID eq %d" % pid, "/NH"], capture_output=True, text=True).stdout
    return str(pid) in out


def main():
    cmd = sys.argv[1]
    rid = sys.argv[2]
    if cmd == "start":
        opt = lambda k, d=None: sys.argv[sys.argv.index(k) + 1] if k in sys.argv else d  # noqa: E731
        run = start(rid, opt("--world"), int(opt("--tickrate", 0)) or None, opt("--ram", "6G"))
        print("started", run)
    elif cmd == "stop":
        stop(rid)
        print("stopped", rid)
    elif cmd == "status":
        pids = json.load(open(pids_path(run_dir(rid))))
        print(json.dumps({"server_alive": alive(pids["server"]), "bridge_alive": alive(pids["bridge"]), **pids}, indent=1))
    elif cmd == "pin":
        vers, server_v = pin(rid, sys.argv[3])
        print("pinned: server %s, %d turtles, versions %s" % (server_v, len(vers), sorted(set(vers.values()))))
    elif cmd == "command":
        params = json.loads(sys.argv[4]) if len(sys.argv) > 4 else {}
        print(bridge_post("/command", {"type": sys.argv[3], "params": params}))
    else:
        print(__doc__)


if __name__ == "__main__":
    main()
