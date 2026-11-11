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
        with self.assertRaises(ramp.RampFailed):
            ramp.ramp(empty, hold_min=20)

    def test_settling_samples_are_left_out(self):
        # the first quarter of a hold is the server settling into the new rate: a slow start does not fail a step that holds
        ctx = FakeCtx({1: 10.0, 2: 15.0, 3: 30.0, 4: 30.0}, settle={2: 60.0})
        self.assertEqual(ramp.ramp(ctx, hold_min=20), 2)


if __name__ == "__main__":
    unittest.main()
