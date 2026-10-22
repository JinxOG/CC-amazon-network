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


def m4():
    """M4: turtle move without a reboot (facing confirmed), and turtle save / restore."""
    here = os.path.dirname(os.path.abspath(__file__))
    runmod.start("m4-a")
    c = ctl.Control("m4-a")
    t0 = time.time()
    while time.time() - t0 < 300 and len(c.computers()) < 25:
        time.sleep(5)
    spots = free_spots(c, 4)
    for (x, y, z) in spots:
        c.command("setblock %d %d %d minecraft:stone" % (x + 1, y, z))      # a stone east of every spot: detect() is true only when facing east
    (sx, sy, sz) = spots[0]
    tid = c.spawn_turtle(sx, sy, sz, "MINER", startup=os.path.join(here, "lua", "uptime_probe.lua"), facing="north")

    def rows():
        out = []
        for line in c.read_disk(tid, "uptime.txt").decode().splitlines():
            parts = line.split()
            if len(parts) == 2:
                out.append((float(parts[0]), parts[1] == "true"))
        return out

    time.sleep(12)
    base = rows()
    record("the probe turtle runs and sees no block while facing north", len(base) >= 5 and not any(d for _, d in base[-3:]), "%d rows, last %s" % (len(base), base[-2:]))

    # B move with facing east to spot 1: the computer stays on, uptime keeps counting, the dump shows the new place, detect now sees the stone
    (mx, my, mz) = spots[1]
    clock_before = rows()[-1][0]
    reply = c.turtle_move(tid, mx, my, mz, "e")
    time.sleep(8)
    r = rows()
    comps = c.computers()
    clocks = [a for a, _ in r]
    monotonic = all(clocks[i] < clocks[i + 1] for i in range(len(clocks) - 1))
    record("move: the turtle is at the new place and the computer stayed on (uptime kept counting, no restart)",
           reply.get("ok") and comps[tid]["pos"] == (mx, my, mz) and comps[tid]["on"] and monotonic and clocks[-1] > clock_before,
           "reply %s; dump %s; uptime %.1f -> %.1f over %d rows, monotonic=%s" % (reply, comps[tid], clock_before, clocks[-1], len(r), monotonic))
    record("move: facing east confirmed (detect sees the stone east of the new place)", all(d for _, d in r[-3:]), "last rows %s" % r[-3:])

    # C every facing, alternating between two spots (a turtle cannot move onto its own block); the second spot has stone on its WEST side only
    (nx, ny, nz) = spots[2]
    c.command("setblock %d %d %d minecraft:air" % (nx + 1, ny, nz))
    c.command("setblock %d %d %d minecraft:stone" % (nx - 1, ny, nz))
    seen = {}
    for f, spot in (("n", (nx, ny, nz)), ("w", (mx, my, mz)), ("s", (nx, ny, nz)), ("e", (mx, my, mz)), ("w", (nx, ny, nz))):
        rep = c.turtle_move(tid, spot[0], spot[1], spot[2], f)
        time.sleep(3)
        seen[f + "@" + ("N" if spot == (nx, ny, nz) else "M")] = (rep.get("ok"), rep.get("facing"), rows()[-1][1])
    record("move: each facing is reported back, and detect agrees where a stone is (east of M, west of N)",
           all(v[0] for v in seen.values()) and seen["e@M"][2] is True and seen["w@N"][2] is True and seen["n@N"][2] is False and seen["w@M"][2] is False and seen["s@N"][2] is False,
           "moves -> %s" % seen)
    bad = c.turtle_move(tid, spots[3][0], spots[3][1] + 4, spots[3][2], "q")
    gone = c.turtle_move(999999, mx, my, mz)
    record("a bad facing or an unknown computer is answered with an error and nothing moves", "error" in bad and "error" in gone, "%s ; %s" % (bad, gone))

    # D save / restore
    c.set_fuel(tid, 777)
    c.set_slot(tid, 3, "minecraft:cobblestone", 9)
    pos0 = c.computers()[tid]["pos"]
    with open(os.path.join(c.disks, str(tid), "marker.txt"), "w") as f:
        f.write("before")
    sv = c.turtle_save(tid, "m4save")
    c.set_fuel(tid, 111)
    c.clear_slot(tid, 3)
    c.set_slot(tid, 5, "minecraft:dirt", 2)
    with open(os.path.join(c.disks, str(tid), "marker.txt"), "w") as f:
        f.write("after")
    c.turtle_move(tid, spots[3][0], spots[3][1], spots[3][2], "w")
    time.sleep(2)
    changed = (c.get_fuel(tid), c.computers()[tid]["pos"])
    rs = c.turtle_restore("m4save")
    time.sleep(10)
    back_fuel = c.get_fuel(tid)
    here_pos = c.computers()[tid]["pos"]
    slot3 = c.get_slot(tid, 3)
    slot5 = c.block_data(here_pos, "Items[{Slot:5b}]")
    marker = open(os.path.join(c.disks, str(tid), "marker.txt")).read()
    record("restore: fuel, position, inventory and the disk folder come back to what was saved",
           sv.get("ok") and rs.get("ok") and back_fuel == 777 and here_pos == pos0 and "cobblestone" in slot3 and "dirt" not in slot5 and marker == "before" and c.computers()[tid]["on"],
           "changed state was fuel/pos %s; after restore fuel %s, pos %s, slot3 %s, slot5 %s, marker %s, on=%s; replies %s %s" % (changed, back_fuel, here_pos, slot3[:60], slot5[:60], marker, c.computers()[tid]["on"], sv, rs))
    time.sleep(8)
    r3 = rows()
    record("restore: the program is running again after the restore", len(r3) >= 2 and r3[-1][0] < 60, "last rows %s" % r3[-2:])
    nosave = c.turtle_restore("nosuchsave")
    record("a restore from a name that was never saved is answered with an error", "error" in nosave, nosave)
    iv = [i["verb"] for i in c.t2_lines("interventions")]
    record("moves, the save and the restore are in the interventions log", iv.count("turtle_move") >= 6 and "turtle_save" in iv and "turtle_restore" in iv, iv)
    runmod.stop("m4-a")


