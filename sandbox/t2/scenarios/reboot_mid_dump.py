"""W1 (ore chest is a ledger kind, 1.9.153 = ff54ed0), layer 2: a miner is shut down in the middle of a dump, with its ore ender chest placed in the
world. Same story as sandbox/scenarios/reboot_mid_dump.lua (node_181, 2026-10-08). Pin the fleet to ff54ed0 (or later) first, run at 1x.

Real Minecraft cannot reboot "at the drop action", so the cut is made as soon as the server logs a miner's DUMPING phase (polled every game second),
a few game seconds later the computer is turned on again; up to eight dumps are cut (each a little later after the line: the chest is placed some seconds after DUMPING is logged, and the miner has no modem during the dump, so nothing can be polled mid-dump) until the ledger has recovered a chest. WHAT IS ASSERTED, and
why not "the job completes": with two miners the healthy one finishes the job while a crippled one sits benched, so completion passes on broken
code. The symptom is the refusal (slot_16_must_hold_the_ore_ender_chest) and the proof of the fix is a ledger recovery, so those are counted; a run
with zero recoveries is reported as not having exercised the fix."""
NAME = "reboot_mid_dump"


def steps(ctx):
    ctx.wait_registered(14, 300)
    ctx.dispatch("ORDER_MINE", {"x1": 1920, "z1": -2624, "x2": 1984, "z2": -2624, "minerCount": 2})
    cuts = 0
    seen = 0
    DELAYS = [2, 5, 8, 3, 6, 10, 4, 7]       # seconds after the DUMPING line (W1: the chest is not down when the line is logged; the swap before the place varies)
    while cuts < len(DELAYS) and not ctx.log_lines("Ledger: recovered the ore_chest"):
        lines = ctx.wait_until(lambda: [l for l in ctx.log_lines("phase: DUMPING") if True][seen:] or None, 2 * 3600, poll=1)
        if not lines:
            ctx.note("no further DUMPING phase within two game hours; stopping the cuts")
            break
        seen += len(lines)
        line = lines[-1]
        node = line.split("INFO")[-1].split()[0]
        cid = int(node.replace("node_", ""))
        ctx.wait_game(DELAYS[cuts], poll=1)
        ctx.control.shutdown([cid])
        cuts += 1
        ctx.note("cut %d: %s (computer #%d) shut down %d s after its DUMPING phase" % (cuts, node, cid, DELAYS[cuts - 1]))
        ctx.wait_game(5, poll=1)
        ctx.control.turn_on([cid])
        ctx.wait_game(120)

    done = ctx.wait_until(lambda: ctx.log_lines("Job complete: job_"), 6 * 3600)
    ctx.expect(bool(done), "the job completed")
    refused = len(ctx.log_lines("must_hold_the_ore_ender_chest"))
    recovered = len(ctx.log_lines("Ledger: recovered the ore_chest"))
    ctx.note("cuts %d, refusals %d, ledger recoveries %d" % (cuts, refused, recovered))
    ctx.expect(refused == 0, "no miner was benched for a missing ore chest after the reboot mid-dump (refusals: %d)" % refused)
    ctx.expect(recovered >= 1, "the ledger recovered a placed ore chest at boot (recovery lines: %d); zero means no cut caught a placed chest, so this run proved nothing" % recovered)
