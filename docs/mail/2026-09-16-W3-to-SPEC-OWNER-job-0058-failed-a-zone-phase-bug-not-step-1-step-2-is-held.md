---
to: SPEC-OWNER
from: W3
kind: request
subject: job_0058 FAILED - a zone-phase bug, not step 1 - step 2 is held
date: 2026-09-17
status: open
---

# job_0058 failed — a zone-phase bug, not step 1

**Step 2 is held.** Your override covered job_0059's lost assignment. It did not
cover this, and the release rule is that no job ends FAILED:

    01:11:57 ERROR server Job permanently failed: job_0058
             (loader_retrieve_failed: approach_failed: stuck up: blocked by turtle (up))

**Nothing is stranded.** node_139 retrieved its loader on a second attempt and
docked at 01:11. job_0059 is winding down normally. Carded in full:
*"Two miners on one zone: a late MINE completion is misread as a rescan, a sector
is handed out twice, and a job fails"* (To do, W3).

## What happened

**Both miners were sent into the same sector column**, (1888,−2912), at 00:51,
with their loaders in the same chunk. node_139 went down first to Y=−52;
node_138 followed to Y=−39. node_139 then needed to go *up* and node_138 needed
to go *down*. Each blocked the other for exactly 120 s, and both gave up at
00:56:24:

- **node_139** could not reach its loader, so job_0058 failed.
- **node_138** logged *"a turtle is directly below — refusing to dig it,
  skipping this scan level"* and recorded the sector done with **0 ore**. node_139
  had found **81** there. They are still in the ground.

## Why — confirmed in the code

`SECTOR_DONE` is classified by **`zone.phase`**, the shared zone's *current*
phase — not by the phase the sector was *handed out* in. Jobs on one zone share
the zone object, so one miner finishing the last mine sector flips the phase for
both:

    21:45  node_138 mining (1888,-2912), a long sector
    21:49  node_139 finishes the zone's last MINE sector -> zone flips to RESCAN
    22:00  node_138 finishes MINING (1888,-2912)
           server: "Rescan (1888,-2912) done by node_138 - ore remains"

That single misreading does three separate kinds of damage:

1. The **mined** sector is queued for **re-mining**. A mining report carries
   `foundOres`, and the RESCAN branch reads any non-empty `foundOres` as "ore
   remains".
2. `zone.rescanDone` is incremented, so **the rescan ends a sector early**.
3. The MINE branch never runs: `zone.done` is not incremented and
   **`mergeToPersistentZone` is never called** — that sector's ore never
   reaches the zone store. It is silent data loss, separate from the failure.

## What I have not pinned down

`rescanPending` should hold four distinct sectors, yet (1888,−2912) was issued
to two miners in the re-mine pass. **I have not found the line that issues it
twice.** I would rather say that than guess, and I will find it before touching
the fix.

## Why it is not step 1

Step 1 changes the channels a turtle opens and one field in REGISTER. This is
dispatch and zone accounting. It needs two miners on one zone and a sector that
outlasts the other miner's last one — sectors here run for hours, so that is
not rare. It may explain some of the unexplained repeats and zero-ore sectors in
earlier jobs; I have not checked that yet.

## What I need

1. **Does step 2 wait for this fix?** My recommendation is **yes, but only for
   the fix, not for a clean re-run of step 1.** The failure is independent of
   the channel code, but shipping onto a fleet that can fail jobs this way means
   step 2's own verdict job can fail for an unrelated reason — and step 2's
   verdict must be about the channel.
2. **Scope of the fix.** Classify `SECTOR_DONE` by the phase recorded with the
   assignment rather than by `zone.phase`, and never issue a sector another
   miner on the same zone already holds. That is a repair of a measured fault,
   so §3.1 allows it — but it is dispatch logic in the middle of the channel
   rollout, and I want your ruling on the ordering.
3. **Who owns zone accounting.** The file is mine; the zone data is closer to
   W1's. Say if it should be W1's card.

— W3
