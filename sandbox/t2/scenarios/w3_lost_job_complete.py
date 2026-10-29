"""W3 card "A miner that reconnects after its last sector goes home without closing the job", layer 2 with T2's channel
filter, as ruled 2026-10-26. Same story as sandbox/scenarios/w3_lost_job_complete.lua. T2's radio loss cannot pick a
message type, but a miner sends JOB_COMPLETE about 10 game seconds after it docks (it refuels first), so the miner's
position is polled and the moment it is at its dock everything to the dispatch computer on channel 1 is lost for 30 s:
the JOB_COMPLETE goes with it -- the 2026-09-15 job_0052 shape (a disconnect eating the completion). The turtle must log
'JOB_COMPLETE sent for job_X'; the server must catch it ('Idle-stuck MINE job job_X ... IN_PROGRESS') and close the job
('Job complete: job_X') within 15 minutes. The sector (1984,-2624) held no ore in the earlier runs, so the job is short.
If the completion arrives anyway (a 'Job complete' within a minute of the send) the run is INCONCLUSIVE: re-run.
Pin any build from 1.9.12x on. 1x, ~30 game minutes.
Revised 2026-10-28 (W3), after w3-lost-job-complete: the miner came home with its tank above 80 %, skipped the dock
refuel and sent JOB_COMPLETE the moment it docked, before the loss began -- the job closed normally; the loss then ate
its log batch instead. Now its fuel is set to 50,000 as it turns for home, so it refuels at the dock (~10 s) and the
JOB_COMPLETE goes out inside the loss. And the evidence that it was lost is T2's own radio log (t2control/radio.jsonl,
outcome "lost"), not the turtle's 'JOB_COMPLETE sent' line, which travels on the same channel and can be lost with it."""
import datetime
import json
import os
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
    # Below 80 %: it refuels at the dock, so JOB_COMPLETE comes ~10 s after it docks. Retried: the turtle is moving.
    low = False
    for _ in range(40):
        try:
            c.set_fuel(cid, 50000)
            if (c.get_fuel(cid) or 100000) <= 60000:
                low = True
                break
        except Exception:
            pass
        time.sleep(0.3)
    ctx.expect(low, "%s's fuel set to 50,000 so it refuels at its dock (INCONCLUSIVE otherwise)" % node)
    if not low:
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
    radio = os.path.join(c.run, "t2control", "radio.jsonl")

    def completes():
        out = []
        with open(radio, encoding="utf-8", errors="replace") as f:
            for line in f:
                if "JOB_COMPLETE" in line and job in line and ('"%d_' % cid) in line:
                    d = json.loads(line)
                    if d.get("to") == sid:
                        out.append(d)
        return out

    sent = ctx.wait_until(lambda: completes() or None, 300)
    ctx.expect(bool(sent), "%s transmitted JOB_COMPLETE for %s (T2 radio log)" % (node, job))
    if not sent:
        return
    first = sent[0]
    ctx.note("first JOB_COMPLETE to the server: tick %s, outcome %s" % (first.get("tick"), first.get("outcome")))
    ctx.expect(first.get("outcome") == "lost",
               "it was lost in the loss (INCONCLUSIVE if delivered: re-run) -- outcome %r" % first.get("outcome"))
    if first.get("outcome") != "lost":
        return
    t_sent = datetime.datetime.utcfromtimestamp(first["utc"] / 1000.0)
    ctx.wait_game(60)
    early = [l for l in ctx.log_lines("Job complete: " + job) if ts(l) <= t_sent + datetime.timedelta(seconds=60)]
    ctx.expect(not early, "the server did not close it then")
    closed = ctx.wait_until(lambda: ctx.log_lines("Job complete: " + job), 30 * 60)
    # Two recoveries are possible and both are the server's: the idle-stuck watchdog, or -- when the loss makes the
    # turtle re-register, as in w3-lost-job-complete-b -- the re-send of the still-open job, which the turtle runs
    # to an immediate MINE_COMPLETE and docks again (a wasted trip out of the depot). Either is a recovery; which one is noted.
    stuck = [l for l in ctx.log_lines("Idle-stuck MINE job " + job)]
    resent = [l for l in ctx.log_lines("Re-sent job " + job)]
    ctx.note("recovered by: %s" % ("the idle-stuck watchdog" if stuck else ("the re-send after re-registering" if resent else "neither seen")))
    ctx.expect(bool(stuck) or bool(resent), "the server recovered it (idle-stuck watchdog or re-send after re-registering)")
    mins = (ts(closed[0]) - t_sent).total_seconds() / 60 if closed else None
    ctx.note("closed %s min after the lost JOB_COMPLETE" % ("%.1f" % mins if mins is not None else "never"))
    ctx.expect(bool(closed) and mins <= 15, "%s was closed within 15 minutes (%s)" % (job, "%.1f min" % mins if mins else "never"))
