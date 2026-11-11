"""Shakeout Task 7: the speed ramp (sandbox/t2/shakeout/ramp.py). A fake ctx stands in for the T2 run: its tick samples are the
synthetic mean tick time of whatever speed is set.

    python -I sandbox/tests/test_shakeout_ramp.py
"""
import os
import sys
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "t2"))
from shakeout import ramp  # noqa: E402


class FakeCtx:
    """scenario.Ctx's shape: tickrate(n), wait_real(seconds, poll) appending (real s, game ticks, mean tick ms, tick rate)."""

    def __init__(self, means, settle=None):
        self.means, self.settle = means, settle or {}
        self.samples, self.notes, self.rates = [], [], []
        self.rate, self.clock = 20, 0.0

    def tickrate(self, n):
        self.rate = n
        self.rates.append(n)

    def wait_real(self, seconds, poll=10):
        speed = self.rate / 20.0
        for i in range(int(seconds // poll)):
            self.clock += poll
            early = i < int(seconds // poll) // 4
            ms = self.settle.get(speed) if early and speed in self.settle else self.means[speed]
            self.samples.append((self.clock, 0, ms, self.rate))

    def note(self, text):
        self.notes.append(text)


class RampPicksAndStops(unittest.TestCase):
    def test_ramp_picks_and_stops(self):
        # budgets (80% of 50 ms / speed): 1x 40, 2x 20, 3x 13.3, 4x 10
        ctx = FakeCtx({1: 10.0, 2: 15.0, 3: 14.0, 4: 1.0})
        self.assertEqual(ramp.ramp(ctx, steps=(1, 2, 3, 4), hold_min=20), 2)
        self.assertEqual(ctx.rates, [20, 40, 60, 40], "it stops at the first step that fails (4x never tried) and sets the pick")
        self.assertEqual([s["speed"] for s in ctx.ramp_steps], [1, 2, 3])
        self.assertTrue(all(s["samples"] > 0 for s in ctx.ramp_steps), ctx.ramp_steps)
        self.assertEqual([s["ok"] for s in ctx.ramp_steps], [True, True, False])
        # every step holds hold_min real minutes
        self.assertEqual(ctx.clock, 3 * 20 * 60)
        # all four hold: the highest
        self.assertEqual(ramp.ramp(FakeCtx({1: 5.0, 2: 9.0, 3: 9.5, 4: 9.9}), hold_min=20), 4)
        # "under" 80%: exactly on the line fails
        self.assertEqual(ramp.ramp(FakeCtx({1: 30.0, 2: 20.0, 3: 1.0, 4: 1.0}), hold_min=20), 1)

    def test_one_x_over_40_ms_raises(self):
        ctx = FakeCtx({1: 40.5, 2: 1.0, 3: 1.0, 4: 1.0})
        with self.assertRaises(ramp.RampFailed) as cm:
            ramp.ramp(ctx, hold_min=20)
        self.assertIn("40", str(cm.exception))
        self.assertEqual(ctx.rates[0], 20)
        self.assertNotIn(40, ctx.rates, "nothing faster is tried once 1x fails")
        # no tick samples at all at 1x is not a pass either
        empty = FakeCtx({1: None, 2: 1.0})
        with self.assertRaises(ramp.RampFailed) as cm:
            ramp.ramp(empty, hold_min=20)
        self.assertIn("no tick data read at 1x", str(cm.exception))
        # the message names the step that actually came first
        with self.assertRaises(ramp.RampFailed) as cm:
            ramp.ramp(FakeCtx({2: 30.0, 3: 1.0}), steps=(2, 3), hold_min=20)
        self.assertIn("2x (the first step) does not hold", str(cm.exception))
        self.assertIn("20.00", str(cm.exception))

    def test_settling_samples_are_left_out(self):
        # the first quarter of a hold is the server settling into the new rate: a slow start does not fail a step that holds
        ctx = FakeCtx({1: 10.0, 2: 15.0, 3: 30.0, 4: 30.0}, settle={2: 60.0})
        self.assertEqual(ramp.ramp(ctx, hold_min=20), 2)


class TheRampRunsOnAWorkingFleet(unittest.TestCase):
    """Final review I7: the ramp measured an idle server. on_poll is called at every sample; the shakeout ramp path passes the
    feeder's tick, on the placed fleet."""

    def test_on_poll_is_called_after_every_sample(self):
        ctx = FakeCtx({1: 10.0, 2: 15.0, 3: 30.0, 4: 1.0})
        seen = []
        ramp.ramp(ctx, steps=(1, 2, 3), hold_min=20, on_poll=lambda: seen.append(len(ctx.samples)))
        self.assertEqual(len(seen), len(ctx.samples), "one call per sample")
        self.assertEqual(seen, list(range(1, len(ctx.samples) + 1)), "each straight after its sample")
        self.assertEqual(len(ctx.samples), 3 * 20 * 60 // ramp.POLL_S, "the same samples as without a hook")
        self.assertEqual(ctx.clock, 3 * 20 * 60)

    def test_the_shakeout_ramp_ticks_the_feeder_on_the_placed_fleet(self):
        import importlib.util
        spec = importlib.util.spec_from_file_location("t_shakeout_drv", os.path.join(HERE, "..", "t2", "scenarios", "shakeout.py"))
        drv = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(drv)
        ticks, setups = [], []

        class Feed:
            def tick(self, now):
                ticks.append(now)
        drv._feeder = lambda ctx: (Feed(), None)
        drv.setup = lambda ctx: setups.append(1) or setattr(ctx, "shakeout_fleet", {"placed": {"node_1": {}}})
        ctx = FakeCtx({1: 10.0, 2: 15.0, 3: 30.0, 4: 1.0})
        self.assertEqual(drv.ramp_on_fleet(ctx, steps=(1, 2, 3), hold_min=20), 2)
        self.assertEqual(setups, [1], "the fleet is placed first")
        self.assertEqual(len(ticks), len(ctx.samples), "the feeder ticks at every sample of every hold")
        self.assertGreater(len(ticks), 0)
        ctx2 = FakeCtx({1: 10.0, 2: 50.0})
        ctx2.shakeout_fleet = {"placed": {"node_1": {}}}
        drv.ramp_on_fleet(ctx2, steps=(1, 2), hold_min=1)
        self.assertEqual(setups, [1], "a fleet already placed is not placed again")


if __name__ == "__main__":
    unittest.main()
