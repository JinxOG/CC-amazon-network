"""Shakeout Task 5: the fault schedule (sandbox/t2/shakeout/schedule.py) and its simulator replay
(sandbox/scenarios/shakeout_replay.lua). Nothing here talks to a real server: the T2 verbs run against a fake Control (or a
real Control whose rcon is a fake), and the replay runs in the sandbox's Lua interpreter against a recording fake sim.

    python -I sandbox/tests/test_shakeout_schedule.py
"""
import json
import os
import subprocess
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "t2"))
from shakeout import schedule, world  # noqa: E402
import control  # noqa: E402

REPO = os.path.abspath(os.path.join(HERE, "..", ".."))
MIN = 60000
HOUR = 3600000


# ---------------------------------------------------------------------------------------------------------------------
# A fake Control: every verb the APPLY table may call, recorded; computers, GPS hosts and disks as a small world has them
# ---------------------------------------------------------------------------------------------------------------------

class FakeControl:
    def __init__(self, disks):
        self.disks = disks
        self.calls = []
        self.up = True
        self.comps = {95: (136, 67, -2802), 99: (148, 72, -2829), 300: (160, 67, -2786), 48: (322, 92, -2814),
                      49: (322, 92, -2809), 50: (327, 92, -2814), 51: (322, 96, -2814),
                      201: (153, 67, -2806), 202: (167, 67, -2806), 203: (300, 120, -2500)}
        self.roles = {95: "SERVER", 99: "WAREHOUSE", 300: "atc", 201: "DELIVERY", 202: "MINER", 203: "MINER"}
        self.slots = {}
        self.on = {i: True for i in self.comps}
        self.fail_next = []          # verbs that raise once (a dropped connection, say)
        for i in self.comps:
            os.makedirs(os.path.join(disks, str(i)), exist_ok=True)

    def _rec(self, name, *args, **kw):
        if name in self.fail_next:
            self.fail_next.remove(name)
            raise OSError("rcon: connection reset (fake)")
        self.calls.append((name, args, kw))

    def computers(self):
        return {i: {"on": self.on[i], "pos": p} for i, p in self.comps.items()}

    def role_of(self, i):
        return self.roles.get(i)

    def gps_hosts(self):
        return [48, 49, 50, 51]

    def shutdown(self, ids):
        self._rec("shutdown", list(ids))
        for i in ids:
            self.on[i] = False

    def turn_on(self, ids):
        self._rec("turn_on", list(ids))
        for i in ids:
            self.on[i] = True

    def gps_down(self, hosts=None):
        self._rec("gps_down", list(hosts))
        for i in hosts:
            self.on[i] = False
        return hosts

    def world_restart(self):
        self._rec("world_restart")

    def server_crash(self):
        self._rec("server_crash")
        self.up = False

    def restart_after_crash(self):
        self._rec("restart_after_crash")
        self.up = True

    def tick_rate(self, rate):
        self._rec("tick_rate", rate)

    def block_data(self, pos, path=""):
        cid = next(i for i, p in self.comps.items() if p == tuple(pos))
        slot = int(path.split("Slot:")[1].split("b")[0]) if "Slot:" in path else None
        if slot is not None and slot not in self.slots.get(cid, {}):
            return "Found no elements matching %s" % path
        return "%d, %d, %d has the following block data: {}" % tuple(pos)

    def command(self, text):
        self._rec("command", text)
        if text.startswith("execute if block"):
            return "Test passed" if "facing=south" in text else "Test failed"
        return "ok"

    def __getattr__(self, name):
        if name in ("radio_loss", "radio_latency", "chunk_unload", "rs_stall", "rs_offline", "clear_slot", "set_fuel",
                    "set_slot", "turtle_move"):
            return lambda *a, **k: self._rec(name, *a, **k)
        raise AttributeError(name)


class FakeCtx:
    def __init__(self, ctl=None):
        self.run = tempfile.mkdtemp(prefix="shakeout_sched_test")
        self.control = self._raw = ctl or FakeControl(os.path.join(self.run, "disks"))
        self.interventions = []
        self.notes = []
        self.rate = 20
        self.samples = []
        self.g0 = None
        self.shakeout_fleet = {"server": 95, "placed": {"node_201": {"type": "DELIVERY", "x": 153, "y": 67, "z": -2806},
                                                       "node_202": {"type": "MINER", "x": 167, "y": 67, "z": -2806},
                                                       "node_203": {"type": "MINER", "x": 171, "y": 67, "z": -2806}}}

        self.checks = []

    def note(self, text):
        self.notes.append(text)

    def expect(self, ok, message):
        self.checks.append({"ok": bool(ok), "message": message})

    def sample(self):
        raise OSError("no server in a unit test")

    def state(self):
        return {"diskFree": 600000}


