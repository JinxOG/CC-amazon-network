"""W3 card GPS 3 release A (the fuel journal, checked at boot; the check-only commit or later), layer 2. Pin the fleet
first (`run.py pin <run-id> <sha>`). The three-sector job's miner is shut down by the game three times while it works
(`computercraft shutdown`, which can land mid-move) and turned back on. After each, it measures its facing as before and
logs the journal check: it must agree -- never "JOURNAL DISAGREES WITH GPS" and never "JOURNAL FACING DIFFERS" (no one
turned it). The job must still complete. 1x. The job-time cost is measured separately: three_sectors.py at 1x, once
pinned to bfc2770 (1.9.151, no journal) and once to this commit; the ruling allows at most 2% longer."""
NAME = "w3_gps3_journal"


def steps(ctx):
    ctx.wait_registered(14, 300)
    ctx.dispatch("ORDER_MINE", {"x1": 1920, "z1": -2624, "x2": 1984, "z2": -2624, "minerCount": 2})
    went = ctx.wait_until(lambda: ctx.log_lines("Dispatched job_"), 600)
    ctx.expect(bool(went), "the job was dispatched")
    if not went:
        return
    node = went[0].split("-> ")[1].split()[0]
    cid = int(node.replace("node_", ""))
    ctx.note("miner %s (computer #%d)" % (node, cid))

    for i in range(3):
        mined = ctx.wait_until(lambda: len([l for l in ctx.log_lines("Sector (") if "done by" in l]) >= i + 1, 3 * 3600)
        if not mined:
            ctx.note("no sector %d finished; stopping the cuts" % (i + 1))
            break
        ctx.wait_game(40 + 25 * i)                          # somewhere inside the next sector
        before = len(ctx.log_lines("Journal:"))
        ctx.control.shutdown([cid])
        ctx.wait_game(5)
        ctx.control.turn_on([cid])
        said = ctx.wait_until(lambda: len(ctx.log_lines("Journal:")) > before, 300)
        lines = [l for l in ctx.log_lines("Journal:")][before:]
        ctx.note("cut %d: %s" % (i + 1, " | ".join(l[-120:] for l in lines[:3])))
        ctx.expect(bool(said), "cut %d: the turtle said what the journal gave it" % (i + 1))

    done = ctx.wait_until(lambda: ctx.log_lines("Job complete: job_"), 6 * 3600)
    ctx.expect(bool(done), "the job completed")
    agrees = len(ctx.log_lines("Journal: agrees with GPS"))
    ctx.note("agrees %d, 1 block off %d, nothing to check %d" % (
        agrees, len(ctx.log_lines("Journal: 1 block from GPS")), len(ctx.log_lines("Journal: nothing to check"))))
    ctx.expect(agrees >= 1, "at least one cut's journal agreed with GPS and the measured facing (%d)" % agrees)
    ctx.expect(len(ctx.log_lines("JOURNAL FACING DIFFERS")) == 0, "no journal facing differed (nobody turned it)")
    ctx.expect(len(ctx.log_lines("JOURNAL DISAGREES WITH GPS")) == 0, "no journal disagreed with GPS by more than a block")
    ctx.expect(len(ctx.log_lines("Journal write failed")) == 0, "no journal write failed")
