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

    def state(self):
        return {"turtles": self.turtles, "jobs": list(self.jobs.values()), "storage": self.storage}

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
        f.tick(1000.0 + 200)
        self.assertEqual(ctx.orders, [], "no order for a turtle that has only just been seen idle")
        f.tick(1000.0 + 301)
        self.assertTrue(any(t == "ORDER_MINE" for t, _ in ctx.orders), "an order within the idle limit (half of it)")

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

    def test_idle_clock_resets_only_for_turtles_given_work(self):
        # no stock to deliver: the delivery turtles' idleness must stay on the clock, not be wiped
        ctx = FakeCtx(miners=0, deliverers=3)
        ctx.storage = []
        f = feeder.Feeder(ctx, min_jobs=0, sites=0)
        f.tick(0.0)
        f.tick(400.0)
        self.assertEqual(ctx.orders, [])
        self.assertTrue(all(f.idle_since[t] == 0.0 for t in ctx.turtles), f.idle_since)
        ctx.storage = [{"name": "minecraft:cobblestone", "amount": 5000}]
        f.tick(450.0)
        self.assertEqual(len([o for o in ctx.orders if o[0] == "ORDER_DELIVERY"]), 3, "one delivery per idle delivery turtle")

    def test_no_stock_note_is_rate_limited(self):
        ctx = FakeCtx(deliverers=2, miners=0)
        ctx.storage = []
        f = feeder.Feeder(ctx, min_jobs=0, sites=0)
        f.tick(0.0)
        for i in range(1, 100):
            f.tick(i * 15.0 + 300)
        self.assertEqual(len([n for n in ctx.notes if "no ordinary stock" in n]), 1)


class HousekeepingTests(unittest.TestCase):
    def setUp(self):
        self.saved = feeder.RS_CAPACITY

    def tearDown(self):
        feeder.RS_CAPACITY = self.saved

    def _lines(self, ctx):
        with open(os.path.join(ctx.run, "shakeout", "housekeeping.log"), encoding="utf8") as f:
            return [l for l in f.read().splitlines() if l]

    def test_housekeeping_is_logged_not_intervention(self):
        ctx = FakeCtx()
        feeder.RS_CAPACITY = 20000000
        ctx.storage = [{"name": "minecraft:cobblestone", "amount": 2000000}, {"name": "minecraft:iron_ore", "amount": 100000}]
        feeder.housekeep(ctx, 0.0)                         # the first call only sets the timetable
        self.assertEqual(feeder.housekeep(ctx, 10.0), [], "not due yet")
        feeder.housekeep(ctx, feeder.HOUSEKEEP_EVERY_S + 1)
        self.assertEqual(ctx.interventions, [], "housekeeping is not an intervention")
        self.assertEqual(ctx._raw.commands, [], "and runs no console command")
        lines = self._lines(ctx)
        self.assertTrue(lines and all("HOUSEKEEPING " in l for l in lines), lines)
        self.assertTrue(any("HOUSEKEEPING storage-headroom-ok" in l for l in lines), lines)
        self.assertEqual([o for o in ctx.orders if o[0] == "ORDER_DELIVERY"], [], "plenty of room: nothing drained")

    def test_low_headroom_is_a_named_finding_and_drains_ore(self):
        ctx = FakeCtx()
        feeder.RS_CAPACITY = 10000000
        ctx.storage = [{"name": "minecraft:cobblestone", "amount": 2000000}, {"name": "minecraft:iron_ore", "amount": 7500000},
                       {"name": "minecraft:coal_ore", "amount": 10}]
        feeder.housekeep(ctx, 0.0)
        feeder.housekeep(ctx, feeder.HOUSEKEEP_EVERY_S + 1)
        lines = self._lines(ctx)
        self.assertTrue(any("HOUSEKEEPING storage-headroom-low" in l for l in lines), lines)
        self.assertTrue(any("HOUSEKEEPING drain_ore ordered" in l and "iron_ore" in l for l in lines), lines)
        drains = [p for t, p in ctx.orders if t == "ORDER_DELIVERY"]
        self.assertEqual(len(drains), 1)
        self.assertEqual(drains[0]["items"][0]["name"], "minecraft:iron_ore")
        self.assertEqual(drains[0]["destination"], {"x": 174, "y": 67, "z": -2829})
        self.assertEqual(ctx.interventions, [])

    def test_unknown_capacity_is_said(self):
        ctx = FakeCtx()
        feeder.RS_CAPACITY = None
        feeder.housekeep(ctx, 0.0)
        feeder.housekeep(ctx, feeder.HOUSEKEEP_EVERY_S + 1)
        self.assertTrue(any("HOUSEKEEPING storage-headroom-unknown" in l for l in self._lines(ctx)))

    def test_capacity_of_disks(self):
        def item(c):
            return {"Type": "refinedstorage:item", "Data": {"Capacity": c, "Items": []}}
        self.assertEqual(feeder.capacity_of_disks([item(1000), item(2000), {"Type": "refinedstorage:fluid", "Data": {"Capacity": 5}}]), 3000)
        self.assertEqual(feeder.capacity_of_disks([item(1000), item(-1)]), float("inf"))
        self.assertIsNone(feeder.capacity_of_disks([]))
        self.assertIsNone(feeder.rs_capacity_of_world("no-such-world"))


if __name__ == "__main__":
    unittest.main()