def entry(i, t_ms, fault, args, quiet_ms=0):
    return {"id": "f%03d" % i, "t_ms": t_ms, "fault": fault, "args": args, "quiet_ms": quiet_ms}


def calls_of(ctl, name):
    return [c for c in ctl.calls if c[0] == name]


def fillers(ctx):
    out = []
    for d in os.listdir(ctx.control.disks):
        out += [os.path.join(d, f) for f in os.listdir(os.path.join(ctx.control.disks, d)) if f.startswith(schedule.FILLER_PREFIX)]
    return out


# ---------------------------------------------------------------------------------------------------------------------
# The schedule itself
# ---------------------------------------------------------------------------------------------------------------------

class TheSchedule(unittest.TestCase):
    def test_schedule_is_deterministic(self):
        a = schedule.make_schedule(7, 24, schedule.DEFAULT_RATES)
        b = schedule.make_schedule(7, 24, schedule.DEFAULT_RATES)
        self.assertEqual(json.dumps(a, sort_keys=True), json.dumps(b, sort_keys=True))
        c = schedule.make_schedule(8, 24, schedule.DEFAULT_RATES)
        self.assertNotEqual(json.dumps(a, sort_keys=True), json.dumps(c, sort_keys=True), "another seed, another schedule")

    def test_every_fault_type_fires(self):
        self.assertEqual(sorted(schedule.FAULTS), sorted(schedule.DEFAULT_RATES), "every fault has a default rate")
        for seed in range(1, 21):
            s = schedule.make_schedule(seed, 24, schedule.DEFAULT_RATES)
            counts = {f: 0 for f in schedule.FAULTS}
            for e in s:
                counts[e["fault"]] += 1
            for f, n in counts.items():
                want = 1 if f == "restart_burst5" else 3
                self.assertGreaterEqual(n, want, "seed %d: %s fired %d times (%s)" % (seed, f, n, counts))

    def test_the_minimum_counts_hold_even_when_the_rates_ask_for_fewer(self):
        rates = {f: 1 for f in schedule.FAULTS}                 # one a day each: the minimums must win
        s = schedule.make_schedule(3, 24, rates)
        counts = {}
        for e in s:
            counts[e["fault"]] = counts.get(e["fault"], 0) + 1
        self.assertEqual(counts["restart_burst5"], 1)
        self.assertTrue(all(counts[f] >= 3 for f in schedule.FAULTS if f != "restart_burst5"), counts)

    def test_some_faults_land_in_recovery(self):
        for seed in range(1, 21):
            s = schedule.make_schedule(seed, 24, schedule.DEFAULT_RATES)
            times = [e["t_ms"] for e in s]
            self.assertEqual(times, sorted(times))
            close = sum(1 for a, b in zip(times, times[1:]) if b - a <= 10 * MIN)
            self.assertGreaterEqual(close / len(s), 0.10, "seed %d: %d of %d within 10 min of the one before" % (seed, close, len(s)))

    def test_a_sparse_schedule_still_lands_faults_in_recovery(self):
        """Five days at one fault of each kind a day: spaced that thinly, chance alone puts fewer than 10% within 10 minutes of
        the one before for some seeds (measured: 3 of 20 seeds at 6-8% with the chaining switched off); the chaining must."""
        rates = {f: 1 for f in schedule.FAULTS}
        for seed in range(1, 21):
            s = schedule.make_schedule(seed, 120, rates)
            self.assertGreaterEqual(schedule.recovery_share(s), 0.10, "seed %d" % seed)

    def test_the_recovery_check_can_fail(self):
        """The measure itself: evenly spaced faults (one an hour) have none within 10 minutes."""
        s = [entry(i, i * HOUR, "radio_loss", {}) for i in range(24)]
        self.assertEqual(schedule.recovery_share(s), 0.0)

    def test_a_disk_full_window_holds_a_server_crash(self):
        """Review Focus 3, made certain to happen in the run: some disk_full window has a server_crash inside it."""
        for seed in range(1, 11):
            s = schedule.make_schedule(seed, 24, schedule.DEFAULT_RATES)
            windows = [(e["t_ms"], e["t_ms"] + e["args"]["dur_ms"]) for e in s if e["fault"] == "disk_full"]
            crashes = [e["t_ms"] for e in s if e["fault"] == "server_crash"]
            self.assertTrue(any(a < t < b for a, b in windows for t in crashes), "seed %d" % seed)

    def test_nothing_starts_inside_a_restart_burst_and_bridge_or_disk_windows_never_overlap(self):
        for seed in range(1, 11):
            s = schedule.make_schedule(seed, 24, schedule.DEFAULT_RATES)
            for b in (e for e in s if e["fault"] == "restart_burst5"):
                inside = [e["id"] for e in s if e is not b and b["t_ms"] <= e["t_ms"] < b["t_ms"] + b["quiet_ms"]]
                self.assertEqual(inside, [], "seed %d" % seed)
            for group in (("bridge_down", "bridge_slow"), ("disk_full",)):
                w = sorted((e["t_ms"], e["t_ms"] + e["args"]["dur_ms"]) for e in s if e["fault"] in group)
                self.assertTrue(all(a[1] <= b[0] for a, b in zip(w, w[1:])), "seed %d %s overlap: %s" % (seed, group, w))

    def test_quiet_windows_cover_the_planned_silences(self):
        s = schedule.make_schedule(5, 24, schedule.DEFAULT_RATES)
        for e in s:
            if e["fault"] == "bridge_down":
                self.assertGreaterEqual(e["quiet_ms"], e["args"]["dur_ms"])
            elif e["fault"] == "restart_burst5":
                self.assertGreaterEqual(e["quiet_ms"], 5 * schedule.RESTART_QUIET_MS)
            elif e["fault"] in ("radio_latency", "low_fuel", "put_back_turned"):
                self.assertEqual(e["quiet_ms"], 0, "the fleet keeps talking through %s" % e["fault"])

    def test_write_and_load_round_trip(self):
        s = schedule.make_schedule(2, 6, schedule.DEFAULT_RATES)
        path = os.path.join(tempfile.mkdtemp(), "schedule.json")
        schedule.write_schedule(path, s, seed=2, hours=6, rates=schedule.DEFAULT_RATES)
        with open(path) as f:
            doc = json.load(f)
        self.assertEqual(doc["seed"], 2)
        self.assertEqual(doc["rates"], schedule.DEFAULT_RATES)
        self.assertEqual(doc["entries"], s)
        self.assertEqual(schedule.load_schedule(path), s)

    def test_every_fault_has_a_t2_verb(self):
        self.assertEqual(sorted(schedule.APPLY), sorted(schedule.FAULTS))

    def test_one_of_each_is_in_order_and_spaced(self):
        s = schedule.one_of_each(seed=1)
        self.assertEqual([e["fault"] for e in s], list(schedule.FAULTS))
        for a, b in zip(s, s[1:]):
            self.assertGreaterEqual(b["t_ms"], a["t_ms"] + a["args"].get("dur_ms", 0) + a["quiet_ms"])


