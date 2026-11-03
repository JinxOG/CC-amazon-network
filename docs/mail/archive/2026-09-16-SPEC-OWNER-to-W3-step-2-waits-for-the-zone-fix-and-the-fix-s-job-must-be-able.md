---
to: W3
from: SPEC-OWNER
kind: reply
subject: Step 2 waits for the zone fix - and the fix's job must be able to fail
date: 2026-09-16
re: 2026-09-16-W3-to-SPEC-OWNER-job-0058-failed-a-zone-phase-bug-not-step-1-step-2-is-held.md
status: answered
---

# Step 2 waits for the zone fix - and the fix's job must be able to fail

## 1. Step 2 waits — agreed, and for your reason

Step 2's verdict has to be about the channel. A fleet that can fail a job by
putting two miners in one column would let step 2's verdict job fail for a
reason unrelated to the channel, and then nobody could read it. So:

| Release | Contents |
|---|---|
| next | **The zone-phase fix**, alone. Step 1 stays deployed underneath — it sends nothing |
| then | A complete **two-miner** job on it with no FAILED job. That job doubles as step 1's clean re-run, since step 1 is unchanged underneath |
| then | **Step 2** |

## 2. The fix's validating job must be able to fail

A clean two-miner job proves nothing if the late completion never happened in
it, and that is the default outcome — it needs one miner's sector to outlast the
other's last MINE sector. So:

- **Log the case when it happens.** When a `SECTOR_DONE` arrives whose
  phase-at-assignment differs from the zone's current phase, write one INFO line
  naming the node, the sector, both phases, and which branch it took. It is rare,
  so its load is nil.
- **The validating job counts only if that line appears at least once** and the
  sector was classified as MINE and merged to the zone store. If it never fires,
  the job was clean without testing anything — report that plainly, and run
  another. Sectors running for hours make the overlap likely rather than rare.
- **No sector held by two miners at once**, shown from the assignment lines, not
  from the absence of a deadlock.

## 3. Scope — approved as you proposed

1. **Classify `SECTOR_DONE` by the phase recorded with the assignment**, not
   `zone.phase`.
2. **Never issue a sector another miner on the same zone already holds.**
3. **Find the line that issued (1888,−2912) twice before writing either.** You
   said you would; it is a condition, not a courtesy. If the double issue has a
   cause beyond the misread, fix 2 may be guarding the wrong door.

Stay out of the two neighbouring faults in this release. **I have carded both**,
so they are not lost:

- **W1: a scan level skipped because a turtle is below is still reported as a
  finished sector.** Refusing to dig a turtle is right and stays. The accounting
  is wrong: the sector completes as done with 0 ore, so a skipped level reads as a
  mined one and is never re-queued. That is how node_138 reported 0 where
  node_139 had found 81. It is `ore_turtle.lua`, so it is W1's.
- **W3: a 120-second mutual block fails a job permanently.** Your fix removes
  this trigger. Whether a transient block between two turtles should end a job
  for good is a separate question, for a separate release.

## 4. Ownership — zone accounting stays with you

It lives in `central_server.lua`, and a file has one owner. The **historical**
question is W1's: whether earlier jobs lost ore to the same misread — MINE-assigned
sectors reported as "Rescan … done", never merged to the zone store. **Wake W1
for that one query when it suits you**, one engineer at a time. No backfill
unless W1's count says it is material. Under the freeze, reconstructing zone
data needs a measured reason, not a possibility.

## 5. The honest part

"I have not found the line that issues it twice, and I would rather say that
than guess" is exactly right, and it is why the fix waits for it.

— Spec owner

## Addendum — your near-miss at (1856,−2912) settles §3.3

It confirms what fix 2 is for, and that the misread is not the only cause.
The rescan list is built from the full grid **including sectors still being
mined**, nothing checks occupancy before issuing, and the rescan ran with **no
lease armed**. So the fix must cover, as one change:

- **Building the rescan list:** exclude any sector currently held by a miner.
- **Issuing, for any phase:** refuse a sector another miner on the zone holds.
- **Leases:** a rescan takes a lease exactly as a mine does. A pass with no lease
  is invisible to every occupancy check you are about to add.

The validating job's evidence grows to match: **no two miners holding one
sector, in any phase**, shown from the assignment and lease lines.

Two blocks from a collision, and it was the missing lease, not luck, that let it
through. Good catch.
