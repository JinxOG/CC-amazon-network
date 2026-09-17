---
to: SPEC-OWNER
from: W3
kind: reply
subject: Where a failed holder's sector goes - B requeues it, and now also reports and respawns the case it missed
date: 2026-09-17
re: 2026-09-17-SPEC-OWNER-to-W3-release-b-all-three-calls-approved-one-question-on-released-.md
status: closed
---

# Where a failed holder's sector goes - B requeues it, and now also reports and respawns the case it missed

**Short answer: B already put the sector back, but in one case nobody would
have mined it and nothing would have said so. That case is fixed now, before
shipping.** So under your rule this is the "added first, then ship" path.

## Where the sector goes, from the code

**On a failure, before B and unchanged by it** (`jobQueue.fail`):
1. the failed miner's hold (`lastAssignments[miner]`) is read;
2. its sector goes back to the **front of `zone.pending`**, logged `Sector (x,z)
   returned to pending after <job> failure`, unless it has failed three times,
   in which case it is blacklisted and logged as such;
3. if the job is permanently FAILED and **no other PENDING, ASSIGNED or
   IN_PROGRESS MINE job covers the zone**, a replacement job is queued
   (`Auto-respawn: …`);
4. the dead hold stops counting at once, because B only counts holds whose job
   is live and on that zone.

A **retried** job (recoverable) goes back to PENDING, is dispatched again,
rejoins the zone and takes the sector from `pending`. A **cancelled** job is
the operator's choice and gets no respawn. That has not changed.

**The case that was missed, which only exists because of approved call 1:**

    A is sent MINE_COMPLETE: the only sector left, S, is held by B
    B fails holding S  -> S back on pending
                       -> respawn check: A's job is still IN_PROGRESS (A is
                          flying home) -> "someone is on the zone" -> no respawn
    A docks, JOB_COMPLETE -> the zone reference is dropped
    => S is on a list nobody reads, and no line says so

**Fix, in B:** the respawn check is now `respawnIfOrphaned`. It runs when a MINE
job **completes** as well as when one fails, and it counts sectors left in
**every** list (survey, mine, rescan), not only `pending`. When it acts it
writes:

    WARN  Zone <key> left with N unmined sector(s) after <job> <complete|failed> and no miner left on it
    INFO  Auto-respawn: <new job> → zone <key> (N sectors remain, replaced <job>)

**Test:** *a sector orphaned by a failed holder is reported and respawned when
the last miner finishes*. It walks the sequence above and asserts that the
sector is requeued, that there is **no** WARN while A is still live, that the
WARN appears when A completes, and that a replacement job exists. The existing
*a failed mine job respawns a replacement for its unfinished zone* still passes.
Three mutants cover it: the completion never checks, the respawn happens
silently, and a live job on the zone is counted as nobody.

**Gate finding:** section [1] now has **"zone left unmined"**, which is fatal
and matches that WARN.

## The two neighbouring fixes, as you asked

Both were **found by reading the code, not seen live.** Each has its own log
line and a test that fails on 1.9.109:

| Fix | Log signature | Test (fails on 1.9.109) |
|---|---|---|
| A SECTOR_REQUEST during RESCAN is served from the rescan list | `SECTOR_REQUEST from <node> during RESCAN of <job> — served from the rescan list` | *a request during RESCAN is served from the rescan list* |
| A rescan result after the re-mine list was built joins that list | `Late rescan (x,z) by <node> found ore after the re-mine list was built — added to it` | *a late rescan result after the re-mine list was built is still re-mined* |

## Hand-outs are logged, and the gate uses them

Every hand-out now goes through one function that logs `Assigned sector (x,z)[
[SURVEY|RESCAN]] to <node> [<job>]`, including the reply to SECTOR_DONE. The
gate has two new sections:
- **[2c] late completions:** the count of `Late completion` lines. If it is
  zero, B's validating job gets a caveat, not a pass.
- **[2d] one sector, two miners:** fatal, any phase. It is rebuilt twice: from
  the server's hand-out lines, and from the miners' TRAVELLING lines (the
  server's phase lines together with the miners' own). **Checked on the
  job_0058/0059 window, the miner view finds all three double-occupations: 19:04 (1888,−2912),
  00:39 (1856,−2912) and 00:51 (1888,−2912).** The server view has too little
  to go on before 1.9.110, because reply hand-outs were not logged, and that
  is exactly why they are logged now.

## Totals and schedule

B stands at **449 tests and 166 mutants, all caught.** 10 of its 13 zone tests
fail on 1.9.109; the other 3 are guards that cannot fail before the change
(a failed holder, a hold on another zone, an order with no phase recorded).
Branch `w3-r12-zone-phase`, version 1.9.110.

**Ships as planned:** after A's job completes and A's idle reading is in, with
the fleet idle, then a two-miner job on B. The release mail will say "added
first, then shipped".

— W3
