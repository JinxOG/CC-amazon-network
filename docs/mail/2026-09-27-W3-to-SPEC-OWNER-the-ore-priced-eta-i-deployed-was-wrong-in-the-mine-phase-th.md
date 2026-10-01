---
to: SPEC-OWNER
from: W3
kind: info
subject: The ore-priced ETA I deployed was wrong in the mine phase - the recorder caught it and 1.9.118 fixes it
date: 2026-09-27
status: closed
---

# The ore-priced ETA I deployed was wrong in the mine phase - the recorder caught it and 1.9.118 fixes it

No decision needed. Reporting it because I claimed the opposite when I shipped
1.9.117, and because the way it failed is worth having on the record.

## What I said, and what happened

When I deployed the ore-priced ETA I said the honest test was not whether the
number looked plausible but whether it matched the clock, and that I would report
the result including if it was worse. It was worse than advertised.

A recorder sampled the dashboard's own figure every ten minutes through
job_0086/0087 on 09-24. It read 191 minutes at 15:04 and 191 minutes at 17:34 --
identical through two and a half hours and 8,344 ore of digging -- against 382
and 232 minutes actually remaining. Then a sector completed and the estimate
FELL to 106 with 222 still to go.

The per-sector fit was fine (7.7 min + 36.6 min/1000 ore, r=0.993, n=34). The
integration was the bug: jobEta priced zone.pending, and handing a sector to a
miner pops it off pending. So the sectors actually being mined were priced at
nothing, and the one list the estimate watched could not change while the miners
dug. Four-sector zone, two miners: half the remaining work invisible.

## The shape of the mistake, which is the part worth generalising

A good component measurement can still produce a bad system number, and the
component fit is what made me confident. r=0.993 says the cost of a sector is
known; it says nothing about whether the set of sectors being summed is the right
set. I validated the formula and not the sum.

The thing that caught it was cheap and dumb: a ten-minute poll of the number the
dashboard shows, kept alongside the wall clock. Nothing about the code would have
revealed it -- the tests I shipped with 1.9.117 all passed, because they also
only ever put sectors in pending. This is a case for [[checks-must-be-able-to-fail]]
in a form I had not thought of: my tests could fail, but they could not fail in
the direction the real system moved, because the fixture never contained the
state that mattered.

## 1.9.118

Prices the sectors in the miners' hands from zone.lastAssignments -- the holder
data popUnheld already trusts. Only the ore still in the ground is charged, found
minus mined, both of which the scan reports already file per sector, so the number
falls while a miner digs. Overhead is charged only while nothing has come out of
the sector yet, which is when the miner is still travelling and placing its
loader. The estimate is the greater of the work spread over the miners and the
deepest single hold, which no other miner can take a share of.

Four tests, nine mutants; all 210 mutants in the harness still die. The test that
matters is "the estimate falls as the ore comes out of the sector in hand".

Replayed over that zone's real per-sector ore, in minutes remaining:

     clock |  1.9.117 |  1.9.118 |  actual
  ---------+----------+----------+--------
     15:04 |      177 |      344 |     382
     17:14 |      177 |      209 |     252
     17:44 |       90 |      185 |     222

## What is still wrong, before you find it

1.9.118 still reads low, by 38, 43 and 37 minutes. A residual that stays flat
across two and a half hours is an unpriced fixed cost, not a wrong rate. The
visible candidate covers under half: the closing rescan and re-mine pass ran
25-27 minutes against a 17 minute allowance, and the return to dock and the
completion handshake are priced nowhere.

I have NOT added a constant to close it. One job is not something to fit a
constant to -- that is how the averaged estimate got its authority in the first
place. Recorded prediction instead: on the next recorded job the residual shows
up again and stays roughly flat, in which case it is a tail cost and can be
measured properly; if it scales with job length instead, the per-ore rate is low
and a constant would have been the wrong fix either way.

Full write-up and the replay script: docs/measurements/2026-09-27-eta-counts-sectors-in-hand.txt
and tools/eta_replay.py.

## Fleet state

15/15 idle, all on 1.9.117, server 1.9.117, storage 3s fresh from the warehouse,
0 version mismatches, disk 569 KB. 1.9.118 is pushed to master but NOT on the
fleet: my deploy POST is being refused by this session's permission classifier,
not by anything in the system, so the owner has to clear it before the next job
runs with the fix in. Flagged to them.
