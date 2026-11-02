"""W1 card "A sector that refuses every ore reports the same as an empty one", layer 2 (fix in 1.9.154, 0a0f664).

Same fault as sandbox/scenarios/w1_skip_reason.lua, on the real server. W3 measured node_183/job_0167 on 1.9.135: two
re-mine trips scanned 134 and 100 ores at Y=-52 and mined 0, and the log could not say which, because mineOreList
printed a bare count -- "Skipped N unreachable ores (bedrock/fenced/blocked)". "134 refused" and "nothing was there"
rendered identically, and that parenthesis overclaimed: nothing in the move layer can tell bedrock from any other
unbreakable block. 1.9.154 buckets the reason base.move.to already returned and navToOre discarded.

STAGING. Rather than hunt the world for ore, this PLANTS one: a 3x3x3 of bedrock with an iron ore block at its centre,
inside the first sector of the calibration's three-sector job and at y=0, which is one of the miner's scan levels (it
scans at 16, 0, -32, -52, radius 16). The geo scanner reports the ore, so it enters the mining list; every one of its
six faces is bedrock, which CC refuses to break, so navToOre cannot reach it. That is the real shape of the fault --
ore reported found and then not mined -- and the reason must come out as "blocked".

WHY 1x AND WHY NOT TO COMPLETION. 1x because at a higher tick rate the game clock outruns the fleet's os.epoch
deadlines (see NOT STAGED), and a deadline firing early could turn this refusal into the "aborted" bucket and fail the
run for the wrong reason. Not to completion because the skip line is printed at the end of each scan level, long before
the job ends; the simulator layer already proves the job completes despite the unreachable ore, and repeating that here
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

ORE = (1925, 0, -2619)                       # inside the first sector of ZONE, on the y=0 scan level
ZONE = {"x1": 1920, "z1": -2624, "x2": 1984, "z2": -2624, "minerCount": 2}
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
    orders = len(ctx.log_lines("Bridge cmd: ORDER_MINE"))
    ctx.expect(orders == 1, "the server received the ORDER_MINE exactly once (%d)" % orders)

    got = ctx.wait_until(lambda: len(ctx.log_lines(NEW_FMT)) > new0, 3 * 3600)
    lines = [l for l in ctx.log_lines(NEW_FMT)][new0:]
    for l in lines:
        ctx.note("skip line: %s" % l.strip())
    ctx.expect(bool(got), "a miner reported a skip in the 1.9.154 format, with its denominators (%d new lines)" % len(lines))

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

    # Put the world back: stone where the shell and the planted ore were.
    c.command("fill %d %d %d %d %d %d minecraft:stone" % (x - 1, y - 1, z - 1, x + 1, y + 1, z + 1))
    ctx.note("bedrock shell and planted ore returned to stone")
