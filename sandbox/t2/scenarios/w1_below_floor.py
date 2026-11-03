"""W1 card "Miners report ore they are not allowed to dig, and re-mine it forever", layer 2.

Same fault as sandbox/scenarios/w1_below_floor.lua, on the real server.

THE FAULT. The geo scanner sees further down than the miner may go. It scans at Y = 16, 0, -32 and -52 with radius 16,
so the deepest level reads Y=-68..-36, while the dig floor is MIN_ORE_Y = -58. Only that level crosses the floor. Ore
below it used to be counted as FOUND and sent to the server in SECTOR_DONE.foundOres, then silently dropped at mining
time. The server's rescan verdict is read straight off that field (central_server.lua: hasOre = next(p.foundOres) ~=
nil), so it logged "ore remains", queued the sector for a re-mine, the miner dropped the same ore again and reported 0
mined -- round again until "re-mine exhausted". W6 measured 12 wasted sectors and ~35 miner-minutes on node_139
(2026-09-10); on 2026-09-11 jobs 0043/0044 found 454 ores across 20 types and mined 0 of every one. It also corrects a
wrong answer I gave W3: told that job_0167 scanned "134 ores at Y=-52" and mined none, I said the depth floor was not a
candidate. Y=-52 is where the SCANNER sat, not where the ore was, and from there it reads to -68 -- so the floor was a
candidate all along.

NOTHING IS STAGED, AND THAT IS THE POINT. An earlier draft planted three ore blocks at Y=-60. It does not need to: run
w1-skip-c (2026-11-02, pinned to 1.9.156, which is this fix's PARENT) walked this very sector on untouched ground and
produced the entire fault end to end, unprompted --

    Sector (1952,-2624) Y=-52 scan by node_183      [SCAN] Found 77 ore blocks
    Sector (1952,-2624) done by node_183 - 0 ore mined
    Rescan (1952,-2624) done by node_183 - ore remains
    Zone job_0206 rescan found ore in 1 sector(s) - re-mining
    Sector (1952,-2624) done by node_183 - 0 ore mined
    Zone job_0206 re-mine exhausted

-- which is the failing half of this test already in hand, on the real server, with no intervention at all. It also
proves WHERE those 77 sit without probing the world: pre-fix mineOreList prints its skip line only when an ATTEMPTED
ore failed, so one ore above the floor would have been either mined (mined > 0) or reported refused (a skip line).
Neither happened across two passes, so all 77 are below -58. The world is restored from the same 2026-10-18 copy at
every run, so that ore is there every time. This scenario therefore touches nothing: no fill, no setblock, no
forceload. A read-only test cannot damage what it is measuring, and nothing in its result can be an artefact of its own
staging.

WHY NOT THE EARLIER PLANTING, SPECIFICALLY. It silently did nothing. setblock into a chunk the game has not loaded is
refused -- "That position is not loaded" -- and at staging time, before the miner has travelled out and placed its
chunk loader, that ground is always cold. The draft discarded the reply, so four refusals passed unnoticed and the run
read as a fleet failure. See the skip-reason scenario, which genuinely does need to plant and now force-loads first and
checks every reply.

WHAT IT ASSERTS, AND WHY NOT JUST "NO ore remains". An absence proves nothing on its own: a run where the rescan never
happened would log zero "ore remains" lines and look identical to a working fix. So the gates are positive. The miner
must SAY it dropped below-floor ore, and the server must log a rescan verdict of "clean" for this sector. The absence
of "ore remains" is checked beside those, never instead of them, and every message carries its evidence count.

THE ONE THING THAT COULD MAKE GATE 1 LIE, AND THE ANCHOR THAT CATCHES IT. Gate 1 failing with zero lines has two very
different causes: the fix is broken, or the miner never scanned the deep level at all (it was recalled, the job died,
the wait was too short). Those must not read alike, so the anchor is checked and reported with it -- the miner's own
"1952,-2624 Y=-52" line, which is printed on both sides of the fix and does not depend on anything this card changes.
Anchor present and gate 1 empty is a real failure; both empty is inconclusive.

WHY THE "Found N ore blocks" LINE IS NOT THE ANCHOR. After the fix that count is taken AFTER the below-floor split, so
this sector reports "Found 0" -- correctly. Using it as the anchor would be asserting that the bug still exists.

WHY 1x. Above 20 ticks/s the game clock outruns the fleet's os.epoch deadlines, and a deadline firing early could end
the job before the rescan phase -- failing the run for the wrong reason.

WHY IT FAILS ON THE OLD CODE: pre-fix there is no below-floor line at all, so gate 1 fails with the anchor present; and
the ore reaches foundOres, so the rescan logs "ore remains" and the last two gates fail with it. That is not a
prediction -- it is what run w1-skip-c actually logged.
"""
NAME = "w1_below_floor"

