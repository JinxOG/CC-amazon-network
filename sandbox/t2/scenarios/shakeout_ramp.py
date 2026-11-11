"""Shakeout plan Task 8 Step 2: the SPEED RAMP on T2, on the placed fleet with the feeder running. T2 only; NOT RUN YET.

    python sandbox/t2/scenario.py sandbox/t2/scenarios/shakeout_ramp.py --pin <sha>      (setup, then 4 x 20 real minutes)

shakeout.setup(ctx) builds the world and places the 160 turtles; then shakeout.ramp_on_fleet holds 1x, 2x, 3x, 4x for
SHAKEOUT_RAMP_HOLD_MIN real minutes each (default 20) while Feeder.tick runs at every tick sample, so every hold is measured with
the whole fleet working -- not on an idle server (final review I7). The chosen speed is in the notes and ctx.ramp_steps; a
RampFailed (even 1x does not hold) ends the run with that error: stop and tell the user.
"""
import importlib.util
import os

NAME = "shakeout_ramp"

_spec = importlib.util.spec_from_file_location("shakeout_driver", os.path.join(os.path.dirname(os.path.abspath(__file__)), "shakeout.py"))
drv = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(drv)


def steps(ctx):
    speed = drv.ramp_on_fleet(ctx)
    ctx.note("shakeout ramp: chosen speed %sx -- run the 24-hour test with --tickrate %d" % (speed, int(round(20 * speed))))
    ctx.expect(speed is not None, "the ramp chose a speed (%s) with the placed fleet working" % speed)
