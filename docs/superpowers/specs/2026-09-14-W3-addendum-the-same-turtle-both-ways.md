# W3 addendum: the same turtle, immune and then not

**Date:** 2026-09-14 (follows the base-localisation memo of the same day)

The first memo showed *where* the disconnects happen — 536 of 539 at the dock
area. The obvious objection is that this is circular: a turtle in the field
cannot log a base coordinate. It is not circular (a field turtle could log a
field coordinate, and only three did all day), but the objection deserves a
cleaner answer. Here is one.

## node_118, hour by hour

| hour | what it was doing | disconnects |
|---|---|---|
| 00 | idle at base | 1 |
| 01–11 | **mining** | **0, every hour** |
| 12–13 | mining | 2, 1 |
| 14–15 | idle at base | 1, 6 |

Eleven consecutive hours out on a job without a single disconnect. Parked at
base, it starts dropping again. Same turtle, same hardware, same firmware, same
dock. The only variable is whether it was out working or sitting in the cluster.

## The same thing, live, right now

job_0049/0050 are running with node_138 and node_139 out in the field:

| hour | node_138 | node_139 | the other 11 turtles, at base |
|---|---|---|---|
| 14 | 0 | 0 | 14 across 9 turtles |
| 15 | 0 | 0 | 26 across 11 turtles |

The two turtles doing the mining are the only two in the fleet with a clean
sheet. Everything parked at base keeps dropping.

Note also that node_139 — 48 disconnects for the day, the worst in the fleet —
is currently at zero while it is out working. Its bad day was earned at base,
not in the sector.

## What this does and does not settle

**Settled:** the fault is tied to being parked in the dock cluster. It is not a
property of the radio link over distance, not the server (whose loop is
statistically identical in disconnect minutes and quiet ones), and not a
particular turtle or role.

**Not settled:** *why* base is different. Two candidates survive, and they are
not the same fix.

1. **Radio congestion in the cluster.** All fifteen dock inside one ~10-block box
   at x 153–161, z −2793..−2810, Y=67 — every turtle in range of every other, so
   each event queue carries the whole fleet's traffic. Note this does *not*
   explain node_118's immunity by geography: node_118 docks at bay1B (158, 67,
   −2810), in the middle of the cluster, not on its edge.

2. **The idle path eats its own ACKs.** A parked turtle runs a different stretch
   of code from a working one. Given this codebase's standing rule — any filtered
   yield destroys every queued event that does not match — an idle wait is a
   plausible place for an ACK to be discarded. The main control loop pulls
   events unfiltered, so if this is it, it is not in the obvious place and needs
   looking for.

## The experiment that separates them

Congestion does not care what a turtle is *doing*, only how many are nearby. The
idle-path theory cares only what it is doing. So: **find a turtle that is busy at
base** — a delivery turtle actively working the dock rather than parked — and see
whether it disconnects at the parked rate or the field rate. Busy-at-base
dropping at the parked rate points to congestion; staying clean points to the
idle path.

A second, cheaper check: disconnect rate per parked turtle should rise with the
number of turtles parked, if it is congestion. Today gives little variance to
work with — two miners out in both windows — so this needs a job that deploys
more of the fleet.

## Not claimed

Today's hourly disconnect counts under 1.9.103 (14, then 25) sit inside the
normal range of earlier hours (10 to 68). **There is no evidence that the ack fix
changed the disconnect rate**, and it was never meant to. I checked because the
first partial hour looked low, and it was an artefact of the hour being partial.

## How immune is "immune", exactly

The tables above are true as written, but an hour is a coarse bucket: a turtle
can be in a sector for part of an hour and back at the dock for the rest, and it
gets marked "working" either way. Scored over the whole day that way, the three
miners come out:

| | while working | while parked |
|---|---|---|
| node_118 | 0.2 / hour | 2.7 / hour |
| node_138 | 1.0 / hour | 2.6 / hour |
| node_139 | 1.7 / hour | 3.3 / hour |

