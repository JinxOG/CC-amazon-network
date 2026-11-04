---
to: W3
from: SPEC-OWNER
kind: request
subject: TOP PRIORITY from the user: stop the capacity study, build the base air-traffic control computer, prove it in the sim
date: 2026-11-03
status: open
---

# TOP PRIORITY from the user: stop the capacity study, build the base air-traffic control computer, prove it in the sim

**The user's words, 2026-11-03:** "This is top priority. Make him stop the current test, build the system, add the computer and run a sim."

## What to do, in order

1. **Stop the capacity study now** (run `20261103-133047-w3_capacity_week_1mb-1`). Keep what it saved. Its 32 simulated hours are enough to note the disk trend in your summary. The full week can be re-run once traffic works; it will be a fairer test then anyway.
2. **Park your three cards as they stand.** If a card has passed both layers, push it. If not, leave it on your branch and say which is which in your summary. Do not finish them first.
3. **Build the base air-traffic control (ATC) computer.** Board card: "TOP PRIORITY - Base air-traffic control computer: no gridlock at 150 turtles". The card holds the full requirement list and the done-when tests. Short version:
   - its own computer and radio channel;
   - nothing saved to disk: it rebuilds from turtle reports at boot;
   - a grant per corridor section, one turtle per section;
   - waiting happens only in docks and in a tunnel holding line, never in the corridor;
   - it unjams from the open end;
   - **safe when down**: no grant, no new section;
   - turtles get home while the central server is down;
   - area: the building plus the tunnels to both holes;
   - a stuck turtle hands its job back and stops counting as IDLE.
4. **Add the ATC computer to the simulator and run the 150-turtle base.** Run the card's fault scenarios on it. Each check must fail on today's code.

## What I measured in your sim

I read the run's /state through a viewer at about sim hour 32:
- 141 of 142 turtles were not at their docks;
- about 110 sat in the strip between the dock rows (y 67, z -2799..-2804);
- about 20 were in the tunnel (y 60-62, z -2813);
- most were still listed IDLE.

**One question before you design around that:** were bays 2-5 built properly in the sim world, with floor, pillars and aisles where waypoints.lua puts them? Or is some of the jam a world that only has bay 1? Answer with what you checked. It doesn't change the job: a stuck turtle holding its job and a corridor that cannot unjam are wrong at any size.

## Rulings so you don't stall

- **New file:** `atc.lua` (or your name for it) is yours. So are `turtle_base.lua`, `central_server.lua`, `waypoints.lua` and the installer entry.
- **Frozen files:** keep the turtle side in `turtle_base.lua` so `delivery_turtle.lua` and `support_turtle.lua` stay untouched. If that is truly impossible, you have my ruling for the smallest edit that works. List each one in your summary.
- **Sim changes:** if the simulator needs a new computer type or fault (for example "kill the ATC"), make the smallest change in `sandbox/` and copy SANDBOX on the mail. If it is bigger than that, ask me.
- **No live deploys.** The test-server run comes after the user places the computer in the test world.
- **Design note first:** write a short design note before the code: sections, grants, the holding line, what happens on every kind of restart. Put it in your summary mail. It does not need my approval to start.

One summary mail when the sim results are in. You keep the baton.
