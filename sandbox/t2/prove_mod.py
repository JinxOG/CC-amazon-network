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


def free_spots(c, n):
    """n separate spots with two free blocks above each other near the base."""
    spots = []
    for x in range(160, 200, 3):
        for z in range(-2790, -2750, 3):
            if len(spots) == n:
                return spots
            if all("Test passed" in c.command("execute if block %d %d %d air" % (x, 67 + k, z)) for k in range(3)):
                spots.append((x, 67, z))
    if len(spots) < n:
        raise RuntimeError("not enough free spots")
    return spots


def m1():
    here = os.path.dirname(os.path.abspath(__file__))
    run = runmod.start("m1-b")
    c = ctl.Control("m1-b")
    t0 = time.time()
    while time.time() - t0 < 300 and len(c.computers()) < 25:
        time.sleep(5)
    st = c.t2_status()
    record("logs are off after start and nothing is written", not st["radio_log"] and not st["events_log"] and st["radio"]["written"] == 0
           and st["events"]["written"] == 0, st)
    (rx_spot, tx_spot) = free_spots(c, 2)
    rx = c.spawn_computer(rx_spot[0], rx_spot[1], rx_spot[2], os.path.join(here, "lua", "radio_log.lua"), files={"channels.txt": "777\n"})
    tx = c.spawn_computer(tx_spot[0], tx_spot[1], tx_spot[2], os.path.join(here, "lua", "radio_send.lua"), files={"probe.txt": "777\n778\nT2-PROBE\n"})
    time.sleep(25)
    before = c.t2_status()
    c.radio_log("on")
    c.events_log("on")
    time.sleep(40)
    radio = c.t2_lines("radio")
    probe = [l for l in radio if l["channel"] == 777 and l["body"].startswith("T2-PROBE")]
    record("radio log: the scripted message appears with the right channel, reply channel, receiver, body and outcome",
           len(probe) >= 4 and all(l["to"] == rx and l["reply_channel"] == 778 and l["outcome"] == "delivered" for l in probe),
           "%d lines, e.g. %s" % (len(probe), probe[:1]))
    near = probe[0]["from_pos"].split(",") if probe else ["0", "0", "0"]
    record("radio log: the sender position is the sender's", abs(int(near[0]) - tx_spot[0]) <= 1 and abs(int(near[2]) - tx_spot[2]) <= 1,
           "%s against sender at %s" % (probe[0]["from_pos"] if probe else None, tx_spot))
    fleet = [l for l in radio if l["channel"] == 1 and "HEARTBEAT" in l["body"]]
    record("radio log: fleet heartbeats are logged too", len(fleet) >= 10, "%d heartbeat lines" % len(fleet))
    events = c.t2_lines("events")
    rx_events = [e for e in events if e["computer"] == rx and e["event"] == "modem_message" and "T2-PROBE" in e["args"]]
    tx_timers = [e for e in events if e["computer"] == tx and e["event"] == "timer"]
    record("events log: the receiver was handed the modem_message event, and the sender's own timer events are logged",
           len(rx_events) >= 4 and len(tx_timers) >= 4, "%d modem_message events at #%d, %d timer events at #%d" % (len(rx_events), rx, len(tx_timers), tx))
    mid = c.t2_status()
    # off: nothing more is written
    c.radio_log("off")
    c.events_log("off")
    time.sleep(3)
    s1 = c.t2_status()
    time.sleep(20)
    s2 = c.t2_status()
    record("with logging switched off nothing more is written (the same sender keeps sending)",
           s1["radio"]["written"] == s2["radio"]["written"] and s1["events"]["written"] == s2["events"]["written"] and s1["radio"]["written"] > 0,
           "radio %d -> %d, events %d -> %d" % (s1["radio"]["written"], s2["radio"]["written"], s1["events"]["written"], s2["events"]["written"]))
    iv = c.t2_lines("interventions")
    record("interventions: every switch is recorded with its arguments", [i["verb"] + ":" + i["args"]["state"] for i in iv] ==
           ["radio_log:on", "events_log:on", "radio_log:off", "events_log:off"], [i["verb"] + ":" + i["args"]["state"] for i in iv])
    record("no line was dropped", s2["radio"]["dropped"] == 0 and s2["events"]["dropped"] == 0, s2)
    # all: also the attempts that did not reach a program
    c.radio_log("all")
    time.sleep(10)
    c.radio_log("off")
    allr = [l for l in c.t2_lines("radio") if l["outcome"].startswith("not_reached")]
    record("radio log all: attempts that did not reach a program are logged with the reason",
           any(l["outcome"] == "not_reached:channel_closed" for l in allr), "%d not_reached lines, e.g. %s" % (len(allr), allr[:1]))
    runmod.stop("m1-b")


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
    {"m0": m0, "m0ip": m0_ip, "m1": m1}[phase]()
    with open(os.path.join(ROOT, "mod-proof-%s.json" % phase), "w") as f:
        json.dump(results, f, indent=1)
    print("\n".join("%-8s %s" % (r["result"], r["proof"]) for r in results))