# ---------------------------------------------------------------------------------------------------------------------
# The T2 verbs: each fault reaches the control verb the spec names
# ---------------------------------------------------------------------------------------------------------------------

class TheVerbs(unittest.TestCase):
    def fire(self, e, until=None):
        ctx = FakeCtx()
        sched = [e]
        schedule.run_due(ctx, sched, e["t_ms"])
        if until is not None:
            schedule.run_due(ctx, sched, until)
        return ctx, ctx.control

    def test_server_crash_is_the_dispatch_computer_off_and_on(self):
        ctx, c = self.fire(entry(1, 1000, "server_crash", {"down_ms": 5000}), until=7000)
        self.assertEqual(calls_of(c, "shutdown"), [("shutdown", ([95],), {})])
        self.assertEqual(calls_of(c, "turn_on"), [("turn_on", ([95],), {})])
        self.assertEqual(calls_of(c, "server_crash"), [], "the Minecraft process is NOT killed by a server_crash")

    def test_back_to_back_server_crashes_keep_it_off_until_the_last_window_ends(self):
        ctx = FakeCtx()
        s = [entry(1, 0, "server_crash", {"down_ms": 5000}), entry(2, 3000, "server_crash", {"down_ms": 5000})]
        for t in (0, 3000, 5000):
            schedule.run_due(ctx, s, t)
        self.assertEqual(calls_of(ctx.control, "turn_on"), [], "the first window's end does not cut the second short")
        schedule.run_due(ctx, s, 8000)
        self.assertEqual(calls_of(ctx.control, "turn_on"), [("turn_on", ([95],), {})])

    def test_atc_and_warehouse_crash_hit_their_own_computers(self):
        _, c = self.fire(entry(1, 0, "atc_crash", {"down_ms": 1000}), until=2000)
        self.assertEqual([x[1][0] for x in calls_of(c, "shutdown")], [[300]])
        _, c = self.fire(entry(1, 0, "warehouse_crash", {"down_ms": 1000}), until=2000)
        self.assertEqual([x[1][0] for x in calls_of(c, "shutdown")], [[99]])
        self.assertEqual([x[1][0] for x in calls_of(c, "turn_on")], [[99]])

    def test_world_restart_kinds(self):
        _, c = self.fire(entry(1, 0, "world_restart", {"kind": "clean"}))
        self.assertEqual(len(calls_of(c, "world_restart")), 1)
        _, c = self.fire(entry(1, 0, "world_restart", {"kind": "crash"}))
        self.assertEqual([x[0] for x in c.calls if x[0] in ("server_crash", "restart_after_crash")], ["server_crash", "restart_after_crash"])

    def test_restart_burst5_is_five_crashes_each_straight_after_the_start(self):
        _, c = self.fire(entry(1, 0, "restart_burst5", {"count": 5}))
        seq = [x[0] for x in c.calls if x[0] in ("server_crash", "restart_after_crash")]
        self.assertEqual(seq, ["server_crash", "restart_after_crash"] * 5)

    def test_gps_down_one_and_overlapping_windows_keep_their_hosts_off(self):
        ctx = FakeCtx()
        c = ctx.control
        s = [entry(1, 0, "gps_down", {"dur_ms": 10000, "count": "all", "pick": 0}),
             entry(2, 2000, "gps_down", {"dur_ms": 2000, "count": 1, "pick": 1})]
        for t in (0, 2000, 4000):
            schedule.run_due(ctx, s, t)
        self.assertEqual(calls_of(c, "turn_on"), [], "the short window ends inside the long one: its host stays off")
        schedule.run_due(ctx, s, 10000)
        self.assertEqual(sorted(sum((x[1][0] for x in calls_of(c, "turn_on")), [])), [48, 49, 50, 51])

    def test_radio_and_storage_faults_go_through_the_control_mod_scaled_to_game_time(self):
        ctx = FakeCtx()
        ctx.rate = 60                        # 3x: a real minute is three game minutes
        s = [entry(1, 0, "radio_loss", {"dur_ms": 60000, "rate": 0.5}), entry(2, 0, "radio_latency", {"dur_ms": 60000, "ms": 1000}),
             entry(3, 0, "rs_stall", {"dur_ms": 60000, "seconds": 2}), entry(4, 0, "rs_offline", {"dur_ms": 60000}),
             entry(5, 0, "tps_drop", {"dur_ms": 60000, "tps": 5})]
        schedule.run_due(ctx, s, 0)
        c = ctx.control
        self.assertEqual(calls_of(c, "radio_loss")[0][1], (0, 180000, 0.5))
        self.assertEqual(calls_of(c, "radio_latency")[0][1], (0, 180000, 3000))
        self.assertEqual(calls_of(c, "rs_stall")[0][1], (0, 180000, 2))
        self.assertEqual(calls_of(c, "rs_offline")[0][1], (0, 180000))
        self.assertEqual(calls_of(c, "tick_rate")[0][1], (15,))
        schedule.run_due(ctx, s, 60000)
        self.assertEqual(calls_of(c, "tick_rate")[-1][1], (60,), "the run's own speed comes back after a tps drop")

    def test_chunk_unload_goes_where_a_turtle_is_working(self):
        _, c = self.fire(entry(1, 0, "chunk_unload", {"dur_ms": 30000, "target": {"role": "MINER", "index": 0, "prefer": "working"},
                                                      "radius_chunks": 1}))
        (_, args, kw), = calls_of(c, "chunk_unload")
        x, y, z = c.comps[203]                                   # node_203 is off its dock: the working miner
        cx, cz = x >> 4, z >> 4
        self.assertEqual(kw["area"], ((cx - 1) * 16, (cz - 1) * 16, (cx + 2) * 16 - 1, (cz + 2) * 16 - 1))
        self.assertEqual(kw["dur"], 30000)

    def test_single_turtle_faults(self):
        _, c = self.fire(entry(1, 0, "turtle_reboot", {"target": {"role": "DELIVERY", "index": 0}, "off_ms": 0}))
        self.assertEqual([x[0] for x in c.calls if x[0] in ("shutdown", "turn_on")], ["shutdown", "turn_on"])
        self.assertEqual(calls_of(c, "shutdown")[0][1], ([201],))
        _, c = self.fire(entry(1, 0, "remove_item", {"target": {"role": "MINER", "index": 1}, "slot": 2, "what": "loader"}))
        self.assertEqual(calls_of(c, "clear_slot")[0][1], (203, 1), "Lua slot 2 is NBT slot 1")
        _, c = self.fire(entry(1, 0, "low_fuel", {"target": {"role": "MINER", "index": 0}, "fuel": 200}))
        self.assertEqual(calls_of(c, "set_fuel")[0][1], (202, 200))
        _, c = self.fire(entry(1, 0, "put_back_turned", {"target": {"role": "DELIVERY", "index": 0}, "turn": 1}))
        self.assertEqual(calls_of(c, "turtle_move")[0][1], (201, 153, 67, -2806), )
        self.assertEqual(calls_of(c, "turtle_move")[0][2], {"facing": "w"}, "it faced south; a quarter turn more is west")
        ctx = FakeCtx()
        ctx.control.slots[202] = {0: "x", 14: "y"}
        schedule.run_due(ctx, [entry(1, 0, "full_inventory", {"target": {"role": "MINER", "index": 0}, "item": "minecraft:cobblestone"})], 0)
        filled = sorted(x[1][1] for x in calls_of(ctx.control, "set_slot"))
        self.assertEqual(filled, [s for s in range(16) if s not in (0, 14)], "every empty slot, none of the full ones")

    def test_every_fault_is_an_intervention(self):
        ctx = FakeCtx()
        schedule.run_due(ctx, [entry(1, 0, "low_fuel", {"target": {"role": "MINER", "index": 0}, "fuel": 200})], 0)
        self.assertTrue(any(i["verb"] == "set_fuel" for i in ctx.interventions), ctx.interventions)
        self.assertTrue(all(isinstance(i["game_seconds"], (int, float)) for i in ctx.interventions))
        with open(os.path.join(ctx.run, "shakeout", "faults.jsonl")) as f:
            log = [json.loads(l) for l in f]
        self.assertEqual([(l["id"], l["phase"]) for l in log], [("f001", "begin")])


