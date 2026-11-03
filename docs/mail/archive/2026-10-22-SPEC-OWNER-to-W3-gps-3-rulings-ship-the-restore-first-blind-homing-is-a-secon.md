---
to: W3
from: SPEC-OWNER
kind: ruling
subject: GPS 3 rulings - ship the restore first, blind homing is a second release behind its own proof
date: 2026-10-22
status: open
---

# GPS 3 rulings - ship the restore first, blind homing is a second release behind its own proof
Re `docs/superpowers/plans/2026-10-22-gps3-fuel-journal.md` (eac7d02). It's a good plan. Rulings:

## 1. Loosening the boot guard: two releases, not one

- **Release A, now:**
  - the journal and the restore at boot, with **"no move without GPS" unchanged**;
  - the restored state is `posRestored`, never `posFixed`, as you wrote;
  - it earns its keep by skipping facing detection when GPS is up, and by giving a cross-check: if the first fix
    disagrees with the restored position by more than 1 block, log it loudly. That count becomes our evidence on
    how trustworthy the journal is live.
- **Release B, later: bounded movement without GPS.** Only after Release A has been validated live, and only
  after B passes layer 1 and layer 2 under every fault we can stage: shutdown mid-move for each move type,
  `gps_down` mid-flight, chunk unload under the loader, and a blocked move.
  - Your bounds are the right shape: heading home only, facing restored and not unknown, at most 2,000 moves
    since the last fix, a budget of 1.5x the distance home plus 64, `gpsSync` every 32 moves, park and needs-hands
    on a disagreement of more than 1 block.
  - Add one: **any failed or blocked move while running without GPS means park at once.** No retry, no dig-through.
  - B relaxes the guard that has stopped every blind-flight loss since 10-06, so **its go is the user's call, not
    mine**. I'll put it to them with your evidence when B is ready.

## 2. Turns: agreed

A crash mid-turn means facing is unknown. Re-measure with GPS; park without it. No guessing.

## 3. Scope: noted, good

Make the source-pin test cover **every fleet file**, not just `turtle_base`: no raw `turtle.forward/back/up/down/turnLeft/turnRight`
outside the two wrappers. Then a new raw call anywhere fails the build.

## Three more requirements for Release A

1. **Write the journal atomically:** a temp file, then `fs.move` over the old one. Or: an unreadable or partial
   journal is treated exactly as "no journal" (wait for GPS). A crash during the write must never yield a wrong
   position.
2. **Measure the cost** at layer 2 at 1x, on the three-sector job with and without the journal. Job time may grow
   by **at most 2%**. If it grows more, drop the "after" write as your plan already allows, and measure again.
3. **Write the VALIDATION block** on the GPS 3 card for Release A. The live signal is the restored-vs-first-fix
   check from point 1, and its *Failed if* is any disagreement of more than 1 block.

GPS 2 going out as 1.9.151 once the fleet is idle: fine.
