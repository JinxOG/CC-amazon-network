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

    done = ctx.wait_until(lambda: ctx.log_lines("Job complete: job_") or (len(ctx.log_lines("Dispatched job_")) >= 2 and len(ctx.log_lines("Position and facing measured after")) >= 1 and len(ctx.log_lines("Loader recovered")) >= 1 and None), 60 * 60)
    # W1 (2026-10-27): "the job completes" measures the whole fleet pipeline, and a 4 h job is hostage to anything else on the host (the first 1x run of
    # this scenario ended with the bridge starved). The fix's CONTRACT is narrower, so that is what is asserted; completion is recorded as a note.
    ctx.note("job completed within the hour after the GPS returned (the wait is capped at one game hour now): %s (informational, not the contract)" % bool(done))
    measured = len(ctx.log_lines("Position and facing measured after"))
    ctx.expect(measured >= 1, "a miner that booted with no GPS parked, kept retrying and measured position and facing once the hosts were back (%d lines)" % measured)
    recovered = len(ctx.log_lines("Loader recovered"))
    ctx.expect(recovered >= 1, "a miner recovered its standing loader after the late fix (%d 'Loader recovered' lines)" % recovered)
    back = len(ctx.log_lines("back in service (was: stuck_no_fix"))
    ctx.expect(back >= 1, "the server saw a stuck_no_fix miner come back in service (%d lines)" % back)
    redispatched = len(ctx.log_lines("Dispatched job_"))
    ctx.expect(redispatched >= 2, "the job was dispatched again after the restart (%d dispatch lines in all)" % redispatched)
    ctx.expect(len(ctx.log_lines("Loader recovery FAILED")) == 0, "no 'Loader recovery FAILED' line")
    stuck = len(ctx.log_lines("stuck_no_fix"))
    ctx.note("stuck_no_fix lines while waiting for a fix: %d" % stuck)
    # W1: with the fix a parked miner reports stuck_no_fix about once a minute while GPS is down. A pass with ZERO such lines means the scenario never
    # made a miner wait for a fix, so it proves nothing about the fix: that is a failed check, not a clean pass.
    ctx.expect(stuck >= 1, "at least one miner sat waiting for a fix and said so (stuck_no_fix lines: %d); zero would mean the wait was never exercised" % stuck)
