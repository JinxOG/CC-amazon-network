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


def m2():
    here = os.path.dirname(os.path.abspath(__file__))
    NL = chr(10)
    runmod.start("m2-a")
    c = ctl.Control("m2-a")
    t0 = time.time()
    while time.time() - t0 < 300 and len(c.computers()) < 25:
        time.sleep(5)
    c.radio_log("on")
    (rx_spot, tx_spot) = free_spots(c, 2)
    rx = c.spawn_computer(rx_spot[0], rx_spot[1], rx_spot[2], os.path.join(here, "lua", "radio_log.lua"), files={"channels.txt": "777" + NL})
    tx = c.spawn_computer(tx_spot[0], tx_spot[1], tx_spot[2], os.path.join(here, "lua", "radio_send.lua"),
                          files={"probe.txt": NL.join(["777", "778", "T2-PROBE", "1"]) + NL})
    time.sleep(15)

    def received():
        """(receive utc ms, sent utc ms, sequence) for every probe message the receiver's own program saw."""
        out = []
        for line in c.harvest_radio(rx):
            m = re.match(r"(\d+) [\d.]+ 777 778 \S+ T2-PROBE #(\d+) t=(\d+)", line.replace(chr(92) + "n", " "))
            if m:
                out.append((int(m.group(1)), int(m.group(3)), int(m.group(2))))
        return out

    def logged(outcome=None, since=0):
        rows = [l for l in c.t2_lines("radio") if l["channel"] == 777 and l["to"] == rx and l["utc"] >= since and "T2-PROBE" in l["body"]]
        return [l for l in rows if outcome is None or l["outcome"].startswith(outcome)]

    # A baseline
    a0 = int(time.time() * 1000)
    time.sleep(12)
    base = received()
    delays = [r - s_ for r, s_, _ in base if r >= a0]
    record("baseline: the receiver gets the probe messages with no delay, and the log says delivered", len(delays) >= 8 and max(delays) < 150 and len(logged("delivered", a0)) >= 8,
           "%d received, max delay %s ms, %d delivered lines" % (len(delays), max(delays) if delays else None, len(logged("delivered", a0))))

    # B loss 1.0 on the channel for 20 s
    b0 = int(time.time() * 1000)
    reply = c.radio_loss(0, 20000, 1.0, channel=777)
    time.sleep(24)
    lost = logged("lost", b0)
    gone = [r for r in received() if b0 + 1500 <= r[1] <= b0 + 18000]
    fleet = [l for l in c.t2_lines("radio") if l["channel"] == 1 and l["utc"] >= b0 and l["outcome"] == "delivered"]
    record("loss 1.0 for 20 s on channel 777: the probe messages are logged lost and the receiver's program gets none", len(lost) >= 12 and len(gone) == 0,
           "%d lost lines, %d messages sent in the window reached the program; reply %s" % (len(lost), len(gone), reply))
    record("the fleet's own traffic on other channels is untouched meanwhile", len(fleet) >= 20, "%d channel-1 deliveries in the window" % len(fleet))
    b1 = int(time.time() * 1000)
    time.sleep(10)
    record("after the rule expires by itself, delivery resumes", len([r for r in received() if r[1] >= b1]) >= 6 and len(logged("delivered", b1)) >= 6,
           "%d received after expiry" % len([r for r in received() if r[1] >= b1]))

    # C loss 0.0
    c0 = int(time.time() * 1000)
    c.radio_loss(0, 20000, 0.0, channel=777)
    time.sleep(22)
    record("loss 0.0 loses nothing", len(logged("lost", c0)) == 0 and len(logged("delivered", c0)) >= 15, "%d lost, %d delivered" % (len(logged("lost", c0)), len(logged("delivered", c0))))

    # D loss 0.5, seeded
    d0 = int(time.time() * 1000)
    c.radio_loss(0, 50000, 0.5, channel=777, seed=5)
    time.sleep(53)
    nl, nd = len(logged("lost", d0)), len(logged("delivered", d0))
    seq_of = lambda text: int(re.search(r"#(\d+)", text).group(1))  # noqa: E731
    sent_in_window = set(seq_of(l["body"]) for l in logged(None, d0))
    seq_delivered = set(seq_of(l["body"]) for l in logged("delivered", d0))
    seq_received = set(q for r, s_, q in received() if q in sent_in_window)
    inner = set(sorted(sent_in_window)[2:-2])      # the first and last two sequence numbers may straddle the window edges
    record("loss 0.5 loses about half, and exactly the messages the log calls delivered reached the program",
           0.25 <= nl / max(1, nl + nd) <= 0.75 and (seq_delivered & inner) == (seq_received & inner) and len(inner) >= 30,
           "%d lost, %d delivered; the same %d of %d inner messages in the log and at the program" % (nl, nd, len(seq_received & inner), len(inner)))

    # E latency 1000 ms
    e0 = int(time.time() * 1000)
    c.radio_latency(0, 20000, 1000, channel=777)
    time.sleep(26)
    dl = [r - s_ for r, s_, _ in received() if e0 + 1500 <= s_ <= e0 + 17000]
    dl_log = logged("delayed", e0)
    record("latency 1000 ms: the measured gap between sending and the program receiving is 1000 ms (to a tick)", len(dl) >= 8 and all(950 <= x <= 1250 for x in dl) and len(dl_log) >= 8,
           "%d messages, delays %s ms, %d delayed lines" % (len(dl), sorted(dl)[:3] + sorted(dl)[-3:] if dl else None, len(dl_log)))
    e1 = int(time.time() * 1000)
    time.sleep(8)
    late = [r - s_ for r, s_, _ in received() if s_ >= e1 + 1500]
    record("after the latency rule expires, delay is back to nothing", len(late) >= 4 and max(late) < 150, "delays %s" % late[:6])

    # F latency range
    f0 = int(time.time() * 1000)
    c.radio_latency(0, 30000, 0, channel=777, max_ms=1500)
    time.sleep(34)
    rows = [(r, s_, q) for r, s_, q in received() if f0 + 1500 <= s_ <= f0 + 28000]
    ds = [r - s_ for r, s_, _ in rows]
    arrival_order = [q for r, s_, q in sorted(rows)]
    reordered = sum(1 for i in range(1, len(arrival_order)) if arrival_order[i] < arrival_order[i - 1])
    record("latency 0..1500 ms: delays spread over the range", len(ds) >= 15 and min(ds) < 400 and max(ds) > 1000 and max(ds) <= 1700, "min %s max %s over %d messages; %d arrived out of order" % (min(ds) if ds else None, max(ds) if ds else None, len(ds), reordered))

    # G receiver gone while delayed
    g0 = int(time.time() * 1000)
    c.radio_latency(0, 20000, 3000, channel=777)
    time.sleep(6)
    c.command("setblock %d %d %d minecraft:air" % rx_spot)
    c.command("setblock %d %d %d minecraft:air" % (rx_spot[0], rx_spot[1] + 1, rx_spot[2]))
    time.sleep(10)
    gone_lines = logged("dropped_receiver_gone", g0)
    record("a delayed message whose receiver is gone is dropped and logged", len(gone_lines) >= 1, "%d dropped_receiver_gone lines" % len(gone_lines))

    iv = [i["verb"] for i in c.t2_lines("interventions")]
    record("every fault command is in the interventions log with its seed and expiry", iv.count("radio_loss") == 3 and iv.count("radio_latency") == 3 and "seed" in c.t2_lines("interventions")[-1]["args"], iv)
    st = c.t2_status()
    record("no line was dropped", st["radio"]["dropped"] == 0, st)
    runmod.stop("m2-a")


