"""W1 card "A sector that refuses every ore reports the same as an empty one", layer 2 (fix in 1.9.154, 0a0f664).

Same fault as sandbox/scenarios/w1_skip_reason.lua, on the real server. W3 measured node_183/job_0167 on 1.9.135: two
re-mine trips scanned 134 and 100 ores at Y=-52 and mined 0, and the log could not say which, because mineOreList
printed a bare count -- "Skipped N unreachable ores (bedrock/fenced/blocked)". "134 refused" and "nothing was there"
rendered identically, and that parenthesis overclaimed: nothing in the move layer can tell bedrock from any other
unbreakable block. 1.9.154 buckets the reason base.move.to already returned and navToOre discarded.

STAGING. Rather than hunt the world for ore, this PLANTS one: a 3x3x3 of bedrock with an iron ore block at its centre,
at y=0, which is one of the miner's scan levels (it scans at 16, 0, -32, -52, radius 16). The geo scanner reports the
ore, so it enters the mining list; every one of its six faces is bedrock, which CC refuses to break, so navToOre cannot
reach it. That is the real shape of the fault -- ore reported found and then not mined -- and the reason must come out
as "blocked".

THE STAGING USED TO DO NOTHING AT ALL (run w1-skip-c, 2026-11-02). setblock and fill into a chunk the game has not
loaded are refused with "That position is not loaded", and at staging time -- before the miner has travelled out and
placed its chunk loader -- that ground is always cold. Worse, the reply was discarded, so four refusals passed
unnoticed: the miner then surveyed a sector with nothing planted in it, found no blocked ore, printed no skip line, and
the run read as a failure of the fix. Two repairs, both below. The chunks are force-loaded BEFORE anything is written,
and every staging command's reply is read and asserted, ending with a positive check that the ore block is actually
there. A staging step that cannot fail is not staging, it is a wish.

ONE SECTOR, NOT THREE, AND WHY (run w1_skip_reason-1102-101833). The first run ordered the calibration's three-sector
zone and was INCONCLUSIVE, through two faults in this file rather than anything in the fleet. The server gave the zone
one miner (its own ratio: one per three sectors), that miner surveyed all three and then mined them one at a time, and
the wait expired with the sector holding the planted ore still in flight -- so "0 new-format lines" meant the code under
test had not run yet, not that it was broken. The order is now a single sector (buildSectorGrid floors and ceils to the
32 step, so one centre in, one sector out), which removes the queue ordering from the question. The second fault was
counting the order line the instant after posting it -- see the check at the end.

WHICH SECTOR, AND WHY NOT (1920,-2624) (run w1-skip-b). The obvious single sector was the one the ore was already in.
It is the wrong one, and that run proved it: the miner logged "MINING (2013 ores at Y=16)" and spent seven minutes
mining and dumping the FIRST of its four scan levels, nowhere near the planted ore at y=0. (That run also died 51
minutes later, but for a reason outside the fleet entirely -- the host suspended to RAM; see
docs/measurements/2026-11-02-host-sleep-destroys-a-1x-run.txt, worth reading before trusting any long 1x run.)
(1952,-2624) is used instead, and run w1-skip-c measured its ore profile exactly: 0 ore inside the lease at Y=16, Y=0
and Y=-32, and 77 at Y=-52 -- all of which sit BELOW the -58 dig floor (pre-fix mineOreList prints its skip line only
when an ATTEMPTED ore failed, and across two passes it printed none and mined none, so none of the 77 were above the
floor). That makes Y=0 genuinely empty ground: the planted ore is the only thing at that level that can produce a skip
line, so the signal cannot be confused with natural ore. The 77 at Y=-52 are the below-floor card's subject and, with
that fix in, never reach mineOreList at all, so they cannot contribute a skip line either.

WHY 1x AND WHY NOT TO COMPLETION. 1x because at a higher tick rate the game clock outruns the fleet's os.epoch
deadlines (see NOT STAGED), and a deadline firing early could turn this refusal into the "aborted" bucket and fail the
run for the wrong reason. Not to completion because the skip line is printed at the end of each scan level, before the
job ends; the simulator layer already proves the job completes despite the unreachable ore, and repeating that here
would cost hours to re-prove what is not in question.

WHY IT FAILS ON THE OLD CODE: pre-1.9.154 prints the bare-count line, so the new-format count never rises and the first
check fails. The old string is asserted absent too, so a half-applied change cannot pass.

TWO THINGS THE STAGING DOES, SAID PLAINLY. The bedrock fill overwrites whatever was in that 3x3x3 -- stone, on the
measurement above. That cannot affect the checks below, which assert that a skip line appeared and which bucket it
named, never a particular ore total; but it does mean this is not a read-only intervention, and the force-load is a
second one. (The below-floor scenario beside this one needs neither and takes neither.) And the simulator layer plants
its ore the same way for the same reason: sealing NATURAL ore seals nothing, because ore grows in veins of 5-10
contiguous blocks, so a shell would overwrite ore and move the counts it is meant to be reading.

Cleanup returns the shell to stone and releases the force-load, which is cosmetic rather than necessary: the runner
starts every run from the 2026-10-18 world copy, so nothing here persists into the next one.
"""
NAME = "w1_skip_reason"

