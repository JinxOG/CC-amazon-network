"""W3 card "A lost JOB_ACK costs the whole job, and it is recorded as complete" (fix 606de4a, live since 1.9.103), layer 2.
Same idea as sandbox/scenarios/w3_lost_job_ack.lua. T2's radio loss filters by receiver, not by message type, so every
message to the dispatch computer on channel 1 is lost for 8 game seconds, starting as the order is sent; the miner's
JOB_ACK (sent within a second of its assignment) is lost, and the server allows 10 s. Its next heartbeat names the job:
the server must log "accepted on that evidence", log no "ACK timeout", and the job must stay open (the miner reaches its
first sector; no "Job complete"). If the ACK slipped through (neither line appears) the run is INCONCLUSIVE, not a pass:
re-run it. Pin bfc2770 (the live commit). 1x, ~15 game minutes; the job is cancelled at the end."""
import os
import re

NAME = "w3_lost_job_ack"


def server_computer(control):
    for d in os.listdir(control.disks):
        try:
            head = control.read_disk(int(d), "startup.lua")[:60].decode("utf8", "replace")
        except (OSError, ValueError):
            continue
        if head.startswith("-- central_server.lua"):
            return int(d)
    return None


def steps(ctx):
    ctx.wait_registered(14, 300)
    sid = server_computer(ctx.control)
    ctx.expect(sid is not None, "found the dispatch computer (#%s)" % sid)
    if sid is None:
        return
    ctx.control.radio_loss(0, 8000, 1, channel=1, to=sid)                # THE TEST: 8 s with nothing reaching the server
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
    ctx.expect(not ctx.log_lines("Job complete: %s" % job), "%s was NOT recorded complete" % job)
    ctx.dispatch("CANCEL_JOB", {"jobId": job})
