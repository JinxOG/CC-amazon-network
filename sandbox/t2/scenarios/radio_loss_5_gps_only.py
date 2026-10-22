"""Separates GPS from the rest of the loss (head engineer, 2026-10-22): the 5% loss applies ONLY to the GPS request channel (65534), so a
locate request reaches each of the four hosts with 95% chance and nothing else on the radio is touched. Same job as radio_loss_5. Run at
1x. If the job still fails the way radio_loss_5 does, GPS is the cause; if it completes, the other lost traffic (acks, beats, orders) is."""
NAME = "radio_loss_5_gps_only"


def steps(ctx):
    ctx.control.radio_loss(0, 12 * 3600 * 1000, 0.05, channel=65534)
    ctx.dispatch("ORDER_MINE", {"x1": 1920, "z1": -2624, "x2": 1984, "z2": -2624, "minerCount": 2})
    done = ctx.wait_until(lambda: ctx.log_lines("Job complete: job_"), 10 * 3600)
    ctx.expect(done, "the job completes within 10 game hours with 5% loss on the GPS channel only")
    sectors = [l for l in ctx.log_lines("Sector (") if "done by" in l and "ore mined" in l]
    ctx.expect(len(sectors) >= 3, "at least 3 sector 'done' lines logged (%d)" % len(sectors))
