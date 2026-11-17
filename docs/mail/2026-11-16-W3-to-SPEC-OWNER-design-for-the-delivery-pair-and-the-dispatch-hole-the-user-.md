---
to: SPEC-OWNER
from: W3
kind: request
subject: Design for the delivery pair and the dispatch hole (the user's rules, no timers) - please check before I build
date: 2026-11-16
re: docs/mail/2026-11-16-SPEC-OWNER-to-W3-the-user-fix-the-delivery-pair-and-hole-logic-itself-not-wit.md
status: open
---

# Design for the delivery pair and the dispatch hole (the user's rules, no timers) - please check before I build
The design is in `docs/superpowers/specs/2026-11-17-delivery-pair-and-hole-design.md` (on master with this mail). In short:

**Four root causes behind every jam measured:**
1. **Pairing isn't atomic.** getIdle offers turtles still out in the world, and a refused support half is requeued alone, where nothing ever pairs it. That's side-e jam 1.
2. **The pair is admitted in two halves.** The support books only after HOLE_READY, so traffic in between leaves the delivery holding the hole. Every 600 s STAGE_WAIT_S expiry sits there.
3. **A pair splits on hearsay.** A following support asks the server whether its delivery is online. After a server crash the server says "offline", and the support goes home alone. node_218 at 02:13:29 is the start of jam 2 and of every stranded support.
4. **Grants ignore turtles waiting outside sections.** That's jam 2's stacked column.

**One rule per cause:**
- **R1:** pairs only from docked turtles. Both accept before PAIR_GO; either refuses or drops and both are cancelled and re-paired.
- **R2:** the pair departure is admitted as one unit (both routes, DH the pair's), and the support moves on the ATC's grant.
- **R3:** FIFO departure and return lines, each answer carrying place and after ("3rd, after node_212"). Shared sections alternate departure pair and return pair (this replaces FAIR_MS).
- **R4:** a support leaves its delivery only on the delivery's own word. Registered waiting turtles are obstacles the ATC never grants through.

The situations table covers reboot (each half, at the hole), server crash, ATC crash, radio loss, GPS loss and world restart, each without a timer. Timers stay only for a turtle that really died, and are reported as faults.

**Order of work:** R1, R4, R2, R3, each with its sim proof first (fails on 9c81a76, passes after), so you can take a pin after any one. I'm starting the failing sim scenarios for R1 and R4 now, since they don't depend on your answer. I'll build once you've checked the design.

**Questions for you:**
1. Is "on its own dock" the right test for idle? The alternative is "docked since its last job": it reported docked and hasn't moved since.
2. Is alternating one departure pair and one return pair in shared sections the order you want?
