"""W1 card "Miners treat the world floor as a scan failure (old chunks: floor at Y 0-4)", LAYER 2.

This is the easiest of W1's layer 2s to judge, because the failure was so loud
and so localised: the very sectors used here produced 16 `place_failed at Y=0`
failures in shakeout-side-h, and side-h finished only ONE mine in 3 h with four
miners. On 1.9.169 the same sectors should produce none.

WHAT WAS MEASURED (shakeout-side-h's own log, before anything was changed):
  - every census that ever ran was `Y 0..32` -- 22 of them -- and ZERO scans
    succeeded at any level below 0, anywhere in the run;
  - a failing miner's real height was y=2 (`GPS resync: 512,2,-2336`, 21 s after
    its three Y=0 failures), and the y values seen across the whole run were
    2, 3, 4, 5, plus 67 at the depot and 210 in travel -- nothing below y=2;
  - the failing sectors were contiguous: 512,-2240 / 512,-2272 / 512,-2336 /
    512,-2400 / 544,-2304 / 544,-2336 / 544,-2368 / 576,-2240.

So the miners never reached Y=0. These sites are OLD pre-1.18 chunks whose floor
is bedrock at about y 0-4, and the square below that level does not exist to
place a scanner into. The live world has the same old chunks near the base.

THE SECTOR CHOSEN. 512,-2336 is one of the eight that failed, and it failed in
side-h specifically (node_231, 20:53:06-20:53:17, three retries then the job
handed back). Using a sector with a recorded failure is the point: a fresh sector
would prove nothing about the fault.

WHAT IT ASSERTS:
  - the miner reached a scan level there, so the path was actually walked;
  - NO `place_failed at Y=0` and no `scan_level_incomplete` for this sector --
    the fault itself;
  - the miner SAID it reached the bottom of the world, by name. Without that the
    absence above is satisfied by a miner that simply never got deep enough, and
    this run would be a pass that proves nothing;
  - the sector is reported DONE rather than re-dispatched, which is the business
    outcome: 16 failures in side-h were 16 jobs handed back.

AND ONE CHECK IN THE OTHER DIRECTION, which matters more than it looks: the
bottom-of-the-world line must NOT appear for a NEW-chunk sector. If deepslate or
anything else were being read as the floor, miners would stop short everywhere
and the "fix" would be worse than the fault. A second order is dispatched to a
sector away from the old chunks to check exactly that.

1x. No reboot and no staging: the fault needs only the world's own geology.
"""
NAME = "w1_world_floor"

# One of the eight sectors that actually failed, and the one node_231 failed on.
OLD_CHUNK = {"x1": 512, "z1": -2336, "x2": 512, "z2": -2336, "minerCount": 1}
# Away from the old chunks: the sector the resume and ore-index cards both use,
# which has 2013 ores at its FIRST scan level and has never shown this fault.
NEW_CHUNK = {"x1": 1920, "z1": -2624, "x2": 1920, "z2": -2624, "minerCount": 1}

PLACE_FAILED = "place_failed at Y=0"
INCOMPLETE = "scan_level_incomplete"
BOTTOM = "Reached the bottom of the world"
BOTTOMS_OUT = "bottoms out above Y="
SCANNING = "phase SCANNING"
DONE = "done by"


def steps(ctx):
    ctx.wait_registered(14, 300)

    base = {k: len(ctx.log_lines(k)) for k in
            (PLACE_FAILED, INCOMPLETE, BOTTOM, BOTTOMS_OUT, SCANNING, DONE)}

    # ---- the old-chunk sector, where the fault lived ----
    ctx.dispatch("ORDER_MINE", OLD_CHUNK)
    scanned = ctx.wait_until(lambda: len(ctx.log_lines(SCANNING)) > base[SCANNING], 2 * 3600)
    ctx.expect(bool(scanned),
               "a miner reached a scan level in the old-chunk sector (%d new SCANNING lines) -- "
               "without this the absences below are satisfied by a miner that never arrived"
               % (len(ctx.log_lines(SCANNING)) - base[SCANNING]))
    if not scanned:
        ctx.note("INCONCLUSIVE: never scanned the old-chunk sector")
        return

    # Give it long enough to work the levels it CAN reach and report the sector.
    ctx.wait_until(lambda: len(ctx.log_lines(DONE)) > base[DONE], 2 * 3600)
    ctx.wait_game(300)

    def since(k):
        return ctx.log_lines(k)[base[k]:]

    failed, incomplete = since(PLACE_FAILED), since(INCOMPLETE)
    bottom, bottoms = since(BOTTOM), since(BOTTOMS_OUT)
    done = since(DONE)
    for name, rows in (("place_failed at Y=0", failed), ("scan_level_incomplete", incomplete),
                       ("reached the bottom", bottom), ("sector bottoms out", bottoms),
                       ("sectors done", done)):
        ctx.note("%s: %d line(s)%s" % (name, len(rows), (" | " + rows[0].strip()[-120:]) if rows else ""))

    # ---- THE FAULT ----
    ctx.expect(not failed,
               "no miner reported place_failed at Y=0 (%d lines) -- side-h produced 16 of these "
               "and finished only 1 mine in 3 h with 4 miners" % len(failed))
    ctx.expect(not incomplete,
               "and no sector was abandoned as scan_level_incomplete (%d lines) -- that is the "
               "line that handed the job back" % len(incomplete))

    # ---- AND IT SAID WHY, which is what stops this being a vacuous pass ----
    ctx.expect(bool(bottom),
               "the miner SAID it reached the bottom of the world (%d '%s' lines) -- with neither "
               "this nor a failure, the run only shows a miner that never went deep, and proves "
               "nothing about the fix" % (len(bottom), BOTTOM))
    ctx.expect(bool(bottoms),
               "and the sector finished on the levels it managed (%d '%s' lines)"
               % (len(bottoms), BOTTOMS_OUT))

    # ---- AND THE SECTOR WAS FINISHED, not handed back ----
    ctx.expect(bool(done),
               "the old-chunk sector was reported DONE (%d done lines) -- 16 failures in side-h "
               "were 16 jobs re-dispatched, so finishing it is the business outcome" % len(done))

    # ---- THE OTHER DIRECTION: a new-chunk sector must NOT bottom out ----
    # If deepslate or anything else were read as the floor, miners would stop
    # short everywhere and this fix would be worse than the fault it replaced.
    mark = {k: len(ctx.log_lines(k)) for k in (BOTTOM, SCANNING)}
    ctx.dispatch("ORDER_MINE", NEW_CHUNK)
    deep = ctx.wait_until(lambda: len(ctx.log_lines(SCANNING)) > mark[SCANNING], 2 * 3600)
    ctx.expect(bool(deep), "a miner reached a scan level in the NEW-chunk sector too (%d new)"
               % (len(ctx.log_lines(SCANNING)) - mark[SCANNING]))
    if deep:
        ctx.wait_game(900)
        spurious = ctx.log_lines(BOTTOM)[mark[BOTTOM]:]
        for l in spurious[:3]:
            ctx.note("new-chunk bottom line: %s" % l.strip()[-130:])
        ctx.expect(not spurious,
                   "and it did NOT claim to reach the bottom of the world there (%d lines) -- "
                   "deepslate is the 1.18 transition and perfectly diggable, so reading it as the "
                   "floor would stop every miner at y=0 in a new chunk and make the fix worse than "
                   "the fault" % len(spurious))
