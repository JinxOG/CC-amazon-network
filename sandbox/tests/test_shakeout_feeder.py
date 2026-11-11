"""Shakeout Task 6: the job feeder and housekeeping (sandbox/t2/shakeout/feeder.py). A fake ctx stands in for the T2 run: its
/state holds turtles, jobs and a storage list, and its dispatch() turns the feeder's POST /command orders into jobs the way
central_server.lua does (an ORDER_MINE makes one job per SECTORS_PER_MINER sectors, capped by minerCount); with assign=True it
also hands each new job to an idle turtle of the right role, as the server's dispatcher does.

    python -I sandbox/tests/test_shakeout_feeder.py
"""
import math
import os
import re
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "t2"))
from shakeout import feeder, world  # noqa: E402

PAD, STEP = 16, 32


def server_bounds(x1, z1, x2, z2):
    """central_server.lua buildSectorGrid, re-typed here on purpose: the bounds a zone really covers after snapping and padding."""
    minx, maxx = math.floor(min(x1, x2) / STEP) * STEP, math.ceil(max(x1, x2) / STEP) * STEP
    minz, maxz = math.floor(min(z1, z2) / STEP) * STEP, math.ceil(max(z1, z2) / STEP) * STEP
    return minx - PAD, minz - PAD, maxx + PAD, maxz + PAD


def overlap(a, b):
    return a[0] <= b[2] and b[0] <= a[2] and a[1] <= b[3] and b[1] <= a[3]


class FakeRaw:
    def __init__(self):
        self.commands = []
        self.world = "no-such-world"
        self.not_air = set()

    def command(self, text):
        self.commands.append(text)
        if text.startswith("execute if block"):
            x, y, z = (int(v) for v in text.split()[3:6])
            return "Test failed" if (x, y, z) in self.not_air else "Test passed"
        return "Modified block data"


