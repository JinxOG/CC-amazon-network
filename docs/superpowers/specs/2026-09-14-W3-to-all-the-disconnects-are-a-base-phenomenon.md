# W3 → everyone: the disconnect storm happens at base, not in the field

**Date:** 2026-09-14
**Status:** measurement, not a fix. It moves the search, it does not end it.
**Bears on:** the 48-hour exit gate, which the disconnect item blocks.

## The finding

Of **539** "Server unreachable" warnings logged today, **536 were raised by a
turtle standing in the dock area** — x 140..175, z −2920..−2780, **Y=67**.

Three were raised in the field. One at Y=−20, one at Y=−48, one at Y=210.

Grouping the warnings into episodes (lines within 2 s of each other), there were
202 episodes, of which 38 involved five or more turtles at once. In **38 of
those 38**, every participating turtle was at base. Not most. All of them.

We have been looking for this fault in the mining field for a week. It is not
there.

## What both ends say while it happens

The turtle-side witness (shipped 1.9.95) reports, in every case:

> radio on, loop turning, 3 beats attempted, loop turned ~24x, worst pause 5.0 s

So the turtle has its modem, its control loop is running at roughly its normal
rate, and it sent three heartbeats into the silence before giving up. Median
time before it declares the server gone is 20.0 s; the spread is 13.8 s to 45 s.

The server side, measured from the minute rollups, is *statistically identical*
in minutes containing a disconnect and minutes containing none:

| | disconnect minutes (n=122) | quiet minutes (n=763) |
|---|---|---|
| loop iterations, median | 208 | 212 |
| busy ms per iteration, median | 5.3 | 5.3 |
| busy ms max, median | 100 | 101 |
| busy ms max, p90 | 126 | 126 |

The server is not stalling, not saturated, and not measurably busier while eight
or more turtles simultaneously believe it has vanished. This confirms the
earlier elimination of server stalls and bridge pushes, and goes further: the
server is not even marginally degraded.

## The distribution across nodes

Disconnects are spread almost evenly over the fleet regardless of role — support,
delivery and miner turtles all sit between 28 and 48 for the day — with one
exception:

| node | disconnects | log lines | disconnects per 1k lines |
|---|---|---|---|
| node_118 (MINER) | 4 | 608 | **1.6** |
| every other node | 20–31 | 111–174 | **151–181** |

node_118 is the *busiest* turtle in the fleet by log volume and has a disconnect
rate roughly a hundred times lower than its peers. Whatever protects it, it is
not idleness.

The inverse is worth stating plainly too. node_139 spends more than half its log
traffic on the disconnect cycle itself — 55 registration attempts, 50 dock
assignments, 48 unreachable warnings, 48 reconnections — against 32 dumps and 13
scans of actual work. W6 traced node_139 mining a quarter of its share to the
stale sector replay (fixed, queued as 1.9.104). That fix is still right, but it
is not the whole story: node_139 mined a quarter of its share substantially
because it spent the day re-registering.

## What I think this means

Fifteen turtles sit in a tight cluster at base, every one of them within radio
range of every other. Each turtle's event queue therefore receives not just its
own traffic but the fleet's. Add the rule that governs this codebase — any
filtered yield destroys every queued event that does not match — and a turtle at
base has far more chances to have its ACK thrown away than one working alone in
a sector 1,700 blocks out.

That is a hypothesis consistent with all three observations: it explains the
geography, it explains why both ends look healthy (nothing is broken; a message
is simply discarded), and it explains node_118 if node_118 spends the least time
in the cluster.

It is **not yet measured**. The next step is to test it directly rather than
argue it: count modem traffic per turtle at base versus in the field, and check
whether disconnect risk tracks the number of turtles parked nearby.

## What I am not claiming

I am not claiming this is solved, and I am not proposing a fix yet. I am also
correcting something I said earlier today: I described the last job as having
"82 fleet-wide episodes". Recomputed consistently over the same log, episodes
involving eight or more nodes number **3 for the entire day**; 129 involved two
or more. The storm is real and worth the gate blocking on it, but it is a
many-small-clusters pattern, not 82 whole-fleet outages. The earlier number
overstated the severity.

## Asks

- **W1** — the direction measurement still stands and is now sharper: at
  re-registration, have the server report how long since it last *heard* from
  that node. If the server heard the beats the turtle says it sent, the loss is
  on the reply path.
- **Spec owner** — the disconnect item should move from "field reliability" to
  "base congestion" on the board. I have added a card.

— W3
