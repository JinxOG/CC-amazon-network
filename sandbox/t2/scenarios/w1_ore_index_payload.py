"""W1 card "Coordinate-based ore index", LAYER 2 -- and specifically the one risk the simulator cannot see.

WHY THIS EXISTS, having first written the card off as not needing layer 2. My own note said "a t2 run would exercise the same
path as layer 1 ... the fault is arithmetic over the levels that ran, and the simulator drives that path exactly". That is true
about the ARITHMETIC and it is not the whole risk. The ore index makes every SECTOR_DONE message substantially bigger -- a
per-name census for a whole 32x32x100 column, plus up to 4096 packed coordinates at 3 bytes each -- and this project has a
recorded failure for exactly that shape:

    "A large /state payload makes the CC server deaf to radio and silently drops heartbeats; looks like a version regression
     but has no guilty commit."

The simulator cannot show that. It does not model CC's event queue pressure, radio throughput or the real cost of serialising a
big table, and the sizes it moves are its own. So the honest layer-2 question for this card is not "is the band right" -- the
unit tests and w1_survey_partial_band settle that -- it is "does the fleet still hear itself with these messages in flight".

WHAT ONLY THE REAL SERVER CAN ANSWER, and the three things measured here:

  1. THE SURVEY LINE REACHES THE SERVER'S LOG, from real world data. The simulator's ore distribution is its own; the real geo
     scanner returns what the real world holds, and the census walks every block it returns. A band that is right over
     synthetic ore can still be wrong over real ore if the scanner reports anything unexpected.
  2. THE PER-LEVEL BANDS TILE THE COLUMN EXACTLY ONCE, read off the live log rather than from the pure function. Y -68..32
     must be covered with no gap and no overlap: 16 owns 0..32, 0 owns -16..-1, -32 owns -48..-17, -52 owns -68..-49.
  3. THE FLEET IS NOT MADE DEAF BY THE BIGGER MESSAGES. Heartbeat and ack health across the mining job, compared against the
     same counters before the job starts, plus the job actually completing. This is the check the card was missing.

WHAT IT DOES NOT CLAIM. It does not re-test the partial-band arithmetic -- that is layer 1's job
(sandbox/scenarios/w1_survey_partial_band.lua, 8 checks, its last 3 red on 1.9.166) and a reboot here would only duplicate it
less precisely. Nor is it a payload-size benchmark; it is a regression check that the fleet still works with the fields on.

1x, because the deafness it looks for is a timing failure and speeding the clock would manufacture or mask it.
"""
NAME = "w1_ore_index_payload"

# (1920,-2624) holds 2013 ores at the FIRST scan level, so a miner commits to real work rather than surveying and turning
# round. Measured in run w1_skip_reason-1102-101833 and reused by the resume card.
ZONE = {"x1": 1920, "z1": -2624, "x2": 1920, "z2": -2624, "minerCount": 1}

CENSUS = "[SCAN] Census:"
SURVEY = " survey: Y "
DONE = "done by"
COMPLETE = "Job complete: "
# The fleet's own words for "I cannot hear the server" and "the server lost a message".
DEAF = ["Server unreachable", "no ACK since", "dropped", "deaf"]

# The band each scan level owns, by censusBand's rule over SCAN_LEVELS {16,0,-32,-52} and SCAN_RADIUS 16.
EXPECTED_BANDS = {(0, 32), (-16, -1), (-48, -17), (-68, -49)}


