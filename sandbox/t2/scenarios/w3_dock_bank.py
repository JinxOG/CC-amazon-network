"""W1 card "Docked miners never bank travel debris - the dock guard cancels the whole bank, not just the dig" (fix 0dc2575,
branch w1-dock-bank), layer 2, written by W3 with the baton. Same story as sandbox/scenarios/w3_dock_bank.lua.
A one-sector job is sent; as the miner turns for home ('phase: RETURNING') it is given travel debris in two mining slots
(NBT, retried until it reads back -- the turtle is flying). At its bay the station chest is below it, as at every bay. It
must log 'Dock tidy: banking travel debris', never 'travel debris kept aboard', end with mining slots 5-13 empty (NBT
4-12), and the station chest below its dock must still be there. On the code before the fix it refuses ('kept aboard')
and docks with the debris. Pin the merge of w1-dock-bank (or 0dc2575 itself). 1x, about 1.5 game hours."""
import re
import time

NAME = "w3_dock_bank"
DEBRIS = {5: ("minecraft:cobblestone", 40), 6: ("minecraft:dirt", 20)}      # NBT slot -> item (Lua slots 6 and 7)


def steps(ctx):
    ctx.wait_registered(14, 300)
    c = ctx.control
    ctx.dispatch("ORDER_MINE", {"x1": 1920, "z1": -2624, "x2": 1920, "z2": -2624, "minerCount": 1})
    went = ctx.wait_until(lambda: ctx.log_lines("Dispatched job_"), 600)
    ctx.expect(bool(went), "the job was dispatched")
    if not went:
        return
    job = re.search(r"Dispatched (job_\d+)", went[0]).group(1)
    node = went[0].split("-> ")[1].split()[0]
    cid = int(node.replace("node_", ""))
    docks = [l for l in ctx.log_lines("Assigned dock:") if node in l]
    m = re.search(r"\((-?\d+),(-?\d+),(-?\d+)\)", docks[-1]) if docks else None
    ctx.expect(m is not None, "%s's dock is known (%r)" % (node, docks[-1:] if docks else None))
    if not m:
        return
    dock = tuple(int(v) for v in m.groups())
    below = (dock[0], dock[1] - 1, dock[2])
    chest0 = c.block_data(below)
    ctx.note("%s (computer #%d), dock %s; below it: %s" % (node, cid, dock, chest0[:120]))

    # Home early rather than after the whole sector: one sector took over three game hours on this world (w3-dock-bank,
    # 2026-10-28, still mining when the 3 h wait ran out). A cancelled job's return docks through the same tidy (sim:
    # sandbox/scenarios/w3_dock_bank_cancel.lua, passes on 0dc2575, fails on c50c898).
    scanned = ctx.wait_until(lambda: [l for l in ctx.log_lines("scan by") if job in l], 3600)
    ctx.expect(bool(scanned), "%s reached its sector" % node)
    ctx.dispatch("CANCEL_JOB", {"jobId": job})
    home = ctx.wait_until(lambda: [l for l in ctx.log_lines("phase: RETURNING") if node in l], 1800)
    ctx.expect(bool(home), "%s turned for home" % node)
    if not home:
        return
    b0 = len([l for l in ctx.log_lines("banking travel debris") if node in l])
    k0 = len([l for l in ctx.log_lines("travel debris kept aboard") if node in l])
    given = []
    for nbt, (item, count) in DEBRIS.items():                       # THE TEST: debris aboard on the way home
        for _ in range(20):
            try:
                if item in str(c.set_slot(cid, nbt, item, count)):
                    given.append(nbt)
                    break
            except (RuntimeError, KeyError):
                pass
            time.sleep(0.2)
    ctx.expect(len(given) == len(DEBRIS), "debris given in flight (NBT slots %r)" % given)

    seen = ctx.wait_until(lambda: [l for l in ctx.log_lines("banking travel debris") if node in l][b0:]
                          or [l for l in ctx.log_lines("travel debris kept aboard") if node in l][k0:], 3600)
    ctx.wait_game(30)
    banked = len([l for l in ctx.log_lines("banking travel debris") if node in l]) - b0
    kept = len([l for l in ctx.log_lines("travel debris kept aboard") if node in l]) - k0
    ctx.expect(bool(seen) and banked > 0, "it banked the debris at its dock ('Dock tidy: banking travel debris': %d)" % banked)
    ctx.expect(kept == 0, "it did not refuse ('travel debris kept aboard': %d)" % kept)
    left = []
    for nbt in range(4, 13):                                         # Lua mining slots 5-13
        text = str(c.get_slot(cid, nbt) or "")
        if "Found no elements" not in text and "id:" in text:
            left.append("slot %d: %s" % (nbt + 1, text[:60]))
    ctx.expect(not left, "mining slots 5-13 are empty (%s)" % " ".join(left))
    chest1 = c.block_data(below)
    ctx.expect(chest1.split(" has the following")[0] == chest0.split(" has the following")[0],
               "the block below the dock is unchanged (before: %s; after: %s)" % (chest0[:80], chest1[:80]))
    ctx.dispatch("CANCEL_JOB", {"jobId": job})