class TheBridgeFaults(unittest.TestCase):
    def setUp(self):
        self.calls = []
        self.saved = {n: getattr(schedule, n) for n in ("_bridge_stop", "_bridge_start", "_proxy_start", "_proxy_stop")}
        schedule._bridge_stop = lambda ctx, e: self.calls.append(("stop",))
        schedule._bridge_start = lambda ctx, e, port: self.calls.append(("start", port))
        schedule._proxy_start = lambda ctx, e, listen, target, ms: self.calls.append(("proxy", listen, target, ms)) or 4242
        schedule._proxy_stop = lambda ctx, e, pid: self.calls.append(("proxy_stop", pid))

    def tearDown(self):
        for n, f in self.saved.items():
            setattr(schedule, n, f)

    def test_bridge_down_stops_and_starts_the_bridge(self):
        ctx = FakeCtx()
        s = [entry(1, 0, "bridge_down", {"dur_ms": 5000})]
        schedule.run_due(ctx, s, 0)
        self.assertEqual(self.calls, [("stop",)])
        schedule.run_due(ctx, s, 5000)
        self.assertEqual(self.calls, [("stop",), ("start", 3000)])

    def test_bridge_slow_puts_a_delaying_proxy_in_front_and_takes_it_away(self):
        ctx = FakeCtx()
        s = [entry(1, 0, "bridge_slow", {"dur_ms": 5000, "ms": 1500})]
        schedule.run_due(ctx, s, 0)
        self.assertEqual(self.calls, [("stop",), ("start", 3001), ("proxy", 3000, 3001, 1500)])
        schedule.run_due(ctx, s, 5000)
        self.assertEqual(self.calls[3:], [("proxy_stop", 4242), ("stop",), ("start", 3000)])

    def test_a_slow_bridge_open_at_teardown_is_put_back(self):
        ctx = FakeCtx()
        s = [entry(1, 0, "bridge_slow", {"dur_ms": 50000, "ms": 1500})]
        schedule.run_due(ctx, s, 0)
        out = schedule.teardown(ctx, s)
        self.assertEqual(out["ended"], ["f001"])
        self.assertEqual(self.calls[-1], ("start", 3000))


