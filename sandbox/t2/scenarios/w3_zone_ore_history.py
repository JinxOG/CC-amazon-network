"""W3 card "Mid-sector ore progress ..." -- the history half (fix 6747a37), layer 2. Same story as
sandbox/scenarios/w3_zone_ore_history.lua. A job mines until /state shows its zone has mined at least 100 ore and a
sector has then finished; the job is cancelled and, once the miner is home, the same ground is ordered again. The new
job's zone is built from the store: after its first scan report its mined ore must still include what was mined before.
On the code before the fix it reads only the new job's scans. Pin a build carrying 6747a37. 1x, ~2 game hours."""
import re

NAME = "w3_zone_ore_history"
ORDER = {"x1": 1920, "z1": -2624, "x2": 1984, "z2": -2624, "minerCount": 1}


def mined(ctx, job):
    z = ((ctx.state() or {}).get("mineZones") or {}).get(job)
    if not isinstance(z, dict) or not isinstance(z.get("oreMined"), dict):
        return None
    return sum(v for v in z["oreMined"].values() if isinstance(v, (int, float)))


def steps(ctx):
    ctx.wait_registered(14, 300)
    ctx.dispatch("ORDER_MINE", ORDER)
    went = ctx.wait_until(lambda: ctx.log_lines("Dispatched job_"), 600)
    ctx.expect(bool(went), "the first job was dispatched")
    if not went:
        return
    job1 = re.search(r"Dispatched (job_\d+)", went[0]).group(1)
    node = went[0].split("-> ")[1].split()[0]
    got = ctx.wait_until(lambda: (mined(ctx, job1) or 0) >= 100, 4 * 3600)
    ctx.expect(bool(got), "the zone mined at least 100 ore (%r)" % mined(ctx, job1))
    if not got:
        ctx.dispatch("CANCEL_JOB", {"jobId": job1})
        return
    d1 = len([l for l in ctx.log_lines("done by") if "Sector (" in l and job1 in l])
    fin = ctx.wait_until(lambda: len([l for l in ctx.log_lines("done by") if "Sector (" in l and job1 in l]) > d1, 3 * 3600)
    ctx.expect(bool(fin), "and then a sector was finished")
    ctx.wait_game(10)
    before = mined(ctx, job1) or 0
    k0 = len([l for l in ctx.log_lines("Docked at bay") if node in l])
    ctx.dispatch("CANCEL_JOB", {"jobId": job1})
    ctx.wait_until(lambda: len([l for l in ctx.log_lines("Docked at bay") if node in l]) > k0, 1800)
    ctx.wait_game(30)
    n0 = len(ctx.log_lines("Dispatched job_"))
    ctx.dispatch("ORDER_MINE", ORDER)                                    # THE TEST: the same ground again
    again = ctx.wait_until(lambda: ctx.log_lines("Dispatched job_")[n0:], 1800)
    ctx.expect(bool(again), "the second job was dispatched")
    if not again:
        return
    job2 = re.search(r"Dispatched (job_\d+)", again[0]).group(1)
    scanned = ctx.wait_until(lambda: [l for l in ctx.log_lines("scan by") if job2 in l], 3 * 3600)
    ctx.expect(bool(scanned), "the second job reported a scan")
    ctx.wait_game(10)
    after = mined(ctx, job2)
    ctx.note("mined before the cancel %r; after the new job's first scan %r" % (before, after))
    ctx.expect(after is not None and after >= before,
               "the zone's mined ore after the new job's first scan (%r) still includes the %r mined before" % (after, before))
    ctx.dispatch("CANCEL_JOB", {"jobId": job2})