def m5():
    """M5: peripheral stall and fail, proved on the warehouse's own RS probe (type rsBridge), both ways."""
    import datetime
    import glob
    runmod.start("m5-a")
    run = runmod.run_dir("m5-a")
    c = ctl.Control("m5-a")
    t0 = time.time()
    while time.time() - t0 < 300 and len(c.computers()) < 25:
        time.sleep(5)

    def now_iso():
        return datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%S")

    def probes(since):
        """(iso time, ms) of every 'RS probe: listItems Nms' line since `since`, and the text of every 'RS listItems failed' line."""
        ok, bad = [], []
        for f in glob.glob(os.path.join(run, "bridge", "logs", "*.txt")):
            for line in open(f, encoding="utf8", errors="replace"):
                if line[:19] < since:
                    continue
                m = re.search(r"RS probe: listItems (\d+)ms", line)
                if m:
                    ok.append((line[:19], int(m.group(1))))
                elif "RS listItems failed" in line:
                    bad.append(line.strip()[:200])
        return sorted(ok), bad

    time.sleep(20)
    a0 = now_iso()
    time.sleep(40)
    base, _ = probes(a0)
    record("baseline: the warehouse probes the RS bridge about every 10 s and each call is quick", len(base) >= 3 and max(m for _, m in base) < 500, "%d probes, ms %s" % (len(base), [m for _, m in base]))

    # B fail for 45 s
    b0 = now_iso()
    rep = c.rs_offline(0, 45000)
    time.sleep(50)
    ok_b, bad_b = probes(b0)
    during = [x for x in ok_b if x[0] <= b0[:17] + "99"]
    record("fail: while the RS bridge is made to fail the warehouse logs the failure and gets no listing",
           rep.get("ok") and len(bad_b) >= 2 and all("T2 fault" in x for x in bad_b), "%d failure lines, e.g. %s; reply %s" % (len(bad_b), bad_b[:1], rep))
    time.sleep(25)
    c0 = now_iso()
    time.sleep(35)
    after_b, bad_after = probes(c0)
    record("fail: after it expires the probes work again", len(after_b) >= 2 and len(bad_after) == 0, "%d good probes, %d failures after expiry" % (len(after_b), len(bad_after)))

    # C stall 1500 ms for 60 s (under the warehouse's 2 s 'slow' line, so its probe rhythm stays at 10 s)
    d0 = now_iso()
    rep = c.rs_stall(0, 60000, 1.5)
    time.sleep(65)
    stalled, _ = probes(d0)
    record("stall 1.5 s: every probe while it lasts reads at least 1.5 s", rep.get("ok") and len(stalled) >= 3 and min(m for _, m in stalled) >= 1500, "%d probes, ms %s" % (len(stalled), [m for _, m in stalled]))
    e0 = now_iso()
    time.sleep(40)
    recov, _ = probes(e0)
    record("stall: after it expires the probes are quick again", len(recov) >= 2 and max(m for _, m in recov) < 500, "ms %s" % [m for _, m in recov])

    # D a rule for another type changes nothing
    f0 = now_iso()
    c.peripheral_stall(0, 40000, "notAType", 3000)
    time.sleep(45)
    other, _ = probes(f0)
    record("a rule for a different peripheral type has no effect on the RS bridge", len(other) >= 2 and max(m for _, m in other) < 500, "ms %s" % [m for _, m in other])
    st = c.t2("peripheral status")
    record("the mod counted the calls it stalled and failed", st["stalled_calls"] >= 3 and st["failed_calls"] >= 2, st)

    # E a long stall: the warehouse's own rule (2 s is 'slow') backs its probes off to 10 minutes
    g0 = now_iso()
    c.rs_stall(0, 30000, 2.5)
    time.sleep(45)
    slow, _ = probes(g0)
    slowlines = []
    for f in glob.glob(os.path.join(run, "bridge", "logs", "*.txt")):
        for line in open(f, encoding="utf8", errors="replace"):
            if line[:19] >= g0 and "slow, next in" in line:
                slowlines.append(line.strip()[-120:])
    record("stall 2.5 s: the warehouse itself calls the reading slow and backs off (its own rule, seen on the real server)", len(slowlines) >= 1, slowlines[:1])
    iv = [i["verb"] for i in c.t2_lines("interventions")]
    record("the faults are in the interventions log", iv.count("peripheral_fail") == 1 and iv.count("peripheral_stall") == 3, iv)
    runmod.stop("m5-a")


