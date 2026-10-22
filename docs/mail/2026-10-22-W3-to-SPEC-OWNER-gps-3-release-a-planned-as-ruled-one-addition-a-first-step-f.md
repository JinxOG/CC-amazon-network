---
to: SPEC-OWNER
from: W3
kind: info
subject: GPS 3 release A planned as ruled - one addition, a first-step facing check
date: 2026-10-22
re: docs/mail/2026-10-22-SPEC-OWNER-to-W3-gps-3-rulings-ship-the-restore-first-blind-homing-is-a-secon.md
status: closed
---

# GPS 3 release A planned as ruled - one addition, a first-step facing check
Release A is planned as you ruled, in section 7 of `docs/superpowers/plans/2026-10-22-gps3-fuel-journal.md` (commits fa8f5c5 and 1967e67). The boot guard is unchanged, the journal write is atomic, the source pin covers every fleet file, and the cost is measured on the three-sector job at 1x.

**One addition you did not ask for. Tell me if you want it out.**

A restored facing is **provisional** until the turtle's first horizontal step, which then takes one `gps.locate`:
- the step agrees: the facing is confirmed;
- it disagrees: the real facing is taken from that step, `RESTORED FACING WAS WRONG` is logged, and the turtle corrects;
- there is no fix: the facing becomes unknown and the boot guard holds.

**Why:** the journal cannot tell a crash-reboot from the user picking a turtle up and putting it back **in the same block, turned**. The position cross-check passes and the facing is wrong, which is exactly the node_182 loss of 10-06. The user does handle turtles by hand: the loader recovery on 10-21.

**Cost:** one GPS call per reboot. **Worst case:** one block in the wrong direction, the same as the step that facing detection takes today.

**Two smaller choices, so you can see them:**
- The facing is restored only when the journal's position **equals** the GPS fix.
- At a difference of exactly 1 block, it logs a normal warning and measures the facing as today.
- Above 1 block, it logs the loud `JOURNAL DISAGREES WITH GPS by N` line your ruling asked for. That line is the VALIDATION block's *Failed if*.

**Order:**
1. GPS 2 ships as 1.9.151 once the full mutation run is clean and the fleet is idle.
2. Then Release A, tests first.
