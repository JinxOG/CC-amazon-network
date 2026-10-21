"""three_sectors with CC's own execution tracking on: `/computercraft track` counts the main-thread tasks (turtle commands
and peripheral calls) each computer runs. The dump at the end is saved to <run>/track.txt and into the report notes, to
compare with the simulator's per-function call counts (real_world_phases.lua)."""
import os

NAME = "three_sectors_tracked"


def steps(ctx):
    ctx._raw.command("computercraft track start")
    ctx.dispatch("ORDER_MINE", {"x1": 1920, "z1": -2624, "x2": 1984, "z2": -2624, "minerCount": 2})
    done = ctx.wait_until(lambda: ctx.log_lines("Job complete: job_"), 6 * 3600)
    ctx.expect(done, "the job completed within 6 game hours")
    dump = ctx._raw.command("computercraft track dump")
    with open(os.path.join(ctx.run, "track.txt"), "w") as f:
        f.write(dump)
    ctx.note("computercraft track dump saved (%d lines)" % len(dump.splitlines()))
    for line in dump.splitlines()[:12]:
        ctx.note(line)
