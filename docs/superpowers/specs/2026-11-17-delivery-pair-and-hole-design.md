# The delivery pair and the dispatch hole, by design (W3, 2026-11-17)

The user's direction (via SPEC-OWNER, `docs/mail/2026-11-16-SPEC-OWNER-to-W3-the-user-fix-the-delivery-pair-and-hole-logic-itself-not-wit.md`):
- one pair in the hole at a time;
- everyone else waits in a known place;
- every turtle knows its place in line;
- a pair leaves only when both are home and have accepted;
- a jam that only a timer clears is a failure.

This is how each rule is made to hold by construction, and how each situation is handled without a timer. Timers stay only as a last line of defence against a turtle that is dead.

## What goes wrong today (the four root causes behind every jam measured)

1. **Pairing is not atomic** (side-e jam 1).
   - `registry.getIdle` offers any IDLE online turtle, including one that is still out in the world finishing a job. node_218 was paired 23 ms after its JOB_COMPLETE, 200 blocks from its dock.
   - Its refusal requeued its half alone (`jobQueue.reassign`), and nothing pairs a lone SUPPORT_FOLLOW. The delivery went to the hole and waited 600 s for a support that did not exist.
2. **The pair is admitted in two halves.**
   - The delivery books its way to the hole. Only when it is there (HOLE_READY) does the support book its own way.
   - Anything admitted in between holds the support back while the delivery holds the hole. Every 600 s STAGE_WAIT_S expiry, and every jam I fixed in the last week, sits in that gap.
3. **A pair splits on secondhand news** (side-e jam 2, side-d).
   - A following support that hears nothing for 15 s asks the server whether its delivery is online. After a server crash the server has not heard the delivery again yet, says "offline", and the support goes home alone (node_218, 02:13:29).
   - It cannot dig, so it is sent to retrace and to wait for holding slots. That is the root of every stranded support.
4. **Grants are made on bookings, not on where turtles physically are.**
   - A turtle waiting outside any section (in a holding column, in the departure tunnel) is invisible to the ATC. It can be granted a route that runs through a turtle that is itself waiting for a section the first one holds (jam 2: node_218 above node_219 in one column).

## The rules, and how each holds

### R1. A pair is formed only from two docked turtles, and both accept before either moves

- **Who may be offered work:** `getIdle` for DELIVERY and SUPPORT offers only a turtle that is **on its own dock** (its reported position equals its dock) and has said "docked" since its last job.
  - A turtle still out in the world is not idle, whatever its status says. This also answers the user's question: a turtle in the field never gets a job.
- **Two-phase:**
  - The server assigns both halves as one PAIR (one record holding both job ids).
  - Each turtle answers JOB_ACCEPT or JOB_REJECT as now.
  - The server sends **PAIR_GO** to both only when both have accepted.
  - A delivery does nothing (no warehouse request, no ATC request) until PAIR_GO. A support waits at its dock as now.
- **Either half refuses, or drops** (offline, reboots before PAIR_GO):
  - both jobs are cancelled;
  - the other half is told (PAIR_CANCEL); it is on its dock, so nothing moves;
  - the master job goes back to PENDING, to be re-paired from docked turtles on the next dispatch pass.
  - A support job is never requeued alone; the lone `SUPPORT_FOLLOW` requeue is removed.
- **No timer.** A refusal is an answer. A turtle that never answers is offline, and the registry's offline rule (a last line, already there) cancels the pair.

### R2. One pair in the dispatch hole at a time, admitted as one unit

- **One admission:** the delivery, after PAIR_GO, asks the ATC for a **pair departure**: its own route and its support's, in one request (`pair = supportId`).
  - The ATC admits both routes in one step, only when both are free. The pair's bookings are queued together in every section; DH is the pair's.
  - No other booking can be admitted to DH until both turtles have left it, down the shaft.
- **Both are told:** on admission the ATC answers the delivery and sends the support the same grant (ATC_GRANT, repeated until the support acknowledges). The support moves on the grant, not on HOLE_READY.
  - Both routes were free at admission, so nothing can hold either turtle back on the way: the wait at the hole is travel time, not traffic.
- **Repeated until acknowledged:** HOLE_READY becomes unnecessary for ordering. SUPPORT_STAGED stays, repeated until the delivery answers (as in 9c81a76).
- **Waiting at the dock:** while not admitted, both wait on their own docks, a known place in no section. Nobody waits inside a shared section.
- **Last line only:** STAGE_WAIT_S (600 s) stays, for a partner that died after admission.

### R3. Every turtle knows its place in line

- **Departures:** the ATC keeps a FIFO line of pair-departure requests. Every answer to a waiting request carries `place` and `after` ("3rd, after node_212").
  - The turtle logs it when it changes ("Departure: 3rd in line, after node_212"). That is the user's "I'm 5, I go after 4".
  - The line moves when the pair ahead has left DH. No turtle times out of it.
- **Returns:** the holding line is already a line of slots. The ATC keeps the call-up order (FIFO by when the delivery reported in its slot) and tells each waiting pair its place.
  - The pair is called up as one unit: the delivery's and the support's return routes are admitted together, like a departure.
- **Fairness between the two lines:** shared sections (J1, S1, the red lane) alternate one departure pair and one return pair when both lines are waiting.
  - This is a rule of order, not a timer. It replaces FAIR_MS as the anti-starvation rule.

### R4. Nothing is granted a way that is physically blocked

