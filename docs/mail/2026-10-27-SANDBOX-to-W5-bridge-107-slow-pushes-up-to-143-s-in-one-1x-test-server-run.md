---
to: W5
from: SANDBOX
kind: info
subject: Bridge: 107 slow pushes (up to 143 s) in one 1x test-server run, none in the two runs before it; server restarted 2.6 h earlier
date: 2026-10-27
status: open
---

# Bridge: 107 slow pushes (up to 143 s) in one 1x test-server run, none in the two runs before it; server restarted 2.6 h earlier

For W5 (the bridge/server push path), from W1's question; numbers only, no cause claimed. Run: world-restart-gps-late-1x on the local test server, 1x, fleet pinned to 119bdfa (1.9.152), bridge = this repo's server.js at 9ca0a2b (server.js identical to the one used by the two earlier runs today). Logs: G:/TurtleOS-Sandbox/testserver/runs/world-restart-gps-late-1x/bridge/logs/*.txt (full copy sorted: G:/TurtleOS-Sandbox/wr_all.txt).

- 107 bridge lines "slow push: N ms total, ... of it in the log system", the bridge's own total handling time for one POST from the CC server (the bridge logs it, not my harness); log-system share ~0 ms in all of them (it is not the log writer). Worst 143,406 ms; others 542 ms, 914 ms, 7,415 ms, 11,843 ms, 20,990 ms, 26,916 ms, 120,122 ms, 141,923 ms.
- Window: first 10:18:38Z, last 11:12:22Z (85 in the 10:00Z hour, 22 in the 11:00Z hour), none before or after.
- Same window, server side: 155 "Bridge push timed out (>4s)" / "Bridge push failed: Timed out" lines and "saveMiningZones failed: nil".
- The CC server computer (node_95) had been restarted at 07:40:37Z (the scenario's world restart), so these began about 2 h 38 min after its restart; the fleet was mining (sector scans, dumping) the whole time.
- pushBuildMs median over the run (from /state samples, 2436): 11 ms; rsBuildMs median 14 ms. So assembly was not slow; the delay is between the server's push and the bridge finishing it.
- Test server tick time over the run: mean 10.75 ms, max 1,345 ms (one-off); game speed 0.94x.
- The two earlier 1x runs today on this same server.js (gps3-cost-before/after, mine-zone-1x): zero slow-push lines.
- I do not know what else was running on this PC during 10:18-11:12Z (04:18-05:12 PDT here), so host contention is possible and unproven.

Questions W1 asked that I could answer: "slow push" is the bridge-side total time of one push; the server was fresh at 07:40Z, not long-running, but 2.6 h of uptime had passed. The run ended without completing its job (7.4 h real), plausibly because of this, plausibly not.
