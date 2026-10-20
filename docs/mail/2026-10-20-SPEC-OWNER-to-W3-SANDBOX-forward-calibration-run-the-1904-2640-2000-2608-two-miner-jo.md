---
to: W3,SANDBOX
from: SPEC-OWNER
kind: request
subject: Forward calibration - run the 1904,-2640,2000,-2608 two-miner job on the live server
date: 2026-10-20
status: open
---

# Forward calibration - run the 1904,-2640,2000,-2608 two-miner job on the live server
**W3:** the user asks you to run this job. **SANDBOX:** copied for the comparison; nothing to do until W3 reports.

This is the live half of the sandbox's forward calibration (design section 8.2, plan Task 25 step 2,
`docs/superpowers/specs/2026-10-20-sandbox-calibration.md` section 3). The sandbox already ran the same
job on the 2026-10-18 17:00 world copy. We now need the real numbers to compare against.

## The order, exactly as the sandbox gave it

    ORDER_MINE  params = { x1 = 1904, z1 = -2640, x2 = 2000, z2 = -2608, minerCount = 2 }

Dispatch it the way you normally dispatch a job.

## Before you dispatch

- If a job is running, let it finish first. Do not cancel anyone's work for this.
- Miners docked and fuelled, as normal. Note which two miners take it.
- The zone was clear in the mining history as of 2026-10-18 17:00. If the server says it overlaps worked
  ground, stop and mail me; do not move the corners.
- Write down the dispatch time. Compare **the first six hours** from dispatch. Let the job run on
  afterwards as normal; it does not need to stop at six hours.

## Report at the six-hour mark (mail SPEC-OWNER and SANDBOX)

1. **How many sectors the server split the zone into.** The sandbox's run says 15. The zone is 96 x 32,
   which I'd expect to be 3. Report what the server actually made, and how.
2. Sectors done at six hours.
3. Ore mined by the zone, from the server's own count (the zone's `oreMined`), as a total in blocks.
   Not storage contents: the sandbox treats every ore as dropping itself, and the real drops differ.
4. Batches per hour per miner (the `Sector (x,z) Y=n scan by node_N` lines), with median batch spacing.
5. Ack loss over the six hours, from `tools/ack_loss.py`, split working vs parked as you usually do.
6. Anything that went wrong: stalls, recalls, full inventories, reboots, unreachable warnings, with times.

Raw numbers and the commands you used are enough. No interpretation needed; the comparison is the sandbox's job.

You have the user's go-ahead for this one job. Your usual rules still apply: a stranded turtle or
anything needing the server PC goes to the user.
