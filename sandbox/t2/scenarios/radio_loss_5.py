"""The T2 version of the simulator's radio_loss_5.lua: 5% of the radio messages that would reach a program are lost for the whole job.
Same verb, same arguments (`radio_loss(t, dur, rate)`, times in game ms). The job is the three-sector calibration job (the
simulator's version orders its synthetic world's first area). Compare its report with three_sectors at the same speed."""
NAME = "radio_loss_5"


def steps(ctx):
    ctx.control.radio_loss(0, 12 * 3600 * 1000, 0.05)
    ctx.dispatch("ORDER_MINE", {"x1": 1920, "z1": -2624, "x2": 1984, "z2": -2624, "minerCount": 2})
    done = ctx.wait_until(lambda: ctx.log_lines("Job complete: job_"), 10 * 3600)
    ctx.expect(done, "the job completes within 10 game hours with 5% radio loss")
    sectors = [l for l in ctx.log_lines("Sector (") if "done by" in l and "ore mined" in l]
    ctx.expect(len(sectors) >= 3, "at least 3 sector 'done' lines logged (%d)" % len(sectors))
