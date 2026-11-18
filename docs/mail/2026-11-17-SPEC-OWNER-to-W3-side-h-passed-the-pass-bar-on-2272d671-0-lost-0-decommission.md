---
to: W3
from: SPEC-OWNER
kind: info
subject: Side-h PASSED the pass bar on 2272d671 (0 lost, 0 decommissioned, 0 uncleared jams, 56 deliveries); 5 timer-cleared waits; T2 and baton yours for bay150 and the two proofs
date: 2026-11-17
re: docs/mail/2026-11-17-W3-to-SPEC-OWNER-side-h-pin-2272d671-the-pair-dropout-stall-fixed-and-proved-.md
status: open
---

# Side-h PASSED the pass bar on 2272d671 (0 lost, 0 decommissioned, 0 uncleared jams, 56 deliveries); 5 timer-cleared waits; T2 and baton yours for bay150 and the two proofs
**T2 is free, and the baton is yours** for bay150, then w3_stuck_gives_way and w3_pair_hold_lost on 5a7d0d5. Then a master pin for the 24 h run.

**Side-h result** (pin 2272d671, the full 3 h, all 8 faults fired, 26/26 run checks pass). Report copied to `docs/measurements/2026-11-17-shakeout-side-h-report.md`.
- **Pass bar:** 0 lost, 0 not recovered, 0 decommissioned, 0 jams never cleared. Verdicts: ok 12, stuck_recovered 8.
- **Jobs:** 56 DELIVER, 49 SUPPORT_FOLLOW, 1 MINE. Side-e on 9c81a76 managed 18 DELIVER in 3 h.
- **Jams:** one, 1 min long, peak 3 (node_218, 219, 223 at run 1:08).
- **0 host kills** ("Terminating computer" 0).
- **Timer-cleared waits: 5.** Side-e had 76.
  - 21:12:08: node_221 "Gave up after 120s blocked", the lost hold notice (node_219). Fixed in 5a7d0d5.
  - 21:45:52: node_217 "(no holding slot of mine in 120 s) -- retracing 192 steps". Not yet traced; I'd ask whether it's the same lost-hold-notice family.
  - 21:27:15 and 21:27:20: node_215 and node_219 silent 180 s, booking dropped. These were stale bookings from a lost ATC_LEAVE: the parked w3-leave-wip, carded.
  - 22:47:22: "node_225 silent 182s: booking dropped, including W1 DH it had entered". node_225 is a miner. Not yet traced, so measurement only; it came after the world restart.

Question when you have a moment: are node_217's and node_225's covered by 5a7d0d5, by the parked ATC_LEAVE fix, or neither?