class TheDelayProxy(unittest.TestCase):
    def test_it_forwards_and_holds_each_request_back(self):
        import http.server
        import threading
        import time
        import urllib.request

        class Echo(http.server.BaseHTTPRequestHandler):
            def do_POST(self):
                body = self.rfile.read(int(self.headers["Content-Length"]))
                self.send_response(200)
                self.send_header("Content-Length", str(len(body) + 3))
                self.end_headers()
                self.wfile.write(b"ok:" + body)

            def log_message(self, *a):
                pass
        target = http.server.HTTPServer(("127.0.0.1", 0), Echo)
        threading.Thread(target=target.serve_forever, daemon=True).start()
        proxy = schedule.DelayProxy(0, target.server_address[1], 300)
        threading.Thread(target=proxy.serve_forever, daemon=True).start()
        try:
            t0 = time.time()
            req = urllib.request.Request("http://127.0.0.1:%d/command" % proxy.server_address[1], data=b"hello", method="POST")
            with urllib.request.urlopen(req, timeout=10) as r:
                self.assertEqual(r.read(), b"ok:hello")
            self.assertGreaterEqual(time.time() - t0, 0.3)
        finally:
            proxy.shutdown()
            target.shutdown()
            proxy.server_close()
            target.server_close()


# ---------------------------------------------------------------------------------------------------------------------
# Review Focus 3: a filler file left on the server disk
# ---------------------------------------------------------------------------------------------------------------------

