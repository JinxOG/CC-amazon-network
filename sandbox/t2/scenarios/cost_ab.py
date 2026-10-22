"""Cost of the control mod's logs: alternating windows of the same job at 10x with the radio and event logs off and on.
Four windows of 150 real seconds each (off, on, off, on); the mean tick time of each is in the notes."""
NAME = "cost_ab"


def steps(ctx):
    ctx.dispatch("ORDER_MINE", {"x1": 1920, "z1": -2624, "x2": 1984, "z2": -2624, "minerCount": 2})
    ctx.tickrate(200)
    ctx.wait_real(120)                      # the survey: settle
    means = []
    for state in ("off", "on", "off", "on"):
        ctx._raw.radio_log(state)
        ctx._raw.events_log(state)
        ctx.wait_real(20)
        before = len(ctx.samples)
        ctx.wait_real(150)
        ms = [s[2] for s in ctx.samples[before:] if s[2] is not None]
        mean = sum(ms) / len(ms)
        means.append((state, mean))
        ctx.note("window logs %s: mean tick %.2f ms over %d samples" % (state, mean, len(ms)))
    off = [m for s, m in means if s == "off"]
    on = [m for s, m in means if s == "on"]
    diff = 100 * (sum(on) / len(on) - sum(off) / len(off)) / (sum(off) / len(off))
    ctx.note("logs on against logs off: %+.1f%% (bar 5%%)" % diff)
    ctx.expect(abs(diff) <= 5.0, "mean tick time with both logs on is within 5%% of off (%+.1f%%)" % diff)
