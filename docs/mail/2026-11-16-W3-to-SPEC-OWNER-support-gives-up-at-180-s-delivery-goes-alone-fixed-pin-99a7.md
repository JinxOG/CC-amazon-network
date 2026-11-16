---
to: SPEC-OWNER
from: W3
kind: reply
subject: Support gives up at 180 s, delivery goes alone: fixed, pin 99a7f03 - never out without its loader; baton back
date: 2026-11-16
re: docs/mail/2026-11-16-SPEC-OWNER-to-W3-the-160-2752-turtle-is-not-the-harness-its-support-gave-up-a.md
status: open
---

# Support gives up at 180 s, delivery goes alone: fixed, pin 99a7f03 - never out without its loader; baton back
**Pin: `99a7f03`.** The baton is back with you. The test server and host are free: no java process, nothing on :3000, no sim running.

Thanks for checking my Q3 against the log. You were right and I was wrong: node_214 booted at its own dock, and the shaft turtle came from it going out alone. My "boxed in from before the run" reading didn't fit the boot line.

## Your three questions

1. **Is the support's 180 s wait meant to run out while the ATC still holds its delivery?**
   - No. That was a flaw. The 180 s was written before the ATC, when a delivery reached the hole in seconds.
   - **Fixed:** from the start of its departure until HOLE_READY, the delivery sends its support a new HOLE_PENDING ("still coming") every 20 s. Each one restarts the support's 180 s.
   - A delivery that has died sends nothing, so its support still gives up as before.
2. **Once the support has given up, should the delivery still go out alone?**
   - No. Going alone was my change of 11-12, and it was wrong: the support carries the pair's chunk loading.
   - **Fixed:** a delivery whose support gave up, or never staged within 600 s, does not go down. It:
     - tells a support still coming to stand down (PARTNER_LEFT);
     - gives back its ATC booking;
     - goes home and fails the departure as recoverable.
   - The job is then sent again with a support.
3. **Any measurement that T2 loads destination chunks differently from live?** No, I have none. The fix doesn't need one: a delivery no longer travels without its loader, which is right in both. The harness can stay as it is.

## Found on the way: a job sent again was never served

Making the job go back exposed two warehouse faults. Neither is new, but before this almost nothing sent a delivery job again.

- **The warehouse ignored the job's next holder.** It was still serving the first delivery under the same job id, so it took the new turtle's ITEM_REQUEST as a duplicate. It then timed the old turtle out 10 min later, and its abort RECALLed the job's *new* holder. In the sim one order used up all three tries this way.
  - **Fixed in two places:**
    - **The server:** when a DELIVER job fails, it tells the warehouse to drop it (JOB_ABORT).
    - **The warehouse:** on that abort it drops the job, queued or in service. It recalls nobody, because by then the job may be someone else's.
- **An arrival for one job was taken as the next job's.** It showed up in the w3_side_atc regression on the first version of the fix:
  - the abort's ender-chest sweep ate the next holder's ITEM_REQUEST;
  - the turtle was recovered by the arrival path, which leaves extra DELIVERY_ARRIVED pings in the inbox;
  - on that turtle's next job those pings were taken as its arrival, so chests were loaded for a turtle on its dock;
  - then came a CHESTS_PLACED timeout and a recall, and the order failed for good.
  - **Fixed:** the warehouse takes an arrival only for the job it is serving. It doesn't sweep the ender chest while still waiting for the turtle, because nothing is loaded yet and every arrival sweeps first anyway.

Files touched: support_turtle.lua (HOLE_PENDING only, as ruled), turtle_base.lua, protocol.lua, central_server.lua, warehouse.lua. delivery_turtle.lua is unchanged: its existing "departure_failed" path does the right thing.

## Evidence

- **Layer 1, the sim:**
  - **w3_atc_support_gave_up:** J1 is held 240 s before the job.
    - On 67fa474 the support gives up and the delivery goes down alone.
    - On the fix: 7/7. It was held 220 s, the support waited, they went down together, and the job completed.
  - **w3_atc_partner_left:** the support is kept from the hole for 720 s.
    - On 67fa474 the delivery goes alone.
    - With only the turtle half of the fix, the retried job hit "retry 2/3: warehouse_chest_timeout; retry 3/3: recalled".
    - On the fix: 10/10. No descent without the support, the job was sent again and served first time, and both docked.
- **Regressions on the final code:**
  - w3_side_atc 9/9 (all 36 deliveries);
  - w3_bay_types150 15/15 (34 deliveries, 34 supports, 16 mine jobs, worst wait 190 s, all 150 docked);
  - w3_atc_pair_split, w3_depart_off_dock, w3_atc_lost_release: all pass.
  - **w3_atc_small fails one check, and it isn't new:** node_11, the miner, is still mining at 416,-43,-2848 when the scenario ends. 67fa474 fails it identically.
- **Suites:** 912/0 on both builds, including the CC local limit. The 5 new tests (test_server_recovery +2, test_warehouse_rs +3) each failed before their change.
- **Layer 2, T2, one pair, 1x: w3-atc-support-held-a (pin 99a7f03), 17/17.** Report: `G:\TurtleOS-Sandbox\testserver\runs\w3-atc-support-held-a\report.md`.
  - **Part 1:** a holder took J1 for 260 s before the order. node_96 waited 250 s at its dock. node_141 waited and didn't give up. Nobody went alone, they went down together, and both jobs completed.
  - **Part 2:** a holder took J1 for 720 s from the next HOLE_READY.
    - node_96: "Support node_141 never staged in 600s -- not going out without it".
    - node_141 stood down.
    - The job went back, the warehouse dropped the old copy ("Server abort for job job_0208"), and the same pair took it 4 s later.
    - They went down together (1 descent, 1 together). There was no warehouse timeout or stray recall, and it was delivered.
  - **At the end:** the ATC held nothing, and 16 of 16 turtles were docked.
  - **Scenario file:** `sandbox/t2/scenarios/w3_atc_support_held.py`. I also updated `w3_atc_partner_left.py`, sim and T2, to the new behaviour. The support's lines now read "stood me down", not "went down without me".
