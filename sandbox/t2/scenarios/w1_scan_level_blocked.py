"""W1 card "A scan level skipped for a turtle below is still reported as a finished sector", layer 2.

Same fault as sandbox/scenarios/w1_scan_level_blocked.lua, on the real server.

THE FAULT (W3, job_0058, 2026-09-16). scanSector refuses to dig a fleet member off the square where the geo scanner
goes, which is right: mining a miner costs the computer, its files, its loader_state and its placed loader, in silence.
What was wrong is the accounting after it. The refusal handed back a bare {}, and so does a level with no ore in it, so
the loop counted the level as scanned and the sector was reported DONE with 0 ore. The server has nothing to tell those
apart with, so it never re-queued the sector: node_138 recorded (1888,-2912) done with 0 ore while node_139 had found 81
ore there. Seven separate paths returned that same bare {}.

STAGING. A turtle block is placed on the Y=16 scan square, one below the level the miner stands at. The dig guard
recognises any non-minecraft block whose name contains "turtle" as a fleet member (mine_flow.isFleetTurtle), which is
the real condition. Y=16 is the FIRST of the four levels, so the miner meets the obstruction on arrival and never has to
descend through it -- this stages the scan-placement refusal and nothing else. Blocking a deeper level would also block
the descent and would be testing movement.

THE BLOCK IS NOT A FLEET MEMBER, and that is the point rather than a shortcut. The guard reads the BLOCK NAME, so a
placed turtle block exercises exactly the branch a real fleet member would, without putting a working turtle in the way
of a pickaxe. If the guard were ever narrowed to check something else -- a label, a registry lookup -- this scenario
would stop staging the fault, and the simulator layer beside it would too; both would then fail loudly rather than pass
on a staging that no longer bites.

THE STAGING ASSERTS ITSELF, because run w1-skip-c spent 90 minutes measuring a world it had not set up. setblock into a
chunk the game has not loaded is refused with "That position is not loaded", and before the miner travels out that
ground is always cold. So the chunk is force-loaded first, every reply is read, and the last staging step is a positive
check that the turtle block is really there. A refusal raises rather than merely recording a failed check -- ctx.expect
only records, and a run that goes on for two hours against the wrong world is worse than one that stops.

WHAT IT ASSERTS. The headline is an absence -- the sector must NOT be reported done -- so it is checked only after three
positives: the miner says the level did not run, it retried before giving up, and the server retried the job NAMING
THIS REASON. Each message carries its evidence count.

WHY THE SERVER'S LINE IS "retry N/3" AND NOT "back to queue". The first draft of the simulator layer watched for "back
to queue" and failed with 0 lines while the re-dispatch had plainly happened. That line belongs to the reassign path; a
recoverable JOB_FAILED on a job with retries left logs "Job job_XXXX retry 1/3: <reason>" and hands the sector on. The
reason is asserted inside it, so this cannot pass on an unrelated recoverable failure -- a lost beacon, a refused
loader -- which would otherwise satisfy a bare retry count.

WHY 1x. Above 20 ticks/s the game clock outruns the fleet's os.epoch deadlines, and a deadline firing early could end
the job before the miner reports anything.

WHY IT FAILS ON THE OLD CODE: scanSector returns {} with no reason, the loop treats the level as scanned, and the
sector is reported done with 0 ore. On e08bbd3 the simulator layer printed exactly that -- "Sector (128,-2816) done by
node_11 - 0 ore mined" -- and the first three checks found nothing at all.
"""
NAME = "w1_scan_level_blocked"

SECTOR = (1952, -2624)
ZONE = {"x1": 1952, "z1": -2624, "x2": 1952, "z2": -2624, "minerCount": 1}
SQUARE = (1952, 15, -2624)          # one below the Y=16 level: where the scanner goes
TURTLE = "computercraft:turtle_advanced"

DIDNT_RUN = "did not run"
RETRIED = "retry 1 of "             # the MINER's own line
SRV_RETRY = "retry 1/"              # the SERVER's line; the reason is checked inside it
REASON = "scan_level_incomplete"
DONE = "Sector (%d,%d) done by" % SECTOR
ANCHOR = "%d,%d Y=16" % SECTOR      # the miner reached the level; printed either side of the fix

BAD = ("not loaded", "Unknown", "Incorrect", "Expected", "Failed", "cannot", "No ")