ORE = (1957, 0, -2619)                       # inside ZONE's one sector (centre 1952,-2624, radius 16), y=0 scan level
ZONE = {"x1": 1952, "z1": -2624, "x2": 1952, "z2": -2624, "minerCount": 1}
SECTOR = "Sector (1952,-2624)"               # its 'done by ... ore mined' line, for evidence either way
NEW_FMT = " attempted (scan "                # appears only in the 1.9.154 line
OLD_FMT = "unreachable ores"                 # the bare-count line this replaced

# Replies that mean the command did not do what it says. "not loaded" is the one
# that cost a whole run; the rest are the ordinary ways rcon reports a refusal.
BAD = ("not loaded", "Unknown", "Incorrect", "Expected", "Failed", "cannot", "No ")


def _must(ctx, cmd, want=None):
    """Run a staging command, show its reply, and STOP the run if it refused.

    ctx.expect only records a check; it does not stop anything. Staging has to
    stop the run, because every check after it would be measuring a world that
    was never set up -- which is precisely how run w1-skip-c spent 90 minutes
    proving nothing. The runner catches this, records it as the run's error and
    still writes the report.
    """
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
    x, y, z = ORE

    # Force-load first. Everything below writes to or reads from this ground,
    # and until the miner arrives with its own chunk loader nothing here is in
    # memory -- which is exactly how run w1-skip-c staged nothing and blamed the
    # fleet for it. Column coordinates, covering the whole 3x3 shell footprint.
    _must(ctx, "forceload add %d %d %d %d" % (x - 1, z - 1, x + 1, z + 1))

    # Seal an ore block: bedrock shell first, then the ore in the middle of it.
    _must(ctx, "fill %d %d %d %d %d %d minecraft:bedrock" % (x - 1, y - 1, z - 1, x + 1, y + 1, z + 1))
    _must(ctx, "setblock %d %d %d minecraft:iron_ore replace" % (x, y, z))

    # And the positive check, which is the one that matters: the block is there.
    # Everything above could be made to pass by a server that accepts commands
    # and ignores them; this cannot.
    _must(ctx, "execute if block %d %d %d minecraft:iron_ore" % ORE, want="Test passed")
    _must(ctx, "execute if block %d %d %d minecraft:bedrock" % (x - 1, y - 1, z - 1), want="Test passed")
    ctx.note("planted iron ore at %d,%d,%d inside a 3x3x3 bedrock shell: it scans, and cannot be entered" % ORE)
    ctx.wait_game(3)

    new0 = len(ctx.log_lines(NEW_FMT))
    old0 = len(ctx.log_lines(OLD_FMT))

    ctx.dispatch("ORDER_MINE", ZONE)

    got = ctx.wait_until(lambda: len(ctx.log_lines(NEW_FMT)) > new0, 2 * 3600)
    lines = [l for l in ctx.log_lines(NEW_FMT)][new0:]
    for l in lines:
        ctx.note("skip line: %s" % l.strip())
    # The sector's own 'done' count goes in the message because the first run
    # could not tell a broken fix from a wait that ended too early. If this
    # fails with 0 skip lines AND 0 sector lines, the code under test never ran
    # and the run is inconclusive; 0 skip lines with the sector reported done is
    # a real failure. The two must not read alike.
    mined = [l for l in ctx.log_lines(SECTOR) if "ore mined" in l]
    ctx.expect(bool(got), "a miner reported a skip in the 1.9.154 format, with its denominators "
                          "(%d new lines; the sector was reported done %d times -- 0 and 0 together means the "
                          "mine phase never reached the planted ore, which is inconclusive, not a failure)"
                          % (len(lines), len(mined)))

    # A reason, and the right one. This ore is walled in, so "blocked" is what it
    # is. "unknown" here would mean the classifier stopped recognising a string
    # move.to really returns -- which is the failure that bucket exists to show
    # rather than hide, so it must not be accepted as a pass.
    blocked = [l for l in lines if "blocked" in l]
    ctx.expect(bool(blocked), "and named the reason 'blocked' -- 'unknown' would mean a lost reason string (%r)"
               % ([l.strip() for l in lines][:3]))

    old_now = len(ctx.log_lines(OLD_FMT)) - old0
    ctx.expect(old_now == 0, "and the bare-count line is gone (%d old-format lines) -- both must hold, or the "
                             "change only half landed" % old_now)

    # Counted here, not at dispatch. The first run read 0 and failed, while the
    # job it was denying plainly ran: the server reads the bridge every 3 s and
    # the line still has to ship, so counting it one instruction after posting
    # is a race this scenario loses every time. By now the order has not only
    # arrived, it has produced a skip line. (three_sectors.py counts it at the
    # end for the same reason; ts-10x-1.9.154 is why it is counted at all --
    # one ORDER_MINE was handed over twice, 6 s apart.)
    orders = len(ctx.log_lines("Bridge cmd: ORDER_MINE"))
    ctx.expect(orders == 1, "and the server received the ORDER_MINE exactly once (%d)" % orders)

    # Put the world back: stone where the shell and the planted ore were, and
    # release the force-load so the chunks behave normally again. Noted, not
    # asserted -- this is cosmetic (every run starts from a fresh world copy),
    # and a failed tidy-up must not overwrite a verdict the checks above earned.
    for cmd in ("fill %d %d %d %d %d %d minecraft:stone" % (x - 1, y - 1, z - 1, x + 1, y + 1, z + 1),
                "forceload remove %d %d %d %d" % (x - 1, z - 1, x + 1, z + 1)):
        ctx.note("cleanup: %s -> %s" % (cmd, (ctx.control.command(cmd) or "").strip() or "(no reply)"))
