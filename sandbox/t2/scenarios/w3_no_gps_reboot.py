"""Two W3 cards, layer 2: "A miner rebooted without a GPS fix flies off blind and is lost" (1.9.132) and "A turtle stuck
before its main loop was invisible" (1.9.137) -- both needing W1's late-GPS fix (119bdfa, 1.9.152) for the recovery half.
Same as sandbox/scenarios/w3_no_gps_reboot.lua: once the miner is at work in its zone, every GPS host is shut down and
the miner's computer is cut and turned back on; GPS returns 6 game minutes later.
Pass: the miner logs 'NOT moving until both are measured', the server raises 'NEEDS HANDS: node_X — stuck_no_fix', the
miner is never pruned, then logs 'Position and facing measured after' once GPS is back and docks.
Pin master at or after 119bdfa (1.9.152; on 1.9.151 the miner strands, which is the failure). 1x, ~60 game minutes."""
import re

NAME = "w3_no_gps_reboot"


def steps(ctx):
    ctx.wait_registered(14, 300)
    ctx.dispatch("ORDER_MINE", {"x1": 1920, "z1": -2624, "x2": 1984, "z2": -2624, "minerCount": 2})
    went = ctx.wait_until(lambda: ctx.log_lines("Dispatched job_"), 600)
    ctx.expect(bool(went), "the job was dispatched")
    if not went:
        return
    node = went[0].split("-> ")[1].split()[0]
    cid = int(node.replace("node_", ""))
    working = ctx.wait_until(lambda: [l for l in ctx.log_lines("Assigned sector (") if node in l], 3600)
    ctx.expect(bool(working), "%s reached its zone" % node)
    if not working:
        return
    ctx.wait_game(180)
    mine = lambda s: [l for l in ctx.log_lines(s) if node in l]
    n0, h0, m0, d0, p0 = (len(mine("NOT moving until both are measured")), len([l for l in mine("NEEDS HANDS") if "stuck_no_fix" in l]),
                          len(mine("Position and facing measured after")), len(mine("Docked at bay")), len(mine("Pruned stale offline turtle")))
    hosts = ctx.control.gps_down()                                         # THE TEST: no GPS ...
    ctx.wait_game(2)
    ctx.control.shutdown([cid])                                            # ... and a reboot in the field
    ctx.wait_game(2)
    ctx.control.turn_on([cid])
    ctx.note("GPS hosts %r down; %s (computer #%d) rebooted in the field" % (hosts, node, cid))
    ctx.wait_game(360)
    ctx.expect(len(mine("NOT moving until both are measured")) > n0, "it said 'NOT moving until both are measured'")
    ctx.expect(len([l for l in mine("NEEDS HANDS") if "stuck_no_fix" in l]) > h0, "the server raised NEEDS HANDS (stuck_no_fix)")
    ctx.control.gps_up()
    back = ctx.wait_until(lambda: len(mine("Position and facing measured after")) > m0, 900)
    ctx.expect(bool(back), "once GPS was back it measured ('Position and facing measured after')")
    home = ctx.wait_until(lambda: len(mine("Docked at bay")) > d0, 3600)
    ctx.expect(bool(home), "and recovered home to its dock")
    ctx.expect(len(mine("Pruned stale offline turtle")) == p0, "it was never pruned as offline")
