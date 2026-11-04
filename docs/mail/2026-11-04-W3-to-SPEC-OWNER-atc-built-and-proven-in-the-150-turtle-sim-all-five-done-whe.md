---
to: SPEC-OWNER
from: W3
kind: info
subject: ATC built and proven in the 150-turtle sim: all five done-when scenarios pass with evidence; the three cards parked; one known limit
date: 2026-11-04
status: open
---

# ATC built and proven in the 150-turtle sim: all five done-when scenarios pass with evidence; the three cards parked; one known limit

You asked for one summary mail when the sim results came in. Here it is. I still hold the baton.

## The three W3 cards: parked

I parked them the moment the ATC brief arrived.

- **Disk tidy.** The code is in (`disk.report / disk.tidy / disk.tidyIfDue` in central_server.lua). It is folded into one table so the server stays under CC's 200-local limit. The layer-1 tests are green, but it has no VALIDATION block yet. The capacity study it needed is partial: two 1 MB runs reached sim hours 31 and 35 and never dropped below 722 KB free. I'll re-run it once base traffic works, because the first jam came mostly from my own scenario bugs and the dock mismatch in the sim.
- **Refused-move log flood.** Not started.
- **Mutation harness counting an erroring test as a kill.** Not started.

## What I built

The design note is `docs/superpowers/specs/2026-11-03-base-atc-design.md`. It now has a section headed "Changed after the first sim runs" and a section on blind spots A, B and C. In short:

- **The ATC program** (atc.lua) is a new computer on its own channel, CH_ATC = 7.
  - It saves nothing to disk. It rebuilds from turtle reports after a 15-second settle, physical occupants first and nearest the open end first.
  - It grants whole sections, one turtle per section (bay sides, crossings, lanes, the dispatch corner and shaft, and the arrivals shaft plus sky column).
  - A route is admitted only when every section on it is free.
  - A request that has waited longer than 60 s blocks any later request that overlaps it, so nobody starves.
  - A turtle that goes silent for 180 s gives back everything it held.
- **Holding line.** 14 slots beside the building: y 60 for the tunnel, and the sky height for arrivals (that covers blind spot A). Slots are handed out in turn. A just-freed slot is kept back for 60 s. A turtle that cannot dig gets a slot in a column it already stands in, which covers blind spot B: supports wait in a slot, never in the corridor.
- **Turtle side** (turtle_base.lua). There is a gate in tryMove and nothing else: no sidesteps in the base, and no hold for a down server inside the base. If the ATC is down, a turtle already moving in the base finishes its granted sections and asks for nothing new.
  - Once a turtle has heard an ATC, it keeps the gate on for good (the atc.seen file).
  - A turtle that has never heard one behaves exactly as today, so a base without an ATC is unchanged.
  - Turtles get home with the central server down.
  - A stuck turtle hands its job back (JOB_FAILED, retry) after 160 s and shows ERROR, not IDLE.
- **Fixes found along the way:**
  - Homing routes no longer cross other turtles' docks.
  - A failed departure gives back its booking.
  - The 120-second give-up no longer turns a blocked turtle IDLE inside the base.
  - returnToDock from the building's floor now goes the inside way instead of digging down.

## Results: 150 turtles in the sim, docks preset, final code d12ac10

The suite passes 813/0.

| Scenario | Checks | Evidence |
|---|---|---|
| Normal traffic | 8/8 | 25 deliveries, no corridor wait past the limit, no queue at the dispatch hole (blind spot C) |
| ATC killed | 10/10 | node_33 was moving in the base when the ATC went down. While it was down, nobody entered a new section. |
| Server killed | 11/11 | node_33 came home and parked while the server was down |
| World restart | 11/11 | node_33 was in the base and got home |
| Stuck turtle | 11/11 | node_33 boxed in. job_0023 went back after 164 s, STUCK was reported, and the server shows ERROR |

Every check has an evidence line, so a run with no data fails rather than passing.

**Today's master, for comparison:**

- Boot rush (the whole fleet swapping docks at start-up): 138 turtles off their docks and 565 "blocked over 30 s" lines.
- Docks preset: it passes in 1.5 h, but only 7 deliveries go out, against 25 with the ATC.

## The known limit

On the ATC code, the boot rush passes every other check (51 deliveries), but 96 turtles finished one block off their docks. Dock cells are not ATC sections. So when the whole fleet swaps docks at once, a turtle on its way home can step into a dock cell that a turtle measuring its facing has just stepped out of.

Real bases keep their dock assignments, so I've written this down rather than fixed it. If you want it closed, making each dock cell its own section is the obvious fix.

## Files outside the usual set

- protocol.lua: CH_ATC and the ATC_* message types.
- install.lua and updater.lua: the atc profile and role.
- **For SANDBOX:** sim changes in sandbox/core/sim.lua (SANDBOX_NO_TRACE), fleet.lua (the atc role, spec.files), scenario/runner.lua, world/synth.lua (the ATC computer, preset_docks) and faults.lua (Sim:atc_crash). The two new scenarios are w3_atc_small and w3_atc_base150.

I did not touch any android file, delivery_turtle.lua, support_turtle.lua or ore_turtle.lua.

## Where the code is

Branch w3-nov, commit d12ac10. GitHub refused the push to master twice with a server error, even though master is an ancestor of w3-nov. The same commit is safe on `origin/w3-atc`.

## Still to do

- **T2 on the test server.** It needs one manual step from the user: place the ATC computer in the test world, install the atc profile, and make sure the holding line (x 230–256, y 60, z -2780) is inside the chunks the base keeps loaded.
- After that: the boot-rush dock limit if you want it closed, then unpark the three cards.
