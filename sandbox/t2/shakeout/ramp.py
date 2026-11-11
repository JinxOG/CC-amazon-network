"""Shakeout speed ramp (plan Task 7; spec section 6): before the 24-hour run, find the fastest speed the server holds with the whole
fleet working. T2 ONLY.

    from shakeout import ramp
    speed = ramp.ramp(ctx, steps=(1, 2, 3, 4), hold_min=20)     # raises ramp.RampFailed when even 1x does not hold

Each step sets the tick rate to 20 x speed (ctx.tickrate, the Control tick_rate the scenario runner already uses), holds it for
hold_min REAL minutes while ctx.wait_real samples the server's own figure ("forge tps": "Overall: Mean tick time: N ms", the
"mean tick ms" column of a T2 report.md, sandbox/t2/scenario.py Ctx.sample), and takes the mean of the samples taken at that rate,
the first SETTLE_SHARE of them left out (the server settling into the new rate). A step HOLDS when that mean is under
BUDGET_SHARE (80%) of its tick budget, 50 ms / speed: 40 ms at 1x, 20 at 2x, 13.3 at 3x, 10 at 4x. The ramp climbs until a step
fails and stops there (a faster step is not tried: the server already could not keep up), sets the tick rate to the highest step
that held, and returns that speed. A step with no tick sample does not hold: no evidence is not a pass.
If 1x does not hold, RampFailed: the spec says stop and tell the user, never quietly shrink the fleet.
Every step is in ctx.ramp_steps ({speed, tickrate, budget_ms, limit_ms, mean_ms, samples, ok}) and in a note, evidence included.
"""

TICK_MS = 50.0              # one tick's budget at 1x (20 ticks a second)
BUDGET_SHARE = 0.8          # the spec: mean tick under 80% of its budget
SETTLE_SHARE = 0.25         # the first quarter of a hold is left out


class RampFailed(RuntimeError):
    """Even 1x does not hold with this fleet: stop and tell the user (spec section 6)."""


def limit_ms(speed):
    return BUDGET_SHARE * TICK_MS / float(speed)


def _note(ctx, text):
    if hasattr(ctx, "note"):
        ctx.note(text)


def ramp(ctx, steps=(1, 2, 3, 4), hold_min=20):
    steps = sorted(steps)
    ctx.ramp_steps = []
    chosen = None
    for speed in steps:
        rate = int(round(20 * speed))
        ctx.tickrate(rate)
        first = len(ctx.samples)
        ctx.wait_real(hold_min * 60)
        held = [s for s in ctx.samples[first:] if s[3] == rate]
        settled = held[int(len(held) * SETTLE_SHARE):]
        mss = [s[2] for s in settled if s[2] is not None]
        mean = sum(mss) / len(mss) if mss else None
        lim = limit_ms(speed)
        ok = mean is not None and mean < lim
        step = {"speed": speed, "tickrate": rate, "budget_ms": round(TICK_MS / speed, 2), "limit_ms": round(lim, 2),
                "mean_ms": round(mean, 3) if mean is not None else None, "samples": len(mss), "left_out": len(held) - len(settled),
                "ok": ok}
        ctx.ramp_steps.append(step)
        _note(ctx, "ramp %sx (tick rate %d, %d real min): mean tick %s ms against a limit of %.2f ms (80%% of %.1f ms) -- %s "
                   "(evidence: %d samples, %d settling samples left out)"
              % (speed, rate, hold_min, "%.2f" % mean if mean is not None else "NO SAMPLE", lim, TICK_MS / speed,
                 "holds" if ok else "does NOT hold", len(mss), len(held) - len(settled)))
        if not ok:
            break
        chosen = speed
    if chosen is None:
        s = ctx.ramp_steps[0] if ctx.ramp_steps else {"speed": steps[0] if steps else None, "samples": 0, "mean_ms": None}
        if not s.get("samples"):
            raise RampFailed("no tick data read at %sx (0 'forge tps' samples in %d real min): the speed is unmeasured, not "
                             "too slow -- fix the sampling, then ramp again" % (s.get("speed"), hold_min))
        raise RampFailed("%sx (the first step) does not hold: mean tick %s ms, limit %.2f ms (80%% of %.1f ms), %d samples -- stop "
                         "and tell the user" % (s["speed"], s.get("mean_ms"), limit_ms(s["speed"]), TICK_MS / s["speed"],
                                                s.get("samples", 0)))
    ctx.tickrate(int(round(20 * chosen)))
    _note(ctx, "ramp: chosen speed %sx (the highest step that held)" % chosen)
    return chosen