class FakeCtx:
    def __init__(self, miners=40, deliverers=8, assign=False):
        self.assign = assign
        self.run = tempfile.mkdtemp()
        self.interventions = []
        self.notes = []
        self.orders = []
        self.jobs = {}
        self.n = 0
        self._raw = FakeRaw()
        self.turtles = {}
        for i in range(miners):
            self.turtles["node_%d" % (100 + i)] = {"role": "MINER", "status": "IDLE", "online": True}
        for i in range(deliverers):
            self.turtles["node_%d" % (300 + i)] = {"role": "DELIVERY", "status": "IDLE", "online": True}
        self.storage = [{"name": "minecraft:cobblestone", "amount": 5000}, {"name": "minecraft:iron_ore", "amount": 9000}]

    lag_ms = 0          # serverTime - updatedAt: how old the snapshot the bridge is serving is

    def state(self):
        return {"turtles": self.turtles, "jobs": list(self.jobs.values()), "storage": self.storage,
                "updatedAt": 5000000, "serverTime": 5000000 + self.lag_ms}

    def note(self, text):
        self.notes.append(text)

    def dispatch(self, type_, params=None):
        self.orders.append((type_, params))
        if type_ == "ORDER_MINE":
            x1, z1, x2, z2 = server_bounds(params["x1"], params["z1"], params["x2"], params["z2"])
            sectors = ((x2 - x1 - 2 * PAD) // STEP + 1) * ((z2 - z1 - 2 * PAD) // STEP + 1)
            count = max(1, min(math.ceil(sectors / 3), params.get("minerCount", 99)))
            for _ in range(count):
                self.n += 1
                self.jobs["j%d" % self.n] = {"id": "j%d" % self.n, "type": "MINE", "status": "IN_PROGRESS",
                                             "zoneKey": "%d,%d,%d,%d" % (x1, z1, x2, z2)}
        elif type_ == "ORDER_DELIVERY":
            self.n += 1
            self.jobs["j%d" % self.n] = {"id": "j%d" % self.n, "type": "DELIVER", "status": "IN_PROGRESS",
                                         "destination": params["destination"]}
        if self.assign:         # the server hands each new job to an idle turtle of the right role, else it stays PENDING
            role = "MINER" if type_ == "ORDER_MINE" else "DELIVERY"
            for j in self.jobs.values():
                if "who" in j or j["status"] != "IN_PROGRESS":
                    continue
                for tid, t in self.turtles.items():
                    if t["role"] == role and t["status"] == "IDLE":
                        t["status"] = "WORKING"
                        j["who"] = tid
                        break
                else:
                    j["status"] = "PENDING"
        return {"ok": True}

    def complete_deliveries(self):
        for j in list(self.jobs.values()):
            if j["type"] == "DELIVER":
                j["status"] = "COMPLETE"


def active(ctx):
    return [j for j in ctx.jobs.values() if j["status"] in ("PENDING", "ASSIGNED", "IN_PROGRESS")]


class FeederTests(unittest.TestCase):
    def test_feeder_keeps_ten_jobs(self):
        ctx = FakeCtx()
        f = feeder.Feeder(ctx)
        now = 1000.0
        for _ in range(30):
            f.tick(now)
            now += 60
            ctx.complete_deliveries()
        f.tick(now)
        self.assertGreaterEqual(len(active(ctx)), 10, "at least 10 jobs after a tick")
        sites = {j["zoneKey"] for j in ctx.jobs.values() if j["type"] == "MINE" and j["status"] == "IN_PROGRESS"}
        self.assertGreaterEqual(len(sites), 3, "at least 3 sites open at once (%d)" % len(sites))
        dests = set()
        for t, p in ctx.orders:
            if t == "ORDER_DELIVERY":
                d = p["destination"]
                dests.add((d["x"], d["y"], d["z"]))
        self.assertGreaterEqual(len(dests), 4, "deliveries went to at least 4 destinations (%s)" % sorted(dests))
        self.assertTrue(all("ore" not in p["items"][0]["name"] for t, p in ctx.orders if t == "ORDER_DELIVERY"),
                        "deliveries carry ordinary stock, not ore")

    def test_feeder_refills_after_jobs_end(self):
        ctx = FakeCtx()
        f = feeder.Feeder(ctx)
        f.tick(1000.0)
        for j in ctx.jobs.values():
            j["status"] = "COMPLETE"
        for i in range(5):
            f.tick(1100.0 + 60 * i)
        self.assertGreaterEqual(len(active(ctx)), 10)

    def test_idle_miner_gets_work(self):
        ctx = FakeCtx(miners=1, deliverers=0)
        f = feeder.Feeder(ctx, min_jobs=0, sites=0)
        f.tick(1000.0)
        f.tick(1000.0 + 100)
        self.assertEqual(ctx.orders, [], "no order for a turtle that has only just been seen idle")
        f.tick(1000.0 + 200)
        self.assertTrue(any(t == "ORDER_MINE" for t, _ in ctx.orders), "an order well within the idle limit (a quarter of it)")

    def test_feeder_never_reuses_ground(self):
        boxes = [server_bounds(z["x1"], z["z1"], z["x2"], z["z2"]) for z in feeder.ZONES]
        for i, a in enumerate(boxes):
            for b in boxes[i + 1:]:
                self.assertFalse(overlap(a, b), "zones %s and %s overlap" % (a, b))
            for area in world.BASE_AREAS:
                self.assertFalse(overlap(a, area), "zone %s touches the base %s" % (a, area))
            for w in feeder.WORKED_GROUND:
                self.assertFalse(overlap(a, w), "zone %s touches worked ground %s" % (a, w))
        self.assertEqual(len({z["id"] for z in feeder.ZONES}), len(feeder.ZONES))
        # a small list, spent completely: no zone twice, and running out is said
        small = feeder.ZONES[:5]
        saved = feeder.ZONES
        feeder.ZONES = small
        try:
            ctx = FakeCtx()
            f = feeder.Feeder(ctx)
            now = 0.0
            for i in range(60):
                f.tick(now)
                now += 120
                for j in ctx.jobs.values():
                    j["status"] = "COMPLETE"
        finally:
            feeder.ZONES = saved
        keys = [(p["x1"], p["z1"], p["x2"], p["z2"]) for t, p in ctx.orders if t == "ORDER_MINE"]
        self.assertEqual(len(keys), len(set(keys)), "no zone ordered twice")
        self.assertEqual(set(keys), {(z["x1"], z["z1"], z["x2"], z["z2"]) for z in small})
        self.assertTrue(any("exhausted" in n for n in ctx.notes), "running out of fresh ground is said, not silent")

    def test_worked_ground_is_the_whole_dump(self):
        path = os.path.join(HERE, "..", "..", "docs", "measurements", "2026-09-22-zone-ore-map-dump.txt")
        pts, zones = set(), set()
        with open(path, encoding="utf8") as f:
            for line in f:
                m = re.match(r"\((-?\d+),(-?\d+)\)", line)
                if m:
                    pts.add((int(m.group(1)), int(m.group(2))))
                m = re.match(r"Ore map for zone (-?\d+),(-?\d+),(-?\d+),(-?\d+)", line)
                if m:
                    zones.add(tuple(int(v) for v in m.groups()))
        self.assertEqual(pts, set(feeder.DUMP_SECTORS))
        self.assertEqual(zones, set(feeder.DUMP_ZONES))
        self.assertGreater(len(pts), 100)
        # the zone the reviewer found (1008,-2608,1168,-2480, with [done] sectors) is covered
        self.assertIn((1008, -2608, 1168, -2480), feeder.WORKED_GROUND)

    def test_ground_covers_24_hours_at_4x(self):
        need = feeder.sectors_needed(hours=24, miners=128, speed=4)
        have = len(feeder.ZONES) * feeder.ZONE_SECTORS ** 2
        self.assertGreaterEqual(have, need, "%d sectors of ground, %d needed for 24 h at 4x" % (have, need))
        self.assertGreaterEqual(feeder.MINERS_PER_ZONE, 12)

    def test_destinations_are_staggered(self):
        ds = feeder.DESTINATIONS
        self.assertGreaterEqual(len(ds), 4)
        self.assertEqual(len({d[2] for d in ds}), len(ds), "no two destinations on one z row")

    def test_a_destination_that_is_not_air_is_dropped(self):
        ctx = FakeCtx()
        ctx._raw.not_air.add((172, 68, -2755))
        f = feeder.Feeder(ctx)
        self.assertNotIn((172, 67, -2755), f.dests)
        self.assertGreaterEqual(len(f.dests), 4)
        self.assertTrue(any("not air" in n for n in ctx.notes))

    def test_no_turtle_idles_longer_than_the_limit_at_fleet_scale(self):
        ctx = FakeCtx(miners=128, deliverers=16, assign=True)
        f = feeder.Feeder(ctx)
        now, idle_start, worst = 0.0, {}, {}
        for step in range(int(4 * 3600 / 15)):        # four hours of 15 s polls
            for j in ctx.jobs.values():               # deliveries take 5 minutes; mining never ends
                if j["type"] == "DELIVER" and j["status"] == "IN_PROGRESS" and "who" in j and now - j.setdefault("t", now) >= 300:
                    j["status"] = "COMPLETE"
                    ctx.turtles[j["who"]]["status"] = "IDLE"
            f.tick(now)
            for tid, t in ctx.turtles.items():
                if t["status"] == "IDLE":
                    idle_start.setdefault(tid, now)
                    worst[tid] = max(worst.get(tid, 0), now - idle_start[tid])
                else:
                    idle_start.pop(tid, None)
            now += 15
        self.assertFalse(any("exhausted" in n for n in ctx.notes), "fresh ground remained throughout")
        over = {t: w for t, w in worst.items() if w > 600}
        self.assertEqual(over, {}, "turtles idle over 10 minutes: %d, worst %s" % (len(over), max(worst.values())))
        working = len([1 for t in ctx.turtles.values() if t["role"] == "MINER" and t["status"] != "IDLE"])
        self.assertEqual(working, 128, "every miner is working at the end")

    def test_ordering_resets_no_idle_clock(self):
        # the clock is the evidence: it restarts only when a turtle leaves IDLE, never because an order was placed
        ctx = FakeCtx(miners=2, deliverers=3)
        f = feeder.Feeder(ctx, min_jobs=0, sites=0)
        f.tick(0.0)
        f.tick(400.0)
        self.assertTrue(any(t == "ORDER_DELIVERY" for t, _ in ctx.orders))
        self.assertTrue(all(f.idle_since[t] == 0.0 for t in ctx.turtles), f.idle_since)

    def test_pending_jobs_are_subtracted_before_ordering_more(self):
        ctx = FakeCtx(miners=5, deliverers=0)
        f = feeder.Feeder(ctx, min_jobs=0, sites=0)
        f.tick(0.0)
        f.tick(400.0)
        n = len([o for o in ctx.orders if o[0] == "ORDER_MINE"])
        self.assertEqual(n, 1, "five waiting miners, one full zone of twelve jobs pending")
        for j in ctx.jobs.values():
            j["status"] = "PENDING"
        for i in range(10):
            f.tick(430.0 + 30 * i)
        self.assertEqual(len([o for o in ctx.orders if o[0] == "ORDER_MINE"]), n, "pending jobs cover the waiting miners: no phantom orders")

    def test_mining_orders_are_always_full_zones(self):
        ctx = FakeCtx(miners=1, deliverers=0)
        f = feeder.Feeder(ctx, min_jobs=0, sites=0)
        f.tick(0.0)
        f.tick(400.0)
        self.assertEqual([p["minerCount"] for t, p in ctx.orders if t == "ORDER_MINE"], [feeder.MINERS_PER_ZONE])

    def test_benched_turtles_are_not_waiting(self):
        ctx = FakeCtx(miners=3, deliverers=0)
        for t in ctx.turtles.values():
            t["blockedUntil"] = (1e5 + 9999) * 1000        # server epoch ms, long after the ticks
        f = feeder.Feeder(ctx, min_jobs=0, sites=0)
        f.tick(1e5)
        f.tick(1e5 + 900)
        self.assertEqual(ctx.orders, [], "benched turtles are held back by the server: no phantom orders for them")
        self.assertEqual(f.idle_since, {})

    def test_empty_or_stale_storage_still_delivers_cobblestone(self):
        for st in ({"storage": []}, {"storage": [{"name": "minecraft:iron_ingot", "amount": 9999}], "storageTs": 1}):
            ctx = FakeCtx(deliverers=1, miners=0)
            ctx.state = lambda ctx=ctx, st=st: {"turtles": ctx.turtles, "jobs": list(ctx.jobs.values()), "storage": st["storage"],
                                                "storageTs": st.get("storageTs"), "updatedAt": 5000000, "serverTime": 5000000}
            f = feeder.Feeder(ctx, min_jobs=0, sites=0)
            f.tick(1e6)
            f.tick(1e6 + 400)
            names = [p["items"][0]["name"] for t, p in ctx.orders if t == "ORDER_DELIVERY"]
            self.assertEqual(names, ["minecraft:cobblestone"], st)


class StaleStateTests(unittest.TestCase):
    """A frozen or empty /state must not make the feeder order the same work every poll (reviewer sims sim_stale / sim_empty)."""

    def test_frozen_state_for_30_minutes_places_no_orders(self):
        import copy
        ctx = FakeCtx(miners=128, deliverers=16)
        f = feeder.Feeder(ctx)
        for i, (tid, t) in enumerate(sorted(ctx.turtles.items())):
            t["status"] = ("IDLE" if i < 8 else "WORKING") if t["role"] == "MINER" else ("IDLE" if i % 8 == 0 else "WORKING")
        for k in range(120):
            ctx.jobs["w%d" % k] = {"id": "w%d" % k, "type": "MINE", "status": "IN_PROGRESS", "zoneKey": "z%d" % (k // 12)}
        frozen = copy.deepcopy(ctx.state())
        elapsed = [0]

        def replay():
            st = copy.deepcopy(frozen)
            st["serverTime"] += elapsed[0] * 1000          # the bridge stamps serverTime per request; updatedAt stays at the last push
            return st
        ctx.state = replay
        for step in range(int(30 * 60 / 15)):
            f.tick(1000.0 + step * 15)
            elapsed[0] += 15
        late = ctx.orders[len([o for o in ctx.orders if False]):]
        # the first 30 s are inside the freshness window: a fresh state would justify at most the sites and the idle watch once
        self.assertLessEqual(len(late), 6, "orders from a snapshot that was frozen for 30 min: %d" % len(late))
        n_after_stale = len(ctx.orders)
        for step in range(60):
            f.tick(5000.0 + step * 15)
            elapsed[0] += 15
        self.assertEqual(len(ctx.orders), n_after_stale, "no order at all while the snapshot is more than 30 s old")
        self.assertTrue(any("not fresh" in n for n in ctx.notes))
        self.assertEqual(len([n for n in ctx.notes if "not fresh" in n]), 2, "one note per 30 minutes, not one per poll")

    def test_empty_initial_state_for_4_minutes_places_no_orders(self):
        ctx = FakeCtx(miners=128, deliverers=16)
        f = feeder.Feeder(ctx)
        ctx.state = lambda: {"turtles": {}, "jobs": [], "storage": [], "storageTs": 0, "updatedAt": None, "serverTime": 9000000}
        for step in range(16):
            f.tick(10000.0 + step * 15)
        self.assertEqual(ctx.orders, [])
        ctx.state = lambda: {"turtles": {}, "jobs": [], "storage": [], "updatedAt": 9000000, "serverTime": 9000000}
        f.tick(11000.0)
        self.assertEqual(ctx.orders, [], "a fresh stamp on an empty fleet is still no fleet")

    def test_orders_a_fresh_state_never_shows_are_not_repeated_every_poll(self):
        ctx = FakeCtx(miners=8, deliverers=0)
        ctx.dispatch = lambda t, p=None: ctx.orders.append((t, p))          # the orders vanish: no job ever appears
        f = feeder.Feeder(ctx, min_jobs=0, sites=0)
        for step in range(int(30 * 60 / 15)):
            f.tick(step * 15.0)
        n = len([o for o in ctx.orders if o[0] == "ORDER_MINE"])
        self.assertLessEqual(n, 3, "eight waiting miners, orders that never show: at most one retry per two snapshots past the grace (%d)" % n)
        self.assertGreaterEqual(n, 1)
        self.assertTrue(any("never showed up" in x for x in ctx.notes))

    def test_assigned_jobs_whose_turtle_still_reads_idle_count_as_pending(self):
        ctx = FakeCtx(miners=3, deliverers=0)
        for i, tid in enumerate(sorted(ctx.turtles)):
            ctx.jobs["a%d" % i] = {"id": "a%d" % i, "type": "MINE", "status": "ASSIGNED", "assignedTo": tid, "zoneKey": "k"}
        f = feeder.Feeder(ctx, min_jobs=0, sites=0)
        f.tick(0.0)
        f.tick(400.0)
        self.assertEqual(ctx.orders, [])

    def test_a_failed_order_does_not_spend_the_zone(self):
        ctx = FakeCtx(miners=1, deliverers=0)
        f = feeder.Feeder(ctx, min_jobs=0, sites=0)

        def boom(t, p=None):
            raise OSError("bridge down")
        ctx.dispatch = boom
        f.tick(0.0)
        with self.assertRaises(OSError):
            f.tick(400.0)
        self.assertEqual(f.next_zone, 0)
        self.assertEqual(f.unseen, [])


class LongSiteTests(unittest.TestCase):
    def test_three_lanes_of_contiguous_disjoint_zones(self):
        self.assertEqual(len(feeder.LONG_SITES), 3)
        by_id = {z["id"]: z for z in feeder.ZONES}
        boxes_all = []
        for lane in feeder.LONG_SITES:
            self.assertGreaterEqual(len(lane), 12, "a lane outlasts 24 h at ~2 h a zone")
            zs = [by_id[i] for i in lane]
            for a, b in zip(zs, zs[1:]):
                self.assertEqual(b["z1"], a["z1"], "the follow-on zone is in the same row")
                self.assertEqual(b["x1"] - a["x1"], feeder.ZONE_PITCH, "and directly next to it")
            boxes_all += [server_bounds(z["x1"], z["z1"], z["x2"], z["z2"]) for z in zs]
        for i, a in enumerate(boxes_all):
            for b in boxes_all[i + 1:]:
                self.assertFalse(overlap(a, b))
        for a in boxes_all:
            for w in feeder.WORKED_GROUND:
                self.assertFalse(overlap(a, w))

    def test_a_lane_orders_its_next_zone_when_its_zone_is_spent(self):
        ctx = FakeCtx(miners=30, deliverers=0)
        f = feeder.Feeder(ctx, min_jobs=0, sites=3)
        f.tick(0.0)
        first = [(p["x1"], p["z1"]) for t, p in ctx.orders if t == "ORDER_MINE"]
        self.assertEqual(len(first), 3)
        self.assertEqual(len({z for _, z in first}), 3, "three different lanes")
        f.tick(15.0)                      # a fresh /state shows the three zones' jobs
        for j in ctx.jobs.values():
            j["status"] = "COMPLETE"
        f.tick(feeder.GRACE_S + 100.0)
        second = [(p["x1"], p["z1"]) for t, p in ctx.orders if t == "ORDER_MINE"][3:]
        self.assertEqual(sorted((x - feeder.ZONE_PITCH, z) for x, z in second), sorted(first), "each lane moved one zone along")


class Sim:
    """The reviewer's adversarial sim (scratchpad sim_feed2/3): a dispatcher handing PENDING jobs to idle, un-benched turtles at
    `per_poll` jobs a poll (the oldest first, a DIFFERENT turtle from the one that was waiting), mining jobs that work a zone's 36
    sectors (one per SECTOR_S per miner) and end when it is empty, deliveries that take 300 s, and `benches_per_hour` timed 600 s
    benches (a working miner refuses its job: it goes IDLE, blocked, the job goes back to PENDING)."""
    SECTOR_S = 9400 / 4.0

    def __init__(self, benches_per_hour, per_poll, hours=24, miners=128, deliverers=16, warmup=0):
        import random
        self.rnd = random.Random(1)
        self.ctx = ctx = FakeCtx(miners=miners, deliverers=deliverers)
        self.zones = {}
        orig = ctx.dispatch

        def dispatch(t, p=None):
            before = set(ctx.jobs)
            r = orig(t, p)
            for jid in set(ctx.jobs) - before:
                j = ctx.jobs[jid]
                j["status"] = "PENDING"
                if j["type"] == "MINE":
                    self.zones.setdefault(j["zoneKey"], 36)
            return r
        ctx.dispatch = dispatch
        for t in ctx.turtles.values():
            t["blockedUntil"] = 0
        self.f = feeder.Feeder(ctx)
        self.bph, self.per_poll, self.hours, self.warmup = benches_per_hour, per_poll, hours, warmup
        self.lane_keys = [{feeder.zone_key(z) for z in lane} for lane in self.f.lanes]
        self.lane_open_s = [0.0] * len(self.lane_keys)

    def run(self):
        ctx, f, now, idle_start, worst = self.ctx, self.f, 0.0, {}, 0
        for step in range(int(self.hours * 3600 / 15)):
            for j in ctx.jobs.values():
                if j["status"] != "IN_PROGRESS":
                    continue
                w = ctx.turtles[j["who"]]
                if j["type"] == "DELIVER" and now - j["t"] >= 300:
                    j["status"] = "COMPLETE"
                    w["status"] = "IDLE"
                elif j["type"] == "MINE" and now - j["t"] >= self.SECTOR_S:
                    if self.zones[j["zoneKey"]] > 0:
                        self.zones[j["zoneKey"]] -= 1
                        j["t"] = now
                    else:
                        j["status"] = "COMPLETE"
                        w["status"] = "IDLE"
            if self.rnd.random() < self.bph * 15 / 3600.0:
                ws = [j for j in ctx.jobs.values() if j["type"] == "MINE" and j["status"] == "IN_PROGRESS"]
                if ws:
                    j = self.rnd.choice(ws)
                    w = ctx.turtles[j["who"]]
                    w["status"], w["blockedUntil"], j["status"] = "IDLE", now + 600, "PENDING"
                    del j["who"]
            n = 0
            for jid, j in sorted(ctx.jobs.items(), key=lambda kv: int(kv[0][1:])):
                if j["status"] != "PENDING" or n >= self.per_poll:
                    continue
                role = "MINER" if j["type"] == "MINE" else "DELIVERY"
                for tid, t in ctx.turtles.items():
                    if t["role"] == role and t["status"] == "IDLE" and t["blockedUntil"] <= now:
                        t["status"], j["status"], j["who"], j["t"] = "WORKING", "IN_PROGRESS", tid, now
                        if j["type"] == "MINE" and self.zones[j["zoneKey"]] > 0:
                            self.zones[j["zoneKey"]] -= 1
                        n += 1
                        break
            f.tick(now)
            live = {j.get("zoneKey") for j in ctx.jobs.values() if j["type"] == "MINE" and j["status"] in ("PENDING", "ASSIGNED", "IN_PROGRESS")}
            for k, keys in enumerate(self.lane_keys):
                if keys & live:
                    self.lane_open_s[k] += 15
            for tid, t in ctx.turtles.items():
                if t["status"] == "IDLE" and t["blockedUntil"] <= now:
                    idle_start.setdefault(tid, now)
                    worst = max(worst, now - idle_start[tid]) if now >= self.warmup else worst
                else:
                    idle_start.pop(tid, None)
            now += 15
        return worst


class AdversarialFleetTests(unittest.TestCase):
    def check(self, bph, per_poll, warmup=0):
        sim = Sim(bph, per_poll, warmup=warmup)
        worst = sim.run()
        ctx = sim.ctx
        counts = {p["minerCount"] for t, p in ctx.orders if t == "ORDER_MINE"}
        self.assertEqual(counts, {feeder.MINERS_PER_ZONE}, "every mining order is a full zone")
        self.assertFalse(sim.f.exhausted, "ground lasted 24 h (zones used %d of %d)" % (sim.f.next_zone, len(feeder.ZONES)))
        self.assertLessEqual(worst, 600, "worst un-benched idle time %.0f s" % worst)
        working = len([1 for t in ctx.turtles.values() if t["role"] == "MINER" and t["status"] != "IDLE"])
        self.assertGreater(working, 100, "the miners are working at the end (%d)" % working)
        self.assertEqual(len(sim.lane_open_s), 3)
        for k, secs in enumerate(sim.lane_open_s):
            self.assertGreaterEqual(secs / 3600.0, 20, "long-running site %d was open %.1f h of 24" % (k, secs / 3600.0))

    def test_no_faults_24_hours(self):
        self.check(0, 8)

    def test_six_benches_an_hour_24_hours(self):
        self.check(6, 8)

    def test_slow_dispatcher_with_benches(self):
        self.check(6, 3, warmup=3600)       # 132 jobs at 3 a poll: the first hour is the dispatcher's start-up, not the feeder's


class HousekeepingTests(unittest.TestCase):
    def setUp(self):
        self.saved = (feeder.RS_CAPACITY, feeder.read_rs_disks)
        feeder.RS_CAPACITY = None

    def tearDown(self):
        feeder.RS_CAPACITY, feeder.read_rs_disks = self.saved

    def disks(self, used, capacity, age=60.0):
        item = {"Type": "refinedstorage:item", "Data": {"Items": [{"Quantity": used}]}}
        if capacity is not None:
            item["Data"]["Capacity"] = capacity
        feeder.read_rs_disks = lambda world: ([item], age)

    def _lines(self, ctx):
        with open(os.path.join(ctx.run, "shakeout", "housekeeping.log"), encoding="utf8") as f:
            return [l for l in f.read().splitlines() if l]

    def run_once(self, ctx):
        feeder.housekeep(ctx, 0.0)                         # the first call only sets the timetable
        self.assertEqual(feeder.housekeep(ctx, 10.0), [], "not due yet")
        return feeder.housekeep(ctx, feeder.HOUSEKEEP_EVERY_S + 1)

    def test_housekeeping_is_logged_not_intervention(self):
        ctx = FakeCtx()
        self.disks(2000000, 20000000)
        self.run_once(ctx)
        self.assertEqual(ctx.interventions, [], "housekeeping is not an intervention")
        lines = self._lines(ctx)
        self.assertTrue(lines and all("HOUSEKEEPING " in l for l in lines), lines)
        self.assertTrue(any("HOUSEKEEPING storage-headroom-ok" in l and "file_age=60s" in l for l in lines), lines)
        self.assertEqual([o for o in ctx.orders if o[0] == "ORDER_DELIVERY"], [], "nothing is drained or ordered")

    def test_low_headroom_is_a_named_finding(self):
        ctx = FakeCtx()
        self.disks(9000000, 10000000)
        self.run_once(ctx)
        self.assertTrue(any("HOUSEKEEPING storage-headroom-low" in l for l in self._lines(ctx)), self._lines(ctx))
        self.assertEqual(ctx.orders, [], "no drain order: the trash-can drain is gone")

    def test_unlimited_creative_capacity_is_never_low(self):
        ctx = FakeCtx()
        self.disks(999999999, -1)
        self.run_once(ctx)
        self.assertTrue(any("storage-headroom-ok" in l and "unlimited" in l for l in self._lines(ctx)), self._lines(ctx))

    def test_a_disk_without_capacity_is_unknown_not_unlimited(self):
        ctx = FakeCtx()
        self.disks(1, None)
        self.run_once(ctx)
        self.assertTrue(any("storage-headroom-unknown" in l for l in self._lines(ctx)), self._lines(ctx))
        self.assertFalse(any("unlimited" in l for l in self._lines(ctx)))

    def test_a_stale_file_is_unknown(self):
        ctx = FakeCtx()
        self.disks(1, 100, age=2 * feeder.HOUSEKEEP_EVERY_S + 5)
        self.run_once(ctx)
        self.assertTrue(any("storage-headroom-unknown: RS data is stale" in l for l in self._lines(ctx)), self._lines(ctx))

    def test_an_unreadable_file_is_unknown(self):
        ctx = FakeCtx()
        self.run_once(ctx)                  # read_rs_disks is the real one and the fake world folder does not exist
        self.assertTrue(any("storage-headroom-unknown: RS data unreadable" in l for l in self._lines(ctx)), self._lines(ctx))

    def test_a_low_reading_inside_a_scheduled_storage_fault_is_expected(self):
        ctx = FakeCtx()
        self.disks(9900000, 10000000)
        ctx.shakeout_entries = [{"id": "f007", "fault": "rs_offline"}, {"id": "f008", "fault": "radio_loss"}]
        ctx.shakeout_sched = {"status": {"f007": {"phase": "active"}, "f008": {"phase": "active"}}}
        self.run_once(ctx)
        lines = self._lines(ctx)
        self.assertTrue(any("storage-headroom-expected state=low (inside scheduled rs_offline f007)" in l for l in lines), lines)
        self.assertFalse(any("storage-headroom-low" in l for l in lines), "an expected reading is not the finding")

    def test_delivery_spots_are_cleared_in_a_box_read_from_delivery_turtle_lua(self):
        import re
        lua = os.path.join(HERE, "..", "..", "delivery_turtle.lua")
        with open(lua, encoding="utf8") as f:
            self.assertEqual(feeder.MAX_CHESTS, int(re.search(r"^local MAX_CHESTS\s*=\s*(\d+)", f.read(), re.M).group(1)))
        x, y, z = feeder.DESTINATIONS[0]
        self.assertEqual(feeder.clear_box((x, y, z)), (x - 1, y - 1, z - 1, x + 1, y, z + feeder.MAX_CHESTS + 1))
        ctx = FakeCtx()
        self.disks(1, 100)
        self.run_once(ctx)
        fills = [c for c in ctx._raw.commands if c.startswith("fill ")]
        self.assertEqual(len(fills), len(feeder.DESTINATIONS))
        self.assertTrue(all(c.endswith("minecraft:air replace minecraft:chest") for c in fills), "only plain chests, never the entangled one")
        self.assertEqual(len([c for c in ctx._raw.commands if c.startswith("kill @e[type=minecraft:item")]), len(feeder.DESTINATIONS))
        self.assertEqual(ctx.interventions, [])
        self.assertTrue(any("HOUSEKEEPING clear-delivery-spot" in l for l in self._lines(ctx)))

    def test_a_spot_with_a_turtle_in_the_box_or_a_delivery_heading_there_is_left_alone(self):
        ctx = FakeCtx()
        self.disks(1, 100)
        x, y, z = feeder.DESTINATIONS[0]
        ctx.turtles["node_300"].update({"x": x, "y": y, "z": z + 3})
        hx, hy, hz = feeder.DESTINATIONS[1]
        ctx.jobs["j1"] = {"id": "j1", "type": "DELIVER", "status": "IN_PROGRESS", "destination": {"x": hx, "y": hy, "z": hz}}
        self.run_once(ctx)
        lines = self._lines(ctx)
        self.assertTrue(any("%d,%d,%d skipped: a turtle is inside" % (x, y, z) in l for l in lines), lines)
        self.assertTrue(any("%d,%d,%d skipped: a delivery is on its way" % (hx, hy, hz) in l for l in lines), lines)
        self.assertEqual(len([c for c in ctx._raw.commands if c.startswith("fill ")]), len(feeder.DESTINATIONS) - 2)

    def test_capacity_and_used_of_disks(self):
        def item(c, q=0):
            return {"Type": "refinedstorage:item", "Data": {"Capacity": c, "Items": [{"Quantity": q}]}}
        self.assertEqual(feeder.capacity_of_disks([item(1000), item(2000), {"Type": "refinedstorage:fluid", "Data": {"Capacity": 5}}]), 3000)
        self.assertEqual(feeder.used_of_disks([item(1000, 7), item(2000, 5)]), 12)
        self.assertEqual(feeder.capacity_of_disks([item(1000), item(-1)]), float("inf"))
        self.assertIsNone(feeder.capacity_of_disks([item(1000), item(-5)]), "only -1 is unlimited")
        self.assertIsNone(feeder.capacity_of_disks([item(1000), {"Type": "refinedstorage:item", "Data": {"Items": []}}]), "no Capacity: unknown")
        self.assertIsNone(feeder.capacity_of_disks([]))
        self.assertIsNone(feeder.rs_capacity_of_world("no-such-world"))


if __name__ == "__main__":
    unittest.main()