class TheDiskFiller(unittest.TestCase):
    def sched(self):
        return [entry(1, 1000, "disk_full", {"dur_ms": 60000, "leave_bytes": 20000}),
                entry(2, 20000, "server_crash", {"down_ms": 10000}),
                entry(3, 25000, "world_restart", {"kind": "crash"})]

    def test_disk_filler_always_removed_at_the_window_end(self):
        ctx = FakeCtx()
        s = self.sched()
        schedule.run_due(ctx, s, 1000)
        made = fillers(ctx)
        self.assertEqual(len(made), 1, "the filler is written into the dispatch computer's folder")
        self.assertTrue(made[0].startswith("95"))
        size = os.path.getsize(os.path.join(ctx.control.disks, made[0]))
        self.assertEqual(size, 600000 - 20000, "sized from diskFree, leaving leave_bytes")
        self.assertEqual(len(calls_of(ctx.control, "world_restart")), 1, "a restart makes CC measure the disk again")
        for t in (20000, 25000, 30000, 61000):
            schedule.run_due(ctx, s, t)
        self.assertEqual(fillers(ctx), [], "the crash inside the window does not leave the filler behind")
        self.assertEqual(len(calls_of(ctx.control, "world_restart")), 2, "and the disk is measured again once it is gone")

    def test_disk_filler_always_removed_at_teardown(self):
        ctx = FakeCtx()
        s = self.sched()
        for t in (1000, 20000, 25000):
            schedule.run_due(ctx, s, t)
        self.assertEqual(len(fillers(ctx)), 1)
        out = schedule.teardown(ctx, s)
        self.assertEqual(fillers(ctx), [])
        self.assertEqual(out["fillers_left"], [])
        self.assertEqual(len(out["fillers_removed"]), 1)

    def test_the_filler_goes_even_when_the_restart_after_it_fails(self):
        ctx = FakeCtx()
        s = self.sched()[:1]
        schedule.run_due(ctx, s, 1000)
        ctx.control.fail_next = ["world_restart"]                # the remeasuring restart at the window's end dies
        schedule.run_due(ctx, s, 61000)
        self.assertEqual(fillers(ctx), [], "removal comes first and does not need the game")

    def test_teardown_sweeps_a_filler_from_a_runner_that_died(self):
        ctx = FakeCtx()
        stray = os.path.join(ctx.control.disks, "95", schedule.FILLER_PREFIX + "f009.bin")
        with open(stray, "wb") as f:
            f.write(b"x" * 100)
        out = schedule.teardown(ctx, [])                         # a new runner: it never knew about f009
        self.assertFalse(os.path.exists(stray))
        self.assertEqual(out["fillers_removed"], [stray])

    def test_the_teardown_check_can_fail(self):
        ctx = FakeCtx()
        stray = os.path.join(ctx.control.disks, "95", schedule.FILLER_PREFIX + "f009.bin")
        with open(stray, "wb") as f:
            f.write(b"x")
        real_remove = schedule.os.remove
        schedule.os.remove = lambda p: (_ for _ in ()).throw(PermissionError(p))
        try:
            out = schedule.teardown(ctx, [])
        finally:
            schedule.os.remove = real_remove
        self.assertEqual(out["fillers_left"], [stray], "a filler that could not be removed is reported, never hidden")


# ---------------------------------------------------------------------------------------------------------------------
# Review Focus 2: the harness survives its own server dying
# ---------------------------------------------------------------------------------------------------------------------

