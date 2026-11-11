"""Shakeout Task 6: the job feeder and housekeeping (sandbox/t2/shakeout/feeder.py). A fake ctx stands in for the T2 run: its
/state holds turtles, jobs and a storage list, and its dispatch() turns the feeder's POST /command orders into jobs the way
central_server.lua does (an ORDER_MINE makes one job per SECTORS_PER_MINER sectors, capped by minerCount).

    python -I sandbox/tests/test_shakeout_feeder.py
"""
import math
import os
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

    def command(self, text):
        self.commands.append(text)
        return "Modified block data"


class FakeCtx:
    def __init__(self, miners=40, deliverers=8):
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
        self.assertEqual(ctx.orders, [], "no order for a turtle that has only just been seen idle")
        f.tick(1000.0 + 601)
        self.assertTrue(any(t == "ORDER_MINE" for t, _ in ctx.orders), "an order after 10 minutes idle")

    def test_feeder_never_reuses_ground(self):
        boxes = [server_bounds(z["x1"], z["z1"], z["x2"], z["z2"]) for z in feeder.ZONES]
        for i, a in enumerate(boxes):
            for b in boxes[i + 1:]:
                self.assertFalse(overlap(a, b), "zones %s and %s overlap" % (a, b))
            for area in world.BASE_AREAS:
                self.assertFalse(overlap(a, area), "zone %s touches the base %s" % (a, area))
            for w in feeder.WORKED_GROUND:
                self.assertFalse(overlap(a, w), "zone %s touches worked ground %s" % (a, w))
        self.assertGreaterEqual(len([z for z in feeder.ZONES if z["kind"] == "long"]), 6)
        self.assertEqual(len({z["id"] for z in feeder.ZONES}), len(feeder.ZONES))
        ctx = FakeCtx()
        f = feeder.Feeder(ctx)
        now = 0.0
        for i in range(400):
            f.tick(now)
            now += 120
            if i % 3 == 0:
                for j in ctx.jobs.values():
                    j["status"] = "COMPLETE"
        keys = [(p["x1"], p["z1"], p["x2"], p["z2"]) for t, p in ctx.orders if t == "ORDER_MINE"]
        self.assertEqual(len(keys), len(set(keys)), "no zone ordered twice")
        listed = {(z["x1"], z["z1"], z["x2"], z["z2"]) for z in feeder.ZONES}
        self.assertTrue(set(keys) <= listed)
        self.assertGreater(len(keys), 10)
        self.assertTrue(any("exhausted" in n for n in ctx.notes), "running out of fresh ground is said, not silent")


class HousekeepingTests(unittest.TestCase):
    def test_housekeeping_is_logged_not_intervention(self):
        ctx = FakeCtx()
        feeder.ORE_DRAIN_POS = (140, 67, -2830)
        feeder.STOCK_POS = (144, 67, -2830)
        try:
            feeder.housekeep(ctx, 0.0)                         # the first call only sets the timetable
            feeder.housekeep(ctx, feeder.DRAIN_EVERY_S + 1)
            feeder.housekeep(ctx, feeder.TOPUP_EVERY_S + 2)
        finally:
            feeder.ORE_DRAIN_POS = feeder.STOCK_POS = None
        self.assertEqual(ctx.interventions, [], "housekeeping is not an intervention")
        with open(os.path.join(ctx.run, "shakeout", "housekeeping.log"), encoding="utf8") as f:
            lines = [l for l in f.read().splitlines() if l]
        self.assertTrue(lines and all("HOUSEKEEPING " in l for l in lines), lines)
        self.assertTrue(any("HOUSEKEEPING drain_ore" in l for l in lines), lines)
        self.assertTrue(any("HOUSEKEEPING topup_stock" in l for l in lines), lines)
        self.assertEqual(len(ctx._raw.commands), len(lines), "each action ran one console command and logged one line")

    def test_unconfigured_housekeeping_says_so(self):
        ctx = FakeCtx()
        feeder.housekeep(ctx, 0.0)
        feeder.housekeep(ctx, feeder.DRAIN_EVERY_S + 1)
        with open(os.path.join(ctx.run, "shakeout", "housekeeping.log"), encoding="utf8") as f:
            text = f.read()
        self.assertIn("HOUSEKEEPING drain_ore skipped", text)
        self.assertEqual(ctx._raw.commands, [])


if __name__ == "__main__":
    unittest.main()