def _must(ctx, cmd, want=None):
    """Run a staging command, show its reply, and STOP the run if it refused."""
    reply = (ctx.control.command(cmd) or "").strip()
    ctx.note("staging: %s -> %s" % (cmd, reply or "(no reply)"))
    bad = [m for m in BAD if m in reply]
    ok = not bad and (want is None or want in reply)
    ctx.expect(ok, "staging command %r was accepted and did what it says (replied %r; refusal markers %s; "
                   "wanted %r)" % (cmd, reply, bad or "none", want))
    if not ok:
        raise RuntimeError("staging refused: %r replied %r (markers %s, wanted %r)" % (cmd, reply, bad, want))
    return reply


def steps(ctx):
    ctx.wait_registered(14, 300)
    x, y, z = SQUARE

    _must(ctx, "forceload add %d %d %d %d" % (x - 1, z - 1, x + 1, z + 1))
    _must(ctx, "setblock %d %d %d %s replace" % (x, y, z, TURTLE))
    _must(ctx, "execute if block %d %d %d %s" % (x, y, z, TURTLE), want="Test passed")
    ctx.note("a turtle block stands on the Y=16 scan square at %d,%d,%d" % SQUARE)
    ctx.wait_game(3)

    base = {k: len(ctx.log_lines(k)) for k in (DIDNT_RUN, RETRIED, SRV_RETRY, DONE)}
    ctx.dispatch("ORDER_MINE", ZONE)

    # ANCHOR first: the miner reached the level this card is about. Everything
    # below is meaningless if it never got there, and "never got there" must not
    # be allowed to read like a pass.
    reached = ctx.wait_until(lambda: ctx.log_lines(ANCHOR), 1 * 3600)
    ctx.expect(bool(reached), "the miner reached the Y=16 scan level of this sector (%d lines)" % len(reached or []))

    # POSITIVE 1: it says the level did not run. The old code said nothing.
    said = ctx.wait_until(lambda: len(ctx.log_lines(DIDNT_RUN)) > base[DIDNT_RUN], 1 * 3600)
    lines = ctx.log_lines(DIDNT_RUN)[base[DIDNT_RUN]:]
    for l in lines[:5]:
        ctx.note("did-not-run line: %s" % l.strip())
    ctx.expect(bool(said), "the miner reported that the level did not run (%d lines)" % len(lines))

    # POSITIVE 2: and it tried again first. A turtle on the scan square is
    # usually one crossing a shaft; abandoning the sector on the first refusal
    # would turn a two-second encounter into a re-dispatched job.
    retries = len(ctx.log_lines(RETRIED)) - base[RETRIED]
    ctx.expect(retries >= 1, "and retried the level rather than abandoning the sector on the first refusal "
                             "(%d retry lines)" % retries)

    # POSITIVE 3: the server retried the job, naming this reason.
    back = ctx.wait_until(lambda: len(ctx.log_lines(SRV_RETRY)) > base[SRV_RETRY], 1 * 3600)
    srv = ctx.log_lines(SRV_RETRY)[base[SRV_RETRY]:]
    for l in srv[:5]:
        ctx.note("server retry line: %s" % l.strip())
    named = [l for l in srv if REASON in l]
    ctx.expect(bool(back), "the server retried the job rather than closing it (%d lines)" % len(srv))
    ctx.expect(bool(named), "and the reason it carried was the skipped level itself (%d of %d lines name %r) -- "
                            "without this, any recoverable failure would satisfy the check above"
               % (len(named), len(srv), REASON))

    # AND THE ABSENCE, last, with the positives in hand: the sector was never
    # reported finished. On the old code this is the line that told the server
    # there was nothing left to do here.
    done = len(ctx.log_lines(DONE)) - base[DONE]
    ctx.expect(done == 0, "and the sector was never reported done, which is what stopped it being re-queued "
                          "(%d done lines)" % done)

    # Put the world back. Noted, not asserted: cosmetic, since every run starts
    # from a fresh world copy, and a failed tidy-up must not overwrite a verdict
    # the checks above earned.
    for cmd in ("setblock %d %d %d minecraft:stone replace" % SQUARE,
                "forceload remove %d %d %d %d" % (x - 1, z - 1, x + 1, z + 1)):
        ctx.note("cleanup: %s -> %s" % (cmd, (ctx.control.command(cmd) or "").strip() or "(no reply)"))