class FakeGameServer:
    """A game server rcon talks to. Going down closes every open connection; a new one can only be made while it is up."""

    def __init__(self):
        self.up = True
        self.connections = []
        self.got = []

    def connect(self):
        if not self.up:
            raise ConnectionRefusedError("rcon: the server is down (fake)")
        conn = FakeRconConn(self)
        self.connections.append(conn)
        return conn


class FakeRconConn:
    def __init__(self, server):
        self.server, self.alive = server, True

    def command(self, text):
        if not self.alive or not self.server.up:
            self.alive = False
            raise RuntimeError("rcon: connection closed")
        self.server.got.append(text)
        return '{"ok":true}' if text.startswith("t2 ") else "ok"


class RealControlOnAFakeServer(control.Control):
    """The real Control (its reconnect-on-failure in command()), with the game process verbs faked."""

    def __init__(self, game, disks):
        self.game, self.disks = game, disks
        self._rcon, self._gps_hosts_down, self._scheduled = None, None, []

    def rcon(self):
        if self._rcon is None:
            self._rcon = self.game.connect()
        return self._rcon

    def server_crash(self):
        self.game.up = False
        for conn in self.game.connections:
            conn.alive = False
        self._rcon = None

    def restart_after_crash(self):
        self.game.up = True
        return {"server": 1}


class TheRunnerSurvivesItsServer(unittest.TestCase):
    def test_runner_survives_restart_burst(self):
        game = FakeGameServer()
        ctx = FakeCtx()
        ctx.rate = 60
        ctx.control = ctx._raw = RealControlOnAFakeServer(game, os.path.join(ctx.run, "disks"))
        ctx.control.command("t2 status")                                    # an open connection before the burst
        s = [entry(1, 1000, "restart_burst5", {"count": 5}, quiet_ms=50 * MIN),
             entry(2, 5000, "radio_loss", {"dur_ms": 60000, "rate": 0.2})]
        acted = schedule.run_due(ctx, s, 1000)                              # the burst: five times down and up
        self.assertIn(("f001", "begin"), acted)
        self.assertEqual(schedule.run_due(ctx, s, 4999), [], "the next fault waits for its own time")
        game.connections[-1].alive = False                                 # and the connection drops again while idle
        sent_before = len(game.got)
        acted = schedule.run_due(ctx, s, 5000)
        self.assertIn(("f002", "begin"), acted, "the next fault fires at its wall-clock time")
        self.assertTrue(any(t.startswith("t2 radio loss 0.2 180") for t in game.got[sent_before:]), game.got[sent_before:])
        self.assertGreaterEqual(len(game.connections), 3, "rcon reconnected after the burst, and again after the idle drop")
        st = schedule.state_of(ctx)
        self.assertEqual(st["status"]["f002"]["late_ms"], 0)

    def test_a_fault_due_while_the_runner_was_blocked_fires_late_and_says_so(self):
        ctx = FakeCtx()
        s = [entry(1, 1000, "radio_loss", {"dur_ms": 60000, "rate": 0.2})]
        schedule.run_due(ctx, s, 31 * MIN)
        st = schedule.state_of(ctx)
        self.assertEqual(st["status"]["f001"]["late_ms"], 31 * MIN - 1000)

    def test_a_fault_whose_server_is_down_is_retried_not_lost(self):
        ctx = FakeCtx()
        ctx.control.fail_next = ["radio_loss"]
        s = [entry(1, 1000, "radio_loss", {"dur_ms": 60000, "rate": 0.2})]
        acted = schedule.run_due(ctx, s, 1000)
        self.assertIn(("f001", "retry"), acted)
        acted = schedule.run_due(ctx, s, 2000)
        self.assertIn(("f001", "begin"), acted)

    def test_a_restart_that_never_comes_back_is_retried_on_the_next_call(self):
        ctx = FakeCtx()
        c = ctx.control
        def dies():
            c.calls.append(("restart_after_crash", (), {}))
            raise SystemExit("the server exited during start-up (fake)")
        c.restart_after_crash = dies
        s = [entry(1, 1000, "world_restart", {"kind": "crash"})]
        schedule.run_due(ctx, s, 1000)                                       # must not raise: SystemExit is caught
        self.assertTrue(schedule.state_of(ctx)["need_relaunch"])
        c.restart_after_crash = lambda: c.calls.append(("restart_after_crash", (), {}))
        schedule.run_due(ctx, s, 2000)
        self.assertFalse(schedule.state_of(ctx)["need_relaunch"])
        self.assertEqual(len(calls_of(c, "restart_after_crash")), 2)