def steps(ctx):
    ctx.wait_registered(14, 300)

    # Baseline the comms-health counters BEFORE the job, so "there were warnings" cannot be blamed on the census when the
    # fleet was already complaining at boot. Every miner logs "Server unreachable ... never connected" while the server
    # starts, and counting from zero would read that as a regression.
    before = {k: len(ctx.log_lines(k)) for k in DEAF}
    ctx.note("comms warnings before the job: %s" % before)

    ctx.dispatch("ORDER_MINE", ZONE)

    # Let it work. The job completing is itself one of the three measurements: a fleet made deaf by the payload stops
    # finishing jobs, which is how the recorded failure presented.
    # WATCH FOR A WINDOW, AND JUDGE PROGRESS -- not completion.
    #
    # The first version waited for "Job complete" and asserted it. Run
    # w1-ore-index-b failed that check and the fleet was fine: a single-centre
    # ORDER_MINE pads and snaps to 32, so the order grew past one sector (the
    # server's last word was "1/1 sectors remaining"), and mining real ore with
    # one miner at 1x simply takes longer than three hours. The first sector
    # alone ran 20:12 to 22:43.
    #
    # Completion was the wrong gate because it cannot tell SLOW from STUCK, and
    # the fault this scenario hunts -- the payload making the server deaf --
    # presents as "jobs stop finishing". The discriminator that fits inside a
    # bounded window is whether sectors were STILL completing when the window
    # closed. In that run the last one landed at 22:47:06 with the run ending at
    # 22:50:38, and census lines were still arriving at 22:45 -- progress to the
    # final 2% of the watch, which is the opposite of stopped.
    WATCH = 3 * 3600
    finished = ctx.wait_until(lambda: ctx.log_lines(COMPLETE), WATCH)
    sectors = ctx.log_lines(DONE)
    census = ctx.log_lines(CENSUS)
    survey = ctx.log_lines(SURVEY)
    ctx.note("sector-done lines: %d; census lines: %d; survey lines: %d; job complete: %s"
             % (len(sectors), len(census), len(survey), bool(finished)))

    # ---- 1: the survey reached the log at all, from real world data ----
    ctx.expect(len(census) >= 4,
               "the miner published per-level census lines from real world scan data (%d; a sector is 4 levels, so fewer "
               "than 4 means no sector was fully surveyed and every check below would be measuring nothing)" % len(census))
    for l in survey[:6]:
        ctx.note("survey: %s" % l.strip()[-120:])
    ctx.expect(bool(survey),
               "and a whole-sector survey line naming the Y it covered (%d lines)" % len(survey))

    # ---- 2: the per-level bands tile Y -68..32 exactly once ----
    import re
    seen = set()
    for l in census:
        m = re.search(r"blocks in Y (-?\d+)\.\.(-?\d+)", l)
        if m:
            seen.add((int(m.group(1)), int(m.group(2))))
    ctx.note("distinct census bands seen live: %s" % sorted(seen))
    missing = EXPECTED_BANDS - seen
    unexpected = seen - EXPECTED_BANDS
    ctx.expect(not missing and not unexpected,
               "the four scan levels tile Y -68..32 exactly once, live (missing: %s; unexpected: %s) -- an overlap would "
               "double-count ore and a gap would hide it, and both look like data"
               % (sorted(missing) or "none", sorted(unexpected) or "none"))

    # ---- 3: THE CARD'S MISSING CHECK -- the bigger messages did not make the fleet deaf ----
    after = {k: len(ctx.log_lines(k)) for k in DEAF}
    added = {k: after[k] - before[k] for k in DEAF}
    ctx.note("comms warnings added during the job: %s" % added)
    # STILL FINISHING SECTORS WHEN THE WINDOW CLOSED, which is what separates a
    # fleet gone deaf from one that is merely slow. Completion is recorded, not
    # gated -- see the note at the wait above for why.
    def stamps(substr):
        out = []
        for l in ctx.log_lines(substr):
            m = re.match(r"\s*(\d{4}-\d\d-\d\dT[\d:.]+Z)", l)
            if m:
                out.append(m.group(1))
        return sorted(out)

    done_at, census_at = stamps(DONE), stamps(CENSUS)
    last_progress = max(done_at[-1:] + census_at[-1:]) if (done_at or census_at) else None
    all_lines = stamps("")
    run_end = all_lines[-1] if all_lines else None
    ctx.note("job complete: %s; last sector-done: %s; last census: %s; last log line: %s"
             % (bool(finished), done_at[-1:] or "none", census_at[-1:] or "none", run_end))

    # Progress inside the last 20 minutes of whatever the log covers. Measured
    # from the log's own final timestamp rather than from wall clock, so a run
    # cut short early is judged against when it actually ended.
    fresh = None
    if last_progress and run_end:
        import datetime as _dt
        def t(s):
            return _dt.datetime.strptime(s[:19], "%Y-%m-%dT%H:%M:%S")
        fresh = (t(run_end) - t(last_progress)).total_seconds() <= 1200
    ctx.note("progress was still arriving at the end of the window: %s" % fresh)
    ctx.expect(bool(finished) or fresh is True,
               "the fleet was STILL completing sectors when the window closed (%d sectors done; job complete: %s; last "
               "progress %s against a log ending %s) -- the recorded payload-deafness failure presented as jobs that "
               "STOPPED finishing, so progress continuing to the end is the thing that rules it out. Slow is not stuck: a "
               "single-centre order pads and snaps to 32 and one miner mining real ore at 1x needs longer than this watch."
               % (len(sectors), bool(finished), last_progress, run_end))
    ctx.expect(added.get("Server unreachable", 0) == 0 and added.get("no ACK since", 0) == 0,
               "and no miner lost contact with the server while those reports were in flight (new 'Server unreachable': "
               "%d, new 'no ACK since': %d, measured against %d and %d before the job so the boot-time warnings every "
               "miner logs cannot be mistaken for a regression)"
               % (added.get("Server unreachable", 0), added.get("no ACK since", 0),
                  before.get("Server unreachable", 0), before.get("no ACK since", 0)))
