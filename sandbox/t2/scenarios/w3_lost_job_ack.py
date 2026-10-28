"""W3 card "A lost JOB_ACK costs the whole job, and it is recorded as complete" (fix 606de4a, live since 1.9.103), layer 2.
Same idea as sandbox/scenarios/w3_lost_job_ack.lua. T2's radio loss filters by receiver, not by message type, so every
message to the dispatch computer on channel 1 is lost for 3 game seconds, starting as the order is sent; the miner's
JOB_ACK (sent within a second of its assignment) is lost, and the server allows 10 s.
Revised 2026-10-28 (W3), after w3-lost-job-ack-b: the loss was 8 s. The order reached the server 1.2 s into it, so the
JOB_ACK, the STATUS_UPDATE and the next heartbeat (+5.9 s) were all lost, and the heartbeat after that came 7.2 s later
(jitter is +/-40%), past the 10 s deadline: the server was right to time it out; the test, not the code, was wrong.
With 3 s the window after the loss is about 8 s, longer than the widest heartbeat gap. That run also passed "carried on
to its first sector" while the miner was in fact recalled: it logged 'phase: RETURNING' in the same second. So the
miner must now also not be recalled and not return within a minute of its first sector. Its next heartbeat names the job:
the server must log "accepted on that evidence", log no "ACK timeout", and the job must stay open (the miner reaches its
first sector; no "Job complete"). If the ACK slipped through (neither line appears) the run is INCONCLUSIVE, not a pass:
re-run it. Pin bfc2770 (the live commit). 1x, ~15 game minutes; the job is cancelled at the end."""
import os
import re

NAME = "w3_lost_job_ack"


def server_computer(ctx):
    """The id of the RUNNING dispatch computer: the last 'Central server online ... ID: node_NNN' line the server itself logged. (A scan of the disks for a
    startup.lua that starts '-- central_server.lua' also finds decoy computers of the world copy, such as #110, and acted on the wrong one.)"""
    lines = ctx.log_lines("Central server online")
    if not lines:
        return None
    try:
        return int(lines[-1].rsplit("node_", 1)[1].split()[0])
    except (IndexError, ValueError):
        return None


def steps(ctx):
    ctx.wait_registered(14, 300)
    sid = server_computer(ctx)
    ctx.expect(sid is not None, "found the dispatch computer (#%s)" % sid)
    if sid is None:
        return
    ctx.control.radio_loss(0, 3000, 1, channel=1, to=sid)                # THE TEST: 3 s with nothing reaching the server
    ctx.dispatch("ORDER_MINE", {"x1": 1920, "z1": -2624, "x2": 1984, "z2": -2624, "minerCount": 2})
    went = ctx.wait_until(lambda: ctx.log_lines("Dispatched job_"), 600)
    ctx.expect(bool(went), "the job was dispatched")
    if not went:
        return
    job = re.search(r"Dispatched (job_\d+)", went[0]).group(1)
    node = went[0].split("-> ")[1].split()[0]
    ctx.wait_game(60)
    accepted = [l for l in ctx.log_lines("accepted on that evidence") if job in l]
    timeout = [l for l in ctx.log_lines("ACK timeout") if job in l]
    ctx.expect(bool(accepted) or bool(timeout),
               "the ACK was really lost (INCONCLUSIVE if neither 'accepted on that evidence' nor 'ACK timeout': re-run)")
    ctx.expect(bool(accepted), "the server accepted %s on the miner's own reports" % job)
    ctx.expect(not timeout, "no ACK timeout for %s" % job)
    sector = ctx.wait_until(lambda: [l for l in ctx.log_lines("Assigned sector (") if node in l], 1800)
    ctx.expect(bool(sector), "%s carried on to its first sector" % node)
    recalled = [l for l in ctx.log_lines("RECALL") if node in l]
    ctx.expect(not recalled, "%s was not recalled (%d RECALL line(s))" % (node, len(recalled)))
    if sector:
        ctx.wait_game(60)
    back = [l for l in ctx.log_lines("phase: RETURNING") if node in l]
    ctx.expect(not back, "%s did not turn for home (%d 'phase: RETURNING' line(s))" % (node, len(back)))
    ctx.expect(not ctx.log_lines("Job complete: %s" % job), "%s was NOT recorded complete" % job)
    ctx.dispatch("CANCEL_JOB", {"jobId": job})
