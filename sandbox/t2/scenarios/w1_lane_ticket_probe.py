"""W1 card "Miners lose GPS and freeze on one stretch of the flight lane (x ~1300-1550, y 200, z -2813)" -- the MECHANISM, on real
chunk loading.

WHAT THIS DECIDES. The card is framed as a GPS coverage gap over one stretch of sky and proposes a relay part-way along or a different
route. W3's update of 2026-10-20 points elsewhere: two frozen miners were each WOKEN BY A PASSING TURTLE (node_177 on 10-15, node_178 on
10-20), and node_183 crossed the whole lane both ways that day with zero GPS failures. "Woken by a passer" is what chunk loading looks
like, not what a radio dead spot looks like. If the mechanism is chunk loading, a GPS relay fixes nothing and the card's proposed fix is
aimed at the wrong thing.

WHY THE SIMULATOR COULD NOT SETTLE IT, and I should not have expected it to. sandbox/scenarios/w1_lane_freeze_mechanism.lua pulls the
chunk under a flying miner and reports FROZEN BY THE UNLOAD AND RECOVERED. That is the simulator's MODEL of chunk loading answering a
question about the real one. Reading the control mod's own M3 proof (sandbox/t2/prove_mod.py) shows the gap: chunk_unload works by a
REFUSAL HOOK that forbids new tickets for the duration, and M3's own control arm records that with no release in force "the chunk stays
loaded after the same forceload add and remove" -- the loader re-forced it. So a turtle whose loader holds a ticket cannot be stranded by
a chunk going quiet. The simulator was answering "what if the turtle cannot get a ticket", which is not what an empty lane does.

SO THE REAL QUESTION IS THE ONE UNDERNEATH: does a miner in flight hold a chunk ticket at all? Two independent ways it might not, both
already known to this project:

  A. SHARED TICKETS. A chunk loader copied in creative keeps its chunky UUID, and copies share ONE Forge ticket -- only the last-placed
     one holds it (memory: copied-turtles-share-chunk-ticket; the fleet's rule is to build loaders from fresh parts). Every other turtle
     in such a group travels with no ticket of its own and depends entirely on somebody else keeping its chunks up. That matches the live
     symptom exactly, including being woken by a passer. `chunk list` reports each loader's uuid, so this is directly readable.
  B. NOT LISTED AT ALL while travelling. The mod lists the loaders whose computers are loaded; a travelling miner that never appears has
     no ticket in flight whatever its parts.

WHAT IT MEASURES, in order of cost. A is a single listing and needs no job: it is read first so that a run whose job never gets going
still answers something. B dispatches a mining job and then watches one miner's own position against `execute if loaded` for the block it
is standing on, which is the same question the live symptom was read from ("appeared frozen at their loader coordinates").

WHAT IT ASSERTS. Only the things that are defects whichever way the mechanism turns out: that the probe had loaders to look at at all,
that no two of them share a ticket, and that no turtle was ever found sitting in an unloaded chunk. The MECHANISM VERDICT is recorded in
the notes for a human, because a test that asserts the answer it hopes for is not an experiment.

NO FLEET CHANGE. Read-only: a listing, /state, and `execute if loaded`. Nothing is staged, nothing is unloaded, no turtle is touched.
1x, because the flight timings are the measurement.
"""
NAME = "w1_lane_ticket_probe"

# The resume card's zone: (1920,-2624) holds minable ore at the FIRST scan level, so a miner commits to a long flight out rather than
# surveying and turning round. The flight is what this probe is about, not the mining.
ZONE = {"x1": 1920, "z1": -2624, "x2": 1920, "z2": -2624, "minerCount": 1}

# Chunks the test world does not keep up on its own, which would otherwise freeze turtles for reasons that are not this card:
# the arrivals side (memory: t2-arrivals-side-dead) and the base/ATC span (memory: atc-computer).
FORCELOAD = [(224, -2816, 271, -2784)]

TRAVEL_Y = 100          # above this a turtle is in flight, not working the ground
WATCH_GAME_SECONDS = 2400

