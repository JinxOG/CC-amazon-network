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

# The runner's waits are real-time sleeps on T2; here they are nothing. And no test may touch a real bridge on 3000.
schedule.DISK_SETTLE_S = 0
schedule.DISK_POLL_S = 0
schedule.DISK_WAIT_S = 1
REAL_PING = schedule._bridge_ping
schedule._bridge_ping = lambda port, timeout=10: None

FACING_LETTER = {"n": "north", "e": "east", "s": "south", "w": "west"}


class FakeControl:
    """What the game would show after each verb: computers on or off, slots, fuel, facings, the tick rate, the control mod's
    replies, and the dispatch computer's disk as CC measures it -- only when the world restarts (w3_low_disk.py)."""

    def __init__(self, disks):
        self.disks = disks
        self.calls = []
        self.up = True
        self.comps = {95: (136, 67, -2802), 99: (148, 72, -2829), 300: (160, 67, -2786), 48: (322, 92, -2814),
                      49: (322, 92, -2809), 50: (327, 92, -2814), 51: (322, 96, -2814),
                      201: (153, 67, -2806), 202: (167, 67, -2806), 203: (300, 120, -2500)}
        self.roles = {95: "SERVER", 99: "WAREHOUSE", 300: "atc", 201: "DELIVERY", 202: "MINER", 203: "MINER"}
        self.slots = {}
        self.fuel = {}
        self.facing = {201: "south", 202: "south", 203: "south"}
        self.rate = 20
        self.on = {i: True for i in self.comps}
        self.fail_next = []          # verbs that raise once (a dropped connection, say)
        self.always_fail = []        # verbs that raise every time
        self.noop = []               # verbs that "work" but change nothing (the no-op a proof must not pass)
        self.capacity = 600000
        self.restarts = 0
        self.remeasures = True
        self.measured = self.capacity
        for i in self.comps:
            os.makedirs(os.path.join(disks, str(i)), exist_ok=True)

    def _rec(self, name, *args, **kw):
        if name in self.always_fail:
            raise OSError("rcon: connection refused (fake)")
        if name in self.fail_next:
            self.fail_next.remove(name)
            raise OSError("rcon: connection reset (fake)")
        self.calls.append((name, args, kw))
        return name not in self.noop

    def _measure(self):
        self.restarts += 1
        if self.remeasures:
            d = os.path.join(self.disks, "95")
            self.measured = self.capacity - sum(os.path.getsize(os.path.join(d, f)) for f in os.listdir(d))

    def computers(self):
        return {i: {"on": self.on[i], "pos": p} for i, p in self.comps.items()}

    def role_of(self, i):
        return self.roles.get(i)

    def gps_hosts(self):
        return [48, 49, 50, 51]

    def shutdown(self, ids):
        if self._rec("shutdown", list(ids)):
            for i in ids:
                self.on[i] = False

    def turn_on(self, ids):
        if self._rec("turn_on", list(ids)):
            for i in ids:
                self.on[i] = True

    def gps_down(self, hosts=None):
        if self._rec("gps_down", list(hosts)):
            for i in hosts:
                self.on[i] = False
        return hosts

    def world_restart(self):
        self._rec("world_restart")
        self._measure()

    def server_crash(self):
        self._rec("server_crash")
        self.up = False

    def restart_after_crash(self):
        self._rec("restart_after_crash")
        self.up = True
        self._measure()

    def tick_rate(self, rate):
        if self._rec("tick_rate", rate):
            self.rate = rate

    def _cid_at(self, pos):
        return next(i for i, p in self.comps.items() if p == tuple(pos))

    def block_data(self, pos, path=""):
        cid = self._cid_at(pos)
        slot = int(path.split("Slot:")[1].split("b")[0]) if "Slot:" in path else None
        if slot is not None and slot not in self.slots.get(cid, {}):
            return "Found no elements matching %s" % path
        return "%d, %d, %d has the following block data: {}" % tuple(pos)

    def command(self, text):
        self._rec("command", text)
        if text.startswith("execute if block"):
            x, y, z = (int(v) for v in text.split()[3:6])
            return "Test passed" if "facing=%s]" % self.facing.get(self._cid_at((x, y, z))) in text else "Test failed"
        if text == "tickrate":
            return "The tick rate is %d per second" % self.rate
        if text == "time query gametime":
            return "The time is 123456" if self.up else ""
        return "ok"

    def clear_slot(self, cid, slot):
        if self._rec("clear_slot", cid, slot):
            self.slots.get(cid, {}).pop(slot, None)

    def set_slot(self, cid, slot, item, count=1, tag=None):
        if self._rec("set_slot", cid, slot, item, count):
            self.slots.setdefault(cid, {})[slot] = item

    def set_fuel(self, cid, level):
        if self._rec("set_fuel", cid, level):
            self.fuel[cid] = level

    def get_fuel(self, cid):
        return self.fuel.get(cid, 50000)

    def turtle_move(self, cid, x, y, z, facing=None):
        if self._rec("turtle_move", cid, x, y, z, facing=facing):
            self.facing[cid] = FACING_LETTER[facing]
        return {"ok": True}

    def __getattr__(self, name):
        if name in ("radio_loss", "radio_latency", "chunk_unload", "rs_stall", "rs_offline"):
            return lambda *a, **k: {"ok": True, "verb": name} if self._rec(name, *a, **k) else {"ok": False}
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
        return {"diskFree": getattr(self.control, "measured", 600000)}

    def log_lines(self, substr=""):
        line = "INFO   Central server online (v1) ID: node_95"
        return [line] * (1 + getattr(self.control, "restarts", 0)) if substr in line else []


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

    def test_the_default_24_hour_schedule_builds_for_seeds_1_to_20(self):
        for seed in range(1, 21):
            s = schedule.make_schedule(seed, 24, schedule.DEFAULT_RATES)
            self.assertEqual(len(s), sum(schedule.DEFAULT_RATES.values()), "seed %d" % seed)

    def test_the_tick_rate_read_back_is_exact(self):
        class C:
            def __init__(self, reply):
                self.reply = reply

            def command(self, text):
                return self.reply
        self.assertFalse(schedule._tick_seen(C("The tick rate is 20 per second"), 2)["ok"], "2 is not 20")
        self.assertTrue(schedule._tick_seen(C("The tick rate is 20 per second"), 20)["ok"])
        self.assertTrue(schedule._tick_seen(C("Target tick rate: 15.0"), 15)["ok"])
        self.assertFalse(schedule._tick_seen(C("Target tick rate: 150"), 15)["ok"])

    def test_rates_must_name_every_fault(self):
        rates = dict(schedule.DEFAULT_RATES)
        del rates["low_fuel"]
        with self.assertRaises(ValueError) as cm:
            schedule.make_schedule(1, 24, rates)
        self.assertIn("low_fuel", str(cm.exception))
        schedule.make_schedule(1, 24, dict(rates, low_fuel=0))       # 0 leaves it out on purpose

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


