"""W3 card "A miner rebooted at its dock ignores the job re-sent to it and idles 8 minutes" (fix b1a96eb, 1.9.144; live on
1.9.151), layer 2. Same as sandbox/scenarios/w3_dock_idle_reboot.lua: the miner is rebooted seconds after it sets off, still
in the depot lane. The server must re-send its job on the miner's first heartbeat, and the miner must set off again
within 3 minutes, with no idle-stuck requeue. Pin any commit at or after 1.9.144 (the live fleet is on bfc2770). 1x."""
NAME = "w3_dock_idle_reboot"


def steps(ctx):
    ctx.wait_registered(14, 300)
    ctx.dispatch("ORDER_MINE", {"x1": 1920, "z1": -2624, "x2": 1984, "z2": -2624, "minerCount": 2})
    went = ctx.wait_until(lambda: ctx.log_lines("Dispatched job_"), 600)
    ctx.expect(bool(went), "the job was dispatched")
    if not went:
        return
    node = went[0].split("-> ")[1].split()[0]
    cid = int(node.replace("node_", ""))
    dep = ctx.wait_until(lambda: [l for l in ctx.log_lines("phase: DEPARTING") if node in l], 600)
    ctx.expect(bool(dep), "%s set off" % node)
    if not dep:
        return
    ctx.wait_game(3)                                    # still in the depot lane
    before = len([l for l in ctx.log_lines("phase: DEPARTING") if node in l])
    ctx.control.shutdown([cid])
    ctx.wait_game(2)
    ctx.control.turn_on([cid])
    t0 = ctx.game_seconds()
    again = ctx.wait_until(lambda: len([l for l in ctx.log_lines("phase: DEPARTING") if node in l]) > before, 900)
    waited = ctx.game_seconds() - t0
    ctx.expect(bool(again), "the rebooted miner set off again on its job")
    ctx.expect(bool(again) and waited < 180, "within 3 minutes of the reboot (%.0f s)" % waited)
    ctx.expect(len(ctx.log_lines("(first heartbeat)")) >= 1, "the server re-sent the job on its first heartbeat")
    ctx.expect(len(ctx.log_lines("Idle-stuck MINE job")) == 0, "no idle-stuck requeue was needed")
    done = ctx.wait_until(lambda: ctx.log_lines("Job complete: job_"), 6 * 3600)
    ctx.expect(bool(done), "the job completed")
