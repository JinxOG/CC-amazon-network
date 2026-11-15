---
to: SPEC-OWNER
from: W3
kind: reply
subject: Stranded supports fixed: pin 360d551 - w3_side_atc passes every check (48 of 48), T2 13/13; baton back
date: 2026-11-14
re: docs/mail/2026-11-14-SPEC-OWNER-to-W3-ruling-fix-the-stranded-supports-before-the-24-h-run-the-use.md
status: open
---

# Stranded supports fixed: pin 360d551 - w3_side_atc passes every check (48 of 48), T2 13/13; baton back
**Pin: `360d551`.** The baton is back with you. The test server and host are free: no java process, nothing on :3000, no sim running. No frozen file was touched: everything is in turtle_base.lua, atc.lua, waypoints.lua and central_server.lua.

## Your four done-whens

1. **w3_side_atc.lua passes every check.**
   - All 48 deliveries done, no support left in the tunnel, every turtle docked, the ATC holds nothing, worst wait to be let in 190 s, nobody STUCK.
   - On eea9424 the same scenario fails the new check: 6 supports in the tunnel, 23 of 26 delivered.
2. **Regressions pass.**
   - w3_bay_types150: 34/34 deliveries, 32 supports, 16 mine jobs, worst wait 160 s, nobody STUCK.
   - w3_atc_pair_split, w3_atc_partner_left and w3_atc_support_gave_up all pass; w3_depart_off_dock 9/9.
   - Suites 905/0 on both builds; CC local limit: turtle_base 147, atc 47, central_server 195.
   - w3_atc_small still fails its one check identically on 152baeb, so it's not this.
3. **T2 w3-depart-off-dock-e** (pin 360d551, one pair, 1x; warehouse off, ATC crash for 2 min, total blackout for 5 min): 13 of 13 checks.
   - Support node_145 went home alone, "Partner offline": a lost query while its delivery waited at the warehouse. That's the trigger that stranded node_141 on eea9424.
   - It met rock, logged "retracing the 143 step(s) I came by", booked DH and its way home, climbed the shaft and docked.
   - Its delivery then held its own failure back ("bringing support node_145 home first"), came home, and completed the job when it was given it back.
   - ATC empty at the end, all 16 turtles docked, GPS back after 307 s.
   - The hold-back path itself (the delivery bringing a support that is still with it) is proven in the sim, not on T2: there the support was already home.
4. **Pushed.** This is the reply.

## What it took

Fixing the stranding uncovered five more things that stopped a base from clearing after a blackout. All are fixed, and each has a test that fails without its change.

- **A failed job brings the support home** (c04c3ce). A delivery whose job fails out in the world holds the report back, brings its support home as after a delivery, then reports it. A JOB_ABORT here used to send the support home alone, through rock.
- **The way it came** (c04c3ce). A turtle that can't dig keeps every cell since it left the floor and walks it back when:
  - its way home is shut;
  - it is in the dispatch shaft;
  - or it is kept 120 s from the only slot it may take.

  It books the shaft and its way home before the no-sidestep zone. Waiting at the shaft's foot, it had stood in the one cell a departing delivery needed.
- **ATC fairness** (c04c3ce). A turtle standing in a section is never held back by fairness, only by what's occupied. Held back, it closed circles through chains of waiters: one in DH behind returns that were behind a request waiting for that DH.
- **ATC blackout** (c04c3ce). Silence counts only while others are heard. In a total blackout the sweep had taken the sections turtles stood in and granted them to others.
- **Holding-line approach** (4ea9e9d, 22c41ee).
  - From the taxi row's side (destinations south of the base, like 196,-2761, which the feeder orders), the approach crossed the taxi row. A support then stopped on it, inside ARR, and its delivery waited for its own support.
  - It now goes round, and stays clear of ARR even for a follower up to 4 behind. One block closer, a lagging support cut the corner into the shaft's foot and held ARR for 18 minutes.
- **Server and delivery** (360d551).
  - A blackout times no turtle out on the server. It had requeued a job while its delivery still stood at the destination, and the job failed three times.
  - A delivery out in the world ignores its own support's JOB_ABORT and carries on alone ("job_aborted_at_destination" had failed an order for good). The warehouse's JOB_ABORT still counts.
  - A partner's JOB_ABORT from an earlier job is ignored.
  - Before going home from a job that ended away from the dock, a turtle takes back what it placed there. A delivery had left its ender chest behind, and every job after failed at dispatch.

## For your re-run of shakeout_side

These change behaviour the side test exercises everywhere: the ATC's fairness and its sweep, the arrivals approach from the south, and how failed jobs end. Worth noting:

- A failed job's report now waits until the delivery and its support are home. The server sees the failure minutes later than before, and the job stays assigned meanwhile.
- A retracing support holds DH and its way home while it walks back near the depot, typically a minute or two. Departures wait for it.
- **What is not covered:** a support that *reboots* in the tunnel loses its trail, since the trail is kept in memory only, so walking back is not available after a reboot. Boot recovery is as before.

The card is in "Done - not server validated", with the validation block.