class BridgeWorld:
    """What listens where: the real bridge, the delaying proxy, or nothing. Stands in for the bridge process verbs."""

    def __init__(self, test, fail_start=(), fail_proxy=False):
        self.ports, self.bridge_port, self.calls = {3000: "bridge"}, 3000, []
        self.fail_start, self.fail_proxy = set(fail_start), fail_proxy
        self.slow = False                                  # the bridge process runs but does not answer in time
        self.saved = {n: getattr(schedule, n) for n in ("_bridge_stop", "_bridge_start", "_proxy_start", "_proxy_stop", "_bridge_ping",
                                                       "_bridge_alive")}
        schedule._bridge_stop, schedule._bridge_start = self.stop, self.start
        schedule._proxy_start, schedule._proxy_stop, schedule._bridge_ping = self.proxy, self.proxy_stop, self.ping
        schedule._bridge_alive = lambda ctx: "bridge" in self.ports.values()
        test.addCleanup(lambda: [setattr(schedule, n, f) for n, f in self.saved.items()])

    def stop(self, ctx, e):
        self.calls.append(("stop",))
        if self.ports.get(self.bridge_port) == "bridge":
            del self.ports[self.bridge_port]

    def start(self, ctx, e, port):
        self.calls.append(("start", port))
        if port in self.fail_start:
            raise SystemExit("something still listens on 127.0.0.1:%d (fake)" % port)
        self.ports[port], self.bridge_port = "bridge", port

    def proxy(self, ctx, e, listen, target, ms):
        self.calls.append(("proxy", listen, target, ms))
        if self.fail_proxy:
            raise OSError("proxy would not start (fake)")
        self.ports[listen], self.delay = "proxy", ms
        return 4242

    def proxy_stop(self, ctx, e, pid):
        self.calls.append(("proxy_stop", pid))
        self.ports = {p: v for p, v in self.ports.items() if v != "proxy"}

    def ping(self, port, timeout=10):
        if self.slow:
            return None
        v = self.ports.get(port)
        if v == "proxy":
            return float(self.delay) if self.ports.get(3001) == "bridge" else None
        return 1.0 if v == "bridge" else None