def m6():
    """M6: pause and step, proved on the game clock, on a probe turtle's own uptime, and on the console staying alive."""
    here = os.path.dirname(os.path.abspath(__file__))
    runmod.start("m6-a")
    c = ctl.Control("m6-a")
    t0 = time.time()
    while time.time() - t0 < 300 and len(c.computers()) < 25:
        time.sleep(5)
    (sx, sy, sz) = free_spots(c, 1)[0]
    tid = c.spawn_turtle(sx, sy, sz, "MINER", startup=os.path.join(here, "lua", "uptime_probe.lua"), facing="north")

    def gt():
        for _ in range(8):
            m = re.search(r"(\d+)", c.command("time query gametime"))
            if m:
                return int(m.group(1))
            time.sleep(2)
        raise RuntimeError("no game time")

    def rows():
        return [line for line in c.read_disk(tid, "uptime.txt").decode().splitlines() if line.strip()]

    time.sleep(12)
    g_a = gt()
    time.sleep(5)
    g_b = gt()
    record("running: the game clock advances about 20 ticks a second", 85 <= g_b - g_a <= 115, "%d ticks in 5 s" % (g_b - g_a))

    # B pause for 12 s
    n_rows = len(rows())
    rep = c.pause()
    time.sleep(1)
    g_p0 = gt()
    r_p0 = len(rows())
    time.sleep(12)
    g_p1 = gt()
    r_p1 = len(rows())
    record("pause: the game clock does not move for 12 s, the probe turtle writes nothing, and the console still answers",
           rep.get("paused") and g_p1 == g_p0 and r_p1 == r_p0, "clock %d -> %d, probe rows %d -> %d, reply %s" % (g_p0, g_p1, r_p0, r_p1, rep))
    st = c.t2("status")
    record("status still answers while paused", "dir" in st, list(st)[:4])

    # C step 10 ticks, exactly
    c.step(10)
    time.sleep(3)
    g_s = gt()
    time.sleep(3)
    g_s2 = gt()
    record("step 10: exactly 10 ticks ran and the server paused again", g_s - g_p1 == 10 and g_s2 == g_s, "clock %d -> %d -> %d" % (g_p1, g_s, g_s2))
    c.step(7)
    c.step(7)
    time.sleep(3)
    g_t = gt()
    record("two steps of 7 add up to exactly 14", g_t - g_s2 == 14, "clock %d -> %d" % (g_s2, g_t))
    c.step(200)
    time.sleep(13)
    g_u = gt()
    rows_u = len(rows())
    record("step 200 runs 200 ticks (10 s of game time) and the probe turtle writes about 10 rows meanwhile", g_u - g_t == 200 and 8 <= rows_u - r_p1 <= 14 + 5, "clock %d -> %d, probe rows +%d" % (g_t, g_u, rows_u - r_p1))

    # D resume
    rep2 = c.resume()
    time.sleep(2)
    g_v = gt()
    time.sleep(5)
    g_w = gt()
    record("resume: the clock runs at 20 ticks a second again", 85 <= g_w - g_v <= 115 and not rep2.get("paused"), "%d ticks in 5 s; reply %s" % (g_w - g_v, rep2))
    time.sleep(3)
    r_end = rows()
    clocks = [float(x.split()[0]) for x in r_end]
    record("the probe turtle's own uptime never went backwards (no restart from pausing)", all(clocks[i] < clocks[i + 1] for i in range(len(clocks) - 1)), "%d rows, uptime %.1f .. %.1f" % (len(clocks), clocks[0], clocks[-1]))
    iv = [i["verb"] for i in c.t2_lines("interventions")]
    record("pause, steps and resume are in the interventions log", iv.count("pause") == 1 and iv.count("step") == 4 and iv.count("resume") == 1, iv)
    runmod.stop("m6-a")


def cost():
    """The finished mod (M0-M6 hooks, every fault off, logs off) against the M0 no-mod reading: mean tick time, fleet booted and idle at 1x."""
    runmod.start("cost-a")
    vals = sample_tick("cost-a", seconds=300, every=10)
    mean = sum(vals) / len(vals)
    base = 7.96     # M0 report: the same measurement without the mod (18 samples)
    record("with every hook of the finished mod loaded and every fault off, the idle mean tick time is within 5% of the no-mod reading (7.96 ms, M0)",
           mean <= base * 1.05, "%.2f ms mean over %d samples (min %.2f, max %.2f); no-mod %.2f ms; %+.1f%%" % (mean, len(vals), min(vals), max(vals), base, (mean / base - 1) * 100))
    runmod.stop("cost-a")


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
    {"m0": m0, "m0ip": m0_ip, "m1": m1, "m2": m2, "m3": m3, "m4": m4, "m5": m5, "m6": m6, "cost": cost}[phase]()
    with open(os.path.join(ROOT, "mod-proof-%s.json" % phase), "w") as f:
        json.dump(results, f, indent=1)
    print("\n".join("%-8s %s" % (r["result"], r["proof"]) for r in results))