- **Which turtles the ATC counts as obstacles:** any turtle waiting in a known waiting place (dock, holding slot, departure-tunnel cell) is registered with the ATC as standing there, through its reports.
  - The ATC does not grant a route through a cell occupied by a registered turtle, unless that turtle is ahead of it in the same line, and so will move first.
  - Holding slots: one turtle per column, two for a pair, the support above its own delivery. A slot is never given to a turtle whose column holds another pair.
- **Pairs no longer split on hearsay** (cause 3):
  - A support leaves its delivery only on the delivery's own word: PARTNER_LEFT, RETURN_TO_DOCK, or a job end it hears from the delivery.
  - Or, as a last line, after a long silence from the delivery itself while others are heard (the ATC's deaf rule applied to the partner).
  - The server's "online" answer no longer separates a pair: after a server crash the server knows nothing for a while, and that is not news about the delivery.
- **Only on a dead partner:** with pairs kept together, a support never has to find its own way home. Retrace and "no holding slot of mine in 120 s" are left for the case of a partner that really died.

## The situations, and what happens in each (no timer)

| Situation | What happens |
|---|---|
| Support (or delivery) busy or away when the pair is formed | Not offered: only docked turtles are idle (R1). |
| One half refuses | Both cancelled, master job PENDING, re-paired from docked turtles (R1). |
| One half reboots before PAIR_GO | It re-registers with no job; the pair is cancelled and re-paired (R1). |
| Departure held by traffic | Both wait at their docks, told their place in line; admitted as one unit when the whole path is free (R2, R3). |
| Delivery at the hole, support on its way | Its way was free when admitted, so it is travel time. SUPPORT_STAGED is repeated until heard (9c81a76). |
| Radio loss during staging | Repeats until acknowledged: SUPPORT_STAGED, ATC_GRANT, PAIR_GO. Nothing is sent once. |
| Delivery reboots in the hole cell | The pair's booking is kept alive by both (9c81a76 keep-alive). The support at staging does not step in while the cell is occupied. The rebooted delivery resumes as the pair's head: it re-reads its job from the server's re-send and re-asserts the pair (`pair = supportId`), so the ATC keeps the unit. Then it either descends with its support (job still live) or both go home in the line (job cancelled). |
| Support reboots at staging | It resumes as the pair's support from the server's re-send and re-sends SUPPORT_STAGED. Its delivery is waiting at the hole. |
| Server crash | Turtles in a pair keep the pair: no "partner offline" from the server (R4). Departures not yet admitted wait at their docks; the ones under way finish. On restart the server rebuilds pairs from the job records (both halves are linked). |
| ATC crash | It rebuilds from reports, as now. Each report now carries `pair` and `place`, so pairs are rebuilt as units and the lines in their order. |
| GPS loss | A turtle that cannot measure waits where it is and keeps its booking alive (9c81a76). Its partner waits too. Nothing is granted through it, since it reports where it stands. |
| World restart | Everyone reboots at once. Each re-asserts what it was doing from its journal and the server's re-send. Pairs are rebuilt from the job records. The ATC settles as now, with pairs as units. |
| Delivery's job fails out in the world | It brings its support home first (already done: failLater), then fails the job. The pair returns as a unit. |
| A turtle actually dies (never comes back) | The last-line timers: offline at the registry, STAGE_WAIT_S at the hole, silence at the ATC. These are the only places a timer moves traffic, and they are reported as faults. |

## What changes, by file

- **central_server.lua:**
  - `getIdle` requires at-dock for DELIVERY/SUPPORT;
  - the pair record and PAIR_GO / PAIR_CANCEL;
  - no lone support requeue;
  - pairs rebuilt on restart.
- **atc.lua:**
  - the pair request (`pair`), admitted as one unit, with ATC_GRANT to the support;
  - the departure and return lines with place and after;
  - the alternation rule replacing FAIR_MS;
  - registered waiting turtles as obstacles;
  - reports carry pair and place.
- **turtle_base.lua:**
  - the delivery's departure asks for the pair departure and waits at its dock, logging its place;
  - the support's departure moves on ATC_GRANT;
  - the pair return;
  - waiting places reported.
- **delivery_turtle.lua:** waits for PAIR_GO before the warehouse request.
- **support_turtle.lua:**
  - waits for ATC_GRANT, not HOLE_READY;
  - leaves its delivery only on the delivery's own word, not on the server's online flag.
- **protocol.lua:** PAIR_GO, PAIR_CANCEL and ATC_GRANT, plus the `place` / `after` / `pair` fields.

## How it is proved

- **Sim, each failing on 9c81a76 and passing after:**
  - **w3_pair_busy_support:** a support paired while still out finishing a job, side-e jam 1.
  - **w3_pair_refuse:** either half refuses.
  - **w3_pair_server_crash:** a server crash while a pair is out, side-e jam 2 and the split.
  - **w3_pair_line:** 20 orders at once. Every departure logs its place, and the line moves with no STAGE_WAIT_S or 120 s give-up anywhere in the run.
  - **w3_side_atc, w3_bay_types150:** with a new check that no jam was cleared by a timer. This means no "never staged in", no "Gave up after 120s", and no "silent ... booking dropped" for a live turtle.
- **The existing pair scenarios** stay green.
- **T2:** one pair through R1-R4 with a server crash and a radio loss, once the test server is free.

## Order of work

1. R1 (the atomic pair): it removes jam 1 outright, and it is server-side.
2. R4 (no split on hearsay): it removes the stranded supports.
3. R2 (the pair as one unit).
4. R3 (place in line, and alternation).

Each lands with its sim proof before the next starts, so the side test can take a pin after any of them.
