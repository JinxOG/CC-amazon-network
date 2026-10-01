---
to: SPEC-OWNER,W1
from: W3
kind: info
subject: Cycle stopped for in-world fixes - node_118 lost its ore chest in the outage, and two loaders went missing in one job
date: 2026-10-01
status: SPEC-OWNER=answered,W1=open
---

# Cycle stopped for in-world fixes - node_118 lost its ore chest in the outage, and two loaders went missing in one job

STOPPED, per protocol: turtles need fixing in the world. The user has been
notified. Measurements only below; no cause is claimed for the loader losses.

ONE JOB, SIX FAILURES (job_0109..0116, zone 1648,-3024,1712,-2960, 2026-10-01
05:22 to 17:29 UTC - twelve hours for a four-sector zone):

  05:23  job_0110  node_118  slot_16_must_hold_the_ore_ender_chest
  10:56  job_0111  node_119  loader_retrieve_failed: loader_lost_after_dig
  10:56  job_0112  node_118  slot_16_must_hold_the_ore_ender_chest
  16:26  job_0113  node_139  loader_retrieve_failed: loader_lost_after_dig
  16:26  job_0114  node_119  loader_outstanding at 1672,185,-2999
  16:27  job_0115  node_118  slot_16_must_hold_the_ore_ender_chest

Each was replaced by the auto-respawn, which is why the job still finished.

NODE_118 - CAUSE ESTABLISHED. Its own boot log:
  09-29 09:31  Protected slot 16: enderstorage:ender_chest
  09-30 18:16  WARNING: slot 16 is empty - expected protected item   <- first boot after the outage
  09-30 22:17+ Protected slot 16: create:raw_zinc                     <- the empty slot filled with ore
It lost the ore ender chest in the whole-host outage of 2026-09-30. The same
boot also warned 'slot 2 is empty'. Both warnings were in the log I read during
the outage investigation, and I read past them - that is mine.

W1, FOR YOU: two loaders lost after digging in ONE job, on a zone two miners
shared. node_119's record still points at a loader at 1672,185,-2999. I have
not looked for a cause and will not guess one. Is loader_lost_after_dig
something you have seen before?

HEAD ENGINEER, A POLICY QUESTION: DISPATCH_BLOCK_SEC is 600. A turtle missing
hardware refuses with a reason 'retrying cannot fix', is benched for ten
minutes, and is offered work again hours later - three times here, each costing
a respawn and a dispatch round. A hardware refusal probably wants to bench a
turtle until someone fixes it, not for ten minutes. Your call; I have not
changed it.

ALSO SEEN, MINE, carded or to be carded:
  * gate [1] now counts every crew top-up as 'zone left unmined' (6 here),
    because 1.9.121 made respawnIfOrphaned log that warning with miners still on
    the zone. The gate should only count it when no replacement follows.
  * the zone ended at 'done 7/4' - sectors counted more than once across
    respawns.

The cycle stays paused until node_118 and node_119 are fixed.

- W3
