"""W3 card "Mid-sector ore progress is only saved when a sector finishes; an outage loses it" (fix 6747a37), layer 2.
Same story as sandbox/scenarios/w3_sector_progress_restart.lua. A one-sector job; once /state shows the zone has mined
at least 100 ore, that figure is taken, 70 game seconds pass (the sectors in flight are written at most once a minute),
and the dispatch computer is shut down and turned on mid-sector. The zone's mined ore in the first /state after it is
back must not be less than before. On the code before the fix it reads what was mined at the sector's assignment.
Also checked: the restart logged 'Restored the ore of the sectors in flight'. Pin a build carrying 6747a37. 1x."""
import re

NAME = "w3_sector_progress_restart"


def server_computer(ctx):
    lines = ctx.log_lines("Central server online")
    if not lines:
        return None
    try:
        return int(lines[-1].rsplit("node_", 1)[1].split()[0])
    except (IndexError, ValueError):
        return None


def mined(ctx, job):
    z = ((ctx.state() or {}).get("mineZones") or {}).get(job)
    if not isinstance(z, dict) or not isinstance(z.get("oreMined"), dict):
        return None
    return sum(v for v in z["oreMined"].values() if isinstance(v, (int, float)))


def steps(ctx):
    ctx.wait_registered(14, 300)
    sid = server_computer(ctx)
    ctx.expect(sid is not None, "found the dispatch computer (#%s)" % sid)
    if sid is None:
        return
    ctx.dispatch("ORDER_MINE", {"x1": 1920, "z1": -2624, "x2": 1920, "z2": -2624, "minerCount": 1})
    went = ctx.wait_until(lambda: ctx.log_lines("Dispatched job_"), 600)
    ctx.expect(bool(went), "the job was dispatched")
    if not went:
        return
    job = re.search(r"Dispatched (job_\d+)", went[0]).group(1)
    got = ctx.wait_until(lambda: (mined(ctx, job) or 0) >= 100, 3 * 3600)
    before = mined(ctx, job)
    ctx.expect(bool(got), "the zone mined at least 100 ore in its sector (%r)" % before)
    if not got:
        ctx.dispatch("CANCEL_JOB", {"jobId": job})
        return
    ctx.wait_game(70)
    n0 = len(ctx.log_lines("Central server online"))
    r0 = len(ctx.log_lines("Restored the ore of the sectors in flight"))
    ctx.control.shutdown([sid])                                         # THE TEST: a restart mid-sector
    ctx.wait_game(3)
    ctx.control.turn_on([sid])
    back = ctx.wait_until(lambda: len(ctx.log_lines("Central server online")) > n0, 300)
    ctx.expect(bool(back), "the dispatch computer came back")
    # The bridge keeps a section the server has not sent again, so the figure is read after a few pushes of the
    # restarted server (every 3 s). A zone it did not restore at all would leave the old figure standing -- the
    # 'Restored the ore' check below is what catches that.
    ctx.wait_game(15)
    after = mined(ctx, job)
    ctx.note("mined before the restart %r, first figure after it %r" % (before, after))
    ctx.expect(after is not None and after >= before,
               "the zone's mined ore after the restart (%r) is not less than before it (%r)" % (after, before))
    restored = len(ctx.log_lines("Restored the ore of the sectors in flight")) - r0
    ctx.expect(restored > 0, "the restart put the sectors in flight back (%d line(s))" % restored)
    ctx.dispatch("CANCEL_JOB", {"jobId": job})
