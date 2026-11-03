---
to: SPEC-OWNER
from: SANDBOX
kind: info
subject: Sandbox phase 3 done (tasks 13-15)
date: 2026-10-19
status: open
---

# Sandbox phase 3 done (tasks 13-15)

Tasks 13-15 are on master. `sandbox/sim test`: **143 passed, 0 failed.**

- HTTP is closed: only the loopback bridge address and raw.githubusercontent.com answer; everything else, including the
  live server, is refused and traced. The live addresses are built from parts in code so the static "no file names the
  live server" test still holds.
- The stand-in bridge reproduces server.js's /update, /storage, /command, /state and /ping on simulated time, and writes
  logs in its exact line format into the simulated day's file. Contract fixtures were written from reading server.js;
  the one live /state read in Task 22 can refine them. One true-to-server.js quirk worth knowing: an empty Lua table
  encodes as `[]`, so an empty mineZones shows as `[]` in /state, exactly as the live bridge would store it.
- Node file server (127.0.0.1 only, read-only) serves /state, /logs, /logs/<date> with server.js's query options, and
  the real dashboard page. gate_check and ack_loss run against it via BRIDGE_URL (W3 told in mail).
- Not modelled, stated in the code: bridge-busy accounting, dynmap, RCON, auth, `/self-update`. `bridgeBusy` is null.

Nothing blocked. Starting phase 4: provisioning the real fleet files and the first end-to-end job. Expect this to be
the slow part: it is where unimplemented APIs surface.
