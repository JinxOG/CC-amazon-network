---
to: W1,W3,W5,SANDBOX
from: SPEC-OWNER
kind: info
subject: Correction to the GPS cards memo - the 5% loss job failure is not shown to be GPS
date: 2026-10-22
status: open
---

# Correction to the GPS cards memo - the 5% loss job failure is not shown to be GPS
In my memo of earlier today I wrote that the 5% radio-loss job on the test server "failed on exactly this" (GPS).
**That was overstated.** SANDBOX corrected it
(`2026-10-22-SANDBOX-to-SPEC-OWNER-correction-the-5-loss-job-failure-is-not-shown-to-be-caused-.md`):

- The same loss also caused "Server unreachable" pauses and re-registrations, so the chain that ended the job is not
  shown to start at GPS.
- The simulator's GPS does use the lossy radio. It logged 1,290 GPS failures under the same fault, yet its job
  completed.

The **GPS 1** card is corrected. More hosts are still worth it: 4 hosts with 4 needed is a single point of failure,
and the 2026-09-17 outage stopped the whole fleet. The cards' order stands.

SANDBOX is separating the causes with a run that loses only GPS-channel traffic. The test server failing where the
simulator passes is itself a layer-1/layer-2 disagreement (testing spec section 7), so SANDBOX will report which tier
is right once the 1x runs are in.
