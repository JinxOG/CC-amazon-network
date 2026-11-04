# Base air-traffic control (ATC): design note

W3, 2026-11-03. Board card "TOP PRIORITY - Base air-traffic control computer: no gridlock at 150 turtles".

## Why the base jams today

Measured in the 150-turtle sim:
- 141 of 142 turtles were off their docks.
- About 110 of them sat in the taxiway strip and about 20 in the tunnel.

Reading the code gives four causes:

1. **Each bay has one shared centre column.** One one-block column per bay side joins the aisles to the taxiway. Leaving and returning turtles use it in opposite directions, so two of them can meet head-on.
2. **Nobody coordinates.** A blocked turtle waits up to 120 s where it stands, in the lane. It may also step one block sideways (`bypassForward`), which can put it in the other lane.
3. **A boxed-in turtle never recovers.** Facing detection must step one block. With no free side it fails, logs "boxed in on all four sides" and tries again for ever. Meanwhile it holds its job and is still counted IDLE.
4. **Returners all target one cell.** Every returning turtle aims for the same cell below the arrivals hole and piles up there.

About the sim world: the synthetic world has no building, just flat floor at y 67 and the two shafts. All 5 x 16 dock slots exist on each side, enough for 150 turtles. So the jam came from turtles blocking each other, not from a missing bay or a wall.

## The idea

A separate computer, the ATC, hands out permission to enter each short section of the base, one turtle per section.

- **Its own channel.** It listens on channel 7 and answers on each turtle's private channel (1000 + id).
- **Nothing on disk.** All its state is in memory and is rebuilt from the turtles at boot.
- **The rule lives in turtle_base.** Every step passes through `tryMove`. A step into a new section waits there until the ATC says the turtle may enter.

## Sections

Sections come from cell coordinates (`waypoints.lua`, `W.atcSection(x, y, z)`).

| Section | Cells |
|---|---|
| `S<b>` | The worker side of bay b: centre column, aisles, and everything between the taxiway and the back aisle. Dock cells excluded. |
| `N<b>` | The support side of bay b, the same shape. |
| `J<b>` | The crossing at bay b's centre column on the taxiway strip (z -2801..-2803). |
| `W<b>` | The white (outbound) lane between crossings b-1 and b. W1 runs from the dispatch corner to crossing 1. |
| `R<b>` | The red (inbound) lane between crossings b and b+1. R5 runs from crossing 5 to the arrivals run. |
| `DH` | The dispatch corner: (143, -2803..-2813) on the floor and the shaft down to y 60. |
| `ARR` | The arrivals shaft (228, -2782, y 60..67). Also the run on the floor to the red lane, the taxi row under the hole (y 60, z -2782, x 229..), and the sky column above the hole. |

- **Docks are outside every section.** A docked turtle holds nothing.
- **Waiting places are outside every section.** These are the docks and the holding line. The holding line is a row of slots at (228 + 2k, 60, -2780), one block north of the taxi row, so a turtle called up never passes another one waiting.
- **The sky has a second holding line.** Miners returning from the sky use slots at the same x and z, at y 200.

## Changed after the first sim runs (2026-11-03)

These rules replace the ones in "Grants" and "Sections" below.

- **A route is let in only when every section on it is free.** The turtle itself and its partner don't count against it.
  - So nobody is ever admitted only to wait at a section edge, and the dispatch hole cannot hold a queue.
  - A request that has waited more than 60 s keeps later overlapping requests out, so a long route is not starved.
  - The ordered queues stay, for the rebuild after a restart.
- **The holding line's taxi row is north of the slots (z -2778); the slots are at z -2780.** A turtle reaches its slot from the south: along the row it is on, then up the slot's own column. So:
  - its approach crosses no section;
  - it never drives back up the delivery spot's own column, which outbound turtles use;
  - the support following one block behind stops south of the slot, out of the way when its delivery leaves northwards.
- **A turtle looks for an ATC before its first step into the base.** Hearing the ATC's hello is not enough on its own.
  - In the first 150-turtle run, 147 turtles started homing within 2 s of boot. They heard the ATC only at its 60 s repeat, and the boot rush jammed with no gates.
  - Now the first step into the base asks the ATC, at most once a minute. The ATC also says hello again 3, 8 and 14 s after it boots.

## The three blind spots on the card (A, B, C), and how they are handled

- **A, sky arrivals.** Miners fly home at y 200 straight to the point above the arrivals hole. `move.to` recognises that flight, so `ore_turtle.lua` is untouched, and sends the miner instead to a SKY holding slot beside the column. The slots are at (228 + 2k, y, -2780) and the sky taxi row is part of ARR, so the miner never hovers in the column.
  - The miner waits in its slot until its whole way home is free, then is called down.
  - Tunnel and sky arrivals both need ARR first. The ATC takes them in the order the requests came, so it alone decides who uses the hole next.