class TheBridgeFaults(unittest.TestCase):
    def test_bridge_down_stops_and_starts_the_bridge(self):
        b = BridgeWorld(self)
        ctx = FakeCtx()
        s = [entry(1, 0, "bridge_down", {"dur_ms": 5000})]
        schedule.run_due(ctx, s, 0)
        self.assertEqual(b.ports, {}, "nothing answers on 3000 during the window")
        self.assertTrue(schedule.state_of(ctx)["status"]["f001"]["detail"]["observed"]["ok"])
        schedule.run_due(ctx, s, 5000)
        self.assertEqual(b.ports, {3000: "bridge"})

    def test_bridge_slow_puts_a_delaying_proxy_in_front_and_takes_it_away(self):
        b = BridgeWorld(self)
        ctx = FakeCtx()
        s = [entry(1, 0, "bridge_slow", {"dur_ms": 5000, "ms": 1500})]
        schedule.run_due(ctx, s, 0)
        self.assertEqual(b.calls, [("stop",), ("start", 3001), ("proxy", 3000, 3001, 1500)])
        self.assertEqual(b.ports, {3000: "proxy", 3001: "bridge"})
        obs = schedule.state_of(ctx)["status"]["f001"]["detail"]["observed"]
        self.assertTrue(obs["ok"], obs)
        schedule.run_due(ctx, s, 5000)
        self.assertEqual(b.ports, {3000: "bridge"}, "the proxy gone and the real bridge back on 3000")

    def test_a_slow_bridge_open_at_teardown_is_put_back(self):
        b = BridgeWorld(self)
        ctx = FakeCtx()
        s = [entry(1, 0, "bridge_slow", {"dur_ms": 50000, "ms": 1500})]
        schedule.run_due(ctx, s, 0)
        out = schedule.teardown(ctx, s)
        self.assertEqual(out["ended"], ["f001"])
        self.assertEqual(b.ports, {3000: "bridge"})

    def test_a_slow_bridge_that_cannot_start_on_3001_leaves_the_bridge_on_3000(self):
        b = BridgeWorld(self, fail_start={3001})
        ctx = FakeCtx()
        s = [entry(1, 0, "bridge_slow", {"dur_ms": 5000, "ms": 1500})]
        self.assertIn(("f001", "retry"), schedule.run_due(ctx, s, 0))
        self.assertEqual(b.ports, {3000: "bridge"}, "restored at once, not left dark until the window would have ended")
        acted = schedule.run_due(ctx, s, schedule.RETRY_MS)                   # it keeps failing: given up, undone once
        self.assertIn(("f001", "fail"), acted)
        self.assertEqual(b.ports, {3000: "bridge"})
        self.assertEqual(schedule.teardown(ctx, s)["end_errors"], [])

    def test_a_bridge_that_is_only_slow_is_never_killed(self):
        b = BridgeWorld(self)
        ctx = FakeCtx()
        s = [entry(1, 0, "bridge_down", {"dur_ms": 5000})]
        schedule.run_due(ctx, s, 0)
        b.ports = {3000: "bridge"}                            # the stop did not take: the process lives on ...
        b.slow = True                                        # ... and is too slow to answer a ping
        n = len(b.calls)
        schedule.run_due(ctx, s, 5000)                       # the window's end
        schedule.teardown(ctx, s)
        self.assertEqual(b.calls[n:], [], "a slow bridge whose process is alive is never stopped or started")
        with open(os.path.join(ctx.run, "shakeout", "faults.jsonl")) as f:
            self.assertIn("bridge-slow-left-alone", f.read())

    def test_a_dead_bridge_is_started_again(self):
        b = BridgeWorld(self)
        ctx = FakeCtx()
        b.ports = {}                                          # its process died
        schedule._bridge_restore(ctx, None, schedule.state_of(ctx))
        self.assertEqual((b.calls, b.ports), ([("start", 3000)], {3000: "bridge"}), "started, and nothing stopped first")

    def test_a_ping_that_gets_a_garbled_reply_reads_as_no_answer(self):
        import socketserver
        import threading

        class Garbage(socketserver.BaseRequestHandler):
            def handle(self):
                self.request.recv(1024)
                self.request.sendall(b"not http at all" + bytes([13, 10, 13, 10]))
        srv = socketserver.TCPServer(("127.0.0.1", 0), Garbage)
        threading.Thread(target=srv.serve_forever, daemon=True).start()
        try:
            self.assertIsNone(REAL_PING(srv.server_address[1], 3), "an HTTPException is no answer, not a crash")
        finally:
            srv.shutdown()
            srv.server_close()

    def test_a_slow_bridge_whose_proxy_will_not_start_is_put_back(self):
        b = BridgeWorld(self, fail_proxy=True)
        ctx = FakeCtx()
        schedule.run_due(ctx, [entry(1, 0, "bridge_slow", {"dur_ms": 5000, "ms": 1500})], 0)
        self.assertEqual(b.ports, {3000: "bridge"}, "the bridge on 3001 stopped, the real one back on 3000")


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


