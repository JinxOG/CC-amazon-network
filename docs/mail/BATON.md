# The baton

**Holder: SPEC-OWNER (head engineer) - the shakeout's test-server proofs and runs. Since 2026-11-13** (W3 2026-09-15 to 11-02; W1, W5 and W3 on 2026-11-02; W3 to 11-09; W5 on 11-09; W1 11-09 to 11-10; SPEC-OWNER 11-10 to 11-11; W3 11-11 to 11-12, ATC deadlock; SPEC-OWNER 11-12 to 11-13; W3 on 11-13, replay cap, compact save, duplicate key).

**Phase:** the cleanup (`docs/superpowers/specs/2026-09-11-cleanup-phase-design.md`),
working through the holder's cards on the board until they are Done. **Next goal: the shakeout stress test**
(spec and plan approved 2026-11-09, `docs/superpowers/plans/2026-11-09-shakeout-stress-test.md`). W5's
slow-push card is done; W1's resume-after-restart card is the last prerequisite. W3 (SHAKEOUT 1) is next.

**Androids are on hold, not retired** (the user, 2026-11-02). The user is building a refresh of the CC Androids
mod and androids are coming back. Nobody removes, trims or changes an android file or android dashboard entry
until the refresh ships and the user says go. The "retired Android files" card is on the back burner.

The holder drives. Everyone else is asleep until woken, does the one thing they
were woken for, replies, and stops.

**The holder runs the cycle without stopping for the user** — build, deploy,
test, next release — and waits on long jobs in a background watcher rather than
going idle. The only reasons to stop for the user are **a stranded turtle** that
needs fetching in the world, and **anything on the server PC**. Full rule:
protocol §2, *The holder runs the cycle without stopping*.

**Only the head engineer moves the baton, and only with the user's say-so.**

## The streamlined card cycle (the user, 2026-10-27, to cut token use)

**One engineer works at a time: the baton holder.** For each card, the holder alone:

1. writes the layer-1 test, runs it in the simulator, and shows it fails on the old code and passes on the new;
2. runs layer 2 **itself** on the local test server, with `sandbox/t2/scenario.py`. Only the holder uses the
   test server, so there is no queue and no hand-off;
3. checks its own results, writes the VALIDATION block, and moves the card to **"Done - not server validated"**;
4. leaves the rest to the watcher, which confirms it from the live logs and moves it to Done.

**No relaying.** The holder does not ask SANDBOX or anyone else to run tests, and does not send progress
messages. Mail is only for:
- a question that only another engineer can answer;
- a ruling needed from the spec owner;
- the user.

**SANDBOX** maintains the simulator and test-server tools only when asked. It is not a test service.

**Everyone else stays asleep** until the head engineer, with the user's say-so, hands them the baton.

## History

| From | To | Date | Why |
|---|---|---|---|
| — | W3 | 2026-09-15 | First holder. The cleanup's Wave 2 queue is almost entirely W3's |
| W3 | W1 | 2026-11-02 | W3's workable cards are all through both layers; the user hands the baton to W1 to work its cards the same lean way |
| W1 | W5 | 2026-11-02 | W1's queue is empty (six cards closed, three not startable); the user hands the baton to W5 for its dashboard cards |
| W5 | W3 | 2026-11-02 | W5's workable cards are done except the slow-push reproduction, which waits for a quiet host; the user hands the baton back to W3 for the disk card and two newly assigned cards |
| W3 | W5 | 2026-11-09 | W3's cards are all through both layers (ATC, disk, GPS 2, DUMPING facing, inbox leak); the user hands the baton to W5 for the bridge slow-push card, a shakeout prerequisite |
| W5 | W1 | 2026-11-09 | W5's slow-push card is done (host starvation, not the bridge; eee8bc1); the user hands the baton to W1 for the resume-after-restart card, the last shakeout prerequisite |
| W3 | SPEC-OWNER | 2026-11-10 | The user wants the shakeout code built now with fewer open instances; the head engineer builds plan Tasks 1-7 (W3's per-bay types and SANDBOX's kit) itself. W3 and SANDBOX stay asleep |
| SPEC-OWNER | W3 | 2026-11-11 | The shakeout kit is built and pushed (b8d5ed0); its per-bay sim found an ATC x delivery/support deadlock at the dispatch hole that is also on master. The user hands the baton to W3 to fix it (and the NEEDS HANDS 'facing unknown' card), then back to SPEC-OWNER for the T2 proofs |
| W3 | SPEC-OWNER | 2026-11-12 | W3 fixed the ATC dispatch-hole deadlock (two circles) and the NEEDS HANDS 'facing unknown' card through both layers (w3_bay_types150 passes every check, verified by SPEC-OWNER); the baton returns for the shakeout's T2 proofs and runs, as the user agreed 2026-11-11 |
| SPEC-OWNER | W3 | 2026-11-13 | shakeout-faults-a found two fleet blockers for the 24-hour run: the dispatch computer's disk fills under shakeout load (one 36-sector zone's survey, saved twice and spaced out), and after a bridge restart its log replay (~1 MB) is refused as too large forever. With the dropped same-millisecond commands from shakeout-fleet-d, the user hands the baton to W3 for the three approved fixes, then back to SPEC-OWNER for the rest of the shakeout |
| W3 | SPEC-OWNER | 2026-11-13 | W3's three fixes are through both layers (f856df1, 975a3ad; T2 w3-push-cap-a 22 of 22 checks pinned 903f354; Lua suite 890 of 890, verified by SPEC-OWNER). The baton returns for the rest of the shakeout, as the user agreed when handing it over. The disk card waits on SPEC-OWNER's dress-rehearsal reading |
