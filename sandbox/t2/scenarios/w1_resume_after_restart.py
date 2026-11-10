"""W1 card "After a restart, turtles resume the job where they stand instead of flying home", layer 2.

Same fault as sandbox/scenarios/w1_resume_after_restart.lua, on real Minecraft.

WHAT IT COST, measured live on the 2026-11-03 13:02 UTC daily restart with all five miners mid-job about 2,000 blocks
out: boot recovery 13:02:56-13:03:00, docked 13:20:42-13:22:07, departing again 13:21:45-13:26:53, and node_178 did
not mine until 13:39:36. About 36 minutes each, nearly all of it a round trip to collect a job the server re-sends on
registration anyway.

HOW THE REBOOT IS STAGED, AND WHY THIS ONE. The bridge command REBOOT_TURTLE sends proto.MSG.REBOOT to one turtle,
and that message exists for exactly this: its own comment says it is there "to produce a genuine mid-sector
re-registration on demand", because waiting for one to happen to a working miner could take days. So the staging is
the fleet's own purpose-built mechanism rather than anything invented here, and no world file is touched.

It is a SINGLE-TURTLE reboot, not a world restart, and that is the honest difference from layer 1. The server stays
up, so the job is never requeued by a server restart -- which makes this the stricter test of the two halves that
matter here: the turtle must keep its own order (the server withholds the sector on re-registration) and must not
announce a recovery that would make the server give its job away. A world restart on T2 would also restart the
server, and the 24-hour shakeout will exercise that path for real.

WHAT IT ASSERTS. The miner must SAY it resumed and name the sector; it must be mining again within five minutes of
its boot line; and there must be no DOCKED line in between. Each is positive except the last, and the last is checked
only after the others, because "no dock line" on its own is equally satisfied by a job that simply died.

WHY 1x. Above 20 ticks/s the game clock outruns the fleet's os.epoch deadlines, and the three-minute idle fallback
this card adds is a wall-clock gap -- at speed it would fire while the turtle was still recovering and send it home
for the wrong reason.

WHY IT FAILS ON THE OLD CODE: the old path always flew home, so the resume line never appears, a DOCKED line does, and
the gap from boot to mining again is the round trip.
"""
NAME = "w1_resume_after_restart"

ZONE = {"x1": 1952, "z1": -2624, "x2": 1952, "z2": -2624, "minerCount": 1}
MINING = "phase: MINING"
RESUMED = "resuming sector ("          # the miner's own print; its radio copy can be eaten mid-recovery
WENT_HOME = "going home: "
DOCKED = "phase: DOCKED"
BOOTING = "booting ==="


def steps(ctx):
    ctx.wait_registered(14, 300)

    ctx.dispatch("ORDER_MINE", ZONE)

    # MID-SECTOR, not between sectors: a turtle between sectors has nothing to
    # resume and going home was never wrong for it.
    at_work = ctx.wait_until(lambda: ctx.log_lines(MINING), 2 * 3600)
    ctx.expect(bool(at_work), "the miner reached the MINING phase before the reboot (%d lines)"
               % len(at_work or []))
    if not at_work:
        raise RuntimeError("never reached MINING; nothing to reboot mid-sector")

    who = None
    for l in at_work:
        for tok in l.split():
            if tok.startswith("node_") and tok[5:].isdigit():
                who = tok
    ctx.note("mining miner: %s" % who)
    ctx.wait_game(60)

    base = {k: len(ctx.log_lines(k)) for k in (MINING, RESUMED, WENT_HOME, DOCKED, BOOTING)}
    ctx.dispatch("REBOOT_TURTLE", {"turtleId": who})

    came_back = ctx.wait_until(lambda: len(ctx.log_lines(BOOTING)) > base[BOOTING], 1800)
    ctx.expect(bool(came_back), "the miner rebooted (%d new boot lines)"
               % (len(ctx.log_lines(BOOTING)) - base[BOOTING]))

    # POSITIVE: it said it was resuming, and which sector.
    said = ctx.wait_until(lambda: len(ctx.log_lines(RESUMED)) > base[RESUMED], 1800)
    lines = ctx.log_lines(RESUMED)[base[RESUMED]:]
    for l in lines:
        ctx.note("resume line: %s" % l.strip())
    home = ctx.log_lines(WENT_HOME)[base[WENT_HOME]:]
    for l in home:
        ctx.note("went-home line: %s" % l.strip())
    ctx.expect(bool(said), "the miner reported resuming its sector where it stands (%d resume lines, "
                           "%d went-home lines%s)"
               % (len(lines), len(home), (": " + home[0].strip()) if home else ""))

    # AND IT IS MINING AGAIN. The card's five minutes, in game time.
    back = ctx.wait_until(lambda: len(ctx.log_lines(MINING)) > base[MINING], 300)
    ctx.expect(bool(back), "and it was mining again within 5 minutes of booting (%d new MINING lines)"
               % (len(ctx.log_lines(MINING)) - base[MINING]))

    # AND IT NEVER WENT HOME, checked last so an absence cannot pass on a dead job.
    docked_now = len(ctx.log_lines(DOCKED)) - base[DOCKED]
    ctx.expect(docked_now == 0, "and no DOCKED line between the reboot and mining again (%d) -- the 36 minutes "
                                "this card is about" % docked_now)
