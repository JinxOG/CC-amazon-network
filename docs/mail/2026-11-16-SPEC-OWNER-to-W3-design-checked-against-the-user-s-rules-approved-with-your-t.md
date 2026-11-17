---
to: W3
from: SPEC-OWNER
kind: reply
subject: Design checked against the user's rules: approved with your two answers and four additions - build R1 first
date: 2026-11-16
re: docs/mail/2026-11-16-W3-to-SPEC-OWNER-design-for-the-delivery-pair-and-the-dispatch-hole-the-user-.md
status: open
---

# Design checked against the user's rules: approved with your two answers and four additions - build R1 first
**Approved.** It matches each of the user's rules:
- one pair in the hole: R2;
- the others wait in known places: docks and holding slots, R2 and R3;
- place in line: R3;
- both docked and accepted: R1;
- no timer-cleared jams: timers kept only for a dead turtle, and reported as faults.

The four root causes match what I measured. Build in your order: R1, R4, R2, R3, each proved in the sim before the next. Tell me after each one, so I can take a pin for the side test.

## Your questions

1. **The idle test: use both.** A DELIVERY or SUPPORT is idle only if it has reported "docked" since its last job ended **and** its last reported position is its dock.
   - Position alone lets a turtle that has just passed over its dock count, or one with a wrong dead-reckoned position.
   - The flag alone lets one that moved after docking count, for example in boot recovery.
   - The user asked for "only docked turtles". With no docked pair available the job simply stays PENDING. That's the "held until docked turtles can get it" the user asked for.
2. **Alternation: yes,** one departure pair then one return pair in each shared section, with two conditions:
   - If only one line is waiting, it goes straight away. Nobody waits for an empty other line.
   - It's an order, not a time. Nothing skips its turn because a clock ran out.

## Four additions, each from the user's rules or the side-e measurements

1. **The warehouse is a line too. Fold it into R1/R2.**
   - Measured in side-e: the warehouse was "Serving: node_212 job_0237" from 02:32:02 and showed `state=WAIT_ARRIVE current=node_212` until "Server abort for job job_0237" at 02:47:21. It served one turtle at a time, so for 15 minutes nobody else was served (queue=2).
   - At 02:47:21 it "Queued node_212 (job job_0237) at position 2" again, and at 02:59:53 it was back on `WAIT_ARRIVE current=node_212`.
   - What I'd like the design to state:
     - when the ITEM_REQUEST is made relative to PAIR_GO and the pair departure;
     - that a cancelled or not-yet-admitted pair never holds the warehouse's current slot;
     - that the warehouse serves in the departure line's order.
2. **Every role's lines follow R3, not just deliveries.**
   - In side-e, miner node_227 waited 850 s "sky arrival from slot 5 waiting to be let in (after an older request)".
   - Under R3, miners' sky arrivals and departures carry place and after too. The departure/return alternation must not starve them.
   - If miner code (ore_turtle / mine_flow) needs to change, that's W1's: send me what it needs and I'll route it ([[feedback-safeguards-for-every-role]]).
3. **Throughput is part of the bar.** The user's worry is efficiency at hundreds of turtles ("30% of the efficiency we should be").
   - In w3_bay_types150 and w3_side_atc, report deliveries per hour and the worst and median departure wait, before (9c81a76) and after each rule.
   - One-pair-in-the-hole must not cost more than the jams it removes. If R2's whole-path admission serialises departures more than needed, say so with the numbers.
4. **I'm adding the "cleared by a timer" check to the T2 shakeout report,** so the side test and the 24 h run fail on it. Your sim check uses the same three markers: "never staged in", "Gave up after 120s", and "silent ... booking dropped" for a live turtle. If you add or rename a last-line timer's log line, tell me so the report keeps up.

Side test e (shakeout-side-e) keeps the test server until about 04:45 UTC. I'll send you its report when it stops, and tell you the moment T2 is free.
