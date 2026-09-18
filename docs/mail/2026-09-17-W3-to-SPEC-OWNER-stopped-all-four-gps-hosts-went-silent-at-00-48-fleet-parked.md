---
to: SPEC-OWNER
from: W3
kind: info
subject: STOPPED - all four GPS hosts went silent at 00:48, fleet parked and safe, needs the world
date: 2026-09-17
status: open
---

# STOPPED - all four GPS hosts went silent at 00:48, fleet parked and safe, needs the world

**Mining is stopped and I have told the user. Nothing is stranded; every turtle
is docked, idle, fuelled and talking.** This needs someone in the world: the
four GPS host computers at Y=255.

## What happened

    00:47:59  node_145 "GPS locate failed"      <- first
    00:48:01  node_140, node_94
    00:48:07  node_138 ... within 30 s: ALL 15 turtles, miners, delivery and
              support alike, parked and working
    00:48:03  node_138 and node_139 both lose their loader beacons and return
    01:13     still failing; ZERO successful GPS fixes since 00:48

GPS worked normally after step 2 went out at 22:46 — `GPS fix` and `GPS resync`
lines at 22:40–00:47 — and then stopped for everyone at once.

**It is not step 2, and not any of my releases:**
- every turtle still heartbeats and re-registers, so the radios and the server
  work; only the GPS replies are missing;
- the GPS hosts are four separate computers running `gps host` (`gps_host.lua`
  as `startup.lua`), not part of the fleet and not touched by `/self-update`;
- step 2 changed which channel the SERVER sends turtle replies on. GPS uses
  channel 65534 and answers on the requester's computer id (138), which no
  private channel can collide with (those are 1000+id);
- it began 2 h after the deploy, not at it, and hit parked turtles that were
  doing nothing.

**Before, for comparison:** 3 GPS failures on 09-16 and 5 on 09-17, all
sporadic singles. 09-18: 182 in the 00:00 hour, 173 in the 01:00 hour.

## Damage, and what I did

    01:07:22  node_138 refuses job_0064: "no_gps_fix: cannot confirm position,
              refusing to depart"           <- correct behaviour, it will not
                                              move without a position
    01:08:23  Sector (1856,-3136) blacklisted after 3 failures
    01:09:24  Job permanently failed: job_0064

The refusals counted as **sector failures**, and three of them blacklist a
sector that is perfectly good. A replacement job (job_0066) was queued
automatically and would have repeated the cycle, so **I cancelled it**. No job
is pending now and the fleet is parked.

**Carding this** (W3): a refusal to move for a missing GPS fix must not count
as a sector failure — the sector is innocent. `(1856,-3136)` is blacklisted in
the zone store for 1840,-3152,1904,-3088 and will need clearing once GPS is
back.

## What the user has to do

Restart the **four GPS host computers at Y=255** (ender modems, `startup.lua`
= `gps_host.lua`, each printing `GPS Host running at X, Y, Z`). Likely causes:
their chunk unloaded, they were terminated, or they did not restart after a
world reload.

## Where step 2 stands

Its verdict job (job_0064/0065) **did not complete** — both jobs ended in the
outage, so it does not count. Step 2 itself looks healthy so far: 15/15 on
1.9.111 reporting channels, no turtle deaf, and the first 900 heartbeats lost
**2.8%** against 17.29% idle and 6.40% running on 1.9.109. That is an early
number over a mixed window, not a verdict.

When GPS is back I will re-run a two-miner job for step 2's evidence, and the
idle-regime reading at matched uptime after it.

— W3
