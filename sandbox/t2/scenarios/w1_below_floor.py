"""W1 card "Miners report ore they are not allowed to dig, and re-mine it forever", layer 2.

Same fault as sandbox/scenarios/w1_below_floor.lua, on the real server.

THE FAULT. The geo scanner sees further down than the miner may go. It scans at Y = 16, 0, -32 and -52 with radius 16,
so the deepest level reads Y=-68..-36, while the dig floor is MIN_ORE_Y = -58. Only that deepest level crosses the
floor. Ore below it used to be counted as FOUND and sent to the server in SECTOR_DONE.foundOres, then silently dropped
at mining time. The server's rescan verdict is read straight off that field (central_server.lua:
hasOre = next(p.foundOres) ~= nil), so it logged "ore remains", queued the sector for a re-mine, the miner dropped the
same ore again and reported 0 mined -- round again until "re-mine exhausted". W6 measured 12 wasted sectors and ~35
miner-minutes on node_139 (2026-09-10); on 2026-09-11 jobs 0043/0044 found 454 ores across 20 types and mined 0 of
every one. It also corrects a wrong answer I gave W3: told that job_0167 scanned "134 ores at Y=-52" and mined none,
I said the depth floor was not a candidate. Y=-52 is where the SCANNER sat, not where the ore was, and from there it
reads to -68 -- so the floor was a candidate all along.

STAGING. Three ore blocks are planted at Y=-60 inside the one sector this orders, which is below the -58 floor and
inside the deepest scan level's reach. Y=-60 falls in the 1.20 bedrock band (-64..-59), so the setblock replaces
bedrock or deepslate rather than plain stone; that is the point -- real below-floor ore lives down there among the
bedrock, which is exactly why the miner is not allowed to go.

WHAT IT ASSERTS, AND WHY NOT JUST "NO ore remains". An absence proves nothing on its own: a run where the rescan never
happened would log zero "ore remains" lines and look identical to a working fix. So both gates are positive. The miner
must SAY it dropped below-floor ore, and the server must log a rescan verdict of "clean" for this sector. The absence
of "ore remains" is checked beside those, never instead of them, and every message carries its evidence count so a
no-data run cannot read like a pass.

THE ONE CONFOUND, NAMED, AND WHY THIS SECTOR. "Clean" is a claim about the whole sector, not only the planted ore. If
this sector holds NATURAL ore above the floor that the miner cannot reach (walled in by bedrock, say), the rescan will
say "ore remains" for a reason this card is not about -- that is the skip-reason card's territory. The mined-ore count
goes in the failure message so a reader can tell the two apart. The sector is chosen to make that confound unlikely on
evidence rather than hope: in run w1_skip_reason-1102-101833 on this world copy, (1952,-2624) reported "0 ore mined"
and finished in about four minutes, where its neighbour (1920,-2624) held 2013 ores at the Y=16 level alone -- enough
that a later run spent seven minutes on that one level and never reached the deeper ones. Empty ground means the
planted below-floor ore is the only thing in the sector that can change the verdict.

WHY 1x. Above 20 ticks/s the game clock outruns the fleet's os.epoch deadlines, and a deadline firing early could end
the job before the rescan phase -- failing the run for the wrong reason.

WHY IT FAILS ON THE OLD CODE: pre-fix there is no below-floor line at all, so the first gate fails; and the planted ore
reaches foundOres, so the rescan logs "ore remains" and the last two gates fail with it.
"""
NAME = "w1_below_floor"

SECTOR = (1952, -2624)                       # one sector: buildSectorGrid floors/ceils to the 32 step
ZONE = {"x1": 1952, "z1": -2624, "x2": 1952, "z2": -2624, "minerCount": 1}
ORES = [(1957, -60, -2619), (1947, -60, -2630), (1962, -60, -2615)]   # all within radius 16 of the sector centre

DROPPED = "ore below the Y="                 # the [SCAN] line this card adds
VERDICT = "Rescan (%d,%d) done by" % SECTOR  # "... — clean [job_xxxx: 1/1]" or "— ore remains ["
EXHAUST = "re-mine exhausted"


def steps(ctx):
    ctx.wait_registered(14, 300)
    c = ctx.control

    for (x, y, z) in ORES:
        c.command("setblock %d %d %d minecraft:diamond_ore replace" % (x, y, z))
    ctx.note("planted %d diamond ore at Y=-60, below the -58 dig floor and inside the Y=-52 scan level's reach"
             % len(ORES))
    ctx.wait_game(3)

    drop0 = len(ctx.log_lines(DROPPED))
    ctx.dispatch("ORDER_MINE", ZONE)

    # GATE 1: the miner says so. Absent before the fix, which dropped the ore
    # without a word -- and the silence is half of what made this card expensive
    # to find, because "found nothing" and "found ore I may not touch" read alike.
    said = ctx.wait_until(lambda: len(ctx.log_lines(DROPPED)) > drop0, 2 * 3600)
    lines = ctx.log_lines(DROPPED)[drop0:]
    for l in lines:
        ctx.note("below-floor line: %s" % l.strip())
    ctx.expect(bool(said), "the miner reported dropping ore below the dig floor (%d lines)" % len(lines))

    # GATE 2: the server reached a verdict at all. Checked before its content,
    # because no rescan means the next check is reading an empty list.
    got = ctx.wait_until(lambda: ctx.log_lines(VERDICT), 3 * 3600)
    verdicts = ctx.log_lines(VERDICT)
    for l in verdicts:
        ctx.note("rescan verdict: %s" % l.strip())
    mined = [l for l in ctx.log_lines("Sector (%d,%d)" % SECTOR) if "ore mined" in l]
    ctx.expect(bool(got), "the server logged a rescan verdict for this sector (%d verdicts, %d sector-done lines) "
                          "-- 0 and 0 together means the job never reached the rescan phase, which is inconclusive, "
                          "not a failure" % (len(verdicts), len(mined)))

    # GATE 3: and the verdict was "clean". This is the fix: the verdict is read
    # straight off foundOres, so leaving unreachable ore out of that field is
    # the whole of it.
    clean = [l for l in verdicts if "clean" in l]
    remains = [l for l in verdicts if "ore remains" in l]
    ctx.expect(bool(clean) and not remains,
               "and the verdict was 'clean', never 'ore remains' for ore nobody may dig (clean %d, remains %d; "
               "the sector reported %s -- natural unreachable ore above the floor would also read 'ore remains', "
               "and that is the skip-reason card, not this one)"
               % (len(clean), len(remains), [l.strip()[-60:] for l in mined] or "no done line"))

    ctx.expect(not ctx.log_lines(EXHAUST),
               "and the zone never ran out of re-mine attempts (%d)" % len(ctx.log_lines(EXHAUST)))

    for (x, y, z) in ORES:
        c.command("setblock %d %d %d minecraft:bedrock replace" % (x, y, z))
    ctx.note("planted ore returned to bedrock (cosmetic: every run starts from a fresh world copy)")