def m3():
    """M3: chunk unload under a loader, proved both ways (the refusal hook holds the chunk down; without a release the loader re-forces)."""
    runmod.start("m3-a")
    c = ctl.Control("m3-a")
    t0 = time.time()
    while time.time() - t0 < 300 and len(c.computers()) < 25:
        time.sleep(5)
    c.events_log("on")
    time.sleep(10)
    loaders = c.chunk_loaders()
    record("the mod lists the chunk-loader turtles whose computers are loaded", len(loaders) >= 1, "%d loaders, first %s" % (len(loaders), loaders[:1]))
    if not loaders:
        runmod.stop("m3-a")
        return
    # The base's loaders stand in the same few chunks and cover each other, so the fault must release EVERY loader near the chunk under
    # test (this is what the simulator's chunk_unload(area) does too): all loaders within 4 chunks of the first one.
    L = loaders[0]
    cx, cz = L["chunk_x"], L["chunk_z"]
    group = [l for l in loaders if max(abs(l["chunk_x"] - cx), abs(l["chunk_z"] - cz)) <= 4]
    gids = sorted(l["computer"] for l in group)
    cid = L["computer"]
    area = ((cx - 4) * 16, (cz - 4) * 16, (cx + 4) * 16 + 15, (cz + 4) * 16 + 15)
    bx, bz = cx * 16 + 8, cz * 16 + 8
    print("chunk (%d,%d); %d of %d loaders within 4 chunks: %s" % (cx, cz, len(group), len(loaders), gids), flush=True)

    def loaded():
        return "passed" in c.command("execute if loaded %d 70 %d" % (bx, bz)).lower()

    def on():
        return any(c.computers().get(i, {}).get("on", False) for i in gids)

    def events_since(ms):
        return len([e for e in c.t2_lines("events") if e["computer"] == cid and e["utc"] >= ms])

    def fl():
        return c.command("forceload query %d %d" % (bx, bz)).strip()[:80]

    # baseline: loaded and alive
    a0 = int(time.time() * 1000)
    time.sleep(8)
    record("before the fault the loader's chunk is loaded and its computer is alive", loaded() and all(c.computers().get(i, {}).get("on", False) for i in gids),
           "chunk (%d,%d) loaded=%s, loaders on=%s; forceload: %s" % (cx, cz, loaded(), len(gids), fl()))

    # B release for 40 s
    b0 = int(time.time() * 1000)
    reply = c.chunk_unload(0, area=area, dur=40000)
    rel = reply[0]
    time.sleep(10)
    record("after the release the chunk is unloaded and the loaders' computers are off", (not loaded()) and (not on()),
           "loaded=%s, any loader computer on=%s; %s" % (loaded(), on(), rel))
    st = c.t2("chunk status")
    record("the loader is listed as released and gone from the loaders list", st["released"] == 1 and not (set(gids) & set(l["computer"] for l in c.chunk_loaders())) and rel.get("tickets_released", 0) >= len(gids), "%s; %s" % (st, rel))

    # C the refusal hook: a ticket request for a chunk inside the released area goes through the one Forge method every chunk-loading mod uses
    p_in = c.t2("chunk probe %d %d" % (cx, cz))
    p_out = c.t2("chunk probe %d %d" % (cx + 30, cz))
    record("a ticket request inside the released area is refused (refusal hook); one outside it is accepted",
           p_in["accepted"] is False and p_in["refusals"] >= 1 and p_out["accepted"] is True, "inside %s; outside %s" % (p_in, p_out))
    # the chunk can be brought back by other means (the loaders do not re-hold it), and goes again when those end
    c.command("forceload add %d %d" % (bx, bz))
    time.sleep(8)
    back_up = loaded()
    c.command("forceload remove %d %d" % (bx, bz))
    time.sleep(10)
    record("brought back by /forceload the loaders do not re-hold it: it goes again when that ends", back_up and (not loaded()), "loaded while forced=%s, after /forceload remove=%s" % (back_up, loaded()))

    # D expiry puts the ticket back
    time.sleep(max(0, 45 - (time.time() * 1000 - b0) / 1000))
    d0 = int(time.time() * 1000)
    time.sleep(15)
    record("when the release runs out the ticket is put back: chunk loaded and the computer boots again", loaded() and all(c.computers().get(i, {}).get("on", False) for i in gids) and c.t2("chunk status")["released"] == 0,
           "loaded=%s, computers on: %s; %s" % (loaded(), [i for i in gids if c.computers().get(i, {}).get("on", False)], c.t2("chunk status")))
    time.sleep(10)
    record("the loader is listed again, with a ticket of its own", set(gids) <= set(l["computer"] for l in c.chunk_loaders()), "%d of %d listed again" % (len(set(gids) & set(l["computer"] for l in c.chunk_loaders())), len(gids)))

    p_after = c.t2("chunk probe %d %d" % (cx, cz))
    record("after the release has run out the same request is accepted again", p_after["accepted"] is True, p_after)
    # E control: with no release, a vanilla forceload add + remove does NOT unload the chunk (the loader re-forced), so C above was the hook, not luck
    c.command("forceload add %d %d" % (bx, bz))
    time.sleep(5)
    c.command("forceload remove %d %d" % (bx, bz))
    time.sleep(10)
    record("control: with no release the chunk stays loaded after the same forceload add and remove", loaded(), "loaded=%s" % loaded())

    # F bad input
    r1 = c.t2("chunk unload 999999 10")
    record("an unknown computer is answered with an error, and nothing changes", "error" in r1 and c.t2("chunk status")["released"] == 0, r1)
    iv = [i["verb"] for i in c.t2_lines("interventions")]
    record("the release is in the interventions log", iv.count("chunk_unload_area") == 1, iv)
    st = c.t2_status()
    record("no line was dropped", st["events"]["dropped"] == 0, st)
    runmod.stop("m3-a")


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
    {"m0": m0, "m0ip": m0_ip, "m1": m1, "m2": m2, "m3": m3}[phase]()
    with open(os.path.join(ROOT, "mod-proof-%s.json" % phase), "w") as f:
        json.dump(results, f, indent=1)
    print("\n".join("%-8s %s" % (r["result"], r["proof"]) for r in results))
