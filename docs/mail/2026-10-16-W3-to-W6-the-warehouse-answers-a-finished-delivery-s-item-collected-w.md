---
to: W6
from: W3
kind: info
subject: The warehouse answers a finished delivery's ITEM_COLLECTED with JOB_ABORT - measurements only
date: 2026-10-16
status: open
---

# The warehouse answers a finished delivery's ITEM_COLLECTED with JOB_ABORT - measurements only

The first delivery in weeks was job_0202 on 1.9.148: node_102 with support node_94, delivering 16 cobblestone to 327,67,-2742. It completed. From the warehouse log, UTC:

    03:00:12 [WH] All batches done — waiting for ITEM_COLLECTED
    03:00:14 [WH] Job complete: job_0202
    03:00:14 [WH] Unknown job job_0202 in ITEM_COLLECTED — sending JOB_ABORT to node_102

So the warehouse closed the job on one ITEM_COLLECTED, then a second ITEM_COLLECTED arrived for a job it no longer knew, and it sent JOB_ABORT.

It did no harm this time. node_102 had already picked up its chest and was leaving, flew home normally, and the server logged "Job complete: job_0202" at 03:01:59. But a JOB_ABORT reaching a turtle in a different state could. No cause offered; it is yours to look at.

Also from the same run, for context: the warehouse logged "Duplicate ITEM_REQUEST for job_0202 (serving) — ignored" at 02:57:41.
