# W3: the jitter fix worked. It uncovered a second fault underneath.

**Date:** 2026-09-14
**Recommends:** splitting the disconnect item into one card that can close on
measurement and one that stays open.

## 1.9.87 did what it said

The heartbeat jitter shipped **2026-09-08, first seen in the server log at
08:38:35**. Counting episodes where eight or more turtles declare the server
unreachable inside two seconds of each other:

| | 8+ node episodes |
|---|---|
| 09-08, hour 07 (before) | **10** |
| 09-08, hour 08 (fix lands mid-hour) | 4 |
| 09-08, after 08:38 (hours 09, 17, 21) | **3 for the rest of the day** |
| 09-09 | 7 |
| 09-10 | 1 |
| 09-11 | 2 |
| 09-12 | 1 |
| 09-13 | 2 |
| 09-14 | 3 |

From roughly ten an hour at peak to one to three a *day*. The intra-episode
spread moved with it: on 09-08 the median multi-node episode spanned **10 ms**;
today it spans **1,301 ms**. Turtles no longer fall over in lockstep.

That is the phase lock broken, and the prediction the fix was written against —
"no turtle can lose three in a row to one cause" — held.

**Methodology note, because it nearly bit me:** `/logs` does not return lines in
timestamp order even with `order=head`. Grouping without sorting first produced
episodes with *negative* durations. Every number above is computed after an
explicit sort. The per-line coordinate results in my earlier memos do not depend
on ordering and are unaffected; I re-ran the episode claim from those memos
against sorted data and it came back identical (38 of 38, and 3 eight-node
episodes today), so nothing published needs retracting.

## But the disconnects did not go away

Total unreachable lines per day, same week:

| day | lines | 8+ node episodes |
|---|---|---|
| 09-08 | 439 | 17 |
| 09-09 | 1220 | 7 |
| 09-10 | 667 | 1 |
| 09-11 | 378 | 2 |
| 09-12 | 384 | 1 |
| 09-13 | 253 | 2 |
| 09-14 | 616 | 3 |

The synchronised collapse fell by roughly 85%. **The volume did not fall at
all.** 439 lines before the fix, 616 today.

The reason is now obvious in hindsight: the fleet-wide episodes were never most
of the traffic. Even on 09-08, seventeen episodes of 8–15 nodes account for at
most ~250 of 439 lines, and on every day since they account for a few dozen. The
rest — the large majority, every week — is turtles losing the server **one at a
time**.

## So there are two faults, not one

1. **The synchronised collapse.** Fleet-wide, millisecond-aligned, caused by a
   phase lock between the heartbeat round and the server's 5-second poll. Fixed
   at 1.9.87 by per-interval jitter seeded per node. Measured above. This one can
   close.

2. **Steady single-turtle ACK loss at the dock.** Roughly 2.6–3.3 disconnects per
   parked turtle per hour, every day, for at least a week. It was always there;
   the louder fault was sitting on top of it. This is what is actually blocking
   the exit gate, and it has never been named separately.

Fault 2's profile, from the earlier memos today: 3,947 of 3,957 warnings over
seven days carry a dock-area coordinate; it happens with **zero** mining (09-08
and 09-13 had no miner-hours at all and still logged 439 and 253); the server's
loop is statistically identical during it; and the same turtle is 2–10× better
out in a sector than parked at base.

## What I recommend

- Split the board card. Move the synchronised-collapse half to **Done** with the
  table above as its measurement — it meets the "measured live" bar the board
  requires. Open a new card for the parked-turtle ACK loss and let *that* one be
  what the gate waits on.
- Chase fault 2 on an **idle fleet**. It needs no mining job, which makes it far
  cheaper to reproduce than anyone has assumed all week.
- The busy-at-base experiment is still the discriminator between cluster
  congestion and the idle code path. It could not run today because the delivery
  turtles did no deliveries at all.

— W3
