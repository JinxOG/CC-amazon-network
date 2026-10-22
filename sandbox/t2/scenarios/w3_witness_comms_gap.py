"""W3 card "Turtles say how they lost the server" (the unreachable-warning witness, 1.9.106 and later), layer 2, case A only.
Same as case A of sandbox/scenarios/w3_witness_comms_gap.lua: the DISPATCH computer is shut down for 3 minutes the moment a
miner starts a loader swap. The modem is off for about a second, so by the time the miner misses its acks its radio is
back: the miner's "Server unreachable" warning must say "radio on and loop turning". Case B (one miner's modem pulled out)
cannot be staged here -- peripheral fail acts on every computer's modems at once -- and stays a layer-1 result.
Pin any commit at or after 1.9.106. 1x."""
import os
import re

NAME = "w3_witness_comms_gap"


def server_computer(control):
    """The dispatch computer: its startup.lua is central_server.lua, whose first line names it. Not a phrase search."""
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
    ctx.dispatch("ORDER_MINE", {"x1": 1920, "z1": -2624, "x2": 1984, "z2": -2624, "minerCount": 2})
    hit = ctx.wait_until(lambda: len(ctx.log_lines("phase: RETRIEVING (comms gap expected)")) >= 2, 6 * 3600)
    ctx.expect(bool(hit), "a miner started a loader swap")
    if not hit:
        return
    miner = re.search(r"(node_\d+) phase", ctx.log_lines("phase: RETRIEVING (comms gap expected)")[1]).group(1)
    before = len([l for l in ctx.log_lines("Server unreachable") if miner in l])
    ctx.control.shutdown([sid])
    ctx.wait_game(180)
    ctx.control.turn_on([sid])
    ctx.wait_game(420)
    warn = [l for l in ctx.log_lines("Server unreachable") if miner in l][before:]
    ctx.note("verdicts: %s" % (" | ".join(w[-200:] for w in warn[:3]) or "none"))
    ctx.expect(len(warn) >= 1, "%s reported losing the server (%d)" % (miner, len(warn)))
    ctx.expect(len(warn) >= 1 and "radio on and loop turning" in warn[0],
               "the verdict is 'radio on and loop turning' -- the radio was back before the acks were missed")
    done = ctx.wait_until(lambda: ctx.log_lines("Job complete: job_"), 6 * 3600)
    ctx.expect(bool(done), "the job completed")
