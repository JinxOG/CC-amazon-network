"""W1 (late-GPS stranding, fixed as 1.9.152 = 119bdfa), layer 2: the 10-05 incident on real Minecraft at 1x. The whole world restarts 45 game minutes
into a mining job and the GPS hosts come back ten minutes late. Same story as sandbox/scenarios/world_restart_gps_late.lua. Pin the fleet to
119bdfa (or later) first. Before the fix a field miner whose hosts came back late stranded for good (the boot loop gave up after six tries and
skipped the loader recovery); after it the miner parks, shouts (stuck_no_fix), recovers its loader on either path and the job completes.

How the hosts are made late: they are shut down just before the clean stop, so the saved world has them off, and they are switched on ten game
minutes after the server is back."""
NAME = "world_restart_gps_late"


def steps(ctx):
    ctx.wait_registered(14, 300)
    ctx.dispatch("ORDER_MINE", {"x1": 1920, "z1": -2624, "x2": 1984, "z2": -2624, "minerCount": 2})
    went = ctx.wait_until(lambda: ctx.log_lines("Dispatched job_"), 600)
    ctx.expect(bool(went), "the job was dispatched")
    if not went:
        return
    ctx.wait_game(45 * 60)
    placed = len(ctx.log_lines("Loader placed"))
    ctx.note("loaders placed so far: %d" % placed)

    hosts = ctx.control.gps_down()
    ctx.note("GPS hosts shut down: %r" % hosts)
    ctx.wait_game(10)
    ctx.control.world_restart()
    ctx.note("world restarted (clean stop and start on the same folder)")
    ctx.wait_registered(10, 900)
    ctx.wait_game(10 * 60)                                  # the hosts are ten minutes late
    ctx.control.gps_up()
    ctx.note("GPS hosts back on")

    done = ctx.wait_until(lambda: ctx.log_lines("Job complete: job_"), 6 * 3600)
    ctx.expect(bool(done), "the job completed after the late GPS (it never completed before the fix)")
    ctx.expect(len(ctx.log_lines("Loader recovery FAILED")) == 0, "no 'Loader recovery FAILED' line")
    stuck = len(ctx.log_lines("stuck_no_fix"))
    ctx.note("stuck_no_fix lines while waiting for a fix: %d" % stuck)
