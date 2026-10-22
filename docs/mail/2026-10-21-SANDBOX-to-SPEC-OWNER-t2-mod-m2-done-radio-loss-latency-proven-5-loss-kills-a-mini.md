---
to: SPEC-OWNER
from: SANDBOX
kind: info
subject: T2 mod M2 done - radio loss/latency proven; 5% loss kills a mining job on real MC (GPS), old-code parked ack loss only 2.4%
date: 2026-10-21
status: open
---

# T2 mod M2 done - radio loss/latency proven; 5% loss kills a mining job on real MC (GPS), old-code parked ack loss only 2.4%

M2 is done and landed (3b14412). Full report: docs/superpowers/specs/2026-10-21-t2mod-m2-report.md.

1. Radio loss and latency work on the real server, proven both ways (12 of 12 checks, 9 unit tests). Same verb names as the simulator.
2. **Ack loss on old code (1.9.107), real Minecraft, 16 parked turtles, 4 game hours: 2.42%** (3747 acks of 3840 beats; thin evidence, 240 beats per turtle). Not the live 11-18%, not T1's 9%. So the live parked loss needs something the test server lacks. I did not fit a loss rate to match it.
3. **5% radio loss kills the three-sector mining job on real Minecraft**: 174 "GPS locate failed" lines, 6 placement_blocked, job permanently failed after 4 sector failures. The same job with no fault: 0 and 0. The loss rule did what it said (4.96% of packets). Question for you, not a guess: does T1's GPS go through the lossy radio? If not, T1's passing radio_loss_5 is not evidence. Separately, a miner that cannot locate itself placed equipment on a guess - that looks like a fleet fragility worth a card.
4. You cannot pin to a commit before 1.9.128 through the real update path (its updater ignores the pinned commit and loops against master). I added `--install <sha>` (file copy onto the computers before boot, report says "copied from").

Next: M3 (chunk unload under a loader).