# RUN a (2026-11-10) AND WHY THIS READS THE GAME INSTEAD OF /state.
#
# The first version took the turtle's position from the bridge's /state and then asked the game whether THAT block was loaded. node_183
# flew the lane at y 200, z -2813 -- the card's own altitude and z -- and came back "chunk loaded=False" at x 542, 607 and 681 while
# moving continuously from 143 to 768. A turtle in an unloaded chunk cannot move, so those three readings were almost certainly my own
# instrument: /state carries the turtle's last REPORTED position, which lags, so by the time the loaded-check ran the turtle had left and
# the chunk had gone down behind it. Two clocks, one conclusion -- the same mistake as reading /state against hours-old log lines.
#
# control.computers() is the game's own view: the real block position AND whether the computer is RUNNING. A turtle whose chunk unloads
# has its computer shut down -- the mod's M3 proof records exactly that ("the loaders' computers are off") -- so `on` answers the freeze
# question directly instead of being inferred across two timestamps. Position and loaded-state are then read from the same source, one
# after the other, with nothing in between.


def steps(ctx):
    c = ctx.control

    # Keep the base side up, so nothing freezes for a known-unrelated reason. Replies are read rather than discarded: a forceload that
    # silently did nothing is the staging trap that void-ed run w1-skip-c (memory: t2-staging-traps).
    for (x1, z1, x2, z2) in FORCELOAD:
        r = c.command("forceload add %d %d %d %d" % (x1, z1, x2, z2))
        ctx.note("forceload add %d %d..%d %d -> %s" % (x1, z1, x2, z2, r.strip()[:90]))

    ctx.wait_registered(14, 300)

    # ---- MEASUREMENT A: do any loaders share a ticket? Needs no job. ----
    loaders = c.chunk_loaders()
    ctx.note("chunk list: %d loaders" % len(loaders))
    for l in loaders:
        ctx.note("  loader computer %s at chunk %s,%s uuid %s"
                 % (l.get("computer"), l.get("chunk_x"), l.get("chunk_z"), l.get("uuid")))

    by_uuid = {}
    for l in loaders:
        by_uuid.setdefault(l.get("uuid"), []).append(l.get("computer"))
    shared = {u: ids for u, ids in by_uuid.items() if len(ids) > 1}

    ctx.expect(len(loaders) >= 1,
               "the mod listed chunk loaders to examine (%d) -- with none, every check below would pass for want of evidence rather "
               "than because the fleet is healthy" % len(loaders))
    ctx.expect(not shared,
               "no two chunk loaders share a Forge ticket (%d uuids across %d loaders; shared: %s) -- copies made in creative keep "
               "their chunky UUID and only the LAST placed holds the ticket, so every other turtle in such a group flies with no "
               "chunk loading of its own"
               % (len(by_uuid), len(loaders), ", ".join("%s<-%s" % (u, ids) for u, ids in shared.items()) or "none"))

    # ---- MEASUREMENT B: is a miner in flight standing in a loaded chunk? ----
    ctx.dispatch("ORDER_MINE", ZONE)

    # Which computer ids are miners, from /state once -- the roster does not change mid-run, and after this the probe reads only the game.
    miners = sorted(int(n.replace("node_", "")) for n, t in (ctx.state().get("turtles") or {}).items()
                    if isinstance(t, dict) and (t.get("role") or "").upper() == "MINER" and n.replace("node_", "").isdigit())
    ctx.note("miner computer ids: %s" % miners)

    seen_flying, frozen_hits, unloaded_hits, samples = {}, [], [], 0
    listed_while_flying, not_listed_while_flying = 0, 0
    last_pos = {}

    def sample():
        nonlocal samples, listed_while_flying, not_listed_while_flying
        samples += 1
        try:
            dump = c.computers()
            ids_listed = {int(l.get("computer")) for l in c.chunk_loaders()}
        except Exception as e:  # noqa: BLE001 - a hiccup must not end the probe
            ctx.note("sample %d: could not read the game: %s" % (samples, e))
            return False
        for cid in miners:
            row = dump.get(cid)
            if not row or not row.get("pos"):
                continue
            x, y, z = row["pos"]
            if y < TRAVEL_Y:
                last_pos[cid] = None
                continue                     # on the ground: not the lane
            running = bool(row.get("on"))
            holds = cid in ids_listed
            loaded = "passed" in c.command("execute if loaded %d %d %d" % (x, y, z)).lower()
            moved = last_pos.get(cid) not in (None, (x, y, z))
            seen_flying["node_%d" % cid] = "%d,%d,%d" % (x, y, z)
            if holds:
                listed_while_flying += 1
            else:
                not_listed_while_flying += 1
            ctx.note("sample %d: node_%d at %d,%d,%d -- computer running=%s, chunk loaded=%s, holds a ticket=%s, moved since last=%s"
                     % (samples, cid, x, y, z, running, loaded, holds, moved))
            # A FROZEN TURTLE IS ONE WHOSE COMPUTER IS OFF. That is the state the mod's own M3 proof produces by unloading a chunk, and
            # it needs no inference across two clocks.
            if not running:
                frozen_hits.append("node_%d at %d,%d,%d (chunk loaded=%s)" % (cid, x, y, z, loaded))
            if not loaded:
                unloaded_hits.append("node_%d at %d,%d,%d (computer running=%s)" % (cid, x, y, z, running))
            last_pos[cid] = (x, y, z)
        return bool(seen_flying)

    # Watch until a miner has been seen in flight, then keep sampling for a while so one reading cannot carry the verdict.
    ctx.wait_until(sample, 900, poll=20)
    ctx.wait_until(lambda: (sample() and samples >= 14), WATCH_GAME_SECONDS, poll=30)

    ctx.note("miners seen in flight: %s" % (seen_flying or "none"))
    ctx.note("samples: %d; in-flight readings with a listed ticket: %d, without: %d; frozen readings: %d; unloaded readings: %d"
             % (samples, listed_while_flying, not_listed_while_flying, len(frozen_hits), len(unloaded_hits)))

    ctx.expect(bool(seen_flying),
               "at least one miner was seen above y %d, i.e. actually in flight (%d samples, miners seen: %s) -- without that, the "
               "checks below cannot fail and the run says nothing about the lane"
               % (TRAVEL_Y, samples, ", ".join(seen_flying) or "none"))

    # THE HEADLINE, and the one reading that needs no inference: a turtle in flight whose COMPUTER IS OFF has frozen. This is the live
    # symptom, measured the way the mod's own M3 proof measures it.
    ctx.expect(not frozen_hits,
               "no miner's computer was ever found switched off in flight (%d such readings of %d samples: %s)"
               % (len(frozen_hits), samples, "; ".join(frozen_hits[:3]) or "none"))

    # Secondary, and NOT a defect on its own: the lane going down behind a turtle is expected -- nothing is meant to hold it. It only
    # matters together with the turtle's own position, which is why it is reported beside `running` rather than asserted alone.
    ctx.note("in-flight readings where the game said that block was not loaded: %d of %d (%s)"
             % (len(unloaded_hits), samples, "; ".join(unloaded_hits[:4]) or "none"))

    # THE VERDICT, recorded not asserted.
    if not seen_flying:
        verdict = "NO READING: no miner reached travel altitude, so this run says nothing about the lane"
    elif frozen_hits:
        verdict = ("A MINER IN FLIGHT WAS FOUND WITH ITS COMPUTER OFF -- chunk loading freezes turtles on the lane for real, the card "
                   "should be re-aimed at keeping the lane loaded, and a GPS relay would not fix it")
    elif not_listed_while_flying and not listed_while_flying:
        verdict = ("A FLYING MINER HOLDS NO TICKET OF ITS OWN and never froze here -- so something else is keeping its chunks up, and "
                   "on the live lane, where nothing does, it is exposed")
    else:
        verdict = ("A FLYING MINER CARRIES ITS OWN CHUNK LOADING and never froze across this flight (%d readings, all holding a "
                   "ticket) -- so an EMPTY lane alone does not strand a healthy miner, and whatever happened live needs the ticket "
                   "itself to have failed. Chunks going down BEHIND it is normal and not the fault." % listed_while_flying)
    ctx.note("MECHANISM VERDICT: %s" % verdict)
    if shared:
        ctx.note("AND NOTE: shared tickets were found, which alone explains a turtle frozen mid-lane and woken by a passer, "
                 "independently of anything measured in flight above")
