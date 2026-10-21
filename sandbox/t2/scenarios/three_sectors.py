"""The three-sector job of the calibration (order 1920,-2624 to 1984,-2624; the server gives it one miner), run to the end.
The tick rate comes from --tickrate (20 = real time). Compared with the simulator's real_world_three_sectors by
sandbox/t2/compare.py."""
NAME = "three_sectors"


def steps(ctx):
    ctx.dispatch("ORDER_MINE", {"x1": 1920, "z1": -2624, "x2": 1984, "z2": -2624, "minerCount": 2})
    done = ctx.wait_until(lambda: ctx.log_lines("Job complete: job_"), 6 * 3600)
    ctx.expect(done, "the job completed within 6 game hours")
    ctx.expect(len(ctx.log_lines("Dispatched job_")) >= 1, "a job was dispatched")
    sectors = [l for l in ctx.log_lines("Sector (") if "done by" in l and "ore mined" in l]
    ctx.expect(len(sectors) >= 3, "at least 3 sector 'done' lines logged (%d)" % len(sectors))
