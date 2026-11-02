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

ONE SECTOR, NOT THREE, AND WHY (run w1_skip_reason-1102-101833). The first run ordered the calibration's three-sector
zone and was INCONCLUSIVE, through two faults in this file rather than anything in the fleet. The server gave the zone
one miner (its own ratio: one per three sectors), that miner surveyed all three and then mined them one at a time, and
the 3-hour wait below expired with the sector holding the planted ore still in flight -- so "0 new-format lines" meant
the code under test had not run yet, not that it was broken. The order is now the single sector that holds the ore
(x1=x2=1920, z1=z2=-2624: buildSectorGrid floors and ceils to the 32 step, so one centre in, one sector out), which
removes the queue ordering from the question and brings the run inside half an hour. The second fault was counting the
order line the instant after posting it -- see the check at the end.

WHY 1x AND WHY NOT TO COMPLETION. 1x because at a higher tick rate the game clock outruns the fleet's os.epoch
deadlines (see NOT STAGED), and a deadline firing early could turn this refusal into the "aborted" bucket and fail the
run for the wrong reason. Not to completion because the skip line is printed at the end of each scan level, before the
job ends; the simulator layer already proves the job completes despite the unreachable ore, and repeating that here
would cost hours to re-prove what is not in question.

WHY IT FAILS ON THE OLD CODE: pre-1.9.154 prints the bare-count line, so the new-format count never rises and the first
check fails. The old string is asserted absent too, so a half-applied change cannot pass.

TWO THINGS THE STAGING DOES, SAID PLAINLY. The bedrock fill overwrites whatever was in that 3x3x3 -- stone normally,
but possibly a cave or a block of natural ore. That cannot affect the checks below, which assert that a skip line
appeared and which bucket it named, never a particular ore total; but it does mean this is not a read-only
intervention. And the simulator layer plants its ore the same way for the same reason: sealing NATURAL ore seals
nothing, because ore grows in veins of 5-10 contiguous blocks, so a shell would overwrite ore and move the counts it
is meant to be reading. Both layers therefore stage one identical fault.

Cleanup returns the shell to stone, which is cosmetic rather than necessary: the runner starts every run from the
2026-10-18 world copy, so nothing here persists into the next one.
"""
NAME = "w1_skip_reason"

ORE = (1925, 0, -2619)                       # inside ZONE's one sector (centre 1920,-2624, radius 16), y=0 scan level
ZONE = {"x1": 1920, "z1": -2624, "x2": 1920, "z2": -2624, "minerCount": 1}
SECTOR = "Sector (1920,-2624)"               # its 'done by ... ore mined' line, for evidence either way
NEW_FMT = " attempted (scan "                # appears only in the 1.9.154 line
OLD_FMT = "unreachable ores"                 # the bare-count line this replaced


def steps(ctx):
    ctx.wait_registered(14, 300)
    x, y, z = ORE
    c = ctx.control

    # Seal an ore block: bedrock shell first, then the ore in the middle of it.
    c.command("fill %d %d %d %d %d %d minecraft:bedrock" % (x - 1, y - 1, z - 1, x + 1, y + 1, z + 1))
    c.command("setblock %d %d %d minecraft:iron_ore replace" % (x, y, z))
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

    # Put the world back: stone where the shell and the planted ore were.
    c.command("fill %d %d %d %d %d %d minecraft:stone" % (x - 1, y - 1, z - 1, x + 1, y + 1, z + 1))
    ctx.note("bedrock shell and planted ore returned to stone")
