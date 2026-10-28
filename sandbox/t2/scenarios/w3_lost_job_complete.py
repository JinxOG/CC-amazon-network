"""W3 card "A miner that reconnects after its last sector goes home without closing the job", layer 2 with T2's channel
filter, as ruled 2026-10-26. Same story as sandbox/scenarios/w3_lost_job_complete.lua. T2's radio loss cannot pick a
message type, but a miner sends JOB_COMPLETE about 10 game seconds after it docks (it refuels first), so the miner's
position is polled and the moment it is at its dock everything to the dispatch computer on channel 1 is lost for 30 s:
the JOB_COMPLETE goes with it -- the 2026-09-15 job_0052 shape (a disconnect eating the completion). The turtle must log
'JOB_COMPLETE sent for job_X'; the server must catch it ('Idle-stuck MINE job job_X ... IN_PROGRESS') and close the job
('Job complete: job_X') within 15 minutes. The sector (1984,-2624) held no ore in the earlier runs, so the job is short.
If the completion arrives anyway (a 'Job complete' within a minute of the send) the run is INCONCLUSIVE: re-run.
Pin any build from 1.9.12x on. 1x, ~30 game minutes."""
import datetime
import re
import time

NAME = "w3_lost_job_complete"


def server_computer(ctx):
    lines = ctx.log_lines("Central server online")
    if not lines:
        return None
    try:
        return int(lines[-1].rsplit("node_", 1)[1].split()[0])
    except (IndexError, ValueError):
        return None


def ts(line):
    return datetime.datetime.strptime(line[:23], "%Y-%m-%dT%H:%M:%S.%f")


def steps(ctx):
    ctx.wait_registered(14, 300)
    c = ctx.control
    sid = server_computer(ctx)
    ctx.expect(sid is not None, "found the dispatch computer (#%s)" % sid)
    if sid is None:
        return
    ctx.dispatch("ORDER_MINE", {"x1": 1984, "z1": -2624, "x2": 1984, "z2": -2624, "minerCount": 1})
    went = ctx.wait_until(lambda: ctx.log_lines("Dispatched job_"), 600)
    ctx.expect(bool(went), "the job was dispatched")
    if not went:
        return
    job = re.search(r"Dispatched (job_\d+)", went[0]).group(1)
    node = went[0].split("-> ")[1].split()[0]
    cid = int(node.replace("node_", ""))
    docks = [l for l in ctx.log_lines("Assigned dock:") if node in l]
    m = re.search(r"\((-?\d+),(-?\d+),(-?\d+)\)", docks[-1]) if docks else None
    ctx.expect(m is not None, "%s's dock is known" % node)
    if not m:
        return
    dock = tuple(int(v) for v in m.groups())
    home = ctx.wait_until(lambda: [l for l in ctx.log_lines("MINE_COMPLETE") if node in l or job in l], 3 * 3600)
    ctx.expect(bool(home), "the zone was finished and %s sent home (MINE_COMPLETE)" % node)
    if not home:
        return
    # Poll its position until it stands on its dock, then cut the radio to the server for 30 s.
    deadline = time.time() + 1800
    at_dock = False
    while time.time() < deadline:
        pos = (c.computers().get(cid) or {}).get("pos")
        if pos and tuple(pos) == dock:
            at_dock = True
            break
        time.sleep(0.5)
    ctx.expect(at_dock, "%s reached its dock %s" % (node, dock))
    if not at_dock:
        return
    c.radio_loss(0, 30000, 1, channel=1, to=sid)                         # THE TEST
    ctx.note("%s on its dock; 30 s with nothing reaching the server" % node)
    sent = ctx.wait_until(lambda: [l for l in ctx.log_lines("JOB_COMPLETE sent for " + job) if node in l], 300)
    ctx.expect(bool(sent), "%s logged 'JOB_COMPLETE sent for %s'" % (node, job))
    if not sent:
        return
    t_sent = ts(sent[0])
    ctx.wait_game(60)
    early = [l for l in ctx.log_lines("Job complete: " + job) if ts(l) <= t_sent + datetime.timedelta(seconds=60)]
    ctx.expect(not early, "the completion was lost (INCONCLUSIVE if 'Job complete' came within a minute: re-run)")
    closed = ctx.wait_until(lambda: ctx.log_lines("Job complete: " + job), 30 * 60)
    stuck = [l for l in ctx.log_lines("Idle-stuck MINE job " + job)]
    ctx.expect(bool(stuck), "the idle-stuck watchdog caught it (%s)" % (stuck[0][-110:] if stuck else "none"))
    mins = (ts(closed[0]) - t_sent).total_seconds() / 60 if closed else None
    ctx.note("closed %s min after the lost JOB_COMPLETE" % ("%.1f" % mins if mins is not None else "never"))
    ctx.expect(bool(closed) and mins <= 15, "%s was closed within 15 minutes (%s)" % (job, "%.1f min" % mins if mins else "never"))