- **B, support staging.** The support waits in its dock until its delivery is at the hole and sends HOLE_READY, as today. Its route is then let in only when every section of it is free.
  - The support is booked as one party with its delivery. It may share the dispatch corner (DH) its partner is holding for it, and nobody else may.
  - So staging is a granted section with a limit of one party, and nobody queues behind the pair. Later departures wait in their docks.
- **C, a departures burst test.** `sandbox/scenarios/w3_atc_base150.lua` opens with 20 deliveries ordered at once on the 150-turtle base. Its checks are:
  - no 'Still waiting' at a section edge over 30 s;
  - nobody waiting to enter DH;
  - nobody blocked by a turtle inside the base for over 30 s;
  - every turtle on a dock at the end.

  The same scenario with `W3_NO_ATC=1` on today's master is the run where these checks fail.

## Grants: reservations admitted in order

A turtle about to use the base asks for its whole route as an ordered list of sections. It works the list out from the route's waypoints, stepping the cells in `move.to`'s own order: vertical, then x, then z.

1. **Admission.** The ATC admits a reservation only when the route's first section is free. Admitting appends the reservation to the queue of every section on the route, all at once. Being admitted does not mean the turtle may enter.
2. **Entry.** A turtle may enter a section only when its reservation is at the head of that section's queue. It asks with `ATC_ENTER` before the step.
3. **Release.** Leaving a section releases it (`ATC_LEAVE`), and the next reservation in that queue may enter.

**No deadlock.** Every reservation waits only for reservations admitted earlier. Admission is one global order, so no cycle can form, head-on meetings in a column included.

**Waiting is short and only behind a moving turtle.** A turtle only ever waits at the edge of its next section, and only behind an earlier reservation. That reservation's own turtle is already moving. The bound is set and checked in the sim:
- no turtle waits more than 30 s at a section edge while the turtle ahead is moving;
- a turtle ahead that has stopped is the stuck case.

**Late starters cannot block the corridor.** Departing turtles wait in their dock: the reservation is only admitted when the column `S<b>`/`N<b>` is free. Returning turtles wait in the holding line: admitted only when `ARR` is free.

**A step with no reservation still asks.** A one-section reservation is requested just for that step. Examples are facing detection beside a dock, a dock correction, and a miner's own path. So one-turtle-per-section holds for every move, from every caller.

**Inside the base the bypasses are off.** No sidestep out of a lane or shaft. They exist for the open world.

## Safe when down

No answer means no entry.

- **The ATC goes silent.** A turtle that needs a new section stops at the edge of the section it holds and asks again every few seconds. Nobody enters anything new, so nothing can jam. The base pauses.
- **Outside the ATC's area nothing changes.** Turtles in the field keep working.

## Every restart

- **The ATC restarts.** Its state is gone. It broadcasts `ATC_HELLO` with a new epoch and refuses entry for 15 s while it collects reports. Every turtle that hears a new epoch reports where it stands, the section it is in, and the rest of its route. The ATC then:
  1. puts each reporting turtle at the head of the queue of the section it physically occupies;
  2. admits the remaining routes in order of distance to the open end, nearest first (the dispatch hole for departures, the dock for returns).

  Turtles left mid-corridor therefore unjam from the open end inward.
- **A turtle restarts mid-corridor.** It boots, finds its position (GPS), and reports to the ATC as above. Its old reservation is replaced by one from where it stands. A reservation whose turtle stays silent for 3 minutes is dropped from every section it has not entered. The section it physically sits in stays held until it reports again or is removed.
- **The world restarts.** Both of the above happen at once. The ATC boots empty, every turtle boots and reports, and the base clears from the open end.
- **The central server restarts or is down.** The ATC does not need it, and turtles already on their way home keep going home. Today `tryMove` holds every move while the server is unreachable. Inside the ATC area it no longer holds: the ATC is the authority there, and the server is not needed to park.

## A stuck turtle lets go

A turtle that makes no progress for 3 minutes gives up its job:
- it sends `JOB_FAILED` with `retry = true` and reason `stuck`;
- it moves to status ERROR, which the server does not count IDLE and does not dispatch.

"No progress" means: refused the same step, boxed in on all four sides, or held at a section edge with nobody moving ahead.

The server already requeues a retryable `JOB_FAILED`, so the job goes back to the queue. The stated bound is 4 minutes from the turtle stopping to its job being queued again.

## Files

- **`atc.lua`** (new): the ATC program.
- **`waypoints.lua`**: the section map, the holding lines, and the ATC channel and message names, so `protocol.lua` stays as it is.
- **`turtle_base.lua`**: the gate in `tryMove`, reservations around the base routes, the stuck rule, no bypass in the base, and no server-down hold in the base.
- **`install.lua` and `updater.lua`**: an `atc` profile.
- **`delivery_turtle.lua`, `support_turtle.lua` and `ore_turtle.lua`**: untouched.
- **The sim**: an `atc` install role and an ATC computer in the synthetic layout. Fault scenarios: ATC killed, server killed, world restart, stuck turtle.

## Later, not now

- A standby second ATC. It is easy because nothing is saved.
- Pipelining long lane segments by splitting them in two.