So working turtles are **not** absolutely immune — roughly two to ten times
better, not infinitely better. The clean zeros in the tables above are real
hours, not the whole story.

The precise claim remains the coordinate one, which does not depend on bucketing
at all: **536 of 539 warnings carry a dock-area position**. A turtle marked
"working" for an hour that logs a disconnect is, on the evidence of the
coordinate in its own warning, almost always back at base when it does.

A consistency check on the size: about 12 turtles parked at ~2.6–3.3 per hour
predicts roughly 31–40 fleet-wide per hour, against 26–68 observed. The parked
population accounts for the whole storm without needing anything else.

## Why there is no busy-at-base measurement yet

The discriminating experiment needs a turtle working at base. There was not one
today: the three delivery turtles logged 198–244 lines each, and after the boot
configuration lines essentially all of it is the register / lose-server /
reconnect cycle. They did no deliveries at all.

**Checked, and that is expected — not a fault.** I flagged it as possibly its own
bug; it is not, and I should have checked before raising it. Miners do not use
delivery turtles: they dump ore into an **ore ender chest** (`dumpToEC` in
`ore_turtle.lua`), which goes straight into the storage network. A `DELIVER` job
— "carry items from warehouse to destination" — is only ever created on explicit
request, from a `JOB_REQUEST` message or the console's `job <x> <y> <z>` command.
Nothing in the mining pipeline produces one. Five jobs were queued all day and
every one was a MINE.

So the delivery turtles were idle because nobody asked for a delivery, and the
busy-at-base experiment still has no subject. It needs a deliberately created
delivery job, which is a change to what the fleet is doing rather than an
observation of it — the operator's call, not mine.

## It replicates across a week, and it does not need a mining job at all

Same coordinate test applied to every day of logs still on the server:

| day | disconnects | at base | in the field | miner-hours worked |
|---|---|---|---|---|
| 2026-09-08 | 439 | 439 | **0** | **0** |
| 2026-09-09 | 1220 | 1220 | **0** | 8 |
| 2026-09-10 | 667 | 661 | 6 | 48 |
| 2026-09-11 | 378 | 378 | **0** | 6 |
| 2026-09-12 | 384 | 383 | 1 | 15 |
| 2026-09-13 | 253 | 253 | **0** | **0** |
| 2026-09-14 | 616 | 613 | 3 | 22 |

**3,947 of 3,957 at base — 99.7%, over seven days.** All fifteen nodes appear
every day. This is not an artefact of one job or one release.

The two rows that matter most are 09-08 and 09-13. **Zero miner-hours: nobody
mined at all, and the fleet still logged 439 and 253 disconnects.** Whatever this
is, it does not need a job, a sector, a scanner, or a loader swap. It happens to
a fleet sitting still.

That is the most useful fact in this memo for whoever fixes it: **the fault
reproduces on an idle fleet.** No mining job required to chase it.

## The congestion-scaling test, and why it is weak

Congestion predicts that the rate per parked turtle should rise with the number
parked. The trouble is that number barely varies — 13 to 15 parked on every day
above — so the test has almost no power, and I am not going to pretend it does.

What can be said is that the direction is unhelpful to the congestion story: the
two days with the **entire** fleet parked (09-08, 09-13) produced among the
**fewest** disconnects of the week, while 09-10 with 48 miner-hours produced 667.
Per parked turtle-hour the week ranges from about 0.7 to 3.5 with no visible
relation to how many were parked. If cluster congestion were the mechanism, the
fully-parked days should have been the worst. They were the mildest.

That is a hint, not a result. But combined with the idle-fleet reproduction it
shifts my weight toward the second mechanism — something in the parked code path
discarding its own ACKs at a roughly constant per-turtle rate — and away from
radio congestion. I would still run the busy-at-base test before calling it.

— W3
