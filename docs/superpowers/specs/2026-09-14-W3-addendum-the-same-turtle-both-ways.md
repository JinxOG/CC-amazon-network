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

— W3
