"""W3 card "A recall is ignored while a turtle is in sky flight" (fix f02be1e, live since 1.9.129; the server log line
needs the next release), layer 2. Same as sandbox/scenarios/w3_recall_in_flight.lua: the job is cancelled 20 s into the
miner's outbound flight. It must turn back within 100 blocks (its distance from its dock is read from /state every 5 s),
place no loader, scan nothing and dock. Pin the commit carrying the log line (see the mail) for the 'recalled in flight'
check; on bfc2770 that one check fails by design and the rest must pass. 1x, ~20 game minutes."""
import re

NAME = "w3_recall_in_flight"


def steps(ctx):
    ctx.wait_registered(14, 300)
    ctx.dispatch("ORDER_MINE", {"x1": 1920, "z1": -2624, "x2": 1984, "z2": -2624, "minerCount": 2})
    went = ctx.wait_until(lambda: ctx.log_lines("Dispatched job_"), 600)
    ctx.expect(bool(went), "the job was dispatched")
    if not went:
        return
    miner = went[0].split("-> ")[1].split()[0]
    job = re.search(r"Dispatched (job_\d+)", went[0]).group(1)
    flying = ctx.wait_until(lambda: [l for l in ctx.log_lines("phase: TRAVELLING") if miner in l], 1200)
    ctx.expect(bool(flying), "%s set off on its outbound flight" % miner)
    if not flying:
        return
    ctx.wait_game(20)

    def away():
        t = (ctx.state().get("turtles") or {}).get(miner) or {}
        return abs((t.get("x") or 0) - (t.get("dockX") or 0)) + abs((t.get("z") or 0) - (t.get("dockZ") or 0))

    placing0 = len([l for l in ctx.log_lines("phase: PLACING_LOADER") if miner in l])
    scanning0 = len([l for l in ctx.log_lines("phase: SCANNING") if miner in l])
    docked0 = len([l for l in ctx.log_lines("Docked at bay") if miner in l])
    at_cancel = away()
    ctx.dispatch("CANCEL_JOB", {"jobId": job})                          # THE TEST
    farthest = at_cancel
    said = False
    for _ in range(int(3600 / 5)):
        farthest = max(farthest, away())
        said = said or bool([l for l in ctx.log_lines("recalled in flight") if miner in l])
        if len([l for l in ctx.log_lines("Docked at bay") if miner in l]) > docked0:
            break
        ctx.wait_game(5)
    ctx.expect(said, "the server logged '%s recalled in flight'" % miner)
    ctx.expect(farthest - at_cancel <= 100, "it turned back within 100 blocks of the recall (flew %d further)" % (farthest - at_cancel))
    ctx.expect(len([l for l in ctx.log_lines("Docked at bay") if miner in l]) > docked0, "%s docked" % miner)
    ctx.expect(len([l for l in ctx.log_lines("phase: PLACING_LOADER") if miner in l]) == placing0, "no loader placed after the recall")
    ctx.expect(len([l for l in ctx.log_lines("phase: SCANNING") if miner in l]) == scanning0, "no scanning after the recall")
