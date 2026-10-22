"""Proves the T2 control mod, phase by phase, against live test-server runs. Each proof must be able to fail.

    python sandbox/t2/prove_mod.py m0            # load guard, placement guard, cost with everything off

Results go to <testserver>/mod-proof-<phase>.json and are printed; the report for the phase is written from them.
"""
import json
import os
import re
import shutil
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(__file__))
import control as ctl  # noqa: E402
import phase0  # noqa: E402
import prepare_run  # noqa: E402
import run as runmod  # noqa: E402
from rcon import Rcon  # noqa: E402

ROOT = prepare_run.ROOT_DEFAULT
SERVER = os.path.join(ROOT, "server")
JAR = os.path.join(SERVER, "mods", "t2control-0.1.0.jar")
PARKED = os.path.join(SERVER, "mods-left-out", "t2control-0.1.0.jar.parked")

results = []


def record(name, ok, evidence):
    results.append({"proof": name, "result": "PROVED" if ok else "FAILED", "evidence": evidence})
    print(("PROVED" if ok else "FAILED"), "-", name, "-", str(evidence)[:300], flush=True)


def sample_tick(run_id, seconds=180, every=10):
    c = ctl.Control(run_id)
    # wait for the fleet to register so both runs are measured in the same state
    t0 = time.time()
    while time.time() - t0 < 300:
        try:
            if len(json.loads(runmod.bridge_get("/state"))["turtles"]) >= 14:
                break
        except Exception:
            pass
        time.sleep(5)
    time.sleep(60)    # let the first ticks settle
    vals = []
    end = time.time() + seconds
    while time.time() < end:
        m = re.search(r"Overall: Mean tick time: ([\d.]+) ms", c.command("forge tps"))
        if m:
            vals.append(float(m.group(1)))
        time.sleep(every)
    return vals


def console_text(run):
    with open(os.path.join(run, "console.log"), encoding="utf8", errors="replace") as f:
        return f.read()


def try_start(run, wait=240):
    """Starts the server on a prepared run folder and reports whether it reached 'Done' or died, with the console text."""
    shutil.rmtree(os.path.join(run, "crash-reports"), ignore_errors=True)   # a crash report left by the step before is not this step's
    proc, log = phase0.start(run)
    t0 = time.time()
    outcome = "timeout"
    while time.time() - t0 < wait:
        time.sleep(3)
        text = console_text(run)
        if re.search(r"Done \([\d.]+s\)!", text):
            outcome = "started"
            break
        if proc.poll() is not None or "Failed to start the minecraft server" in text or "Mod Loading has failed" in text or os.path.isdir(os.path.join(run, "crash-reports")) and os.listdir(os.path.join(run, "crash-reports")):
            outcome = "refused"
            break
    if proc.poll() is None:
        if outcome == "started":
            try:
                host, port, pw = open(os.path.join(run, "rcon.txt")).read().split()
                rc = Rcon(host, int(port), pw, timeout=60)
                rc.command("stop")
                rc.close()
                proc.wait(timeout=120)
            except Exception:
                subprocess.run(["taskkill", "/F", "/PID", str(proc.pid)], capture_output=True)
        else:
            subprocess.run(["taskkill", "/F", "/PID", str(proc.pid)], capture_output=True)
    log.close()
    return outcome, console_text(run)


def m0():
    # A: without the mod
    if os.path.exists(JAR):
        shutil.move(JAR, PARKED)
    runmod.start("m0-base")
    base = sample_tick("m0-base")
    runmod.stop("m0-base")
    # B: with the mod, everything off
    shutil.move(PARKED, JAR)
    run = runmod.start("m0-with")
    with_mod = sample_tick("m0-with")
    text = console_text(run)
    loaded = re.search(r"t2control loaded: local test server", text) is not None
    record("the mod loads on a run started by run.py (allow file, local ip, CC:Tweaked 1.120.2, AP 0.7.46r)", loaded,
           re.findall(r"\[t2control[^\n]*", text)[:2])
    runmod.stop("m0-with")
    mean = lambda v: sum(v) / len(v)  # noqa: E731
    diff = 100 * (mean(with_mod) - mean(base)) / mean(base)
    record("cost: mean tick time with the mod loaded and everything off, against no mod (bar 2%)", abs(diff) <= 2.0,
           "no mod %.2f ms (%d samples), with the mod %.2f ms (%d samples): %+.1f%%" % (mean(base), len(base), mean(with_mod), len(with_mod), diff))
    # C: no allow file
    allow = os.path.join(run, "t2control.allow")
    saved = open(allow).read()
    os.remove(allow)
    outcome, text = try_start(run)
    record("the server refuses to start without the allow file", outcome == "refused" and "allow file" in text,
           "%s; %s" % (outcome, re.findall(r"t2control refuses to run[^\n]*", text)[:1]))
    open(allow, "w").write(saved)
    # D: server-ip not local
    props = os.path.join(run, "server.properties")
    original = open(props).read()
    open(props, "w").write(original.replace("server-ip=127.0.0.1", "server-ip=0.0.0.0"))
    outcome, text = try_start(run)
    record("the server refuses to start with server-ip not 127.0.0.1", outcome == "refused" and "not 127.0.0.1" in text,
           "%s; %s" % (outcome, re.findall(r"t2control refuses to run[^\n]*", text)[:1]))
    open(props, "w").write(original)
    # E: placement guard, with a real jar in a scanned folder
    decoy = os.path.join(ROOT, "server-47410", "mods")
    os.makedirs(decoy, exist_ok=True)
    shutil.copy(JAR, os.path.join(decoy, "t2control-0.1.0.jar"))
    try:
        refused = False
        try:
            prepare_run.check_placement()
        except SystemExit as e:
            refused = "outside the test server" in str(e)
        record("run.py refuses to start when the jar is in another mods folder", refused, decoy)
    finally:
        shutil.rmtree(decoy, ignore_errors=True)
    record("with the decoy gone the placement guard passes", prepare_run.mod_found_outside() == [], "no copies outside server/mods")


def m0_ip():
    """Re-proves the server-ip refusal on the run left by m0 (its first attempt was fooled by a crash report from the step before)."""
    run = runmod.run_dir("m0-with")
    props = os.path.join(run, "server.properties")
    original = open(props).read()
    open(props, "w").write(original.replace("server-ip=127.0.0.1", "server-ip=0.0.0.0"))
    try:
        outcome, text = try_start(run)
    finally:
        open(props, "w").write(original)
    record("the server refuses to start with server-ip not 127.0.0.1", outcome == "refused" and "not 127.0.0.1" in text,
           "%s; %s" % (outcome, re.findall(r"t2control refuses to run[^\n]*", text)[:1]))
    # and the same run with the right ip starts (so the refusal above was the guard, not something else)
    outcome, text = try_start(run)
    record("the same run, with server-ip back to 127.0.0.1, starts", outcome == "started", outcome)


if __name__ == "__main__":
    phase = sys.argv[1]
    {"m0": m0, "m0ip": m0_ip}[phase]()
    with open(os.path.join(ROOT, "mod-proof-%s.json" % phase), "w") as f:
        json.dump(results, f, indent=1)
    print("\n".join("%-8s %s" % (r["result"], r["proof"]) for r in results))
