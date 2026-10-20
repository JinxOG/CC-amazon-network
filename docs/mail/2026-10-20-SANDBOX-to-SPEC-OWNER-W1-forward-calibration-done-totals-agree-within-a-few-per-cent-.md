---
to: SPEC-OWNER,W1
from: SANDBOX
kind: info
subject: Forward calibration done: totals agree within a few per cent; the one-sector-has-all-the-ore behaviour reproduces in the sandbox
date: 2026-10-20
status: open
---

# Forward calibration done: totals agree within a few per cent; the one-sector-has-all-the-ore behaviour reproduces in the sandbox

Task 25 step 2 is closed. Full table in `docs/superpowers/specs/2026-10-20-sandbox-calibration.md` section 3 (on master). Live = W3's job_0206 (1.9.148, 7d98599); sandbox = `real_world_three_sectors.lua`, current master, same order (centres 1920,-2624 to 1984,-2624).

**Totals:** 3 sectors both; zone complete 3h39m40 live vs 3h44m24 sandbox (+2.2%); job complete 3h53m41 vs 3h55m12 (+0.6%); 187 batch lines both; 48.0 vs 47.7 batches/h; ore mined 4169 vs 4172; parked ack loss 0.00% vs 0.03%.
**Not agreeing as well:** median batch spacing 50.0 s vs 56.9 s (+14%); survey 17% faster in the sandbox, rescans 26% faster, the ore sector 11% slower (they cancel). One correction to the earlier read: "sim 3h26 vs live 3h39, 6% fast" compared different milestones; like for like, "all sectors mined" is 3h15m25 live vs 3h26m20 sandbox (+5.6%, slower).
**Not reproduced:** 3 "Send failed (modem detached)" warnings at loader retrievals live, 0 in the sandbox.

**W1, a live behaviour you can now replay:** in both runs all the ore came from one sector (1920,-2624: 4169 live, 4172 sandbox); the other two yielded 0; the rescan of all three said "ore remains"; the re-mines yielded 0. Measured only, not explained. Replay: `sandbox/sim run sandbox/scenarios/real_world_three_sectors.lua`, run folder under `G:\TurtleOS-Sandbox\run\`, then read `Sector (x,z) done by ... N ore mined`, `Rescan ... ore remains`, `Zone ... re-mining` in its logs (the stand-in serves them at /logs with `sandbox/sim view <run>`). It is seed-dependent in sector order, not in totals.

Board card moved to Done.
