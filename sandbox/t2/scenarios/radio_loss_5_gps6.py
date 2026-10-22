"""Card 'GPS 1' (head engineer, 2026-10-22): the 5% radio-loss job again, but with SIX GPS hosts instead of four. Two extra host computers are
placed beside the base's four (same chunk, which the loaders hold), not on one plane with them, before the fault starts and before the job
is ordered. Run it at 1x (no --tickrate) and compare with radio_loss_5 at 1x: does the job complete, and how many "GPS locate failed"
lines are there?"""
import os
import tempfile

NAME = "radio_loss_5_gps6"

# the base's four hosts are at (322,92,-2814), (322,92,-2809), (327,92,-2814), (322,96,-2814); the two new ones are on the far side and
# above, so the six are not all on one plane. Each host's computer needs the block above it free for its wireless modem.
CANDIDATES = [(330, 92, -2809), (330, 100, -2814), (326, 98, -2806), (318, 98, -2811), (330, 96, -2806), (318, 92, -2806)]


def free(ctx, x, y, z):
    return all("Test passed" in ctx._raw.command("execute if block %d %d %d air" % (x, y + k, z)) for k in (0, 1))


def steps(ctx):
    hosts = [h for h in CANDIDATES if free(ctx, *h)][:2]
    ctx.expect(len(hosts) == 2, "two free spots for the extra GPS hosts found (%s)" % hosts)
    before = len(ctx._raw.gps_hosts())
    for (x, y, z) in hosts:
        text = 'shell.run("gps", "host", %d, %d, %d)\n' % (x, y + 1, z)      # the modem sits one block above the computer
        path = os.path.join(tempfile.mkdtemp(prefix="gps_host_"), "gps_host.lua")
        with open(path, "w") as f:
            f.write(text)
        ctx._raw.spawn_computer(x, y, z, path)
        ctx.note("extra GPS host placed at %d,%d,%d (modem at y+1)" % (x, y, z))
    ctx.expect(len(ctx._raw.gps_hosts()) == before + 2, "the server now has %d GPS hosts (was %d)" % (len(ctx._raw.gps_hosts()), before))
    ctx.control.radio_loss(0, 12 * 3600 * 1000, 0.05)
    ctx.dispatch("ORDER_MINE", {"x1": 1920, "z1": -2624, "x2": 1984, "z2": -2624, "minerCount": 2})
    done = ctx.wait_until(lambda: ctx.log_lines("Job complete: job_"), 10 * 3600)
    ctx.expect(done, "the job completes within 10 game hours with 5% radio loss and six GPS hosts")
    sectors = [l for l in ctx.log_lines("Sector (") if "done by" in l and "ore mined" in l]
    ctx.expect(len(sectors) >= 3, "at least 3 sector 'done' lines logged (%d)" % len(sectors))
