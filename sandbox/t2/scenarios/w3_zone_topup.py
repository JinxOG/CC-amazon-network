"""W3 card "A zone left short of miners tops itself back up" (fix 4c27f64, live since 1.9.121), layer 2. Same as
sandbox/scenarios/w3_zone_topup.lua. A two-miner zone is needed: the six-sector order below gives two jobs on one zone
(sharedZoneKey). Once both miners have a sector, one of them is made to report its job complete early -- a JOB_COMPLETE
sent as that miner by a spawned computer (sandbox/t2/lua/w3_say.lua), the outcome seen on 2026-09-29. The server must log
'... K of M miner(s) on it' and 'Auto-respawn' (a replacement queued). Pin bfc2770 (the live commit). 1x, ~40 game
minutes; the jobs are cancelled at the end. SANDBOX: if this order does not give two jobs on one zone, widen x2."""
import os
import re

NAME = "w3_zone_topup"
HERE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def steps(ctx):
    ctx.wait_registered(14, 300)
    ctx.dispatch("ORDER_MINE", {"x1": 1920, "z1": -2656, "x2": 1984, "z2": -2624, "minerCount": 2})
    two = ctx.wait_until(lambda: len(ctx.log_lines("Dispatched job_")) >= 2, 900)
    ctx.expect(bool(two), "two jobs were dispatched for the zone")
    if not two:
        return
    lines = ctx.log_lines("Dispatched job_")
    nodes = [l.split("-> ")[1].split()[0] for l in lines[:2]]
    jobs = [re.search(r"Dispatched (job_\d+)", l).group(1) for l in lines[:2]]
    working = ctx.wait_until(lambda: all([l for l in ctx.log_lines("Assigned sector (") if n in l] for n in nodes), 3600)
    ctx.expect(bool(working), "both miners have a sector")
    if not working:
        return
    ctx.wait_game(60)
    leaver, job = nodes[1], jobs[1]
    short0 = len(ctx.log_lines("miner(s) on it"))
    respawn0 = len(ctx.log_lines("Auto-respawn"))
    msg = '{type="JOB_COMPLETE",from="%s",to="server",seq=990002,ts=0,payload={jobId="%s",result={}}}' % (leaver, job)
    x, y, z = ctx.control.free_spot()
    cid = ctx.control.spawn_computer(x, y, z, os.path.join(HERE, "lua", "w3_say.lua"), files={"say.txt": "1\n1\n%s\n" % msg})
    ctx.note("computer #%d sent %s's early JOB_COMPLETE for %s" % (cid, leaver, job))      # THE TEST
    topped = ctx.wait_until(lambda: len(ctx.log_lines("Auto-respawn")) > respawn0, 300)
    ctx.expect(len(ctx.log_lines("miner(s) on it")) > short0, "the server saw the zone left short ('K of M miner(s) on it')")
    ctx.expect(bool(topped), "and queued a replacement ('Auto-respawn')")
    ctx.control.shutdown([cid])
    for j in re.findall(r"job_\d+", " ".join(ctx.log_lines("Job queued: job_"))):
        ctx.dispatch("CANCEL_JOB", {"jobId": j})