class TheDriverLoop(unittest.TestCase):
    """sandbox/t2/scenarios/shakeout.py's run_loop and shakeout_faults_once.py's per-fault check, on the fake."""

    @staticmethod
    def load(name):
        import importlib.util
        spec = importlib.util.spec_from_file_location("t_" + name, os.path.join(HERE, "..", "t2", "scenarios", name + ".py"))
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        return mod

    def test_the_loop_fires_closes_and_checks_each_fault(self):
        drv, once = self.load("shakeout"), self.load("shakeout_faults_once")
        ctx = FakeCtx()
        s = [entry(1, 0, "server_crash", {"down_ms": 20}), entry(2, 0, "low_fuel", {"target": {"role": "MINER", "index": 0}, "fuel": 9}),
             entry(3, 0, "disk_full", {"dur_ms": 100000, "leave_bytes": 1000})]
        out = drv.run_loop(ctx, s, 0.3, poll=0.01)
        self.assertEqual(out["ended"], ["f003"], "the disk window still open at the end is closed by teardown")
        self.assertEqual(fillers(ctx), [])
        once.check_each(ctx, s)
        self.assertTrue(all(c["ok"] for c in ctx.checks), [c["message"] for c in ctx.checks if not c["ok"]])
        self.assertTrue(any("no filler file left" in c["message"] for c in ctx.checks))

    def test_the_per_fault_check_can_fail(self):
        drv, once = self.load("shakeout"), self.load("shakeout_faults_once")
        ctx = FakeCtx()
        s = [entry(1, 0, "low_fuel", {"target": {"role": "BUILDER", "index": 0}, "fuel": 9})]   # no such turtle: never begins
        drv.run_loop(ctx, s, 0.1, poll=0.01)
        once.check_each(ctx, s)
        self.assertEqual([c["ok"] for c in ctx.checks if "f001" in c["message"]], [False])


# ---------------------------------------------------------------------------------------------------------------------
# The simulator replay
# ---------------------------------------------------------------------------------------------------------------------

HARNESS = os.path.join(HERE, "shakeout_replay_harness.lua")


def run_replay(entries):
    path = os.path.join(tempfile.mkdtemp(prefix="shakeout_replay"), "schedule.json")
    schedule.write_schedule(path, entries, seed=1, hours=1)
    env = dict(os.environ, SHAKEOUT_SCHEDULE=path)
    p = subprocess.run([world.lua_interpreter(), HARNESS], cwd=REPO, env=env, capture_output=True)
    return p.returncode, p.stdout.decode("utf8", "replace"), p.stderr.decode("utf8", "replace")


class TheReplay(unittest.TestCase):
    def test_replay_loads_in_sim(self):
        s = schedule.one_of_each(seed=4)
        code, out, err = run_replay(s)
        self.assertEqual(code, 0, out + err)
        doc = json.loads(out.strip().splitlines()[-1])
        known = set(doc["known_verbs"])
        self.assertTrue({"server_crash", "world_restart", "disk_full", "run_until_time"} <= known, sorted(known))
        used = [c["verb"] for c in doc["calls"]]
        self.assertTrue(set(used) <= known, sorted(set(used) - known))
        for f in schedule.FAULTS:
            self.assertIn(f, doc["handled"], "%s has a simulator handler" % f)
        self.assertEqual(sorted(doc["handled"]), sorted(e["fault"] for e in s), "every entry was replayed")
        self.assertEqual(used.count("world_restart"), 5 + 1, "the burst is five restarts, plus the world_restart entry")

    def test_unknown_names_are_refused_by_name(self):
        code, out, err = run_replay([entry(1, 0, "meteor_strike", {"dur_ms": 1000})])
        self.assertNotEqual(code, 0)
        self.assertIn("meteor_strike", out + err)

    def test_the_fake_sim_refuses_a_verb_the_simulator_does_not_have(self):
        """The check can fail: a harness switch makes the replay call a made-up verb, and the fake sim must refuse it."""
        path = os.path.join(tempfile.mkdtemp(prefix="shakeout_replay"), "schedule.json")
        schedule.write_schedule(path, [entry(1, 0, "radio_loss", {"dur_ms": 1000, "rate": 0.1})], seed=1, hours=1)
        env = dict(os.environ, SHAKEOUT_SCHEDULE=path, SHAKEOUT_HARNESS_BAD_VERB="1")
        p = subprocess.run([world.lua_interpreter(), HARNESS], cwd=REPO, env=env, capture_output=True)
        self.assertNotEqual(p.returncode, 0)
        self.assertIn("not a simulator verb", (p.stdout + p.stderr).decode("utf8", "replace"))


if __name__ == "__main__":
    unittest.main()