class FailedBeginsAreUndone(unittest.TestCase):
    """Review 1, Important 1 (the reviewer's leak_probe.py, as tests): a begin that fails part-way leaves nothing behind."""

    def test_a_shutdown_that_failed_once_leaks_no_hold(self):
        ctx = FakeCtx()
        ctx.control.fail_next = ["shutdown"]
        s = [entry(1, 1000, "server_crash", {"down_ms": 60000})]
        self.assertEqual(schedule.run_due(ctx, s, 1000), [("f001", "retry")])
        self.assertEqual(schedule.run_due(ctx, s, 2000), [("f001", "begin")])
        schedule.run_due(ctx, s, 62000)
        self.assertTrue(ctx.control.on[95], "the dispatch computer is back on after the window")
        self.assertEqual(schedule.state_of(ctx)["holds"], {})
        schedule.teardown(ctx, s)
        self.assertTrue(ctx.control.on[95])

    def test_a_shutdown_that_never_works_is_undone_once_it_is_given_up(self):
        ctx = FakeCtx()
        ctx.control.always_fail = ["shutdown"]
        s = [entry(1, 1000, "server_crash", {"down_ms": 60000})]
        schedule.run_due(ctx, s, 1000)
        acted = schedule.run_due(ctx, s, 1000 + schedule.RETRY_MS)
        self.assertEqual(acted, [("f001", "fail"), ("f001", "undo")])
        self.assertEqual(calls_of(ctx.control, "turn_on"), [("turn_on", ([95],), {})], "the undo turns it on, in case it went off")
        self.assertEqual(schedule.state_of(ctx)["holds"], {})

    def test_an_undo_does_not_cut_another_window_short(self):
        ctx = FakeCtx()
        s = [entry(1, 0, "server_crash", {"down_ms": 60 * MIN}), entry(2, 1000, "server_crash", {"down_ms": 60000})]
        schedule.run_due(ctx, s, 0)
        ctx.control.always_fail = ["shutdown"]
        schedule.run_due(ctx, s, 1000)
        schedule.run_due(ctx, s, 1000 + schedule.RETRY_MS)          # f002 given up and undone
        self.assertFalse(ctx.control.on[95], "f001 still holds it off")
        self.assertEqual(calls_of(ctx.control, "turn_on"), [])

    def test_a_gps_down_that_failed_once_leaks_no_hold(self):
        ctx = FakeCtx()
        ctx.control.fail_next = ["gps_down"]
        s = [entry(1, 1000, "gps_down", {"dur_ms": 60000, "count": 1, "pick": 0})]
        for t in (1000, 2000, 62000):
            schedule.run_due(ctx, s, t)
        self.assertTrue(ctx.control.on[48])
        self.assertEqual(schedule.state_of(ctx)["holds"], {})

    def test_a_gps_down_given_up_turns_its_hosts_back_on(self):
        ctx = FakeCtx()
        ctx.control.always_fail = ["gps_down"]
        s = [entry(1, 1000, "gps_down", {"dur_ms": 60000, "count": "all", "pick": 0})]
        schedule.run_due(ctx, s, 1000)
        schedule.run_due(ctx, s, 1000 + schedule.RETRY_MS)
        self.assertEqual(calls_of(ctx.control, "turn_on"), [("turn_on", ([48, 49, 50, 51],), {})])
        self.assertEqual(schedule.state_of(ctx)["holds"], {})

    def test_a_filler_write_that_fails_leaves_no_partial_file(self):
        ctx = FakeCtx()
        real = schedule._write_filler

        def half(path, size):
            with open(path, "wb") as f:
                f.write(b"\0" * (size // 2))
            raise OSError("disk full on the host (fake)")
        schedule._write_filler = half
        try:
            acted = schedule.run_due(ctx, [entry(1, 0, "disk_full", {"dur_ms": 60000, "leave_bytes": 2048})], 0)
        finally:
            schedule._write_filler = real
        self.assertIn(("f001", "fail"), acted, "a disk fill is not retried: each try costs restarts")
        self.assertEqual(fillers(ctx), [])
        self.assertEqual(calls_of(ctx.control, "world_restart"), [], "nothing was filled, so nothing is measured")


class TheDiskFillIsSeen(unittest.TestCase):
    """Review 1, Important 2: a fill counts only when diskFree shows it (w3_low_disk.py found one can go unseen)."""

    def test_a_seen_fill_records_diskfree_before_and_after(self):
        ctx = FakeCtx()
        s = [entry(1, 0, "disk_full", {"dur_ms": 60000, "leave_bytes": 20000})]
        schedule.run_due(ctx, s, 0)
        d = schedule.state_of(ctx)["status"]["f001"]["detail"]
        self.assertEqual((d["free_before"], d["observed"]["diskFree"], d["observed"]["ok"]), (600000, 20000, True))
        schedule.run_due(ctx, s, 60000)
        self.assertEqual(d["end_observed"], {"diskFree": 600000, "want_more_than": 28000, "ok": True})

    def test_an_unseen_fill_fails_and_takes_its_filler_away(self):
        ctx = FakeCtx()
        ctx.control.remeasures = False                     # the restart does not make CC measure again
        acted = schedule.run_due(ctx, [entry(1, 0, "disk_full", {"dur_ms": 60000, "leave_bytes": 20000})], 0)
        self.assertIn(("f001", "fail"), acted)
        self.assertEqual(fillers(ctx), [])
        with open(os.path.join(ctx.run, "shakeout", "faults.jsonl")) as f:
            log = [json.loads(l) for l in f]
        self.assertIn("the fill was not seen", [l for l in log if l["phase"] == "fail"][0]["error"])

    def test_no_usable_diskfree_means_no_filler_at_all(self):
        for bad in (-1, None, "n/a", 5000):
            ctx = FakeCtx()
            ctx.control.measured = bad
            acted = schedule.run_due(ctx, [entry(1, 0, "disk_full", {"dur_ms": 60000, "leave_bytes": 2048})], 0)
            self.assertIn(("f001", "fail"), acted, bad)
            self.assertEqual(fillers(ctx), [], bad)
            self.assertEqual(calls_of(ctx.control, "world_restart"), [], bad)


class EveryFaultIsSeenToTakeEffect(unittest.TestCase):
    """Review 1, Important 2: each begin records one cheap read showing it worked; a verb that does nothing reads ok False."""

    def run_all(self, ctl_setup=None):
        b = BridgeWorld(self)
        ctx = FakeCtx()
        if ctl_setup:
            ctl_setup(ctx.control)
        sched = schedule.one_of_each(seed=2)
        for e in sched:
            if "target" in e["args"]:
                e["args"]["target"]["role"] = "MINER"
            if e["fault"] == "turtle_reboot":
                e["args"]["off_ms"] = 0
        t = 0
        while t <= sched[-1]["t_ms"] + 3 * HOUR:
            schedule.run_due(ctx, sched, t)
            t += MIN
        return ctx, sched, b

    def test_every_fault_observes_its_own_effect(self):
        ctx, sched, _ = self.run_all()
        st = schedule.state_of(ctx)["status"]
        bad = {e["fault"]: (st[e["id"]].get("detail") or {}).get("observed") for e in sched
               if not ((st[e["id"]].get("detail") or {}).get("observed") or {}).get("ok")}
        self.assertEqual(bad, {})

    def test_a_verb_that_changes_nothing_is_seen(self):
        ctx, sched, _ = self.run_all(lambda c: c.noop.extend(["shutdown", "set_fuel", "tick_rate"]))
        st = schedule.state_of(ctx)["status"]
        bad = sorted(e["fault"] for e in sched if not ((st[e["id"]].get("detail") or {}).get("observed") or {}).get("ok"))
        self.assertEqual(bad, ["atc_crash", "low_fuel", "server_crash", "tps_drop", "turtle_reboot", "warehouse_crash"])


class ChunkUnloadSparesTheBase(unittest.TestCase):
    def test_a_docked_turtle_in_the_base_is_not_a_target(self):
        ctx = FakeCtx()
        ctx.control.comps[203] = (171, 67, -2806)          # every miner docked: their chunks +-1 touch the base
        s = [entry(1, 0, "chunk_unload", {"dur_ms": 30000, "target": {"role": "MINER", "index": 0, "prefer": "working"},
                                          "radius_chunks": 1})]
        self.assertEqual(schedule.run_due(ctx, s, 0), [("f001", "retry")])
        self.assertEqual(calls_of(ctx.control, "chunk_unload"), [], "the base is never unloaded")


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

    def setUp(self):
        self.real_alive = schedule._server_alive
        self.addCleanup(lambda: setattr(schedule, "_server_alive", self.real_alive))

    def test_a_restart_that_never_comes_back_is_retried_on_the_next_call(self):
        schedule._server_alive = lambda ctx: False
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

    def test_no_relaunch_when_it_cannot_be_told_whether_the_server_is_alive(self):
        schedule._server_alive = lambda ctx: None          # pids.json unreadable: a relaunch might start a second server
        ctx = FakeCtx()
        st = schedule.state_of(ctx)
        st["need_relaunch"] = True
        self.assertEqual(schedule.run_due(ctx, [], 1000), [(None, "relaunch-unknown")])
        self.assertEqual(schedule.run_due(ctx, [], 2000), [], "said once, not every call")
        self.assertEqual(calls_of(ctx.control, "restart_after_crash"), [])
        self.assertTrue(st["need_relaunch"])

    def test_teardown_relaunches_first_so_the_ends_can_reach_the_server(self):
        schedule._server_alive = lambda ctx: False
        ctx = FakeCtx()
        s = [entry(1, 0, "server_crash", {"down_ms": 60000})]
        schedule.run_due(ctx, s, 0)
        schedule.state_of(ctx)["need_relaunch"] = True
        out = schedule.teardown(ctx, s)
        seq = [x[0] for x in ctx.control.calls if x[0] in ("restart_after_crash", "turn_on")]
        self.assertEqual(seq, ["restart_after_crash", "turn_on"])
        self.assertEqual(out["relaunch"], [(None, "relaunched")])


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

    def test_the_per_fault_check_fails_a_fault_that_did_nothing(self):
        drv, once = self.load("shakeout"), self.load("shakeout_faults_once")
        ctx = FakeCtx()
        ctx.control.noop = ["shutdown"]                          # begins, logs, records an intervention -- and nothing goes off
        s = [entry(1, 0, "server_crash", {"down_ms": 20})]
        drv.run_loop(ctx, s, 0.1, poll=0.01)
        once.check_each(ctx, s)
        self.assertEqual([c["ok"] for c in ctx.checks if "f001" in c["message"]], [False])

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
