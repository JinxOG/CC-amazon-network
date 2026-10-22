"""W3 card "A requeued zone forgets its re-mine list and closes with ore left" (fix 6aee2ae, 1.9.144; live on 1.9.151),
layer 2. Same as sandbox/scenarios/w3_recheck_reboot.lua: the miner is rebooted right after the zone starts its rescan
pass. The requeued job must keep its rescan zone ("keeps its rescan zone"), never be rebuilt as "0/N sectors remaining",
and every rescan sector must still be rescanned. Pin any commit at or after 1.9.144. 1x; the rescan comes after the whole
three-sector mine pass, so this is a long run."""
import re

NAME = "w3_recheck_reboot"


def steps(ctx):
    ctx.wait_registered(14, 300)
    ctx.dispatch("ORDER_MINE", {"x1": 1920, "z1": -2624, "x2": 1984, "z2": -2624, "minerCount": 2})
    reached = ctx.wait_until(lambda: ctx.log_lines("starting rescan of") and ctx.log_lines("[RESCAN] to node_"), 8 * 3600)
    ctx.expect(bool(reached), "the zone reached its rescan pass")
    if not reached:
        return
    total = int(re.search(r"starting rescan of (\d+)", ctx.log_lines("starting rescan of")[0]).group(1))
    holder = re.search(r"\[RESCAN\] to (node_\d+)", ctx.log_lines("[RESCAN] to node_")[0]).group(1)
    cid = int(holder.replace("node_", ""))
    ctx.wait_game(5)                                    # the order is out; the miner is on its way
    zeros_before = len(ctx.log_lines(": 0/"))
    ctx.control.shutdown([cid])
    ctx.wait_game(2)
    ctx.control.turn_on([cid])
    ctx.note("rebooted %s (computer #%d) at the start of a %d-sector rescan" % (holder, cid, total))

    done = ctx.wait_until(lambda: ctx.log_lines("Job complete: job_"), 6 * 3600)
    ctx.expect(bool(done), "the job completed after a reboot during the rescan pass")
    ctx.expect(len(ctx.log_lines("keeps its rescan zone")) >= 1, "the requeued job kept its rescan zone")
    ctx.expect(len(ctx.log_lines(": 0/")) == zeros_before, "no job was rebuilt as '0/N sectors remaining' after the reboot")
    seen = set()
    for l in ctx.log_lines("Rescan ("):
        m = re.search(r"Rescan \((-?\d+,-?\d+)\)", l)
        if m:
            seen.add(m.group(1))
    ctx.expect(len(seen) >= total, "every sector of the rescan pass was rescanned: %d of %d" % (len(seen), total))
