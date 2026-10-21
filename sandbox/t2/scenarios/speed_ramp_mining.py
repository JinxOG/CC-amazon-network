"""How fast can the server go with the fleet MINING? The job starts at 2x (survey is light), and once the zone is in its
MINE phase the tick rate is stepped up until the mean tick time passes 80% of the tick budget or the server falls behind
the requested rate. Each step: 20 s to settle, then sampled for STEP_SECONDS real seconds."""
NAME = "speed_ramp_mining"
RATES = [20, 40, 60, 80, 100, 120, 160, 200, 250]
STEP_SECONDS = 150


def steps(ctx):
    ctx.dispatch("ORDER_MINE", {"x1": 1920, "z1": -2624, "x2": 1984, "z2": -2624, "minerCount": 2})
    ctx.tickrate(40)
    started = ctx.wait_until(lambda: ctx.log_lines("starting mine phase"), 3 * 3600)
    ctx.expect(started, "the zone reached its MINE phase")
    ctx.note("MINE phase reached at game time %.0f s" % ctx.game_seconds())
    held = None
    for rate in RATES:
        ctx.tickrate(rate)
        ctx.wait_real(20)
        ctx.samples[:] = [s for s in ctx.samples if s[3] != rate]   # the settle samples do not count
        ctx.wait_real(STEP_SECONDS)
        rows = [s for s in ctx.samples if s[3] == rate]
        if len(rows) < 2:
            break
        dt, dg = rows[-1][0] - rows[0][0], rows[-1][1] - rows[0][1]
        speed = dg / dt
        ms = [r[2] for r in rows if r[2] is not None]
        mean_ms = sum(ms) / len(ms)
        budget = 1000.0 / rate
        ctx.note("rate %d: %.1f ticks/s (%.0f%% of requested), mean tick %.1f ms of a %.1f ms budget (%.0f%%)" % (
            rate, speed, 100 * speed / rate, mean_ms, budget, 100 * mean_ms / budget))
        if speed >= 0.95 * rate and mean_ms <= 0.8 * budget:
            held = rate
        else:
            break
    ctx.expect(held is not None, "the server held at least one stepped rate; highest held under mining: %s (%sx)" % (held, held and held / 20))
    ctx.note("MAX SUSTAINED UNDER MINING: %s ticks/s" % held)