SECTOR = (1952, -2624)                       # one sector: buildSectorGrid floors/ceils to the 32 step
ZONE = {"x1": 1952, "z1": -2624, "x2": 1952, "z2": -2624, "minerCount": 1}

DROPPED = "ore below the Y="                 # the [SCAN] line this card adds
ANCHOR = "%d,%d Y=-52" % SECTOR              # the deepest scan level was reached; printed either side of the fix
VERDICT = "Rescan (%d,%d) done by" % SECTOR  # "... - clean [job_xxxx: 1/1]" or "- ore remains ["
DONE = "Sector (%d,%d) done by" % SECTOR
EXHAUST = "re-mine exhausted"


def steps(ctx):
    ctx.wait_registered(14, 300)

    drop0 = len(ctx.log_lines(DROPPED))
    ctx.dispatch("ORDER_MINE", ZONE)

    # GATE 1: the miner says so. Absent before the fix, which dropped the ore
    # without a word -- and the silence is half of what made this card expensive
    # to find, because "found nothing" and "found ore I may not touch" read alike.
    said = ctx.wait_until(lambda: len(ctx.log_lines(DROPPED)) > drop0, 2 * 3600)
    lines = ctx.log_lines(DROPPED)[drop0:]
    for l in lines:
        ctx.note("below-floor line: %s" % l.strip())
    anchor = ctx.log_lines(ANCHOR)
    ctx.expect(bool(said), "the miner reported dropping ore below the dig floor (%d lines; the deepest scan level was "
                           "reached %d times -- with the anchor present and no line this is a real failure, with "
                           "both at 0 the miner never got that deep and the run is inconclusive)"
               % (len(lines), len(anchor)))

    # GATE 2: the server reached a verdict at all. Checked before its content,
    # because no rescan means the next check is reading an empty list.
    got = ctx.wait_until(lambda: ctx.log_lines(VERDICT), 3 * 3600)
    verdicts = ctx.log_lines(VERDICT)
    for l in verdicts:
        ctx.note("rescan verdict: %s" % l.strip())
    done = ctx.log_lines(DONE)
    ctx.expect(bool(got), "the server logged a rescan verdict for this sector (%d verdicts, %d sector-done lines) "
                          "-- 0 and 0 together means the job never reached the rescan phase, which is inconclusive, "
                          "not a failure" % (len(verdicts), len(done)))

    # GATE 3: and the verdict was "clean". This is the fix: the verdict is read
    # straight off foundOres, so leaving ore nobody may dig out of that field is
    # the whole of it. On 1.9.156 this same sector returned "ore remains".
    clean = [l for l in verdicts if "clean" in l]
    remains = [l for l in verdicts if "ore remains" in l]
    ctx.expect(bool(clean) and not remains,
               "and the verdict was 'clean', never 'ore remains' for ore nobody may dig (clean %d, remains %d; "
               "the sector was reported done %d times -- natural unreachable ore ABOVE the floor would also read "
               "'ore remains', and that is the skip-reason card, not this one)"
               % (len(clean), len(remains), len(done)))

    # GATE 4: and the loop never ran. This is the cost the card is about: on
    # 1.9.156 this sector was mined, rescanned, re-mined and only then given up.
    ctx.expect(not ctx.log_lines(EXHAUST),
               "and the zone never ran out of re-mine attempts (%d)" % len(ctx.log_lines(EXHAUST)))
