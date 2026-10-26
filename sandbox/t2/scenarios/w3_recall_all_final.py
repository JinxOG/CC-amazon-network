"""W3 card "Recall-all is undone by a job retry" (fix 3227577, live since 1.9.135), layer 2. Same as
sandbox/scenarios/w3_recall_all_final.lua: once the miner has taken its first sector, a RECALL_ALL is sent, and 3 s later
the miner's own JOB_FAILED for that job arrives with a recoverable reason (placement_blocked) -- the live race of
2026-10-08 08:39, sent by a spawned computer speaking as the miner. The recall-all must cancel the job for good: no
retry and no re-dispatch in the next 25 minutes, and the miner docks. Pin bfc2770 (the live commit). 1x, ~45 game min."""
import os
import re

NAME = "w3_recall_all_final"
HERE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def steps(ctx):
    ctx.wait_registered(14, 300)
    ctx.dispatch("ORDER_MINE", {"x1": 1920, "z1": -2624, "x2": 1984, "z2": -2624, "minerCount": 2})
    went = ctx.wait_until(lambda: ctx.log_lines("Dispatched job_"), 600)
    ctx.expect(bool(went), "the job was dispatched")
    if not went:
        return
    miner = went[0].split("-> ")[1].split()[0]
    job = re.search(r"Dispatched (job_\d+)", went[0]).group(1)
    took = ctx.wait_until(lambda: [l for l in ctx.log_lines("Assigned sector (") if miner in l], 3600)
    ctx.expect(bool(took), "%s took its first sector" % miner)
    if not took:
        return
    ctx.wait_game(60)
    disp0 = len([l for l in ctx.log_lines("Dispatched %s" % job)])
    retry0 = len([l for l in ctx.log_lines(" retry ") if job in l])
    ctx.dispatch("RECALL_ALL", {"reason": "w3_recall_all_final"})        # THE TEST
    ctx.wait_game(3)
    msg = ('{type="JOB_FAILED",from="%s",to="server",seq=990001,ts=0,'
           'payload={jobId="%s",reason="placement_blocked",recoverable=true}}' % (miner, job))
    x, y, z = ctx.control.free_spot()
    cid = ctx.control.spawn_computer(x, y, z, os.path.join(HERE, "lua", "w3_say.lua"), files={"say.txt": "1\n1\n%s\n" % msg})
    ctx.note("computer #%d sent %s's JOB_FAILED placement_blocked for %s after the recall-all" % (cid, miner, job))

    ctx.expect(bool(ctx.wait_until(lambda: ctx.log_lines("Recall-all cancelled"), 60)), "the server cancelled the unfinished job")
    docked = ctx.wait_until(lambda: [l for l in ctx.log_lines("Docked at bay") if miner in l], 3600)
    ctx.expect(bool(docked), "%s docked" % miner)
    ctx.wait_game(25 * 60)
    again = len([l for l in ctx.log_lines("Dispatched %s" % job)]) - disp0
    retried = len([l for l in ctx.log_lines(" retry ") if job in l]) - retry0
    ctx.expect(again == 0, "%s was not dispatched again after the recall-all (%d)" % (job, again))
    ctx.expect(retried == 0, "%s was not retried after the recall-all (%d)" % (job, retried))
    ctx.control.shutdown([cid])
